//
//  AppModel.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import SwiftUI
import Metal

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
}

/// Player-facing launch settings, persisted in UserDefaults under the SAME names as the
/// env vars the renderer reads. `applyToEnvironment()` pushes them into the process
/// environment via setenv so the existing consumers pick them up unchanged:
///   VC_HUD_SIZE         -> Renderer.swift `vcHudSize`
///   VC_MSAA             -> visionos_angle.mm `vcMsaaSamples()`
///   VC_RES              -> visionos.cpp `vcScreenInit()` (render resolution per eye, step 0..4)
///   VC_AIM_SENSITIVITY  -> Cam.cpp `vcAimStickScale()` (right-stick aim/look speed, 1.0 = stock)
/// Call once at launch and again right before opening the immersive space.
enum GameSettings {
    static let hudSizeDefault: Double = 0.4
    /// MSAA default per device (multiview-plan.md, device defaults 2026-09-29): M5 measured
    /// with MSAA 4 on the reference route (90 fps open, 84 in the dense centre, CPU-bound
    /// there, not GPU) -> 4. M2 assumed, not measured -> 2. Anything that is not an M2 is
    /// treated as at least as fast as the M5.
    static var msaaDefault: Int { isM2Device ? 2 : 4 }
    /// Apple GPUs (M2 and M5 alike) support sample counts 1, 2 and 4 only; ANGLE Metal
    /// derives GL_MAX_SAMPLES from supportsTextureSampleCount, so 8 is rejected by the
    /// driver and the MSAA setup fails over to no MSAA. Not offered (2026-10-05).
    static let msaaOptions: [Int] = [0, 2, 4]
    static let msaaMax: Int = 4

    /// Device class from the Metal device name ("Apple M2" on the first Vision Pro).
    /// Logged once so a wrong classification is visible in the console.
    static let isM2Device: Bool = {
        let name = MTLCreateSystemDefaultDevice()?.name ?? "?"
        let m2 = name.contains("M2")
        print("[vc-launcher] Metal device '\(name)' -> \(m2 ? "M2 class (MSAA default 2)" : "M5 class or newer (MSAA default 4)")")
        return m2
    }()
    static let resDefault: Int = 4
    static let resOptions: [Int] = [0, 1, 2, 3, 4]
    static let aimSensitivityDefault: Double = 1.0
    /// One-pass stereo (OVR_multiview): both eyes in one world pass. Always on since the
    /// launcher toggle was removed (2026-10-05; default ON since 2026-09-29, every acceptance
    /// since ran with it). Developer fallback: VC_MULTIVIEW=0 in the Xcode scheme is
    /// honoured by applyToEnvironment() and selects the two-pass path.
    static let multiviewForced: Bool = true

    static func hudSize() -> Double { UserDefaults.standard.object(forKey: "VC_HUD_SIZE") as? Double ?? hudSizeDefault }
    /// Stored values above the hardware maximum (an old "8x" choice) are read as the maximum.
    static func msaa() -> Int { min(UserDefaults.standard.object(forKey: "VC_MSAA") as? Int ?? msaaDefault, msaaMax) }
    static func res() -> Int { UserDefaults.standard.object(forKey: "VC_RES") as? Int ?? resDefault }
    static func aimSensitivity() -> Double { UserDefaults.standard.object(forKey: "VC_AIM_SENSITIVITY") as? Double ?? aimSensitivityDefault }

    /// Per-eye pixel dimensions for a VC_RES step, mirroring the ladder in visionos.cpp.
    static func resLabel(_ step: Int) -> String {
        switch step {
        case 0:  return "1920x1080"
        case 1:  return "2200x2100"
        case 2:  return "2450x2350"
        case 3:  return "2600x2500"
        default: return "2720x2624"
        }
    }

    static func applyToEnvironment() {
        setenv("VC_HUD_SIZE", String(format: "%.3f", hudSize()), 1)
        setenv("VC_MSAA", String(msaa()), 1)
        setenv("VC_RES", String(res()), 1)
        setenv("VC_AIM_SENSITIVITY", String(format: "%.2f", aimSensitivity()), 1)
        // Device class for the game side (Frontend.cpp: draw-distance slider ceiling/default,
        // island-loading default). 1 = M2 class (assumed values), 0 = M5 or newer (measured).
        setenv("VC_DEVICE_M2", isM2Device ? "1" : "0", 1)
        // Multiview: always on. KL_GL_MULTIVIEW makes ANGLE advertise GL_OVR_multiview; it
        // is read at EGL display creation, which happens after this call (immersive space
        // -> game start). Developer fallback: VC_MULTIVIEW=0 set in the Xcode scheme (seen
        // in the process environment at launch) keeps the two-pass path and removes the
        // extension so the mono path sees the same GL as before the multiview work.
        // A value stored by the former launcher toggle is dropped so no device stays on
        // two-pass silently.
        UserDefaults.standard.removeObject(forKey: "VC_MULTIVIEW")
        let schemeOff = ProcessInfo.processInfo.environment["VC_MULTIVIEW"] == "0"
        let mv = multiviewForced && !schemeOff
        setenv("VC_MULTIVIEW", mv ? "1" : "0", 1)
        if mv { setenv("KL_GL_MULTIVIEW", "1", 1) } else { unsetenv("KL_GL_MULTIVIEW") }
        if schemeOff { print("[vc-launcher] VC_MULTIVIEW=0 from the scheme -> two-pass fallback") }
    }
}
