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

// MARK: - Metal Shaders
private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
        // Full-screen quad
        const float2 positions[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
        };
        const float2 texCoords[6] = {
            float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
            float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.texCoord = texCoords[vertexID];
        return out;
    }

    fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                   texture2d<float> yTexture [[texture(0)]],
                                   texture2d<float> uvTexture [[texture(1)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

        float y = yTexture.sample(textureSampler, in.texCoord).r;
        float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;

        // Convert YUV to RGB with proper range expansion
        // VideoToolbox typically outputs video range (16-235 for Y, 16-240 for UV)
        // Scale from video range to full range
        y = (y - 0.0625) * 1.164; // (y - 16/255) * (255/219)
        float u = (uv.r - 0.5) * 1.138; // (u - 128/255) * (255/224)
        float v = (uv.g - 0.5) * 1.138; // (v - 128/255) * (255/224)

        // BT.709 YUV to RGB conversion
        float r = y + 1.5748 * v;
        float g = y - 0.1873 * u - 0.4681 * v;
        float b = y + 1.8556 * u;

        return float4(r, g, b, 1.0);
    }

    // Shader for rendering text overlay
    struct TextVertex {
        float2 position;
        float2 texCoord;
    };

    vertex VertexOut textVertexShader(uint vertexID [[vertex_id]],
                                       constant TextVertex* vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.texCoord = vertices[vertexID].texCoord;
        return out;
    }

    fragment float4 textFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> textTexture [[texture(0)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        float4 textColor = textTexture.sample(textureSampler, in.texCoord);
        return textColor;
    }
    """

private class MetalView: NSView {
    var metalLayer: CAMetalLayer!

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
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

private class FrameQueue {
    private var frames: [CVImageBuffer] = []
    private let lock = NSLock()
    private let maxSize = 3  // Keep only last 3 frames to avoid memory buildup

    func push(_ frame: CVImageBuffer) {
        lock.lock()
        defer { lock.unlock() }

        // Retain the frame before adding to queue
        // CVBufferRetain(frame)

        // If queue is full, drop oldest frame
        if frames.count >= maxSize {
            frames.removeFirst()
            // CVBufferRelease(oldFrame)
        }

        frames.append(frame)
    }

    func pop() -> CVImageBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !frames.isEmpty else {
            return nil
        }

        return frames.removeFirst()  // Caller must release
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        while !frames.isEmpty {
            frames.removeFirst()
        }
    }
}

private func createTextTexture(
    device: MTLDevice, text: String, width outWidth: inout Int, height outHeight: inout Int
) -> MTLTexture? {
    // Set up text attributes
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]

    // Measure text size
    let textSize = (text as NSString).size(withAttributes: attributes)
    let paddingH = 20  // Horizontal padding
    let paddingV = 8  // Vertical padding
    let texWidth = Int(ceil(textSize.width)) + (paddingH * 2)
    let texHeight = Int(ceil(textSize.height)) + (paddingV * 2)

    outWidth = texWidth
    outHeight = texHeight

    // Create bitmap context
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard
        let context = CGContext(
            data: nil,
            width: texWidth,
            height: texHeight,
            bitsPerComponent: 8,
            bytesPerRow: texWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )
    else { return nil }

    // Clear to transparent first
    context.clear(CGRect(x: 0, y: 0, width: texWidth, height: texHeight))

    // Draw semi-transparent black background
    context.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.7)
    context.fill(CGRect(x: 0, y: 0, width: texWidth, height: texHeight))

    // Draw text using NSString
    let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    (text as NSString).draw(at: NSPoint(x: paddingH, y: paddingV), withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()

    // Create Metal texture from bitmap
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: texWidth,
        height: texHeight,
        mipmapped: false
    )
    textureDescriptor.usage = .shaderRead

    guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }

    // Copy bitmap data to texture
    guard let bitmapData = context.data else { return nil }
    texture.replace(
        region: MTLRegionMake2D(0, 0, texWidth, texHeight),
        mipmapLevel: 0,
        withBytes: bitmapData,
        bytesPerRow: texWidth * 4
    )

    return texture
}

class Renderer {
    private let window: NSWindow
    private let metalView: MetalView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private let width: Int
    private let height: Int
    fileprivate var shouldClose = false
    private let frameQueue = FrameQueue()

    // Mouse handling
    private var mouseEventMonitor: Any?
    private var mouseButtonMonitor: Any?
    private var scrollEventMonitor: Any?
    private var keyboardEventMonitor: Any?
    fileprivate var isMouseCaptured = false

    // Stats for OSD
    private var currentStats = FrameStats()
    private let statsLock = NSLock()

    // Text rendering
    private var textTexture: MTLTexture?
    private var textVertexBuffer: MTLBuffer?
    private var textNeedsUpdate = true
    private var firstFrame = true

    // Window delegate
    private var windowDelegate: WindowDelegateHelper?

    @MainActor
    init?(width: Int, height: Int, title: String) {
        // Initialize NSApplication - required for window to appear in dock/taskbar
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        self.width = width
        self.height = height

        // Create Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Failed to create Metal device")
            return nil
        }
        self.device = device

        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            print("Failed to create command queue")
            return nil
        }
        self.commandQueue = commandQueue

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
        metalView.metalLayer.device = device
        metalView.metalLayer.pixelFormat = .bgra8Unorm
        metalView.metalLayer.framebufferOnly = true

        window.contentView = metalView
        window.makeKeyAndOrderFront(nil)
        window.makeMain()

        // Make the view first responder to receive mouse events
        window.makeFirstResponder(metalView)

        // Compile shaders
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)

            guard let vertexFunction = library.makeFunction(name: "vertexShader"),
                let fragmentFunction = library.makeFunction(name: "fragmentShader")
            else {
                print("Failed to create shader functions")
                return nil
            }

            // Create render pipeline
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            // Create text overlay pipeline
            if let textVertexFunction = library.makeFunction(name: "textVertexShader"),
                let textFragmentFunction = library.makeFunction(name: "textFragmentShader")
            {

                let textPipelineDescriptor = MTLRenderPipelineDescriptor()
                textPipelineDescriptor.vertexFunction = textVertexFunction
                textPipelineDescriptor.fragmentFunction = textFragmentFunction
                textPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                textPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                textPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                textPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor =
                    .oneMinusSourceAlpha
                textPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                textPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor =
                    .oneMinusSourceAlpha

                self.textPipelineState = try? device.makeRenderPipelineState(
                    descriptor: textPipelineDescriptor)
                if self.textPipelineState == nil {
                    print("Failed to create text pipeline state (non-fatal)")
                }
            } else {
                self.textPipelineState = nil
                print("Failed to create text shader functions (non-fatal)")
            }

        } catch {
            print("Failed to compile shaders: \(error)")
            return nil
        }

        // Create texture cache for CoreVideo -> Metal texture conversion
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )

        if result == kCVReturnSuccess {
            self.textureCache = cache
        } else {
            print("Failed to create texture cache")
            return nil
        }

        // Set up window delegate to handle window events
        windowDelegate = WindowDelegateHelper(renderer: self)
        window.delegate = windowDelegate

        print("Metal renderer created successfully")
    }

    @MainActor
    deinit {
        releaseMouseAndKeyboard()
        frameQueue.clear()
        window.close()
    }

    // MARK: - Mouse Capture

    @MainActor
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
                Task { @MainActor in
                    self.shouldClose = true
                }
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

    @MainActor
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

    func setStats(_ stats: FrameStats) {
        statsLock.lock()
        defer { statsLock.unlock() }

        currentStats = stats
        textNeedsUpdate = true
    }

    func renderFrame(_ imageBuffer: CVImageBuffer) {
        // Called from decoder thread - just queue the frame
        frameQueue.push(imageBuffer)
    }

    @MainActor
    func processEvents() -> Bool {
        autoreleasepool {
            // Process all queued frames
            while let frame = frameQueue.pop() {
                renderFrameInternal(frame)
                // CVBufferRelease(frame)
            }

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
                        shouldClose = true
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

    @MainActor
    private func renderFrameInternal(_ imageBuffer: CVImageBuffer) {
        autoreleasepool {
            // Lock the pixel buffer
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
            }

            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)

            // Debug: Print pixel format on first frame
            if firstFrame {
                let formatBytes = withUnsafeBytes(of: pixelFormat.bigEndian) { Array($0) }
                let formatStr = String(bytes: formatBytes, encoding: .ascii) ?? "unknown"
                print("Pixel format: \(formatStr) (0x\(String(pixelFormat, radix: 16)))")
                print("Resolution: \(width)x\(height)")
                print("Plane count: \(CVPixelBufferGetPlaneCount(imageBuffer))")
                firstFrame = false
            }

            guard let textureCache = textureCache else { return }

            // Get Metal textures from the CVPixelBuffer (NV12 format has 2 planes)
            var yTextureRef: CVMetalTexture?
            var uvTextureRef: CVMetalTexture?

            // Y plane (luminance)
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                imageBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,  // plane index
                &yTextureRef
            )

            // UV plane (chrominance)
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                imageBuffer,
                nil,
                .rg8Unorm,
                width / 2,
                height / 2,
                1,  // plane index
                &uvTextureRef
            )

            guard let yTextureRef = yTextureRef,
                let uvTextureRef = uvTextureRef,
                let yTexture = CVMetalTextureGetTexture(yTextureRef),
                let uvTexture = CVMetalTextureGetTexture(uvTextureRef)
            else {
                return
            }

            // Get the next drawable
            guard let drawable = metalView.metalLayer.nextDrawable() else {
                return
            }

            // Create command buffer
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            // Create render pass
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = drawable.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 1)
            renderPass.colorAttachments[0].storeAction = .store

            // Create render encoder
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
            else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(uvTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Draw text overlay if stats are available
            statsLock.lock()
            let stats = currentStats
            let needsUpdate = textNeedsUpdate
            statsLock.unlock()

            if stats.frameNumber > 0 {
                // Update text texture if needed
                if needsUpdate || textTexture == nil {
                    let totalTime = stats.decodeTimeMs + stats.prepareTimeMs
                    let fps = totalTime > 0 ? 1000.0 / totalTime : 0
                    let statsText = String(
                        format:
                            "Frame: %d  Decode: %.2fms  Prepare: %.2fms  Total: %.2fms  FPS: %.1f",
                        stats.frameNumber,
                        stats.decodeTimeMs,
                        stats.prepareTimeMs,
                        totalTime,
                        fps)

                    var textWidth = 0
                    var textHeight = 0
                    textTexture = createTextTexture(
                        device: device, text: statsText, width: &textWidth, height: &textHeight)

                    statsLock.lock()
                    textNeedsUpdate = false
                    statsLock.unlock()

                    // Create vertex buffer for text quad (top-left corner)
                    let margin: Float = 10.0
                    let x = -1.0 + (margin * 2.0 / Float(width))
                    let y = 1.0 - (margin * 2.0 / Float(height))
                    let w = Float(textWidth) * 2.0 / Float(width)
                    let h = Float(textHeight) * 2.0 / Float(height)

                    // Vertices with position and texture coordinates
                    struct TextVertex {
                        var x: Float
                        var y: Float
                        var u: Float
                        var v: Float
                    }

                    let vertices: [TextVertex] = [
                        // Triangle 1
                        TextVertex(x: x, y: y, u: 0.0, v: 0.0),  // Top-left
                        TextVertex(x: x + w, y: y, u: 1.0, v: 0.0),  // Top-right
                        TextVertex(x: x, y: y - h, u: 0.0, v: 1.0),  // Bottom-left
                        // Triangle 2
                        TextVertex(x: x, y: y - h, u: 0.0, v: 1.0),  // Bottom-left
                        TextVertex(x: x + w, y: y, u: 1.0, v: 0.0),  // Top-right
                        TextVertex(x: x + w, y: y - h, u: 1.0, v: 1.0),  // Bottom-right
                    ]

                    textVertexBuffer = device.makeBuffer(
                        bytes: vertices, length: MemoryLayout<TextVertex>.stride * vertices.count,
                        options: .storageModeShared)
                }

                // Draw text overlay if we have texture and pipeline
                if let textTexture = textTexture,
                    let textPipelineState = textPipelineState,
                    let textVertexBuffer = textVertexBuffer
                {
                    encoder.setRenderPipelineState(textPipelineState)
                    encoder.setVertexBuffer(textVertexBuffer, offset: 0, index: 0)
                    encoder.setFragmentTexture(textTexture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }

            encoder.endEncoding()

            // Present drawable
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

// MARK: - Window Delegate Helper

private class WindowDelegateHelper: NSObject, NSWindowDelegate {
    weak var renderer: Renderer?

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init()
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        renderer?.releaseMouseAndKeyboard()
        renderer?.shouldClose = true
    }

    @MainActor
    func windowDidResignKey(_ notification: Notification) {
        // Release mouse when window loses focus
        if renderer?.isMouseCaptured == true {
            renderer?.releaseMouseAndKeyboard()
        }
    }
}
