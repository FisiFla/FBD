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
    case sourceUnavailable(String)
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

/// What a PiP session captures.
///
/// ScreenCaptureKit exposes a different filter constructor per kind, so the
/// distinction is real rather than cosmetic: a display capture excludes our own
/// overlay windows, a window capture follows that window's content, and an
/// application capture composites every window the app owns (BetterDisplay's
/// "group of windows").
public enum PiPCaptureSource: Equatable, Sendable {
    /// A whole display, by `CGDirectDisplayID`.
    case display(CGDirectDisplayID)
    /// A single on-screen window, by `CGWindowID`.
    case window(CGWindowID)
    /// Every window belonging to an application, by bundle identifier.
    case application(String)

    /// Stable form used by the CLI, logging and equality.
    public var identifier: String {
        switch self {
        case .display(let id): return "display:\(id)"
        case .window(let id): return "window:\(id)"
        case .application(let bundleID): return "app:\(bundleID)"
        }
    }
}

/// One capturable source, as offered by `PipStreamController.availableSources()`.
public struct PiPCaptureCandidate: Equatable, Sendable {
    public let source: PiPCaptureSource
    /// Human-readable description for the CLI listing.
    public let label: String

    public init(source: PiPCaptureSource, label: String) {
        self.source = source
        self.label = label
    }
}

/// How a capture is presented on the host display.
public enum PiPPresentation: Equatable, Sendable {
    /// Floating, resizable, rounded window — the classic picture-in-picture.
    case floating
    /// Borderless, full-screen on the host display. This is what makes the
    /// controller serve **local streaming** (redirecting one display's contents
    /// onto another) as well as PiP: the pipeline is identical, only the window
    /// differs, which is why there is one controller rather than two copies of
    /// the ScreenCaptureKit + Metal plumbing.
    case fullScreen
}

/// Fetch the shareable content ScreenCaptureKit currently exposes.
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

/// The display containing a window's centre, or nil when it is off-screen.
/// `SCWindow.frame` and `CGDisplayBounds` share one global top-left coordinate
/// space, so containment is a direct test.
private func displayID(containing frame: CGRect) -> CGDirectDisplayID? {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }
        if CGDisplayBounds(number.uint32Value).contains(center) {
            return number.uint32Value
        }
    }
    return nil
}

/// Backing scale factor of the display containing a window, so a captured
/// window is rendered at its physical pixel size rather than its point size.
private func backingScaleFactor(containing frame: CGRect) -> CGFloat {
    guard let id = displayID(containing: frame) else {
        return NSScreen.main?.backingScaleFactor ?? 1
    }
    return NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.backingScaleFactor ?? 1
}

/// Picture-in-Picture streaming controller:
///
/// Opens a single draggable, rounded-corner floating window (~480×270, 16:9)
/// that live-streams a **display, a single window, or every window of an
/// application** through a Metal pipeline (ScreenCaptureKit, macOS 13+). A
/// fragment shader applies brightness/contrast/saturation filters
/// (`setFilter`); the source is aspect-fit into the window with black
/// letterboxing.
///
/// The window is created on the main thread; capture + Metal rendering run on
/// a serial queue. Missing screen-recording permission is reported
/// synchronously via the return value — never crash, never block; async
/// failures tear the PiP down and log.
@MainActor
public final class PipStreamController: NSObject, NSWindowDelegate {
    /// One PiP window process-wide: every UI entry point (display options
    /// menu, footer) shares this instance so opening PiP reuses
    /// the existing window instead of spawning more.
    public static let shared = PipStreamController()

    /// The active PiP window (nil when no PiP is showing).
    private var window: NSWindow?
    /// The active capture session (window + stream + renderer); at most one.
    private var session: PipSession?

    public override init() { super.init() }

    deinit {
        // Break the stream↔output retain cycle (SCStream retains its outputs)
        // if the controller goes away without an explicit stop().
        session?.stop()
    }

    /// Open a PiP window for a display — the original entry point.
    /// Equivalent to `startPiP(source: .display(displayID), on: displayID, …)`,
    /// so the window appears on the display it captures.
    @discardableResult
    public func startPiP(displayID: CGDirectDisplayID, filter: VideoFilter = .identity) -> Bool {
        startPiP(source: .display(displayID), on: displayID, filter: filter)
    }

    /// Open a window capturing `source`.
    ///
    /// `on` is the display the *window* appears on; pass nil to let the source
    /// decide (the captured display for `.display`, the main display
    /// otherwise). `presentation` selects a floating PiP window or a
    /// full-screen local stream. Replaces any active capture. Returns false when
    /// screen-recording permission is missing, Metal is unavailable, or the
    /// placement display has no usable bounds; asynchronous capture failures
    /// tear it down and log — `isActive` then goes false.
    @discardableResult
    public func startPiP(
        source: PiPCaptureSource,
        on hostDisplayID: CGDirectDisplayID? = nil,
        presentation: PiPPresentation = .floating,
        filter: VideoFilter = .identity
    ) -> Bool {
        teardownPip()
        guard ScreenRecordingPermission.ensure() else {
            log.error("startPiP: screen-recording permission missing — grant Screen Recording to FBD in System Settings → Privacy & Security → Screen Recording, then relaunch FBD")
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("startPiP: no Metal device available")
            return false
        }
        let placementID = hostDisplayID ?? defaultHostDisplay(for: source)
        let bounds = CGDisplayBounds(placementID)
        guard isUsable(bounds) else {
            log.error("startPiP: no valid bounds for display \(placementID)")
            return false
        }
        do {
            let renderer = try PipRenderer(device: device)
            let (window, metalView) = makeWindow(
                hostDisplayID: placementID,
                source: source,
                presentation: presentation,
                device: device
            )
            let session = PipSession(
                source: source,
                hostDisplayID: placementID,
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

    /// Capturable sources right now: displays, then on-screen windows, then
    /// applications. Empty when Screen Recording permission is missing or
    /// ScreenCaptureKit has nothing to offer — callers report that rather than
    /// treating it as "no sources exist".
    public func availableSources() async -> [PiPCaptureCandidate] {
        guard ScreenRecordingPermission.ensure() else {
            log.error("availableSources: screen-recording permission missing")
            return []
        }
        guard let content = try? await fetchShareableContent() else { return [] }
        var candidates: [PiPCaptureCandidate] = []
        for display in content.displays {
            candidates.append(PiPCaptureCandidate(
                source: .display(display.displayID),
                label: "display \(display.displayID) (\(display.width)×\(display.height))"
            ))
        }
        for window in content.windows {
            guard window.isOnScreen, window.frame.width >= 16, window.frame.height >= 16 else { continue }
            let app = window.owningApplication?.applicationName ?? "?"
            let title = (window.title?.isEmpty == false) ? window.title! : "(untitled)"
            candidates.append(PiPCaptureCandidate(
                source: .window(window.windowID),
                label: "window \(window.windowID) — \(app): \(title)"
            ))
        }
        for application in content.applications {
            let bundleID = application.bundleIdentifier
            candidates.append(PiPCaptureCandidate(
                source: .application(bundleID),
                label: "app \(bundleID) — \(application.applicationName)"
            ))
        }
        return candidates
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

    // MARK: NSWindowDelegate

    /// The title-bar close button: tear down the session (the window itself
    /// is destroyed by teardown, so the close is fully handled here).
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        teardownPip()
        return false
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

    /// Where the PiP window goes when the caller did not say.
    private func defaultHostDisplay(for source: PiPCaptureSource) -> CGDirectDisplayID {
        if case .display(let id) = source { return id }
        return CGMainDisplayID()
    }

    // MARK: - Window

    /// Build the presentation window for a capture: a floating PiP box or a
    /// full-screen local stream. Both host the same video view, so only the
    /// window differs.
    private func makeWindow(
        hostDisplayID: CGDirectDisplayID,
        source: PiPCaptureSource,
        presentation: PiPPresentation,
        device: MTLDevice
    ) -> (NSWindow, MTKView) {
        switch presentation {
        case .floating:
            return makeFloatingWindow(hostDisplayID: hostDisplayID, source: source, device: device)
        case .fullScreen:
            return makeFullScreenWindow(hostDisplayID: hostDisplayID, source: source, device: device)
        }
    }

    /// `MTKView` configured the same way for every presentation. Frames are
    /// presented manually by the capture pipeline (off-main), not by MTKView's
    /// own draw loop.
    private func makeVideoView(device: MTLDevice, frame: NSRect) -> MTKView {
        let view = MTKView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width, .height]
        return view
    }

    /// Borderless full-screen window on the host display — **local streaming**.
    ///
    /// Floating window level, so the streamed content stays visible instead of
    /// being buried by whatever else is on that display. No close button: the
    /// stream is ended by its owner (`fbdcli stream stop`, or closing the PiP
    /// window from the app).
    private func makeFullScreenWindow(
        hostDisplayID: CGDirectDisplayID,
        source: PiPCaptureSource,
        device: MTLDevice
    ) -> (NSWindow, MTKView) {
        let bounds = CGDisplayBounds(hostDisplayID)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = source.title
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = true
        window.backgroundColor = .black
        window.isMovableByWindowBackground = false
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: bounds.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let view = makeVideoView(device: device, frame: container.bounds)
        container.addSubview(view)

        window.contentView = container
        return (window, view)
    }

    /// Floating PiP window (~480×270) placed near the bottom-right of the host
    /// display: titled so it has a native close button and resize edges, with a
    /// transparent titlebar for the compact look, draggable by its background.
    private func makeFloatingWindow(
        hostDisplayID: CGDirectDisplayID,
        source: PiPCaptureSource,
        device: MTLDevice
    ) -> (NSWindow, MTKView) {
        let size = NSSize(width: 480, height: 270)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == hostDisplayID
        } ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.minY + 24)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = source.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 240, height: 135)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.delegate = self
        // isReleasedWhenClosed stays false: close() on an autoreleased
        // window over-released (segfault). Teardown detaches the content
        // view and drops the session reference; the window then deallocates
        // naturally and the window server removes it.
        window.isReleasedWhenClosed = false
        window.hasShadow = true

        // Rounded black container clips the video layer; letterbox bars are
        // black by construction.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let view = makeVideoView(device: device, frame: container.bounds)
        container.addSubview(view)

        window.contentView = container
        return (window, view)
    }

    private func isUsable(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isEmpty && bounds.width > 0 && bounds.height > 0
    }
}

private extension PiPCaptureSource {
    /// Window title shown while the PiP is live.
    var title: String {
        switch self {
        case .display(let id): return "FBD PiP — display \(id)"
        case .window(let id): return "FBD PiP — window \(id)"
        case .application(let bundleID): return "FBD PiP — \(bundleID)"
        }
    }
}

// MARK: - PiP session (capture + render pipeline)

/// Owns the PiP window's capture stream and renderer. All capture/render work
/// happens on `queue` (a serial queue); window/state mutations hop to the main
/// thread.
private final class PipSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let source: PiPCaptureSource
    let hostDisplayID: CGDirectDisplayID
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
        stateLock.withLock { _isCapturing }
    }

    init(
        source: PiPCaptureSource,
        hostDisplayID: CGDirectDisplayID,
        window: NSWindow,
        metalView: MTKView,
        renderer: PipRenderer,
        owner: PipStreamController
    ) {
        self.source = source
        self.hostDisplayID = hostDisplayID
        self.window = window
        self.metalView = metalView
        self.renderer = renderer
        self.owner = owner
        self.queue = DispatchQueue(label: "dev.fisifla.fbd.pip.\(source.identifier)", qos: .userInteractive)
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

    /// Stop the stream and destroy the window. The window is made invisible
    /// and detached SYNCHRONOUSLY (this runs on the main actor via
    /// teardownPip) — a lone async orderOut leaves the window composited on
    /// this system (same fix as the boost overlay). The stream is stopped on
    /// `queue` afterwards; once the session's strong references drop, the
    /// window deallocates and the window server removes it.
    func stop() {
        stateLock.withLock { _isStopping = true }
        window.alphaValue = 0
        window.contentView = nil
        metalView.delegate = nil
        window.orderOut(nil)
        queue.async { [weak self] in
            guard let self else { return }
            let current = stateLock.withLock { self.stream }
            if let stream = current {
                try? stream.removeStreamOutput(self, type: .screen)
                stream.stopCapture { _ in }
            }
            stateLock.lock()
            self.stream = nil
            stateLock.unlock()
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
            let (filter, size) = try makeFilterAndSize(from: content)
            let config = makeConfiguration(width: size.0, height: size.1)
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stateLock.withLock { stream = newStream }
            // Async startCapture (the completion variant is deprecated).
            Task { @MainActor [weak self, newStream] in
                guard let self else { return }
                do {
                    try await newStream.startCapture()
                    self.stateLock.withLock { self._isCapturing = true }
                } catch {
                    self.fail("startCapture failed: \(error.localizedDescription)")
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Resolve the ScreenCaptureKit filter for this session's source, plus the
    /// capture size to request.
    ///
    /// Display captures keep the historical point-sized configuration;
    /// window captures render at the window's physical pixel size so they are
    /// not upscaled by the letterboxing renderer; application captures fill the
    /// host display (ScreenCaptureKit composites the app's windows into it).
    @MainActor
    private func makeFilterAndSize(from content: SCShareableContent) throws -> (SCContentFilter, (Int, Int)) {
        switch source {
        case .display(let displayID):
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                throw PipError.sourceUnavailable("display \(displayID)")
            }
            // Never capture the PiP window itself — it would otherwise feed
            // back into the next frame. Everything else stays included.
            let ownWindowID = owner?.pipWindowID() ?? 0
            let excluded = content.windows.filter { $0.windowID == ownWindowID }
            // Capture at the panel's PHYSICAL pixel size. `SCDisplay.width/height`
            // are points, so on a 2x panel a point-sized capture is half the
            // available resolution and reads as soft, or as odd scaling once the
            // renderer fits it to a target display — the same reason
            // OverlayController captures pixels rather than points.
            return (
                SCContentFilter(display: scDisplay, excludingWindows: excluded),
                (CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID))
            )

        case .window(let windowID):
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                throw PipError.sourceUnavailable("window \(windowID)")
            }
            let scale = backingScaleFactor(containing: scWindow.frame)
            let width = max(Int((scWindow.frame.width * scale).rounded()), 1)
            let height = max(Int((scWindow.frame.height * scale).rounded()), 1)
            return (SCContentFilter(desktopIndependentWindow: scWindow), (width, height))

        case .application(let bundleID):
            let applications = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !applications.isEmpty else {
                throw PipError.sourceUnavailable("application \(bundleID)")
            }
            // The application filter is display-anchored — the display-less
            // variant was obsoleted — so anchor it to the display the app's
            // windows are ACTUALLY on. Anchoring to the host display instead
            // captures an empty region whenever the app lives on another screen,
            // which renders as a black PiP with no error anywhere.
            let appWindows = content.windows.filter {
                $0.isOnScreen && $0.owningApplication?.bundleIdentifier == bundleID
            }
            let anchorID = appWindows.compactMap { displayID(containing: $0.frame) }.first ?? hostDisplayID
            guard let scDisplay = content.displays.first(where: { $0.displayID == anchorID })
                ?? content.displays.first else {
                throw PipError.sourceUnavailable("display for application \(bundleID)")
            }
            let ownWindowID = owner?.pipWindowID() ?? 0
            let excluded = content.windows.filter { $0.windowID == ownWindowID }
            return (
                SCContentFilter(display: scDisplay, including: applications, exceptingWindows: excluded),
                (CGDisplayPixelsWide(anchorID), CGDisplayPixelsHigh(anchorID))
            )
        }
    }

    private func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15) // 15 fps
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = OSType(kCVPixelFormatType_32BGRA)
        config.capturesAudio = false
        return config
    }

    /// Log the failure and tear the PiP down on the main thread.
    private func fail(_ reason: String) {
        log.error("PiP failed for \(self.source.identifier): \(reason)")
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
        log.error("PiP stream stopped unexpectedly for \(self.source.identifier): \(error.localizedDescription)")
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
        // Opaque by construction. An application-filter capture carries
        // transparency wherever the app has no window (the filter excludes the
        // desktop and dock), and passing that alpha through composited the video
        // away against the window's black container — a black rectangle with no
        // error anywhere. The video quad is meant to be opaque; the letterbox
        // around it comes from the render pass clear colour, not from the alpha.
        return float4(c, 1.0);
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
