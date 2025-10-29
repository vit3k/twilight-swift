import CoreVideo
import Metal
import MetalKit
import QuartzCore

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

// MARK: - Frame Queue

private class FrameQueue {
    private var frames: [CVImageBuffer] = []
    private let lock = NSLock()
    private let maxSize = 3  // Keep only last 3 frames to avoid memory buildup

    func push(_ frame: CVImageBuffer) {
        lock.lock()
        defer { lock.unlock() }

        // If queue is full, drop oldest frame
        if frames.count >= maxSize {
            frames.removeFirst()
        }

        frames.append(frame)
    }

    func pop() -> CVImageBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !frames.isEmpty else {
            return nil
        }

        return frames.removeFirst()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        while !frames.isEmpty {
            frames.removeFirst()
        }
    }
}

// MARK: - Text Texture Helper

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

// MARK: - Metal Renderer

class MetalRenderer {
    internal let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let textPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private let width: Int
    private let height: Int
    private let frameQueue = FrameQueue()

    // Stats for OSD
    private var currentStats = FrameStats()
    private let statsLock = NSLock()
    private var lastFrameTimestamp: CFTimeInterval = 0.0

    // Rolling window for 5-second averages
    private var statsHistory:
        [(
            timestamp: CFTimeInterval, decodeMs: Double, prepareMs: Double, renderMs: Double,
            fps: Double
        )] =
            []
    private let statsWindowDuration: CFTimeInterval = 5.0  // 5 seconds
    private var avgFPS: Double = 0.0
    private var avgDecodeMs: Double = 0.0
    private var avgPrepareMs: Double = 0.0
    private var avgRenderMs: Double = 0.0

    // Text rendering
    private var textTexture: MTLTexture?
    private var textVertexBuffer: MTLBuffer?
    private var textNeedsUpdate = true
    private var firstFrame = true

    private(set) var metalLayer: CAMetalLayer

    init?(width: Int, height: Int) {
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

        // Create Metal layer
        self.metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        // Configure for high-quality rendering
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
        metalLayer.drawableSize = CGSize(
            width: CGFloat(width) * metalLayer.contentsScale,
            height: CGFloat(height) * metalLayer.contentsScale
        )

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

        print("Metal renderer created successfully")
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

    func processFrames() {
        // Process all queued frames
        while let frame = frameQueue.pop() {
            renderFrameInternal(frame)
        }
    }

    func clearFrames() {
        frameQueue.clear()
    }

    private func renderFrameInternal(_ imageBuffer: CVImageBuffer) {
        let renderStart = CACurrentMediaTime()
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
            guard let drawable = metalLayer.nextDrawable() else {
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
                // Calculate rendering time
                let renderEnd = CACurrentMediaTime()
                let renderMs = (renderEnd - renderStart) * 1000.0

                // Calculate actual FPS based on time between render calls
                let currentTime = renderEnd
                var instantFPS: Double = 0.0
                if lastFrameTimestamp > 0 {
                    let timeDelta = currentTime - lastFrameTimestamp
                    instantFPS = 1.0 / timeDelta
                }
                lastFrameTimestamp = currentTime

                // Add current frame stats to history
                statsHistory.append(
                    (
                        timestamp: currentTime, decodeMs: stats.decodeTimeMs,
                        prepareMs: stats.prepareTimeMs, renderMs: renderMs, fps: instantFPS
                    ))

                // Remove entries older than 5 seconds
                let cutoffTime = currentTime - statsWindowDuration
                statsHistory.removeAll { $0.timestamp < cutoffTime }

                // Calculate averages over the 5-second window
                if !statsHistory.isEmpty {
                    avgDecodeMs =
                        statsHistory.reduce(0.0) { $0 + $1.decodeMs } / Double(statsHistory.count)
                    avgPrepareMs =
                        statsHistory.reduce(0.0) { $0 + $1.prepareMs } / Double(statsHistory.count)
                    avgRenderMs =
                        statsHistory.reduce(0.0) { $0 + $1.renderMs } / Double(statsHistory.count)
                    avgFPS =
                        statsHistory.reduce(0.0) { $0 + $1.fps } / Double(statsHistory.count)
                }

                // Update text texture if needed
                if needsUpdate || textTexture == nil {
                    let totalTime = avgDecodeMs + avgPrepareMs + avgRenderMs
                    let statsText = String(
                        format:
                            "Frame: %d  Decode: %.2fms  Prepare: %.2fms  Render: %.2fms  Total: %.2fms  FPS: %.1f (5s avg)",
                        stats.frameNumber,
                        avgDecodeMs,
                        avgPrepareMs,
                        avgRenderMs,
                        totalTime,
                        avgFPS)

                    var textWidth = 0
                    var textHeight = 0
                    textTexture = createTextTexture(
                        device: device, text: statsText, width: &textWidth, height: &textHeight)

                    statsLock.lock()
                    textNeedsUpdate = false
                    statsLock.unlock()

                    // Create vertex buffer for text quad (top-left corner)
                    let margin: Float = 10.0
                    let x = -1.0 + (margin * 2.0 / Float(self.width))
                    let y = 1.0 - (margin * 2.0 / Float(self.height))
                    let w = Float(textWidth) * 2.0 / Float(self.width)
                    let h = Float(textHeight) * 2.0 / Float(self.height)

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
