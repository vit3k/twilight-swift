import CLibMoonlight
import Cocoa
import CoreVideo
import Metal
import MetalKit
import QuartzCore

// MARK: - Keyboard Mapping

/// Maps macOS virtual key codes to Windows virtual key codes
/// Reference: https://developer.apple.com/documentation/appkit/1535851-key_codes
private func macKeyCodeToWindowsVK(_ keyCode: UInt16) -> Int16 {
    switch keyCode {
    // Letters (A-Z)
    case 0: return 0x41  // A
    case 11: return 0x42  // B
    case 8: return 0x43  // C
    case 2: return 0x44  // D
    case 14: return 0x45  // E
    case 3: return 0x46  // F
    case 5: return 0x47  // G
    case 4: return 0x48  // H
    case 34: return 0x49  // I
    case 38: return 0x4A  // J
    case 40: return 0x4B  // K
    case 37: return 0x4C  // L
    case 46: return 0x4D  // M
    case 45: return 0x4E  // N
    case 31: return 0x4F  // O
    case 35: return 0x50  // P
    case 12: return 0x51  // Q
    case 15: return 0x52  // R
    case 1: return 0x53  // S
    case 17: return 0x54  // T
    case 32: return 0x55  // U
    case 9: return 0x56  // V
    case 13: return 0x57  // W
    case 7: return 0x58  // X
    case 16: return 0x59  // Y
    case 6: return 0x5A  // Z

    // Numbers (0-9)
    case 29: return 0x30  // 0
    case 18: return 0x31  // 1
    case 19: return 0x32  // 2
    case 20: return 0x33  // 3
    case 21: return 0x34  // 4
    case 23: return 0x35  // 5
    case 22: return 0x36  // 6
    case 26: return 0x37  // 7
    case 28: return 0x38  // 8
    case 25: return 0x39  // 9

    // Function keys
    case 122: return 0x70  // F1
    case 120: return 0x71  // F2
    case 99: return 0x72  // F3
    case 118: return 0x73  // F4
    case 96: return 0x74  // F5
    case 97: return 0x75  // F6
    case 98: return 0x76  // F7
    case 100: return 0x77  // F8
    case 101: return 0x78  // F9
    case 109: return 0x79  // F10
    case 103: return 0x7A  // F11
    case 111: return 0x7B  // F12

    // Special keys
    case 36: return 0x0D  // Return
    case 48: return 0x09  // Tab
    case 49: return 0x20  // Space
    case 51: return 0x08  // Delete (Backspace)
    case 53: return 0x1B  // Escape
    case 76: return 0x0D  // Enter (numpad)

    // Arrow keys
    case 123: return 0x25  // Left
    case 124: return 0x27  // Right
    case 125: return 0x28  // Down
    case 126: return 0x26  // Up

    // Modifier keys
    case 55: return 0x5B  // Command (Left Windows)
    case 54: return 0x5C  // Right Command (Right Windows)
    case 56: return 0xA0  // Left Shift
    case 60: return 0xA1  // Right Shift
    case 59: return 0xA2  // Left Control
    case 62: return 0xA3  // Right Control
    case 58: return 0xA4  // Left Alt/Option
    case 61: return 0xA5  // Right Alt/Option

    // Editing keys
    case 117: return 0x2E  // Forward Delete
    case 115: return 0x24  // Home
    case 119: return 0x23  // End
    case 116: return 0x21  // Page Up
    case 121: return 0x22  // Page Down

    // Symbols
    case 27: return 0xBD  // Minus
    case 24: return 0xBB  // Equals
    case 33: return 0xDB  // Left bracket
    case 30: return 0xDD  // Right bracket
    case 41: return 0xBA  // Semicolon
    case 39: return 0xDE  // Quote
    case 42: return 0xDC  // Backslash
    case 43: return 0xBC  // Comma
    case 47: return 0xBE  // Period
    case 44: return 0xBF  // Slash
    case 50: return 0xC0  // Grave/tilde

    // Numpad
    case 82: return 0x60  // Numpad 0
    case 83: return 0x61  // Numpad 1
    case 84: return 0x62  // Numpad 2
    case 85: return 0x63  // Numpad 3
    case 86: return 0x64  // Numpad 4
    case 87: return 0x65  // Numpad 5
    case 88: return 0x66  // Numpad 6
    case 89: return 0x67  // Numpad 7
    case 91: return 0x68  // Numpad 8
    case 92: return 0x69  // Numpad 9
    case 65: return 0x6E  // Decimal
    case 67: return 0x6A  // Multiply
    case 69: return 0x6B  // Add
    case 78: return 0x6D  // Subtract
    case 75: return 0x6F  // Divide
    case 71: return 0x90  // Num Lock

    default: return 0x00  // Unknown key
    }
}

/// Converts macOS modifier flags to Moonlight modifier flags
private func convertModifierFlags(_ flags: NSEvent.ModifierFlags) -> Int8 {
    var modifiers: Int8 = 0

    if flags.contains(.shift) {
        modifiers |= Int8(MODIFIER_SHIFT)
    }
    if flags.contains(.control) {
        modifiers |= Int8(MODIFIER_CTRL)
    }
    if flags.contains(.option) {
        modifiers |= Int8(MODIFIER_ALT)
    }
    if flags.contains(.command) {
        modifiers |= Int8(MODIFIER_META)
    }

    return modifiers
}

// MARK: - Metal View

private class MetalView: NSView {
    var metalLayer: CAMetalLayer!
    weak var windowManager: WindowManager?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetalLayer()
    }

    private func setupMetalLayer() {
        wantsLayer = true
        metalLayer = CAMetalLayer()
        layer = metalLayer

        // Set scale to match the display's backing scale factor (supports Retina displays)
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Capture mouse when clicking on the window (if not already captured)
        if let windowManager = windowManager, !windowManager.isMouseCaptured {
            windowManager.captureMouseAndKeyboard()
        }
    }
}

// MARK: - Window Delegate Helper

private class WindowDelegateHelper: NSObject, NSWindowDelegate {
    weak var windowManager: WindowManager?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init()
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        windowManager?.releaseMouseAndKeyboard()
        windowManager?.setShouldClose()
    }

    @MainActor
    func windowDidResignKey(_ notification: Notification) {
        // Release mouse when window loses focus
        if windowManager?.isMouseCaptured == true {
            windowManager?.releaseMouseAndKeyboard()
        }
    }
}

// MARK: - Window Manager

@MainActor
class WindowManager {
    internal let window: NSWindow
    private let metalView: MetalView
    internal private(set) var shouldClose = false

    // Mouse handling
    private var mouseEventMonitor: Any?
    private var mouseButtonMonitor: Any?
    private var scrollEventMonitor: Any?
    private var keyboardEventMonitor: Any?
    fileprivate var isMouseCaptured = false

    // Window delegate
    private var windowDelegate: WindowDelegateHelper?

    internal var metalLayer: CAMetalLayer {
        return metalView.metalLayer
    }

    internal var isVisible: Bool {
        return window.isVisible
    }

    fileprivate func setShouldClose() {
        shouldClose = true
    }

    init?(width: Int, height: Int, title: String) {
        // Initialize NSApplication - required for window to appear in dock/taskbar
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Create window
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]

        self.window = NSWindow(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()

        // Create Metal view
        self.metalView = MetalView(frame: frame)
        metalView.windowManager = self

        window.contentView = metalView
        window.makeKeyAndOrderFront(nil)
        window.makeMain()

        // Make the view first responder to receive mouse events
        window.makeFirstResponder(metalView)

        // Set up window delegate to handle window events
        windowDelegate = WindowDelegateHelper(windowManager: self)
        window.delegate = windowDelegate

        print("Window manager created successfully")
    }

    func captureMouseAndKeyboard() {
        guard !isMouseCaptured else { return }

        // Hide cursor
        NSCursor.hide()

        // Disassociate mouse and cursor (allows reading mouse deltas without cursor movement)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(truncating: 0))

        // Monitor mouse movement
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { event in
            let deltaX = Int16(event.deltaX)
            let deltaY = Int16(event.deltaY)

            // Send relative mouse movement to server
            LiSendMouseMoveEvent(deltaX, deltaY)

            return event
        }

        // Monitor mouse button events
        mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
            .otherMouseUp,
        ]) { event in
            let action: Int8
            let button: Int32

            switch event.type {
            case .leftMouseDown:
                action = Int8(BUTTON_ACTION_PRESS)
                button = BUTTON_LEFT
            case .leftMouseUp:
                action = Int8(BUTTON_ACTION_RELEASE)
                button = BUTTON_LEFT
            case .rightMouseDown:
                action = Int8(BUTTON_ACTION_PRESS)
                button = BUTTON_RIGHT
            case .rightMouseUp:
                action = Int8(BUTTON_ACTION_RELEASE)
                button = BUTTON_RIGHT
            case .otherMouseDown:
                action = Int8(BUTTON_ACTION_PRESS)
                // Map other buttons (middle, X1, X2)
                button =
                    event.buttonNumber == 2
                    ? BUTTON_MIDDLE : (event.buttonNumber == 3 ? BUTTON_X1 : BUTTON_X2)
            case .otherMouseUp:
                action = Int8(BUTTON_ACTION_RELEASE)
                button =
                    event.buttonNumber == 2
                    ? BUTTON_MIDDLE : (event.buttonNumber == 3 ? BUTTON_X1 : BUTTON_X2)
            default:
                return event
            }

            LiSendMouseButtonEvent(action, button)
            return event
        }

        // Monitor scroll events
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.hasPreciseScrollingDeltas {
                // High-resolution scrolling (trackpad)
                LiSendHighResScrollEvent(Int16(event.scrollingDeltaY))

                // Handle horizontal scroll if non-zero
                if event.scrollingDeltaX != 0 {
                    LiSendHighResHScrollEvent(Int16(event.scrollingDeltaX))
                }
            } else {
                // Standard mouse wheel
                let scrollAmount = Int8(clamping: Int(event.scrollingDeltaY))
                LiSendScrollEvent(scrollAmount)

                if event.scrollingDeltaX != 0 {
                    let hScrollAmount = Int8(clamping: Int(event.scrollingDeltaX))
                    LiSendHScrollEvent(hScrollAmount)
                }
            }

            return event
        }

        // Monitor keyboard events
        keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged,
        ]) { [weak self] event in
            guard let self = self else { return event }

            // Special handling for Shift+Ctrl+Option+Q to exit
            if event.type == .keyDown && event.keyCode == 12  // Q key
                && event.modifierFlags.contains(.shift) && event.modifierFlags.contains(.control)
                && event.modifierFlags.contains(.option)
            {
                return nil
            }

            // Special handling for Shift+Ctrl+Option+M to toggle mouse capture
            if event.type == .keyDown && event.keyCode == 46  // M key
                && event.modifierFlags.contains(.shift) && event.modifierFlags.contains(.control)
                && event.modifierFlags.contains(.option)
            {
                Task { @MainActor in
                    if self.isMouseCaptured {
                        self.releaseMouseAndKeyboard()
                    } else {
                        self.captureMouseAndKeyboard()
                    }
                }
                return nil
            }

            // Handle regular keys
            let windowsVK = macKeyCodeToWindowsVK(event.keyCode)
            if windowsVK != 0 {
                let keyAction: Int8

                if event.type == .keyDown {
                    keyAction = Int8(KEY_ACTION_DOWN)
                } else if event.type == .keyUp {
                    keyAction = Int8(KEY_ACTION_UP)
                } else {
                    // .flagsChanged - modifier key pressed/released
                    // Determine if it was pressed or released by checking current state
                    let currentFlags = event.modifierFlags

                    // Check which modifier changed
                    if event.keyCode == 56 || event.keyCode == 60 {  // Shift
                        keyAction =
                            currentFlags.contains(.shift)
                            ? Int8(KEY_ACTION_DOWN) : Int8(KEY_ACTION_UP)
                    } else if event.keyCode == 59 || event.keyCode == 62 {  // Control
                        keyAction =
                            currentFlags.contains(.control)
                            ? Int8(KEY_ACTION_DOWN) : Int8(KEY_ACTION_UP)
                    } else if event.keyCode == 58 || event.keyCode == 61 {  // Option/Alt
                        keyAction =
                            currentFlags.contains(.option)
                            ? Int8(KEY_ACTION_DOWN) : Int8(KEY_ACTION_UP)
                    } else if event.keyCode == 55 || event.keyCode == 54 {  // Command
                        keyAction =
                            currentFlags.contains(.command)
                            ? Int8(KEY_ACTION_DOWN) : Int8(KEY_ACTION_UP)
                    } else {
                        return event
                    }
                }

                let modifiers = convertModifierFlags(event.modifierFlags)
                LiSendKeyboardEvent(Int16(windowsVK), keyAction, modifiers)
            }

            return nil  // Consume the event
        }

        isMouseCaptured = true
        print(
            "Mouse captured - Press Shift+Ctrl+Option+M to toggle capture, Shift+Ctrl+Option+Q to quit"
        )
    }

    func releaseMouseAndKeyboard() {
        guard isMouseCaptured else { return }

        // Remove event monitors
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        if let monitor = mouseButtonMonitor {
            NSEvent.removeMonitor(monitor)
            mouseButtonMonitor = nil
        }

        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }

        if let monitor = keyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardEventMonitor = nil
        }

        // Re-associate mouse and cursor
        CGAssociateMouseAndMouseCursorPosition(boolean_t(truncating: 1))

        // Show cursor
        NSCursor.unhide()

        isMouseCaptured = false
        print("Mouse released")
    }

    func processEvents() -> Bool {
        autoreleasepool {
            // Process window events - MUST be called from main thread
            while let event = NSApp.nextEvent(
                matching: .any, until: nil, inMode: .default, dequeue: true)
            {
                if event.type == .keyDown {
                    // Handle Shift+Ctrl+Option+Q to quit
                    if event.keyCode == 12  // Q key
                        && event.modifierFlags.contains(.shift)
                        && event.modifierFlags.contains(.control)
                        && event.modifierFlags.contains(.option)
                    {
                        setShouldClose()
                        return false
                    }
                    // Handle Shift+Ctrl+Option+M to toggle mouse capture
                    else if event.keyCode == 46  // M key
                        && event.modifierFlags.contains(.shift)
                        && event.modifierFlags.contains(.control)
                        && event.modifierFlags.contains(.option)
                    {
                        if isMouseCaptured {
                            releaseMouseAndKeyboard()
                        } else {
                            captureMouseAndKeyboard()
                        }
                    }
                }

                NSApp.sendEvent(event)
            }

            return !shouldClose && window.isVisible
        }
    }

    func close() {
        releaseMouseAndKeyboard()
        window.close()
    }
}
