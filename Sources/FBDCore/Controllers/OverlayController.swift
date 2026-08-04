import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import MetalKit
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "OverlayController")

/// Errors surfaced by the boost pipeline.
private enum OverlayError: Error {
    case shareableContentUnavailable
    case metalSetupFailed
}

/// Full-screen overlay capabilities, one per display:
///
/// 1. **Dim-to-black** — a borderless black `NSWindow` covering the display
///    with adjustable opacity (`setDimFactor`).
/// 2. **Software brightness boost** — a borderless transparent window hosting
///    an `MTKView` that re-renders the display's captured content
///    (ScreenCaptureKit, macOS 13+) with a brightness multiplier > 1
///    (`setSoftwareBoost`).
///
/// Windows are created on the main thread; the capture + Metal render pipeline
/// runs on a per-display serial queue. Screen-recording permission failures
/// are logged and reported via the return value — never crash, never block.
@MainActor
public final class OverlayController {
    /// Dim overlay windows by display id.
    private var dimWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Active capture sessions (window + stream + renderer) by display id.
    private var boostSessions: [CGDirectDisplayID: BoostSession] = [:]
    private var screenObserver: NSObjectProtocol?

    public init() {
        // Keep overlays glued to their display when the desktop reconfigured
        // (resolution change, display moved, spaces changed).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionOverlays()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Dim to black

    /// True when a dim overlay exists for the display.
    public func isDimming(displayID: CGDirectDisplayID) -> Bool {
        dimWindows[displayID] != nil
    }

    /// Set the dim overlay opacity, 0…1 (0 = no dimming, 1 = fully black).
    /// Removing the overlay when factor <= 0.
    public func setDimFactor(_ factor: Double, displayID: CGDirectDisplayID) {
        let clamped = min(max(factor, 0), 1)
        guard clamped > 0 else {
            removeDim(for: displayID)
            return
        }
        let bounds = CGDisplayBounds(displayID)
        guard isUsable(bounds) else {
            log.warning("setDimFactor: no valid bounds for display \(displayID)")
            removeDim(for: displayID)
            return
        }
        let window = dimWindows[displayID] ?? makeOverlayWindow(bounds: bounds, backgroundColor: .black)
        dimWindows[displayID] = window
        window.alphaValue = CGFloat(clamped)
        window.setFrame(bounds, display: true)
        window.orderFrontRegardless()
    }

    private func removeDim(for displayID: CGDirectDisplayID) {
        guard let window = dimWindows.removeValue(forKey: displayID) else { return }
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Software brightness boost

    /// True when a boost overlay is capturing the display.
    public func isBoosting(displayID: CGDirectDisplayID) -> Bool {
        boostSessions[displayID]?.isCapturing ?? false
    }

    /// Display IDs with an active boost session (observability).
    public func activeBoostDisplayIDs() -> [UInt32] {
        Array(boostSessions.keys)
    }

    /// Start (or update) a live-capture brightness boost for a display.
    /// `factor >= 1` is the brightness multiplier; the stream is stopped when
    /// `factor <= 1`. Returns false when ScreenCaptureKit is unavailable or
    /// screen-recording permission is missing (reason logged); asynchronous
    /// stream failures tear the overlay down and log — `isBoosting` stays false.
    @discardableResult
    public func setSoftwareBoost(_ factor: Double, displayID: CGDirectDisplayID) -> Bool {
        guard factor > 1 else {
            stop(for: displayID)
            return true
        }
        return setScreenFilter(ScreenFilterParams(brightness: factor), displayID: displayID)
    }

    /// Apply (or update) a full-screen software filter for a display. Neutral
    /// params stop the overlay. Returns false when ScreenCaptureKit is
    /// unavailable or screen-recording permission is missing (reason logged);
    /// asynchronous stream failures tear the overlay down and log.
    @discardableResult
    public func setScreenFilter(_ params: ScreenFilterParams, displayID: CGDirectDisplayID) -> Bool {
        guard !params.isNeutral else {
            stopScreenFilter(displayID: displayID)
            return true
        }
        guard CGPreflightScreenCaptureAccess() else {
            log.error("setScreenFilter: screen-recording permission missing — grant Screen Recording to FBD in System Settings → Privacy & Security → Screen Recording")
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("setScreenFilter: no Metal device available")
            return false
        }
        let bounds = CGDisplayBounds(displayID)
        guard isUsable(bounds) else {
            log.error("setScreenFilter: no valid bounds for display \(displayID)")
            return false
        }
        if let session = boostSessions[displayID] {
            session.setParams(params)
            return true
        }
        do {
            let renderer = try BoostRenderer(device: device)
            let window = makeOverlayWindow(bounds: bounds, backgroundColor: .clear)
            let view = makeBoostView(device: device)
            window.contentView = view
            let session = BoostSession(
                displayID: displayID,
                window: window,
                metalView: view,
                renderer: renderer,
                owner: self
            )
            view.delegate = session
            boostSessions[displayID] = session
            window.orderFrontRegardless()
            session.start(params: params)
            return true
        } catch {
            log.error("setScreenFilter: Metal pipeline setup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop any full-screen filter overlay for the display.
    public func stopScreenFilter(displayID: CGDirectDisplayID) {
        teardownBoost(for: displayID)
    }

    private func makeBoostView(device: MTLDevice) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Delegate-draw pattern: the SCK output stores the latest frame and
        // flags needsDisplay; draw(in:) renders on the main thread. Paused +
        // enableSetNeedsDisplay keeps the loop frame-driven rather than
        // spinning at vsync.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    // MARK: - Teardown

    /// Tear down everything for a display (dim overlay + boost stream).
    public func stop(for displayID: CGDirectDisplayID) {
        removeDim(for: displayID)
        teardownBoost(for: displayID)
    }

    /// Tear down all overlays.
    public func stopAll() {
        for id in Array(dimWindows.keys) {
            removeDim(for: id)
        }
        for id in Array(boostSessions.keys) {
            teardownBoost(for: id)
        }
    }

    /// Remove only the boost overlay for a display (dim overlay untouched).
    fileprivate func teardownBoost(for displayID: CGDirectDisplayID) {
        guard let session = boostSessions.removeValue(forKey: displayID) else { return }
        // Hide synchronously (this runs on the main actor): stop()'s async
        // teardown can race the session's deallocation and leave the last
        // Metal frame composited on-screen.
        session.window.alphaValue = 0
        session.window.orderOut(nil)
        session.stop()
    }

    // MARK: - Helpers

    /// Window numbers (as CGWindowIDs) of every overlay owned for a display,
    /// so the capture filter can exclude them (no feedback loop).
    fileprivate func overlayWindowIDs(for displayID: CGDirectDisplayID) -> Set<CGWindowID> {
        var ids: Set<CGWindowID> = []
        if let window = dimWindows[displayID] {
            ids.insert(CGWindowID(window.windowNumber))
        }
        if let session = boostSessions[displayID] {
            ids.insert(CGWindowID(session.window.windowNumber))
        }
        return ids
    }

    /// Whether `session` is still the live boost session for the display —
    /// lets a capture setup that raced with teardown cancel itself.
    fileprivate func isCurrentBoostSession(_ session: BoostSession, for displayID: CGDirectDisplayID) -> Bool {
        boostSessions[displayID] === session
    }

    private func makeOverlayWindow(bounds: CGRect, backgroundColor: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = backgroundColor
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.hasShadow = false
        // Overlays are created per use and never reused — closing destroys
        // them, so teardown can never leave a stale composited window.
        window.isReleasedWhenClosed = true
        return window
    }

    private func repositionOverlays() {
        for (id, window) in dimWindows {
            let bounds = CGDisplayBounds(id)
            guard isUsable(bounds) else { continue }
            window.setFrame(bounds, display: true)
        }
        for (id, session) in boostSessions {
            let bounds = CGDisplayBounds(id)
            guard isUsable(bounds) else { continue }
            session.window.setFrame(bounds, display: true)
            // layer.drawableSize is refreshed per frame by the renderer.
        }
    }

    private func isUsable(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isEmpty && bounds.width > 0 && bounds.height > 0
    }
}

// MARK: - Boost session (capture + render pipeline)

/// Owns one display's capture stream, overlay window and renderer.
/// All capture/render work happens on `queue` (a per-display serial queue);
/// window/state mutations hop to the main thread.
private final class BoostSession: NSObject, SCStreamOutput, SCStreamDelegate, MTKViewDelegate {
    let displayID: CGDirectDisplayID
    let window: NSWindow
    let metalView: MTKView
    private let renderer: BoostRenderer
    private let queue: DispatchQueue
    private weak var owner: OverlayController?

    private let stateLock = NSLock()
    private var _isCapturing = false
    /// Set before an intentional stop so didStopWithError stays quiet.
    private var _isStopping = false
    private var stream: SCStream?
    /// Latest captured frame + current filter params, written on the capture
    /// queue / UI thread, read on the main thread by draw(in:).
    private var latestPixelBuffer: CVPixelBuffer?
    private var filterParams = ScreenFilterParams.neutral

    var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isCapturing
    }

    init(
        displayID: CGDirectDisplayID,
        window: NSWindow,
        metalView: MTKView,
        renderer: BoostRenderer,
        owner: OverlayController
    ) {
        self.displayID = displayID
        self.window = window
        self.metalView = metalView
        self.renderer = renderer
        self.owner = owner
        self.queue = DispatchQueue(label: "dev.fisifla.fbd.boost.\(displayID)", qos: .userInteractive)
    }

    // MARK: Lifecycle

    func start(params: ScreenFilterParams) {
        setParams(params)
        Task { @MainActor [weak self] in
            await self?.runCapture()
        }
    }

    func setParams(_ params: ScreenFilterParams) {
        stateLock.lock()
        filterParams = params
        stateLock.unlock()
    }

    /// Stop the stream and hide the window. The window is hidden FIRST on the
    /// main thread, so a stalled capture queue can never leak the overlay.
    func stop() {
        stateLock.lock()
        _isStopping = true
        stateLock.unlock()
        // Destroy the window outright. The Metal layer can hold its last
        // presented (brightened) frame even after the view is detached, so
        // zero the alpha FIRST — a 0-alpha window composites nothing even if
        // the window server keeps it on-screen. orderOut/close alone were
        // observed to leave shield-level windows composited on this system.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.alphaValue = 0
            self.metalView.delegate = nil
            self.window.contentView = nil
            self.window.orderOut(nil)
            self.window.close()
        }
        queue.async { [weak self] in
            guard let self else { return }
            if let stream = self.stream {
                try? stream.removeStreamOutput(self, type: .screen)
                stream.stopCapture { [weak self] _ in
                    // Break the stream↔session retain cycle even if the stop
                    // callback is delivered asynchronously.
                    self?.stream = nil
                }
            }
        }
    }

    // MARK: Capture setup

    @MainActor private func runCapture() async {
        do {
            let content = try await fetchShareableContent()
            // The session may have been torn down (stop/stopAll) while we were
            // waiting for the shareable-content query. Both this check and
            // teardown run on the main actor, so this is race-free.
            guard owner?.isCurrentBoostSession(self, for: displayID) == true else { return }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("display \(displayID) is not available for screen capture")
                return
            }
            // Never capture our own overlays: transparent boost window + black
            // dim window would otherwise feed back into the next frame.
            let overlayIDs = owner?.overlayWindowIDs(for: displayID) ?? []
            let excluded = content.windows.filter { overlayIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            let config = makeConfiguration(for: scDisplay)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream = newStream
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
                    continuation.resume(throwing: OverlayError.shareableContentUnavailable)
                }
            }
        }
    }

    private func makeConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Capture at the display's PHYSICAL pixel resolution. SCDisplay.width/
        // height are points — on a 2x display (e.g. the built-in XDR panel)
        // that made the overlay render at half resolution, which reads as
        // soft/out-of-focus when the boost is active.
        config.width = CGDisplayPixelsWide(display.displayID)
        config.height = CGDisplayPixelsHigh(display.displayID)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10) // ~10 fps
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = OSType(kCVPixelFormatType_32BGRA)
        config.capturesAudio = false
        return config
    }

    /// Log the failure and tear the overlay down on the main thread.
    private func fail(_ reason: String) {
        log.error("Software boost failed for display \(self.displayID): \(reason)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.teardownBoost(for: self.displayID)
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stateLock.lock()
        latestPixelBuffer = pixelBuffer
        stateLock.unlock()
        // Render on the main thread via the MTKView draw loop (reliable
        // compositing for transparent shield windows).
        DispatchQueue.main.async { [weak self] in
            self?.metalView.needsDisplay = true
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        guard let buffer = latestPixelBuffer else {
            stateLock.unlock()
            return
        }
        let params = filterParams
        stateLock.unlock()
        renderer.render(pixelBuffer: buffer, params: params, in: view)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let stopping = _isStopping
        stateLock.unlock()
        guard !stopping else { return }
        log.error("Boost stream stopped unexpectedly for display \(self.displayID): \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.teardownBoost(for: self.displayID)
        }
    }
}

// MARK: - Metal renderer

/// Draws a captured `CVPixelBuffer` as a fullscreen textured quad with a
/// `brightness` uniform (> 1 brightens). Called from the MTKView draw loop
/// (main thread) via BoostSession.draw(in:).
private final class BoostRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache

    /// MSL: fullscreen textured quad; the fragment shader applies the
    /// brightness uniform to the captured color.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BoostVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BoostVertexOut boost_vert(uint vid [[vertex_id]]) {
        // Two triangles covering the clip space quad.
        float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
        BoostVertexOut out;
        out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        // Captured pixels are top-left origin; Metal NDC is bottom-left.
        out.uv = float2(pos.x, 1.0 - pos.y);
        return out;
    }

    fragment float4 boost_frag(BoostVertexOut in [[stage_in]],
                               constant float *p [[buffer(0)]],
                               texture2d<float> captureTexture [[texture(0)]],
                               sampler captureSampler [[sampler(0)]]) {
        // p[0]=brightness p[1]=contrast p[2]=saturation p[3]=gamma
        // p[4]=temperature p[5]=invert
        float4 color = captureTexture.sample(captureSampler, in.uv);
        float3 c = color.rgb;
        if (p[5] > 0.5) c = 1.0 - c;
        c.r *= (2.0 - p[4]);
        c.b *= p[4];
        c = (c - 0.5) * p[1] + 0.5;
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(luma), c, p[2]);
        c = pow(max(c, 0.0), float3(p[3]));
        c *= p[0];
        return float4(c, color.a);
    }
    """

    init(device: MTLDevice) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw OverlayError.metalSetupFailed
        }
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "boost_vert"),
              let fragmentFunction = library.makeFunction(name: "boost_frag") else {
            throw OverlayError.metalSetupFailed
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
            throw OverlayError.metalSetupFailed
        }
        self.sampler = sampler

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw OverlayError.metalSetupFailed
        }
        self.textureCache = cache

    }

    func render(pixelBuffer: CVPixelBuffer, params: ScreenFilterParams, in view: MTKView) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let drawable = view.currentDrawable else {
            return
        }
        if Int(view.drawableSize.width) != width || Int(view.drawableSize.height) != height {
            view.drawableSize = CGSize(width: width, height: height)
        }

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
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        var uniforms: [Float] = [
            Float(params.brightness), Float(params.contrast),
            Float(params.saturation), Float(params.gamma),
            Float(params.temperature), params.invert ? 1 : 0,
        ]
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.size, index: 0)
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
