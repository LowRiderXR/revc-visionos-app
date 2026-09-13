//
//  AppModel.swift
//  AvpViceCity
//
//  Created by Christian Schmid on 10.08.2026.
//

import SwiftUI

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
    static let msaaDefault: Int = 2
    static let msaaOptions: [Int] = [0, 2, 4, 8]
    static let resDefault: Int = 4
    static let resOptions: [Int] = [0, 1, 2, 3, 4]
    static let aimSensitivityDefault: Double = 1.0

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
    }
}
