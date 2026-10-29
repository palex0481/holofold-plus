import AzaharCore
import CoreMotion
import GameController
import os
import UIKit

/// Physical controllers (MFi, Xbox, PlayStation, Switch Pro, Backbone/Kishi …), keyboards and
/// the gyroscope. Started while a game is on screen.
@MainActor
final class InputManager: ObservableObject {
    static let shared = InputManager()

    /// True once a physical controller has actually been used. Merely being connected is not
    /// enough: the iOS Simulator (and many paired-but-idle pads) always report a gamepad.
    @Published private(set) var hasGamepad = false
    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []
    /// Spatial accessories whose input handlers are set (visionOS 27); kept so the handlers live.
    private var accessories: [AnyObject] = []

    private init() {}

    /// True between start() and stop(): a game is on screen and owns the controllers.
    private(set) var active = false

    /// 3DS buttons whose pressed state a GameController handler last delivered (any thread).
    nonisolated static let handlerHeld = OSAllocatedUnfairLock(initialState: Set<UInt32>())

    func start() {
        active = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attach(n.object as? GCController) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            #if os(visionOS)
            VisionDiag.log("controller disconnected: \((n.object as? GCController)?.vendorName ?? "?")")
            #endif
            Task { @MainActor in
                self?.refreshGamepadState()
                #if os(visionOS)
                self?.rebindTouchpads()
                #endif
            }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attachKeyboard((n.object as? GCKeyboard) ?? GCKeyboard.coalesced) }
        })
        #if os(visionOS)
        VisionDiag.log("game start: \(GCController.controllers().count) controller(s): \(GCController.controllers().map { $0.vendorName ?? "?" }.joined(separator: ", "))")
        if #available(visionOS 27.0, *) {
            VisionDiag.log("game start: \(GCSpatialAccessory.spatialAccessories.count) spatial accessory(ies): \(GCSpatialAccessory.spatialAccessories.map { $0.vendorName ?? "?" }.joined(separator: ", "))")
            GCSpatialAccessory.spatialAccessories.forEach(attachAccessory)
            observers.append(nc.addObserver(forName: .GCSpatialAccessoryDidConnect, object: nil, queue: .main) { [weak self] n in
                guard let accessory = n.object as? GCSpatialAccessory else { return }
                Task { @MainActor in self?.attachAccessory(accessory) }
            })
            observers.append(nc.addObserver(forName: .GCSpatialAccessoryDidDisconnect, object: nil, queue: .main) { n in
                VisionDiag.log("spatial accessory disconnected: \((n.object as? GCSpatialAccessory)?.vendorName ?? "?")")
            })
        }
        #endif
        GCController.controllers().forEach(attach)
        if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
        GCController.startWirelessControllerDiscovery {}
        refreshGamepadState()
        #if !os(visionOS)
        // The headset exposes no device motion or interface orientation to apps; motion
        // controls there come from the controller's own gyro (not wired up yet).
        startMotion()
        updateOrientation()
        observers.append(nc.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOrientation() }
        })
        #endif
    }

    func stop() {
        active = false
        polledHeld.removeAll()
        polledSticks.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        motion.stopDeviceMotionUpdates()
        #if os(visionOS)
        detachMotion()
        if #available(visionOS 27.0, *) {
            for case let accessory as GCSpatialAccessory in accessories { accessory.input?.elementValueDidChangeHandler = nil }
        }
        accessories.removeAll()
        #endif
        az_release_all_input()
        #if os(visionOS)
        for button in touchpadButtons {
            button.pressedChangedHandler = nil
            button.valueChangedHandler = nil
        }
        touchpadButtons.removeAll()
        touchpadDown = false
        #endif
    }

    private func refreshGamepadState() {
        if !GCController.controllers().contains(where: { $0.extendedGamepad != nil || Self.isSpatial($0) }) {
            hasGamepad = false
        }
    }

    private static func isSpatial(_ controller: GCController) -> Bool {
        #if os(visionOS)
        return controller.productCategory == GCProductCategorySpatialController
        #else
        return false
        #endif
    }

    fileprivate func gamepadUsed() {
        if !hasGamepad { hasGamepad = true }
    }

    /// Bind every controller again (the library's navigator hands its pads back after the game
    /// started; whatever it restored must not stay). No-op while no game runs.
    func reattachIfActive(_ reason: String) {
        guard active else { return }
        GCController.controllers().forEach(attach)
        #if os(visionOS)
        VisionDiag.log("input: controllers re-bound (\(reason))")
        #endif
    }

    // MARK: Direct polling (fallback)

    private var polledHeld = Set<UInt32>()
    private var polledSticks: [ObjectIdentifier: SIMD2<Float>] = [:]
    private var lastLostLog = Date.distantPast
    private var lostFrames = 0

    /// Called every frame from the RealityKit pump. Reads each standard gamepad's current state
    /// directly and sends any change to the core, so input reaches the game even if the system
    /// routes events elsewhere or a handler was replaced. Logs frames where a button is down on the
    /// pad but no handler delivered it (the fallback did).
    func pollGamepads() {
        guard active else { return }
        var held = Set<UInt32>()
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad, !(c.vendorName ?? "").contains("VR2 Sense") else { continue }
            func on(_ b: GCControllerButtonInput?, _ button: AZButton) { if b?.isPressed == true { held.insert(button.rawValue) } }
            on(pad.buttonB, AZ_BUTTON_A); on(pad.buttonA, AZ_BUTTON_B)
            on(pad.buttonY, AZ_BUTTON_X); on(pad.buttonX, AZ_BUTTON_Y)
            on(pad.leftShoulder, AZ_BUTTON_L); on(pad.rightShoulder, AZ_BUTTON_R)
            on(pad.leftTrigger, AZ_BUTTON_ZL); on(pad.rightTrigger, AZ_BUTTON_ZR)
            on(pad.buttonMenu, AZ_BUTTON_START); on(pad.buttonOptions, AZ_BUTTON_SELECT)
            on(pad.dpad.up, AZ_BUTTON_UP); on(pad.dpad.down, AZ_BUTTON_DOWN)
            on(pad.dpad.left, AZ_BUTTON_LEFT); on(pad.dpad.right, AZ_BUTTON_RIGHT)
            let id = ObjectIdentifier(pad)
            let stick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            if polledSticks[id] != stick {
                polledSticks[id] = stick
                az_stick(AZ_STICK_CIRCLE_PAD, stick.x, stick.y)
            }
        }
        for raw in held.symmetricDifference(polledHeld) {
            az_button(AZButton(rawValue: raw), held.contains(raw))
        }
        polledHeld = held
        let missed = held.subtracting(Self.handlerHeld.withLock { $0 })
        guard !missed.isEmpty else { return }
        lostFrames += 1
        #if os(visionOS)
        if Date().timeIntervalSince(lastLostLog) > 2 {
            lastLostLog = Date()
            let scenes = UIApplication.shared.connectedScenes.map { "\($0.session.role.rawValue):\($0.activationState.rawValue)" }.joined(separator: ",")
            VisionDiag.log("input LOST: buttons \(missed.sorted()) down on the pad but no handler delivered them (\(lostFrames) frames so far); poll sent them; scenes=[\(scenes)]")
        }
        #endif
    }

    // MARK: Gamepads

    private func attach(_ controller: GCController?) {
        #if os(visionOS)
        if let controller {
            VisionDiag.log("controller: \(controller.vendorName ?? "?") category=\(controller.productCategory) extended=\(controller.extendedGamepad != nil) motion=\(controller.motion != nil)")
        }
        if let controller, controller.productCategory == GCProductCategorySpatialController {
            attachSpatial(controller)
            return
        }
        #endif
        guard let pad = controller?.extendedGamepad else { return }
        controller?.playerIndex = .index1
        func bind(_ input: GCControllerButtonInput?, _ button: AZButton) {
            input?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                InputManager.handlerHeld.withLock { if pressed { $0.insert(button.rawValue) } else { $0.remove(button.rawValue) } }
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        // Nintendo layout by position: the east face button is A, like on a real 3DS.
        bind(pad.buttonB, AZ_BUTTON_A)
        bind(pad.buttonA, AZ_BUTTON_B)
        bind(pad.buttonY, AZ_BUTTON_X)
        bind(pad.buttonX, AZ_BUTTON_Y)
        bind(pad.leftShoulder, AZ_BUTTON_L)
        bind(pad.rightShoulder, AZ_BUTTON_R)
        bind(pad.leftTrigger, AZ_BUTTON_ZL)
        bind(pad.rightTrigger, AZ_BUTTON_ZR)
        bind(pad.buttonMenu, AZ_BUTTON_START)
        bind(pad.buttonOptions, AZ_BUTTON_SELECT)
        bind(pad.buttonHome, AZ_BUTTON_HOME)
        bind(pad.dpad.up, AZ_BUTTON_UP)
        bind(pad.dpad.down, AZ_BUTTON_DOWN)
        bind(pad.dpad.left, AZ_BUTTON_LEFT)
        bind(pad.dpad.right, AZ_BUTTON_RIGHT)
        pad.leftThumbstick.valueChangedHandler = { _, x, y in az_stick(AZ_STICK_CIRCLE_PAD, x, y) }
        pad.rightThumbstick.valueChangedHandler = { _, x, y in az_stick(AZ_STICK_C_STICK, x, y) }
        #if os(visionOS)
        if let controller {
            if (controller.vendorName ?? "").contains("VR2 Sense") { remapSensePair(pad) }
            // The system keeps the PS / Home button for itself (it never reached the app on the
            // device), so holding Options / Menu leaves the game; a short press is still START.
            pad.buttonMenu.pressedChangedHandler = Self.startWithExitHold()
            // The touchpad click is bound only so the system does not take it as a gesture; it
            // toggles nothing. The game window's control bar is look-and-pinch only: no controller
            // button shows, hides or presses it.
            bindTouchpads(on: controller)
            attachMotion(controller)
        }
        #endif
        refreshGamepadState()
    }

    #if os(visionOS)
    /// Touchpad clicks the system did not deliver through pressedChangedHandler. Polled from the
    /// RealityKit pump; the handler and the poll share one rising edge.
    private var touchpadButtons: [GCControllerButtonInput] = []
    private var touchpadDown = false
    private var loggedPhysicalInputs = Set<String>()

    /// Called every compositor pump. visionOS often never fires the touchpad click handler.
    func pollTouchpads() {
        let down = touchpadButtons.contains { $0.isPressed }
        noteTouchpad(down: down, source: "poll")
    }

    private func noteTouchpad(down: Bool, source: String) {
        touchpadDown = down  // no longer toggles the control ornament (L3+R3 does)
    }

    /// Drop buttons from a controller that just disconnected and bind whatever is still there.
    private func rebindTouchpads() {
        touchpadButtons.removeAll()
        touchpadDown = false
        GCController.controllers().forEach { bindTouchpads(on: $0) }
    }

    /// Bind every element that looks like a touchpad click, and stop the system taking the click
    /// as a gesture. Names are logged once per controller so a device log shows what existed.
    private func bindTouchpads(on controller: GCController) {
        let key = "\(controller.vendorName ?? "?")|\(controller.productCategory)"
        if loggedPhysicalInputs.insert(key).inserted {
            let profile = controller.physicalInputProfile
            VisionDiag.log("physical inputs: buttons=[\(profile.buttons.keys.sorted().joined(separator: ","))] dpads=[\(profile.dpads.keys.sorted().joined(separator: ","))]")
        }
        var found: [GCControllerButtonInput] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ button: GCControllerButtonInput?) {
            guard let button else { return }
            guard seen.insert(ObjectIdentifier(button)).inserted else { return }
            found.append(button)
        }
        if let pad = controller.extendedGamepad {
            add((pad as? GCDualSenseGamepad)?.touchpadButton)
            add((pad as? GCDualShockGamepad)?.touchpadButton)
        }
        let profile = controller.physicalInputProfile
        for (name, button) in profile.buttons {
            let lower = name.lowercased()
            if lower.contains("touchpad") || lower.contains("touch pad") || name == GCInputDualShockTouchpadButton {
                add(button)
            }
        }
        for button in found {
            button.preferredSystemGestureState = .disabled
            button.pressedChangedHandler = { _, _, pressed in
                Task { @MainActor in InputManager.shared.noteTouchpad(down: pressed, source: "handler") }
            }
            button.valueChangedHandler = { _, _, pressed in
                Task { @MainActor in InputManager.shared.noteTouchpad(down: pressed, source: "value") }
            }
            if !touchpadButtons.contains(where: { $0 === button }) {
                touchpadButtons.append(button)
            }
        }
        for (name, pad) in profile.dpads where name.lowercased().contains("touch") {
            pad.preferredSystemGestureState = .disabled
        }
        VisionDiag.log("controls toggle: \(found.count) touchpad input(s), class \(type(of: controller.extendedGamepad as Any)), tracked \(touchpadButtons.count), home=\(controller.extendedGamepad?.buttonHome != nil)")
    }

    /// The headset gives apps no device motion, so motion controls come from the controller's own
    /// gyro and accelerometer (DualSense, DualShock 4, Switch Pro …).
    ///
    /// GameController reports them in the controller's frame: x to the right, y toward the bumpers,
    /// z out of the face (Apple's device-frame convention, assumed here and logged on attach so a
    /// device test can confirm it). Holding the pad flat should feel like holding a 3DS upright, so
    /// the vector is turned 90° about x into the frame of a handheld standing upright and facing the
    /// player, which the core takes as CoreMotion portrait (orientation 0).
    private func attachMotion(_ controller: GCController) {
        guard AppSettings.shared.motionControls, let motion = controller.motion else { return }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        az_set_motion_orientation(0)
        let name = controller.vendorName ?? "controller"
        var logged = false
        motion.valueChangedHandler = { m in
            let a: GCAcceleration
            if m.hasGravityAndUserAcceleration {
                a = GCAcceleration(x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y,
                                   z: m.gravity.z + m.userAcceleration.z)
            } else {
                a = m.acceleration
            }
            let r = m.hasRotationRate ? m.rotationRate : GCRotationRate(x: 0, y: 0, z: 0)
            az_motion(Float(a.x), Float(a.z), Float(-a.y), Float(r.x), Float(r.z), Float(-r.y))
            if !logged {
                logged = true
                VisionDiag.log(String(format: "motion: %@ gyro=%d gravity=(%.2f, %.2f, %.2f)", name, m.hasRotationRate ? 1 : 0, a.x, a.y, a.z))
            }
        }
    }

    private func detachMotion() {
        for controller in GCController.controllers() {
            controller.motion?.valueChangedHandler = nil
            if controller.motion?.sensorsRequireManualActivation == true { controller.motion?.sensorsActive = false }
        }
    }
    #endif

    #if os(visionOS)
    /// The PS VR2 Sense pair shows up as one extended gamepad ("PlayStation VR2 Sense Controllers
    /// (L/R)", seen on the device). It has no d-pad, and with the left thumb on the stick the left
    /// face buttons are hard to reach, so on top of the standard layout:
    ///   R2 → Y (same as □: run / fireball), R1 → R, right stick → d-pad (ZR is not mapped).
    private func remapSensePair(_ pad: GCExtendedGamepad) {
        func bind(_ input: GCControllerButtonInput?, _ button: AZButton) {
            input?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        bind(pad.rightTrigger, AZ_BUTTON_Y)
        bind(pad.rightShoulder, AZ_BUTTON_R)
        pad.rightThumbstick.valueChangedHandler = Self.stickAsDpad()
        VisionDiag.log("PS VR2 Sense pair: R2→Y, R1→R, right stick→d-pad")
    }

    #if os(visionOS)
    private static func toggleControls(_ source: String) {
        Task { @MainActor in
            VisionDiag.log("controls toggle pressed: \(source)")
            NotificationCenter.default.post(name: .bifoldToggleControls, object: nil)
        }
    }
    #endif

    /// START on press; held for 1.2 s it asks the game window to exit.
    private static func startWithExitHold() -> GCControllerButtonValueChangedHandler {
        var hold: Task<Void, Never>?
        return { _, _, pressed in
            az_button(AZ_BUTTON_START, pressed)
            hold?.cancel()
            hold = nil
            guard pressed else { return }
            Task { @MainActor in InputManager.shared.gamepadUsed() }
            hold = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                VisionDiag.log("exit: Options held")
                NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
            }
        }
    }

    /// A stick as a digital d-pad with a dead zone, so menus step one item at a time.
    private static func stickAsDpad() -> GCControllerDirectionPadValueChangedHandler {
        var held = Set<UInt32>()
        return { _, x, y in
            let threshold: Float = 0.5
            var now = Set<UInt32>()
            if y > threshold { now.insert(AZ_BUTTON_UP.rawValue) }
            if y < -threshold { now.insert(AZ_BUTTON_DOWN.rawValue) }
            if x < -threshold { now.insert(AZ_BUTTON_LEFT.rawValue) }
            if x > threshold { now.insert(AZ_BUTTON_RIGHT.rawValue) }
            for raw in now.symmetricDifference(held) {
                az_button(AZButton(rawValue: raw), now.contains(raw))
            }
            if !now.isEmpty, held.isEmpty { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            held = now
        }
    }

    /// A PS VR2 Sense controller that reaches the app only as a spatial accessory (visionOS 27):
    /// the left one never showed up as a GCController in one device run while the right one did.
    /// Same layout as attachSpatial, read through the accessory's physical input. Which hand comes
    /// from the "(L)"/"(R)" in its name, else from its face buttons.
    @available(visionOS 27.0, *)
    private func attachAccessory(_ accessory: GCSpatialAccessory) {
        guard let input = accessory.input else {
            VisionDiag.log("spatial accessory without input: \(accessory.vendorName ?? "?")")
            return
        }
        accessories.append(accessory)
        let name = accessory.vendorName ?? ""
        var right = name.contains("(R)")
        var startHold: Task<Void, Never>?
        var dpadHeld = Set<UInt32>()
        var logged = false
        input.elementValueDidChangeHandler = { _, element in
            let aliases = element.aliases
            func has(_ alias: String) -> Bool { aliases.contains(alias) }
            if !name.contains("(L)"), !name.contains("(R)"), has("Button A") || has("Button B") { right = true }
            if !logged {
                logged = true
                VisionDiag.log("spatial accessory input from \(name): \(aliases.sorted().joined(separator: ","))")
            }
            if let pad = element as? GCDirectionPadElement {
                let v = pad.xyAxes.value
                if right {
                    let t: Float = 0.5
                    var now = Set<UInt32>()
                    if v.y > t { now.insert(AZ_BUTTON_UP.rawValue) }
                    if v.y < -t { now.insert(AZ_BUTTON_DOWN.rawValue) }
                    if v.x < -t { now.insert(AZ_BUTTON_LEFT.rawValue) }
                    if v.x > t { now.insert(AZ_BUTTON_RIGHT.rawValue) }
                    for raw in now.symmetricDifference(dpadHeld) { az_button(AZButton(rawValue: raw), now.contains(raw)) }
                    dpadHeld = now
                } else {
                    az_stick(AZ_STICK_CIRCLE_PAD, v.x, v.y)
                }
                return
            }
            guard let button = element as? GCButtonElement else { return }
            let pressed = button.pressedInput.isPressed
            let target: AZButton?
            if has("Button Menu") || has("Button Options") || has("Button Share") {
                if right {
                    az_button(AZ_BUTTON_START, pressed)
                    startHold?.cancel()
                    startHold = pressed ? Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        guard !Task.isCancelled else { return }
                        VisionDiag.log("exit: Options held (accessory)")
                        NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
                    } : nil
                    return
                }
                target = AZ_BUTTON_SELECT
            } else if has("Button A") {
                target = AZ_BUTTON_B
            } else if has("Button B") {
                target = AZ_BUTTON_A
            } else if has("Button X") {
                target = AZ_BUTTON_Y
            } else if has("Button Y") {
                target = AZ_BUTTON_X
            } else if has("Trigger") {
                target = right ? AZ_BUTTON_Y : AZ_BUTTON_L
            } else if has("Grip") {
                target = right ? AZ_BUTTON_R : AZ_BUTTON_ZL
            } else {
                target = nil
            }
            if let target {
                az_button(target, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        VisionDiag.log("spatial accessory attached: \(name) as \(right ? "right" : "left")")
    }

    /// PlayStation VR2 Sense controllers connected one by one (each a "Spatial Controller"; seen
    /// on the device when only the right one was on). No d-pad.
    ///   left:  stick → circle pad, △ X, □ Y, trigger (L2) L, L1 ZL, create SELECT
    ///   right: stick → d-pad, ○ A, ✕ B, trigger (R2) Y (= □, so skills need no left button),
    ///          R1 R, options START (hold: exit game)
    /// Which hand: the right one reports A/B (✕/○), the left one X/Y (□/△).
    private func attachSpatial(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        let isRight = profile.buttons[GCInputButtonA] != nil || profile.buttons[GCInputButtonB] != nil
        func bind(_ name: String, _ button: AZButton) {
            profile.buttons[name]?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        if isRight {
            bind(GCInputButtonB, AZ_BUTTON_A)
            bind(GCInputButtonA, AZ_BUTTON_B)
            bind(__GCInputButtonName.trigger.rawValue, AZ_BUTTON_Y)
            bind(__GCInputButtonName.gripButton.rawValue, AZ_BUTTON_R)
            profile.buttons[GCInputButtonMenu]?.pressedChangedHandler = Self.startWithExitHold()
            profile.buttons[GCInputButtonOptions]?.pressedChangedHandler = Self.startWithExitHold()
            profile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.valueChangedHandler = Self.stickAsDpad()
        } else {
            bind(GCInputButtonY, AZ_BUTTON_X)
            bind(GCInputButtonX, AZ_BUTTON_Y)
            bind(__GCInputButtonName.trigger.rawValue, AZ_BUTTON_L)
            bind(__GCInputButtonName.gripButton.rawValue, AZ_BUTTON_ZL)
            bind(GCInputButtonShare, AZ_BUTTON_SELECT)
            bind(GCInputButtonOptions, AZ_BUTTON_SELECT)
            profile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.valueChangedHandler = { _, x, y in
                az_stick(AZ_STICK_CIRCLE_PAD, x, y)
            }
        }
        VisionDiag.log("PS VR2 Sense (\(isRight ? "right" : "left")) buttons=\(profile.buttons.keys.sorted().joined(separator: ",")) dpads=\(profile.dpads.keys.sorted().joined(separator: ","))")
    }
    #endif

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let kb = keyboard?.keyboardInput else { return }
        let map: [GCKeyCode: AZButton] = [
            .keyX: AZ_BUTTON_A, .keyZ: AZ_BUTTON_B, .keyS: AZ_BUTTON_X, .keyA: AZ_BUTTON_Y,
            .keyQ: AZ_BUTTON_L, .keyW: AZ_BUTTON_R, .one: AZ_BUTTON_ZL, .two: AZ_BUTTON_ZR,
            .returnOrEnter: AZ_BUTTON_START, .rightShift: AZ_BUTTON_SELECT, .keyH: AZ_BUTTON_HOME,
            .upArrow: AZ_BUTTON_UP, .downArrow: AZ_BUTTON_DOWN, .leftArrow: AZ_BUTTON_LEFT, .rightArrow: AZ_BUTTON_RIGHT,
        ]
        var stickKeys = Set<GCKeyCode>()
        kb.keyChangedHandler = { _, _, code, pressed in
            if let b = map[code] {
                az_button(b, pressed)
                return
            }
            let stickCodes: [GCKeyCode] = [.keyI, .keyJ, .keyK, .keyL]
            guard stickCodes.contains(code) else { return }
            if pressed { stickKeys.insert(code) } else { stickKeys.remove(code) }
            let x: Float = (stickKeys.contains(.keyL) ? 1 : 0) - (stickKeys.contains(.keyJ) ? 1 : 0)
            let y: Float = (stickKeys.contains(.keyI) ? 1 : 0) - (stickKeys.contains(.keyK) ? 1 : 0)
            az_stick(AZ_STICK_CIRCLE_PAD, x, y)
        }
    }

    // MARK: Motion

    #if !os(visionOS)
    private func startMotion() {
        guard AppSettings.shared.motionControls, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: OperationQueue()) { data, _ in
            guard let d = data else { return }
            let g = d.gravity, a = d.userAcceleration, r = d.rotationRate
            az_motion(Float(g.x + a.x), Float(g.y + a.y), Float(g.z + a.z),
                      Float(r.x), Float(r.y), Float(r.z))
        }
    }

    private func updateOrientation() {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
        switch orientation {
        case .landscapeRight: az_set_motion_orientation(1) // home indicator on the right
        case .portraitUpsideDown: az_set_motion_orientation(2)
        case .landscapeLeft: az_set_motion_orientation(3)
        default: az_set_motion_orientation(0)
        }
    }
    #endif
}

extension Notification.Name {
    /// A controller's PS / Home button: the game window closes the game (visionOS).
    static let bifoldExitGame = Notification.Name("BifoldExitGame")
    static let bifoldToggleControls = Notification.Name("BifoldToggleControls")
}
