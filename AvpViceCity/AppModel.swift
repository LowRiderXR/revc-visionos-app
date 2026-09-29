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
    /// MSAA default per device (multiview-plan.md, Gerätestandards 2026-09-29): M5 measured
    /// with MSAA 4 on the reference route (90 fps open, 84 in the dense centre, CPU-bound
    /// there, not GPU) -> 4. M2 assumed, not measured -> 2. Anything that is not an M2 is
    /// treated as at least as fast as the M5.
    static var msaaDefault: Int { isM2Device ? 2 : 4 }
    static let msaaOptions: [Int] = [0, 2, 4, 8]

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
    /// One-pass stereo (OVR_multiview): both eyes in one world pass. Default ON since
    /// 2026-09-29: the long play session (missions, cutscenes, interiors, weather, MSAA 4,
    /// full-speed driving) was clean; the only finding (headlight coronas slightly offset)
    /// is the known sprite family S1, independent of the toggle. The toggle stays as the
    /// way back (multiview-plan.md, Launcher).
    static let multiviewDefault: Bool = true
    static func multiviewSetting() -> Bool? { UserDefaults.standard.object(forKey: "VC_MULTIVIEW") as? Bool }
    static func multiview() -> Bool { multiviewSetting() ?? multiviewDefault }

    static func hudSize() -> Double { UserDefaults.standard.object(forKey: "VC_HUD_SIZE") as? Double ?? hudSizeDefault }
    static func msaa() -> Int { UserDefaults.standard.object(forKey: "VC_MSAA") as? Int ?? msaaDefault }
    static func res() -> Int { UserDefaults.standard.object(forKey: "VC_RES") as? Int ?? resDefault }
    static func aimSensitivity() -> Double { UserDefaults.standard.object(forKey: "VC_AIM_SENSITIVITY") as? Double ?? aimSensitivityDefault }

    /// Per-eye pixel dimensions for a VC_RES step, mirroring the ladder in visionos.cpp.
    static func resLabel(_ step: Int) -> String {
        switch step {
        case 0:  return "1920×1080"
        case 1:  return "2200×2100"
        case 2:  return "2450×2350"
        case 3:  return "2600×2500"
        default: return "2720×2624"
        }
    }

    static func applyToEnvironment() {
        setenv("VC_HUD_SIZE", String(format: "%.3f", hudSize()), 1)
        setenv("VC_MSAA", String(msaa()), 1)
        setenv("VC_RES", String(res()), 1)
        setenv("VC_AIM_SENSITIVITY", String(format: "%.2f", aimSensitivity()), 1)
        // Multiview: the launcher is the single switch (toggle, default ON). It always sets
        // both variables, so the scheme entries for VC_MULTIVIEW/KL_GL_MULTIVIEW no longer
        // decide anything -- A/B runs use the toggle. KL_GL_MULTIVIEW makes ANGLE advertise
        // GL_OVR_multiview; it is read at EGL display creation, which happens after this
        // call (immersive space -> game start). OFF removes it so the mono path sees the
        // same GL as before the whole multiview work.
        let mv = multiview()
        setenv("VC_MULTIVIEW", mv ? "1" : "0", 1)
        if mv { setenv("KL_GL_MULTIVIEW", "1", 1) } else { unsetenv("KL_GL_MULTIVIEW") }
    }
}
