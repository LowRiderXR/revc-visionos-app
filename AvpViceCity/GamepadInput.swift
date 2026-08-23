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

import GameController

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
        // Push a neutral snapshot so a button held at disconnect doesn't stick.
        var zero = vc_gamepad_t()
        vc_set_gamepad_state(&zero)
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            return   // only the extended profile carries the sticks/triggers we need
        }
        current = controller
        controller.handlerQueue = .main   // deliver value changes on the main thread

        print("[vc-input-swift] controller connected: \(controller.vendorName ?? "unknown") "
              + "category=\(controller.productCategory) profile=extendedGamepad")

        gamepad.valueChangedHandler = { [weak self] pad, _ in
            self?.push(pad)
        }
        // Seed the initial state so the game sees a defined snapshot immediately.
        push(gamepad)
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
