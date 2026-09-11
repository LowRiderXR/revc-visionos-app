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
///   VC_HUD_SIZE  -> Renderer.swift `vcHudSize`
///   VC_MSAA      -> visionos_angle.mm `vcMsaaSamples()`
/// Call once at launch and again right before opening the immersive space.
enum GameSettings {
    static let hudSizeDefault: Double = 0.4
    static let msaaDefault: Int = 2
    static let msaaOptions: [Int] = [0, 2, 4, 8]

    static func hudSize() -> Double { UserDefaults.standard.object(forKey: "VC_HUD_SIZE") as? Double ?? hudSizeDefault }
    static func msaa() -> Int { UserDefaults.standard.object(forKey: "VC_MSAA") as? Int ?? msaaDefault }

    static func applyToEnvironment() {
        setenv("VC_HUD_SIZE", String(format: "%.3f", hudSize()), 1)
        setenv("VC_MSAA", String(msaa()), 1)
    }
}
