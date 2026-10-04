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
    /// Corner-mask overlay windows by display id (#21).
    private var cornerWindows: [CGDirectDisplayID: NSWindow] = [:]
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

    // MARK: - Rounded corners

    /// True when a corner mask exists for the display.
    public func isMaskingCorners(displayID: CGDirectDisplayID) -> Bool {
        cornerWindows[displayID] != nil
    }

    /// Round a square display — or square off a panel that has rounded corners
    /// of its own — by painting black over everything outside a rounded
    /// rectangle of `radius`.
    ///
    /// A **drawn mask, not a capture**: it reuses the shared overlay-window
    /// factory, so it needs no Screen Recording permission, ignores mouse
    /// events, and sits at the same shielding level as the other overlays.
    /// `radius <= 0` removes the mask outright rather than leaving a no-op
    /// window on screen.
    public func setCornerRadius(_ radius: Double, displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        guard isUsable(bounds) else {
            removeCornerMask(for: displayID)
            return
        }
        let clamped = CornerMask.clampedRadius(radius, in: bounds.size)
        guard clamped > 0 else {
            removeCornerMask(for: displayID)
            return
        }

        let window: NSWindow
        if let existing = cornerWindows[displayID] {
            window = existing
        } else {
            window = makeOverlayWindow(bounds: bounds, backgroundColor: .clear)
            let host = NSView(frame: NSRect(origin: .zero, size: bounds.size))
            host.wantsLayer = true
            let shape = CAShapeLayer()
            shape.fillColor = NSColor.black.cgColor
            // Even-odd over the full rect plus the rounded rect leaves exactly
            // the four slivers outside the rounded shape.
            shape.fillRule = .evenOdd
            host.layer = shape
            window.contentView = host
            cornerWindows[displayID] = window
        }
        (window.contentView?.layer as? CAShapeLayer)?.path =
            CornerMask.path(size: bounds.size, radius: clamped)
        window.setFrame(bounds, display: true)
        window.orderFrontRegardless()
    }

    private func removeCornerMask(for displayID: CGDirectDisplayID) {
        guard let window = cornerWindows.removeValue(forKey: displayID) else { return }
        window.contentView = nil
        window.orderOut(nil)
        window.close()
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
        guard ScreenRecordingPermission.ensure() else {
            log.error("setScreenFilter: screen-recording permission missing — grant Screen Recording to FBD in System Settings → Privacy & Security → Screen Recording, then relaunch FBD")
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
        removeCornerMask(for: displayID)
        teardownBoost(for: displayID)
    }

    /// Tear down all overlays.
    public func stopAll() {
        for id in Array(dimWindows.keys) {
            removeDim(for: id)
        }
        for id in Array(cornerWindows.keys) {
            removeCornerMask(for: id)
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

    /// Update the filter. Callers are main-thread (@MainActor
    /// `OverlayController.setScreenFilter` / `start`), which is the same thread
    /// the MTKView draw loop runs on — so mutating the renderer's LUT texture
    /// here cannot race `draw(in:)`.
    func setParams(_ params: ScreenFilterParams) {
        stateLock.lock()
        filterParams = params
        stateLock.unlock()
        renderer.setLUT(path: params.lutPath)
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
            // The async variant rather than the completion one: it is not
            // deprecated, and it drops the @Sendable completion that forced a
            // non-Sendable self capture across the concurrency boundary.
            do {
                try await newStream.startCapture()
                // Scoped locking: lock()/unlock() are unavailable from an async
                // context (an error in Swift 6), and a scoped critical section is
                // what that diagnostic asks for.
                self.stateLock.withLock { self._isCapturing = true }
            } catch {
                self.fail("startCapture failed: \(error.localizedDescription)")
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

/// Draws a captured `CVPixelBuffer` as a fullscreen textured quad, applying the
/// `ScreenFilterParams` in one pass: colour (brightness/contrast/saturation/
/// gamma/temperature/invert), then an unsharp mask, then geometry and an
/// optional 3D LUT.
///
/// Called from the MTKView draw loop (main thread) via `BoostSession.draw(in:)`,
/// which is also where the parameters and the LUT are updated — one thread, so
/// no locking.
private final class BoostRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureCache: CVMetalTextureCache
    /// Identity LUT bound whenever no cube is loaded, so the `texture3d`
    /// argument is always backed. A 2³ cube sampled linearly *is* the
    /// identity, and `p[11]` skips the stage entirely unless a real LUT is set
    /// — which matters because the stage clamps to 0…1 and would otherwise
    /// clip the XDR boost's > 1 values.
    private let identityLUT: MTLTexture?
    private var lutTexture: MTLTexture?
    private var lutPath: String?

    /// Uniform indices shared with the shader below. Keep the two in step.
    private enum Uniform {
        static let brightness = 0
        static let contrast = 1
        static let saturation = 2
        static let gamma = 3
        static let temperature = 4
        static let invert = 5
        static let sharpness = 6
        static let unsharpRadius = 7
        static let zoom = 8
        static let offsetX = 9
        static let offsetY = 10
        static let lutEnabled = 11
        static let count = 12
    }

    /// MSL: fullscreen textured quad; the vertex stage applies zoom/pan to the
    /// sampling coordinate, the fragment stage the colour, sharpening and LUT
    /// maths. `p[]` indices mirror `Uniform` above.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BoostVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BoostVertexOut boost_vert(uint vid [[vertex_id]],
                                     constant float *p [[buffer(0)]]) {
        // Two triangles covering the clip space quad.
        float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
        BoostVertexOut out;
        out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        // Captured pixels are top-left origin; Metal NDC is bottom-left.
        float2 uv = float2(pos.x, 1.0 - pos.y);
        // p[8]=zoom p[9]=offsetX p[10]=offsetY. Both are clamped on the Swift
        // side so the sampled window always lies inside the source image.
        float zoom = max(p[8], 1.0);
        out.uv = (uv - 0.5) / zoom + float2(p[9], p[10]) + 0.5;
        return out;
    }

    fragment float4 boost_frag(BoostVertexOut in [[stage_in]],
                               constant float *p [[buffer(0)]],
                               texture2d<float> captureTexture [[texture(0)]],
                               texture3d<float> lutTexture [[texture(1)]],
                               sampler captureSampler [[sampler(0)]]) {
        // p[0]=brightness p[1]=contrast p[2]=saturation p[3]=gamma
        // p[4]=temperature p[5]=invert p[6]=sharpness p[7]=unsharpRadius
        // p[11]=lutEnabled
        float4 color = captureTexture.sample(captureSampler, in.uv);
        float3 c = color.rgb;
        if (p[5] > 0.5) c = 1.0 - c;

        // Unsharp mask: a 4-tap cross blur, then push the difference back.
        // Applied on the neutral signal, before the colour maths, so it is a
        // spatial operation on the source image.
        if (p[6] > 0.0 && p[7] > 0.0) {
            float2 texel = 1.0 / float2(captureTexture.get_width(), captureTexture.get_height());
            float2 r = texel * p[7];
            float3 blur = (captureTexture.sample(captureSampler, in.uv + float2(r.x, 0.0)).rgb
                         + captureTexture.sample(captureSampler, in.uv - float2(r.x, 0.0)).rgb
                         + captureTexture.sample(captureSampler, in.uv + float2(0.0, r.y)).rgb
                         + captureTexture.sample(captureSampler, in.uv - float2(0.0, r.y)).rgb) * 0.25;
            c = c + p[6] * (c - blur);
        }

        c.r *= (2.0 - p[4]);
        c.b *= p[4];
        c = (c - 0.5) * p[1] + 0.5;
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(luma), c, p[2]);
        c = pow(max(c, 0.0), float3(p[3]));
        c *= p[0];

        if (p[11] > 0.5) {
            // Address the cube by its texel centres so a size-N LUT maps 0…1
            // onto the full grid rather than stopping half a texel short.
            float size = float(lutTexture.get_width());
            float3 uvw = clamp(c, 0.0, 1.0) * ((size - 1.0) / size) + (0.5 / size);
            c = lutTexture.sample(captureSampler, uvw).rgb;
        }
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
        // Samplers are dimension-agnostic; the 3D LUT reuses this one.
        samplerDescriptor.rAddressMode = .clampToEdge
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
        self.identityLUT = Self.makeIdentityLUTTexture(device: device)
    }

    // MARK: LUT

    /// Load (or clear) the 3D LUT backing the filter. No-op when the path is
    /// unchanged. A LUT that fails to load is logged and the stage is skipped —
    /// a bad cube must never take the overlay down with it.
    func setLUT(path: String?) {
        guard path != lutPath else { return }
        lutPath = path
        guard let path else {
            lutTexture = nil
            return
        }
        do {
            let cube = try LUTCubeParser.parse(contentsOf: URL(fileURLWithPath: path))
            lutTexture = Self.makeTexture(device: device, cube: cube)
            if lutTexture == nil {
                log.error("filter LUT '\(path)' parsed but the GPU texture could not be created")
            }
        } catch {
            log.error("filter LUT '\(path)' could not be loaded: \(String(describing: error))")
            lutTexture = nil
        }
    }

    /// A 2×2×2 identity cube — sampling it linearly is a no-op.
    private static func makeIdentityLUTTexture(device: MTLDevice) -> MTLTexture? {
        var values: [Float] = []
        values.reserveCapacity(8 * 3)
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    values.append(Float(r))
                    values.append(Float(g))
                    values.append(Float(b))
                }
            }
        }
        return makeTexture(device: device, cube: LUTCube(size: 2, values: values))
    }

    /// Upload a cube as a `size³` RGBA float 3D texture.
    private static func makeTexture(device: MTLDevice, cube: LUTCube) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = cube.size
        descriptor.height = cube.size
        descriptor.depth = cube.size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Rows are padded to Metal's 256-byte alignment requirement.
        let rowBytes = ((cube.size * 16) + 255) / 256 * 256
        var bytes = [UInt8](repeating: 0, count: rowBytes * cube.size * cube.size)
        for index in 0..<(cube.size * cube.size * cube.size) {
            let source = index * 3
            let destination = (index / cube.size) * rowBytes + (index % cube.size) * 16
            for component in 0..<3 {
                var bits = cube.values[source + component].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { raw in
                    for offset in 0..<4 {
                        bytes[destination + component * 4 + offset] = raw[offset]
                    }
                }
            }
            // Alpha stays 1.0 (0x3F800000) so the cube can never fade content.
            bytes[destination + 12] = 0x00
            bytes[destination + 13] = 0x00
            bytes[destination + 14] = 0x80
            bytes[destination + 15] = 0x3F
        }

        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: rowBytes,
                bytesPerImage: rowBytes * cube.size
            )
        }
        return texture
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

        var uniforms = [Float](repeating: 0, count: Uniform.count)
        uniforms[Uniform.brightness] = Float(params.brightness)
        uniforms[Uniform.contrast] = Float(params.contrast)
        uniforms[Uniform.saturation] = Float(params.saturation)
        uniforms[Uniform.gamma] = Float(params.gamma)
        uniforms[Uniform.temperature] = Float(params.temperature)
        uniforms[Uniform.invert] = params.invert ? 1 : 0
        uniforms[Uniform.sharpness] = Float(params.sharpness)
        uniforms[Uniform.unsharpRadius] = Float(params.unsharpRadius)
        uniforms[Uniform.zoom] = Float(params.zoom)
        uniforms[Uniform.offsetX] = Float(params.offsetX)
        uniforms[Uniform.offsetY] = Float(params.offsetY)
        let activeLUT = lutTexture ?? identityLUT
        uniforms[Uniform.lutEnabled] = lutTexture != nil ? 1 : 0

        let uniformLength = uniforms.count * MemoryLayout<Float>.size
        // The vertex stage needs zoom/pan from the same block.
        encoder.setVertexBytes(&uniforms, length: uniformLength, index: 0)
        encoder.setFragmentBytes(&uniforms, length: uniformLength, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        if let activeLUT {
            encoder.setFragmentTexture(activeLUT, index: 1)
        }
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Evict cache entries no longer referenced by in-flight command buffers.
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
