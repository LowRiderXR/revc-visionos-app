//
//  GamepadInput.swift
//  AvpViceCity
//
//  Reads an extended gamepad via GameController.framework and pushes each change
//  across the C boundary (vc_set_gamepad_state). Event-driven only: the
//  extendedGamepad valueChangedHandler fills a snapshot and hands it over — no
//  per-frame polling, the render loop is untouched. The C side buffers the
//  snapshot under a mutex; the game thread reads it in CapturePad.
//
//  The other direction, vibration: reVC reports the motor strength on the game
//  thread via vc_set_gamepad_rumble (VCPlatform.h); GamepadRumble below plays it on
//  the controller's CHHapticEngine from its own serial queue.
//

import CoreHaptics
import GameController
import UIKit

/// Owns the GameController observation. Everything here runs on the main thread:
/// GCController delivers connect/disconnect notifications on the main queue and
/// invokes valueChangedHandler on handlerQueue (which we pin to .main). Button
/// logging lives on the C side; here we only log connect once.
final class GamepadInput: NSObject, @unchecked Sendable {
    static let shared = GamepadInput()

    private var current: GCController?

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(controllerDidConnect(_:)),
                       name: .GCControllerDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(controllerDidDisconnect(_:)),
                       name: .GCControllerDidDisconnect, object: nil)

        // App lifecycle: no vibration while in the background; the kept strength is
        // re-applied on return (the game thread keeps running meanwhile).
        nc.addObserver(self, selector: #selector(appDidEnterBackground(_:)),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground(_:)),
                       name: UIApplication.willEnterForegroundNotification, object: nil)

        // Controllers already paired/connected at launch.
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    @objc private func controllerDidConnect(_ note: Notification) {
        if let controller = note.object as? GCController {
            attach(controller)
        }
    }

    @objc private func controllerDidDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController, controller === current else { return }
        current = nil
        GamepadRumble.shared.detach()
        // Push a neutral snapshot so a button held at disconnect doesn't stick.
        var zero = vc_gamepad_t()
        vc_set_gamepad_state(&zero)
    }

    @objc private func appDidEnterBackground(_ note: Notification) {
        GamepadRumble.shared.setInBackground(true)
    }

    @objc private func appWillEnterForeground(_ note: Notification) {
        GamepadRumble.shared.setInBackground(false)
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            return   // only the extended profile carries the sticks/triggers we need
        }
        current = controller
        controller.handlerQueue = .main   // deliver value changes on the main thread

        print("[vc-input-swift] controller connected: \(controller.vendorName ?? "unknown") "
              + "category=\(controller.productCategory) profile=extendedGamepad")

        reportType(controller, gamepad)
        GamepadRumble.shared.attach(controller)   // also handles a switch to another controller

        gamepad.valueChangedHandler = { [weak self] pad, _ in
            self?.push(pad)
        }
        // Seed the initial state so the game sees a defined snapshot immediately.
        push(gamepad)
    }

    /// Controller type for the game's menu picture and in-game button icons, from the
    /// class of the extended profile (the reliable signal; productCategory strings vary).
    /// DualSense has no picture of its own in the game, the DualShock 4 one is the
    /// nearest. Anything unknown is reported as Xbox One: its A/B/X/Y names are the GC
    /// profile's own names. Sent on every attach, i.e. on connect and on every switch to
    /// another controller.
    private func reportType(_ controller: GCController, _ gp: GCExtendedGamepad) {
        let type: vc_gamepad_type_t
        let name: String
        if gp is GCDualSenseGamepad || gp is GCDualShockGamepad {
            type = VC_GAMEPAD_DUALSHOCK4; name = "DualShock 4 / DualSense"
        } else if gp is GCXboxGamepad {
            type = VC_GAMEPAD_XBOXONE; name = "Xbox"
        } else if (controller.vendorName ?? "").localizedCaseInsensitiveContains("nintendo")
                    || controller.productCategory.localizedCaseInsensitiveContains("switch") {
            type = VC_GAMEPAD_SWITCH; name = "Nintendo Switch"
        } else {
            type = VC_GAMEPAD_XBOXONE; name = "generic -> Xbox layout"
        }
        vc_set_gamepad_type(Int32(type.rawValue))
        print("[vc-input-swift] gamepad type: \(name) (\(type.rawValue))")
    }

    /// Fill a vc_gamepad_t from the extended profile and hand it to the C side.
    /// Signs are passed through unchanged: the seam documents up = +1 (the
    /// GCController convention); the reVC skeleton converts to its own sign.
    private func push(_ gp: GCExtendedGamepad) {
        var s = vc_gamepad_t()

        s.left_x  = gp.leftThumbstick.xAxis.value
        s.left_y  = gp.leftThumbstick.yAxis.value
        s.right_x = gp.rightThumbstick.xAxis.value
        s.right_y = gp.rightThumbstick.yAxis.value

        s.left_trigger  = gp.leftTrigger.value
        s.right_trigger = gp.rightTrigger.value

        s.south = gp.buttonA.isPressed ? 1 : 0
        s.east  = gp.buttonB.isPressed ? 1 : 0
        s.west  = gp.buttonX.isPressed ? 1 : 0
        s.north = gp.buttonY.isPressed ? 1 : 0

        s.dpad_up    = gp.dpad.up.isPressed    ? 1 : 0
        s.dpad_down  = gp.dpad.down.isPressed  ? 1 : 0
        s.dpad_left  = gp.dpad.left.isPressed  ? 1 : 0
        s.dpad_right = gp.dpad.right.isPressed ? 1 : 0

        s.left_shoulder  = gp.leftShoulder.isPressed  ? 1 : 0
        s.right_shoulder = gp.rightShoulder.isPressed ? 1 : 0

        s.left_thumb  = (gp.leftThumbstickButton?.isPressed  ?? false) ? 1 : 0
        s.right_thumb = (gp.rightThumbstickButton?.isPressed ?? false) ? 1 : 0

        s.menu    = gp.buttonMenu.isPressed ? 1 : 0
        s.options = (gp.buttonOptions?.isPressed ?? false) ? 1 : 0

        vc_set_gamepad_state(&s)
    }
}

/// Controller vibration. reVC reports the motor strength (0..1, ShakeFreq/255) on the
/// game thread via vc_set_gamepad_rumble; every call here only enqueues onto one serial
/// queue, which owns the CHHapticEngine of the current controller's handles.
///
/// Output model, as SDL does it for MFi controllers: ONE continuous haptic event whose
/// strength follows the game through the dynamic parameter hapticIntensityControl.
/// Started when the strength becomes > 0, stopped at 0. The event's duration is
/// GCHapticDurationInfinite -- the GameController constant documented for exactly this
/// ("create an infinite haptic event that you update in a loop to adjust a controller's
/// motor intensity"), which sidesteps CoreHaptics' 30 s ceiling for finite continuous
/// events, so no restart is needed for long vibrations.
///
/// Suspension: while the layer is paused (Digital Crown, home view) or the app is in the
/// background, the player is stopped but the game's strength is kept and re-applied on
/// return -- the game thread keeps running during that time and would otherwise buzz
/// into the void. The engine's stoppedHandler / resetHandler clear the state and
/// rebuild on demand. Controllers without haptics log once and stay silent.
nonisolated final class GamepadRumble: @unchecked Sendable {
    static let shared = GamepadRumble()

    private let queue = DispatchQueue(label: "vc.gamepad.rumble")

    // Queue-confined state.
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var engineRunning = false
    private var playing = false
    private var intensity: Float = 0          // last strength reported by the game
    private var layerPaused = false
    private var inBackground = false
    private var controllerName = ""

    // MARK: Host-side hooks

    /// New or switched controller (main thread): tear down the previous engine and
    /// create one for this controller's handles.
    func attach(_ controller: GCController) {
        let name = controller.vendorName ?? "unknown"
        nonisolated(unsafe) let haptics = controller.haptics   // handed to the queue once, used only there
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.controllerName = name
            guard let haptics else {
                print("[vc-haptics] controller without haptics: \(name)")
                return
            }
            guard let engine = haptics.createEngine(withLocality: .default) else {
                print("[vc-haptics] no haptic engine for \(name)")
                return
            }
            engine.playsHapticsOnly = true
            engine.stoppedHandler = { [weak self, weak engine] reason in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, let engine, engine === self.engine else { return }   // not a stale engine
                    self.engineStopped(reason)
                }
            }
            engine.resetHandler = { [weak self, weak engine] in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, let engine, engine === self.engine else { return }
                    self.engineReset()
                }
            }
            self.engine = engine
            self.apply()
        }
    }

    func detach() {
        queue.async { self.teardown() }
    }

    /// From the game thread (vc_set_gamepad_rumble). Enqueue only; never blocks.
    func setIntensity(_ value: Float) {
        let v = max(0, min(1, value))
        queue.async {
            guard v != self.intensity else { return }
            self.intensity = v
            self.apply()
        }
    }

    /// Render loop: layer paused / running again.
    func setLayerPaused(_ paused: Bool) {
        queue.async {
            self.layerPaused = paused
            self.apply()
        }
    }

    /// App lifecycle: background / foreground.
    func setInBackground(_ background: Bool) {
        queue.async {
            self.inBackground = background
            self.apply()
        }
    }

    /// Right before exit(0): stop synchronously and give the stop a moment to reach the
    /// controller, so it is not left buzzing when the process disappears.
    func stopForExit() {
        queue.sync {
            let wasPlaying = self.playing
            self.teardown()
            if wasPlaying { usleep(50_000) }
        }
    }

    // MARK: Queue-confined

    private var wantsOutput: Bool { intensity > 0 && !layerPaused && !inBackground }

    private func apply() {
        guard let engine else { return }
        if !wantsOutput {
            if playing, let player {
                try? player.stop(atTime: CHHapticTimeImmediate)
                playing = false
            }
            return
        }
        if !engineRunning {
            do {
                try engine.start()
                engineRunning = true
                print("[vc-haptics] engine started (\(controllerName))")
            } catch {
                print("[vc-haptics] engine start failed: \(error)")
                return
            }
        }
        if player == nil {
            player = makePlayer(engine)
        }
        guard let player else { return }
        do {
            let strength = CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                    value: intensity, relativeTime: 0)
            try player.sendParameters([strength], atTime: CHHapticTimeImmediate)
            if !playing {
                try player.start(atTime: CHHapticTimeImmediate)
                playing = true
            }
        } catch {
            print("[vc-haptics] player failed: \(error)")
            playing = false
        }
    }

    private func makePlayer(_ engine: CHHapticEngine) -> CHHapticPatternPlayer? {
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [
                                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                                      ],
                                      relativeTime: 0,
                                      duration: TimeInterval(GCHapticDurationInfinite))
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            return try engine.makePlayer(with: pattern)
        } catch {
            print("[vc-haptics] pattern failed: \(error)")
            return nil
        }
    }

    private func engineStopped(_ reason: CHHapticEngine.StoppedReason) {
        engineRunning = false
        playing = false
        player = nil
        print("[vc-haptics] engine stopped (reason \(reason.rawValue))")
        // Not restarted here: the next strength > 0 (or resume) starts it again in apply().
    }

    private func engineReset() {
        engineRunning = false
        playing = false
        player = nil
        print("[vc-haptics] engine reset")
        apply()   // restart on demand and re-apply the kept strength
    }

    private func teardown() {
        if playing, let player {
            try? player.stop(atTime: CHHapticTimeImmediate)
        }
        playing = false
        player = nil
        if let engine {
            engine.stoppedHandler = { _ in }
            engine.resetHandler = { }
            if engineRunning { engine.stop() }
        }
        engineRunning = false
        engine = nil
        controllerName = ""
    }
}

/// C entry point for reVC (VCPlatform.h). Game thread; enqueues only.
@_cdecl("vc_set_gamepad_rumble")
nonisolated func vc_set_gamepad_rumble(_ intensity: Float) {
    GamepadRumble.shared.setIntensity(intensity)
}
