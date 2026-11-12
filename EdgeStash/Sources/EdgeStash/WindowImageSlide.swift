import AppKit
import ScreenCaptureKit
import EdgeStashCore

// A clipped, noninteractive stand-in while macOS prevents the real window moving above the menu bar.
@MainActor final class WindowImageSlide {
    private(set) var panel: TabPanel?
    private(set) var imageView: NSImageView?
    private var captureTask: Task<Void, Never>?
    private var timer: Timer?
    private var timeout: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?

    func start(from origin: CGRect, to destination: CGRect, screen: CGRect, primaryHeight: CGFloat, duration: Double,
               capture: @escaping () async -> CGImage?, isValid: @escaping () -> Bool,
               prepare: @escaping () throws -> Void, completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        let timeout = DispatchWorkItem { [weak self] in self?.finish(false) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
        captureTask = Task { @MainActor [weak self] in
            let image = await capture()
            guard !Task.isCancelled, let self else { return }
            self.timeout?.cancel(); self.timeout = nil
            guard let image, isValid() else { self.finish(false); return }
            let viewport = origin.union(destination).intersection(screen)
            guard !viewport.isNull, viewport.width > 0, viewport.height > 0 else { self.finish(false); return }
            let panel = TabPanel(contentRect: flip(viewport, primaryHeight: primaryHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.stationary, .ignoresCycle]
            let clip = NSView(frame: CGRect(origin: .zero, size: viewport.size))
            clip.wantsLayer = true; clip.layer?.masksToBounds = true
            let view = NSImageView()
            view.image = NSImage(cgImage: image, size: origin.size)
            view.imageScaling = .scaleAxesIndependently
            clip.addSubview(view); panel.contentView = clip
            self.panel = panel; self.imageView = view
            @MainActor func place(_ frame: CGRect) {
                view.frame = CGRect(x: frame.minX - viewport.minX, y: viewport.maxY - frame.maxY, width: frame.width, height: frame.height)
            }
            place(origin); panel.orderFrontRegardless(); panel.displayIfNeeded()
            do { try prepare() } catch { self.finish(false); return }
            let started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    guard isValid() else { self.finish(false); return }
                    let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / max(0.01, duration))
                    place(slideFrame(from: origin, to: destination, progress: progress))
                    panel.displayIfNeeded()
                    if progress >= 1 { self.finish(true) }
                }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func finish(_ completed: Bool) {
        let callback = completion; completion = nil
        // Hand the last frame to the real window before removing the stand-in.
        callback?(completed)
        cancel()
    }

    func cancel() {
        completion = nil
        captureTask?.cancel(); captureTask = nil
        timeout?.cancel(); timeout = nil
        timer?.invalidate(); timer = nil
        imageView?.image = nil; imageView = nil
        panel?.close(); panel = nil
    }

    deinit { MainActor.assumeIsolated { cancel() } }
}

func matchingCaptureWindow<Window>(_ windows: [Window], expectedFrame: CGRect, title: String,
                                  frame: (Window) -> CGRect, windowTitle: (Window) -> String?) -> Window? {
    let geometry = windows.filter { framesMatch(frame($0), expectedFrame, tolerance: 3) }
    if geometry.count == 1 { return geometry[0] }
    let pool = geometry.isEmpty ? windows : geometry
    guard !title.isEmpty else { return nil }
    let named = pool.filter { windowTitle($0) == title }
    return named.count == 1 ? named[0] : nil
}

@available(macOS 14.0, *)
func captureWindowImage(pid: pid_t, title: String, frame: CGRect) async -> CGImage? {
    guard CGPreflightScreenCaptureAccess() else { return nil }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !Task.isCancelled else { return nil }
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid }
        // Capture metadata may lag an offscreen move or expose a different title than Accessibility.
        guard let window = matchingCaptureWindow(candidates, expectedFrame: frame, title: title,
            frame: { $0.frame }, windowTitle: { $0.title }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 4096 / max(frame.width, frame.height))
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true; configuration.ignoreGlobalClipSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    } catch { return nil }
}

extension AppDelegate {
    func shouldUseImageSlide(_ entry: StashedWindow, animated: Bool) -> Bool {
        if #available(macOS 14.0, *) {
            return entry.edge == .top && animated && preferences.animate && !isSleeping
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && CGPreflightScreenCaptureAccess()
        }
        return false
    }

    @objc func enableScreenRecording() {
        guard #available(macOS 14.0, *) else { report("Top-edge image slides require macOS 14 or later."); return }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealWithImageSlide(_ entry: StashedWindow, to destination: CGRect) {
        MainActor.assumeIsolated {
            let slide = WindowImageSlide()
            entry.imageSlide = slide
            let expected = try? frame(of: entry.element)
            let title = attribute(entry.element, kAXTitleAttribute) as? String ?? entry.recovery.title
            let pid = entry.recovery.pid
            slide.start(from: entry.edge.hiddenFrame(destination, screen: entry.screen, sliver: 0), to: destination,
                screen: entry.screen, primaryHeight: primaryHeight, duration: preferences.animationDuration,
                capture: {
                    guard #available(macOS 14.0, *), let expected else { return nil }
                    return await captureWindowImage(pid: pid, title: title, frame: expected)
                }, isValid: { [weak self, weak entry] in
                    self?.isSleeping == false && self?.preferences.animate == true && entry?.scope.isActive == true
                        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }, prepare: {}, completion: { [weak self, weak entry, weak slide] _ in
                    guard let self, let entry, let slide, entry.imageSlide === slide else { return }
                    entry.imageSlide = nil; entry.revealed = false
                    if entry.scope.isActive && !self.isSleeping {
                        self.perform { try self.reveal(entry, animated: false) }
                    }
                    self.layoutTabs()
                })
        }
    }

    func hideWithImageSlide(_ entry: StashedWindow, from origin: CGRect) {
        MainActor.assumeIsolated {
            let slide = WindowImageSlide()
            entry.imageSlide = slide
            let title = attribute(entry.element, kAXTitleAttribute) as? String ?? entry.recovery.title
            let pid = entry.recovery.pid
            var concealed = false
            slide.start(from: origin, to: entry.edge.hiddenFrame(origin, screen: entry.screen, sliver: 0),
                screen: entry.screen, primaryHeight: primaryHeight, duration: preferences.animationDuration,
                capture: {
                    guard #available(macOS 14.0, *) else { return nil }
                    return await captureWindowImage(pid: pid, title: title, frame: origin)
                }, isValid: { [weak self, weak entry] in
                    self?.isSleeping == false && self?.preferences.animate == true && entry?.scope.isActive == true
                        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }, prepare: { [weak self, weak entry] in
                    guard let self, let entry, framesMatch(try frame(of: entry.element), origin) else {
                        throw StashError.message("The window changed during its transition.")
                    }
                    concealed = true
                    self.conceal(entry, from: origin, animated: false)
                    guard !entry.revealed else { throw StashError.message("The window could not be hidden.") }
                }, completion: { [weak self, weak entry, weak slide] _ in
                    guard let self, let entry, let slide, entry.imageSlide === slide else { return }
                    entry.imageSlide = nil
                    if !concealed {
                        entry.revealed = true
                        self.perform { try self.hide(entry, animated: false) }
                    }
                    self.layoutTabs()
                })
        }
    }
}
