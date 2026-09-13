//
//  AudioSessionSetup.swift
//  AvpViceCity
//
//  Configures the process-wide AVAudioSession BEFORE OpenAL opens its device
//  (which happens later, on the reVC game thread, once the Immersive Space is
//  open). Called from AvpViceCityApp.init() at launch. Without this the app runs
//  on the default session, which anchors audio to the 2D window scene — closing
//  the window then ends the session and the game's audio (and any cutscene that
//  waits on its audio track) stalls.
//

import AVFAudio

enum GameAudioSession {

    /// Configure and activate a playback session that is independent of the 2D
    /// window, and place its sound stage in front (toward the canvas).
    static func configure() {
        let session = AVAudioSession.sharedInstance()

        // .playback is not tied to any window scene, so it survives the 2D window
        // closing — this is the mandatory fix for the audio dying on window close.
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            print("[vc-audio-swift] session active: category=\(session.category.rawValue) route=[\(route)]")
        } catch {
            print("[vc-audio-swift] session config FAILED: \(error)")
        }

        // Spatial stage: head-tracked (world-stable) and anchored to the user's
        // front, where the world-anchored canvas sits. Exact anchoring to the
        // Metal quad isn't possible here — .scene(identifier:) needs a
        // RealityKit/SwiftUI scene id, which a CompositorServices immersive space
        // doesn't expose. Head-locked (.fixed) is the documented fallback.
        do {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
            print("[vc-audio-swift] spatial experience: headTracked(front, large)")
        } catch {
            print("[vc-audio-swift] spatial experience FAILED (system default in effect): \(error)")
        }

        // DIAGNOSE: watch what ends the audio. When the 2D window closes we expect
        // to see either an interruption (began) or a route change here, with the
        // reason — that tells us WHAT stops playback, since openal-soft itself
        // never touches the session.
        AudioSessionMonitor.shared.start()
    }
}

/// Logs AVAudioSession interruption / route-change events with reason and time.
/// Plain NSObject + @objc selectors so notification delivery on any thread is
/// fine (no main-actor isolation assertion).
final class AudioSessionMonitor: NSObject, @unchecked Sendable {
    static let shared = AudioSessionMonitor()

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(onRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        print("[vc-audio-swift] monitoring interruption + routeChange")
    }

    @objc private func onInterruption(_ note: Notification) {
        let info = note.userInfo
        let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0xFFFF
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        let typeStr = (type == .began) ? "began" : (type == .ended) ? "ended" : "raw(\(typeRaw))"
        var reasonStr = ""
        if #available(visionOS 1.0, *), let rRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt {
            reasonStr = " reasonRaw=\(rRaw)"
        }
        print("[vc-audio-swift] INTERRUPTION type=\(typeStr)\(reasonStr) at \(Date())")

        if type == .began {
            // Pause OpenAL's device so it stops driving the (about to be torn down) unit.
            vc_audio_interruption(1)
        } else if type == .ended {
            // Reactivate the session, THEN nudge OpenAL. Measured: the session comes back
            // fine (.playback/[Speaker]) but openal-soft's output AudioUnit stays stopped,
            // so this reset is what actually restores sound after the headset is re-donned.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                print("[vc-audio-swift] reactivate after .ended: OK")
            } catch {
                print("[vc-audio-swift] reactivate after .ended: FAILED \(error)")
            }
            vc_audio_interruption(0)
        }
    }

    @objc private func onRouteChange(_ note: Notification) {
        let info = note.userInfo
        let reasonRaw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0xFFFF
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        let reasonStr = reason.map { "\($0)" } ?? "raw(\(reasonRaw))"
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }.joined(separator: ",")
        print("[vc-audio-swift] ROUTECHANGE reason=\(reasonStr) outputs=[\(outputs)] at \(Date())")
    }
}
