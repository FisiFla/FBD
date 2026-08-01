import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import MetalKit
import ScreenCaptureKit
import simd
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "PipStreamController")

/// Errors surfaced by the PiP pipeline.
private enum PipError: Error {
    case shareableContentUnavailable
    case metalSetupFailed
}

/// Video filter parameters applied in the Metal fragment shader.
public struct VideoFilter: Equatable, Sendable {
    public var brightness: Double   // 1.0 = none
    public var contrast: Double     // 1.0 = none
    public var saturation: Double   // 1.0 = none
    public static let identity = VideoFilter(brightness: 1, contrast: 1, saturation: 1)

    public init(brightness: Double, contrast: Double, saturation: Double) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
    }
}

/// Picture-in-Picture streaming controller:
///
/// Opens a single draggable, rounded-corner floating window (~480×270, 16:9)
/// that live-streams a display's content through a Metal pipeline
/// (ScreenCaptureKit, macOS 13+). A fragment shader applies
/// brightness/contrast/saturation filters (`setFilter`); the source is
/// aspect-fit into the window with black letterboxing.
///
/// The window is created on the main thread; capture + Metal rendering run on
/// a per-display serial queue. Missing screen-recording permission is reported
/// synchronously via the return value — never crash, never block; async
/// failures tear the PiP down and log.
@MainActor
public final class PipStreamController {
    /// The active PiP window (nil when no PiP is showing).
    private var window: NSWindow?
    /// The active capture session (window + stream + renderer); at most one.
    private var session: PipSession?

    public init() {}

    deinit {
        // Break the stream↔output retain cycle (SCStream retains its outputs)
        // if the controller goes away without an explicit stop().
        session?.stop()
    }

    /// Open a draggable floating PiP window streaming a display's content.
    /// Replaces any active PiP. Returns false when screen-recording
    /// permission is missing (or Metal is unavailable / the display has no
    /// usable bounds); asynchronous capture failures tear the PiP down and
    /// log — `isActive` then goes false.
    @discardableResult
    public func startPiP(displayID: CGDirectDisplayID, filter: VideoFilter = .identity) -> Bool {
        teardownPip()
        guard CGPreflightScreenCaptureAccess() else {
            log.error("startPiP: screen-recording permission missing — grant Screen Recording to FBD in System Settings → Privacy & Security → Screen Recording")
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("startPiP: no Metal device available")
            return false
        }
        let bounds = CGDisplayBounds(displayID)
        guard isUsable(bounds) else {
            log.error("startPiP: no valid bounds for display \(displayID)")
            return false
        }
        do {
            let renderer = try PipRenderer(device: device)
            let (window, metalView) = makeWindow(displayID: displayID, device: device)
            let session = PipSession(
                displayID: displayID,
                window: window,
                metalView: metalView,
                renderer: renderer,
                owner: self
            )
            self.window = window
            self.session = session
            window.orderFrontRegardless()
            session.start(filter: filter)
            return true
        } catch {
            log.error("startPiP: Metal pipeline setup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Update the active PiP's video filter (brightness/contrast/saturation uniforms).
    public func setFilter(_ filter: VideoFilter) {
        guard let session else {
            log.info("setFilter: no active PiP window")
            return
        }
        session.setFilter(filter)
    }

    /// True when a PiP window is showing.
    public var isActive: Bool {
        guard let session else { return false }
        return session.isCapturing && (window?.isVisible ?? false)
    }

    /// Close the PiP window.
    public func stop() {
        teardownPip()
    }

    // MARK: - Teardown

    /// Remove the active PiP (window + stream). Runs on the main actor, so it
    /// cannot race the async capture setup (which re-checks `isCurrentPipSession`).
    private func teardownPip() {
        guard let session else { return }
        self.session = nil
        window = nil
        session.stop()
    }

    /// Tear down only if `session` is still the live one (used by the session's
    /// own failure paths).
    fileprivate func teardownPip(_ session: PipSession) {
        guard self.session === session else { return }
        teardownPip()
    }

    /// Whether `session` is still the live PiP session — lets a capture setup
    /// that raced with teardown cancel itself. Main-actor only, race-free.
    fileprivate func isCurrentPipSession(_ session: PipSession) -> Bool {
        self.session === session
    }

    /// Window number of the PiP window, so the capture filter can exclude it
    /// (no feedback loop).
    fileprivate func pipWindowID() -> CGWindowID {
        guard let window, window.windowNumber > 0 else { return 0 }
        return CGWindowID(window.windowNumber)
    }

    // MARK: - Window

    /// Borderless rounded-corner window (~480×270) placed near the bottom-right
    /// of the source display, draggable by its background.
    private func makeWindow(displayID: CGDirectDisplayID, device: MTLDevice) -> (NSWindow, MTKView) {
        let size = NSSize(width: 480, height: 270)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.minY + 24)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hasShadow = true

        // Rounded black container clips the video layer; letterbox bars are
        // black by construction.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let view = MTKView(frame: container.bounds, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Frames are presented manually by the capture pipeline (off-main),
        // not by MTKView's own draw loop.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)

        window.contentView = container
        return (window, view)
    }

    private func isUsable(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isEmpty && bounds.width > 0 && bounds.height > 0
    }
}

// MARK: - PiP session (capture + render pipeline)

/// Owns the PiP window's capture stream and renderer. All capture/render work
/// happens on `queue` (a serial queue); window/state mutations hop to the main
/// thread.
private final class PipSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    let metalView: MTKView
    private let renderer: PipRenderer
    private let queue: DispatchQueue
    private weak var owner: PipStreamController?

    private let stateLock = NSLock()
    private var _isCapturing = false
    /// Set before an intentional stop so didStopWithError stays quiet.
    private var _isStopping = false
    private var stream: SCStream?

    var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isCapturing
    }

    init(
        displayID: CGDirectDisplayID,
        window: NSWindow,
        metalView: MTKView,
        renderer: PipRenderer,
        owner: PipStreamController
    ) {
        self.displayID = displayID
        self.window = window
        self.metalView = metalView
        self.renderer = renderer
        self.owner = owner
        self.queue = DispatchQueue(label: "dev.fisifla.fbd.pip.\(displayID)", qos: .userInteractive)
    }

    // MARK: Lifecycle

    func start(filter: VideoFilter) {
        queue.async { [weak self] in
            self?.renderer.setFilter(filter)
        }
        Task { @MainActor [weak self] in
            await self?.runCapture()
        }
    }

    func setFilter(_ filter: VideoFilter) {
        queue.async { [weak self] in
            self?.renderer.setFilter(filter)
        }
    }

    /// Stop the stream and hide the window. Serialized with any in-flight
    /// frame on `queue`, so the renderer is never torn down mid-draw.
    func stop() {
        stateLock.lock()
        _isStopping = true
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            let current = self.stream
            stateLock.unlock()
            if let stream = current {
                try? stream.removeStreamOutput(self, type: .screen)
                stream.stopCapture(completionHandler: nil)
            }
            stateLock.lock()
            self.stream = nil
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.window.orderOut(nil)
            }
        }
    }

    // MARK: Capture setup

    @MainActor private func runCapture() async {
        do {
            let content = try await fetchShareableContent()
            // The session may have been torn down (stop/startPiP) while we
            // were waiting for the shareable-content query. Both this check
            // and teardown run on the main actor, so this is race-free.
            guard owner?.isCurrentPipSession(self) == true else { return }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("display \(displayID) is not available for screen capture")
                return
            }
            // Never capture the PiP window itself — it would otherwise feed
            // back into the next frame. Everything else stays included.
            let ownWindowID = owner?.pipWindowID() ?? 0
            let excluded = content.windows.filter { $0.windowID == ownWindowID }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            let config = makeConfiguration(for: scDisplay)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stateLock.lock()
            stream = newStream
            stateLock.unlock()
            newStream.startCapture { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail("startCapture failed: \(error.localizedDescription)")
                } else {
                    self.stateLock.lock()
                    self._isCapturing = true
                    self.stateLock.unlock()
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: PipError.shareableContentUnavailable)
                }
            }
        }
    }

    private func makeConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 fps
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = OSType(kCVPixelFormatType_32BGRA)
        config.capturesAudio = false
        return config
    }

    /// Log the failure and tear the PiP down on the main thread.
    private func fail(_ reason: String) {
        log.error("PiP failed for display \(self.displayID): \(reason)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.teardownPip(self)
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer.render(pixelBuffer: pixelBuffer, in: metalView)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let stopping = _isStopping
        stateLock.unlock()
        guard !stopping else { return }
        log.error("PiP stream stopped unexpectedly for display \(self.displayID): \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.teardownPip(self)
        }
    }
}

// MARK: - Metal renderer

/// Draws a captured `CVPixelBuffer` as a centered, aspect-fit textured quad
/// with brightness/contrast/saturation uniforms applied in the fragment
/// shader (black letterbox). All methods must be called from the owning
/// `PipSession`'s serial queue.
private final class PipRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let filterBuffer: MTLBuffer
    private let fitScaleBuffer: MTLBuffer

    /// MSL: centered quad scaled to aspect-fit the source into the view;
    /// the fragment shader applies the filter uniforms to the captured color.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PipVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct FilterParams {
        float brightness;
        float contrast;
        float saturation;
    };

    vertex PipVertexOut pip_vert(uint vid [[vertex_id]],
                                 constant float2 &fitScale [[buffer(1)]]) {
        // Two triangles covering the clip space quad.
        float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
        PipVertexOut out;
        // Scale the fullscreen quad down so the source aspect ratio fits
        // inside the view (letterbox bars stay clear-black).
        out.position = float4((pos * 2.0 - 1.0) * fitScale, 0.0, 1.0);
        // Captured pixels are top-left origin; Metal NDC is bottom-left.
        out.uv = float2(pos.x, 1.0 - pos.y);
        return out;
    }

    fragment float4 filter_frag(PipVertexOut in [[stage_in]],
                                constant FilterParams &filter [[buffer(0)]],
                                texture2d<float> captureTexture [[texture(0)]],
                                sampler captureSampler [[sampler(0)]]) {
        float4 color = captureTexture.sample(captureSampler, in.uv);
        float3 c = color.rgb;
        c = (c - 0.5) * filter.contrast + 0.5;
        c = c * filter.brightness;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(l), c, filter.saturation);
        return float4(c, color.a);
    }
    """

    init(device: MTLDevice) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw PipError.metalSetupFailed
        }
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "pip_vert"),
              let fragmentFunction = library.makeFunction(name: "filter_frag") else {
            throw PipError.metalSetupFailed
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw PipError.metalSetupFailed
        }
        self.sampler = sampler

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw PipError.metalSetupFailed
        }
        self.textureCache = cache

        guard let filterBuffer = device.makeBuffer(length: 16, options: .storageModeShared),
              let fitScaleBuffer = device.makeBuffer(length: 16, options: .storageModeShared) else {
            throw PipError.metalSetupFailed
        }
        self.filterBuffer = filterBuffer
        self.fitScaleBuffer = fitScaleBuffer
    }

    func setFilter(_ filter: VideoFilter) {
        let params = FilterParams(
            brightness: Float(filter.brightness),
            contrast: Float(filter.contrast),
            saturation: Float(filter.saturation)
        )
        filterBuffer.contents().storeBytes(of: params, as: FilterParams.self)
    }

    func render(pixelBuffer: CVPixelBuffer, in view: MTKView) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let layer = view.layer as? CAMetalLayer,
              let drawable = layer.nextDrawable() else {
            return
        }
        // Keep the drawable at the view's pixel size so letterboxing math
        // (below) matches what is on screen.
        let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
        let target = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
        if target.width > 0, target.height > 0,
           Int(layer.drawableSize.width) != Int(target.width) || Int(layer.drawableSize.height) != Int(target.height) {
            layer.drawableSize = target
        }
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }

        // Aspect-fit the source into the view: quad half-extents in clip space.
        let sourceAspect = CGFloat(width) / CGFloat(height)
        let viewAspect = layer.drawableSize.width / layer.drawableSize.height
        let quadY = min(CGFloat(1), viewAspect / sourceAspect)
        let quadX = quadY * sourceAspect / viewAspect
        var fitScale = SIMD2<Float>(Float(quadX), Float(quadY))
        fitScaleBuffer.contents().storeBytes(of: fitScale, as: SIMD2<Float>.self)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        // Black letterbox around the fitted video.
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(filterBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(fitScaleBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Evict cache entries no longer referenced by in-flight command buffers.
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

/// Layout mirror of the MSL `FilterParams` struct (3 floats, no padding).
private struct FilterParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
}
