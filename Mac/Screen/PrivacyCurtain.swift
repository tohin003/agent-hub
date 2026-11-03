import AppKit
import IOKit.pwr_mgt
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import OpenDirectory
import SwiftUI

/// The privacy screen. While you drive the Mac from your phone, it covers every display with a message and hides the
/// pointer, so people near the Mac can't see what you're doing, and it holds back the Mac's own mouse, trackpad and
/// keyboard. Your phone still sees and drives everything under it, live: the streams leave the curtain's windows out,
/// the apps under it keep drawing (macOS doesn't count it as covering them), the display stays awake, and the hub's
/// clicks and keys pass. At the Mac, any key or click asks for Touch ID (or an Apple Watch) or the account password,
/// which takes it down; for Touch ID the hub comes to the front meanwhile, then hands the Mac back. It never outlives
/// the hub: quitting or restarting Agent Hub takes it down too.
///
/// While it's up the displays' output is black as well (`PrivacyShade`), apart from while someone at the Mac unlocks:
/// macOS doesn't keep even this window over a display while it slides from one Space to another, so each switch
/// showed the Space for about a second. The phone's picture doesn't change: capture reads what macOS draws, before
/// the display's transfer table.
@MainActor
final class PrivacyCurtain {
    private(set) var isOn = false
    /// Someone at the Mac unlocked it.
    var onUnlocked: (() -> Void)?
    /// Its windows were made again (a display came or went).
    var onCovered: (() -> Void)?

    /// Its windows, which the phone's streams leave out.
    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    private let model = CurtainModel()
    private var windows: [CurtainWindow] = []
    private var tap: CurtainTap?
    private var screens: NSObjectProtocol?
    private var idle: Task<Void, Never>?
    private var authentication: LAContext?
    private var misses = 0
    private var retryAfter = Date.distantPast
    /// Keeps the display awake while it's up: asleep, it would stop the phone's picture.
    private var awake: IOPMAssertionID = 0
    /// The pointer is hidden while it's up: macOS draws it above every window, so it would show where the phone clicks.
    private var pointerHidden = false
    /// Brings the hub forward for Touch ID while someone at the Mac unlocks.
    private var forward: Task<Void, Never>?
    /// The app that was in front before that, which gets the Mac back afterwards.
    private var handBackTo: NSRunningApplication?
    /// The displays' output: black while it's up.
    let shade = PrivacyShade(output: SystemDisplayOutput(), fader: SystemFader(), markerPath: DisplayBlackout.markerPath)
    /// Twice a second: the displays stay black, and the watchdog hears the main thread is alive.
    private var monitor: Timer?
    private var watchdog: DispatchSourceTimer?
    /// Gives the displays back if the hub quits or is told to stop while it's up.
    private var quitWatch: (observer: NSObjectProtocol, sources: [DispatchSourceSignal], signals: [Int32])?

    /// The first name on the Mac's account.
    static var name: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    func show() throws {
        guard !isOn else { return }
        guard InputInjector.trusted else {
            throw WireError(code: "accessibility",
                            message: "Allow Agent Hub in System Settings › Privacy & Security › Accessibility to use the privacy screen.")
        }
        let tap = CurtainTap(onWake: { [weak self] in Task { @MainActor [weak self] in self?.beginUnlocking() } },
                             onKey: { [weak self] key in Task { @MainActor [weak self] in self?.typed(key) } })
        guard tap.start() else {
            throw WireError(code: "accessibility",
                            message: "macOS didn't let Agent Hub hold the Mac's mouse and keyboard. Check Accessibility in System Settings.")
        }
        self.tap = tap
        isOn = true
        misses = 0
        retryAfter = .distantPast
        model.name = Self.name
        shade.curtainUp(at: .now)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Agent Hub's privacy screen is up: the phone is using this Mac" as CFString,
                                       &awake) != kIOReturnSuccess {
            awake = 0
            Log.warn("privacy screen: couldn't keep the display awake")
        }
        cover()
        hidePointer()
        startMonitoring()
        watchForQuit()
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                self.cover()
                // A display that came goes black too; one that went is forgotten.
                self.shade.tick(at: .now)
                self.onCovered?()
            }
        }
        let black = shade.blackout.blackDisplays.count, windowOnly = shade.blackout.windowOnlyDisplays.count
        Log.info("privacy screen: on (\(black) display(s) black" + (windowOnly > 0 ? ", \(windowOnly) covered by the window only)" : ")"))
    }

    func hide() {
        guard isOn else { return }
        isOn = false
        shade.curtainDown()
        stopMonitoring()
        stopWatchingForQuit()
        stopUnlocking()
        tap?.stop()
        tap = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        showPointer()
        if awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
        Log.info("privacy screen: off")
    }

    /// A window over each display (again whenever displays come and go); the first one holds the unlock panel.
    private func cover() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.enumerated().map { index, screen in
            let window = CurtainWindow(frame: screen.frame, content: CurtainView(model: model, unlockHere: index == 0))
            window.orderFrontRegardless()
            return window
        }
    }

    private func hidePointer() {
        guard !pointerHidden else { return }
        guard Pointer.setFromBackground(true) else {
            Log.warn("privacy screen: macOS didn't let the hub hide the pointer")
            return
        }
        pointerHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    private func showPointer() {
        guard pointerHidden else { return }
        pointerHidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        _ = Pointer.setFromBackground(false)
    }

    // MARK: Unlocking

    private func beginUnlocking() {
        guard isOn else { return }
        waitForIdle()
        guard !model.unlocking else { return }
        model.unlocking = true
        model.password = ""
        model.message = nil
        tap?.unlocking = true
        // Whoever is at the Mac sees the curtain and its unlock panel.
        shade.unlockingBegan()
        Log.info("privacy screen: someone at the Mac is unlocking; the displays show the curtain")
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: &problem) else {
            Log.info("privacy screen: no Touch ID or Apple Watch to unlock with (\(problem?.code ?? 0): \(problem?.localizedDescription ?? "no reason given"))")
            return
        }
        authentication = context
        // Touch ID answers only the app in front: the hub comes forward first, then shows the Touch ID view, whose
        // appearance starts the check.
        forward = Task { [weak self, weak context] in
            await self?.comeForward()
            guard let self, let context, !Task.isCancelled, self.authentication === context, self.model.unlocking else {
                return
            }
            self.model.touchIDReady = { [weak self, weak context] in
                guard let self, let context, self.authentication === context else { return }
                // Once per check, even if the view is made again (a display came or went).
                self.model.touchIDReady = nil
                self.evaluate(context)
            }
            self.model.touchID = context
        }
    }

    /// Brings the hub to the front, its curtain window taking the keyboard focus (the tap still keeps every key from
    /// it), and remembers the app that was there. macOS may refuse an app in the background that asks; a click on one
    /// of its own windows always brings an app forward, so the hub clicks its curtain once if it has to.
    private func comeForward() async {
        guard let window = windows.first else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            handBackTo = front
        }
        window.takesFocus = true
        // Clickable while it comes forward, so the click below lands on it, not on the app underneath. AppKit passes
        // this to the window server a moment later, which the wait for macOS's own answer covers.
        window.ignoresMouseEvents = false
        defer { window.ignoresMouseEvents = true }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if await becomesActive(within: .milliseconds(300)) {
            Log.info("privacy screen: the hub came forward for Touch ID")
            return
        }
        guard !Task.isCancelled, let display = window.displayID else { return }
        let bounds = CGDisplayBounds(display)
        let pointer = CGEvent(source: nil)?.location
        InputInjector.click(at: CGPoint(x: bounds.midX, y: bounds.midY), button: .left, count: 1, flags: [])
        let came = await becomesActive(within: .milliseconds(600))
        window.makeKeyAndOrderFront(nil)
        // The click moved the (hidden) pointer: put it back where the phone left it.
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        Log.info("privacy screen: the hub \(came ? "came forward" : "couldn't come forward") for Touch ID after a click")
    }

    private func becomesActive(within limit: Duration) async -> Bool {
        let end = ContinuousClock.now + limit
        while !NSApp.isActive {
            guard ContinuousClock.now < end, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    /// Gives the front back to the app that had it before someone at the Mac started unlocking.
    private func handBack() {
        forward?.cancel()
        forward = nil
        windows.first?.takesFocus = false
        guard let app = handBackTo else { return }
        handBackTo = nil
        guard NSApp.isActive, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current, options: [])
    }

    /// Starts once the Touch ID view is on screen, so the prompt is drawn there instead of in a system dialog the
    /// curtain would cover.
    private func evaluate(_ context: LAContext) {
        let check = ObjectIdentifier(context)
        Log.info("privacy screen: waiting for Touch ID (hub in front: \(NSApp.isActive))")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion,
                               localizedReason: "turn off the privacy screen") { [weak self] success, error in
            let reason = (error as NSError?).map { "\($0.code): \($0.localizedDescription)" } ?? "no reason given"
            Task { @MainActor [weak self] in
                guard let self, let current = self.authentication, ObjectIdentifier(current) == check else { return }
                if success {
                    Log.info("privacy screen: Touch ID matched")
                    self.unlocked()
                } else {
                    // Cancelled, too many tries, or no match: the password still works.
                    Log.info("privacy screen: Touch ID stopped (\(reason)); the password still works")
                    self.authentication = nil
                    self.model.touchID = nil
                }
            }
        }
    }

    private func typed(_ key: CurtainKey) {
        guard isOn, model.unlocking else { return }
        waitForIdle()
        switch key {
        case .text(let text):
            guard !model.checking else { return }
            model.password += text
            model.message = nil
        case .delete:
            if !model.password.isEmpty, !model.checking { model.password.removeLast() }
        case .cancel:
            stopUnlocking()
        case .submit:
            checkPassword()
        }
    }

    private func checkPassword() {
        let password = model.password
        guard !password.isEmpty, !model.checking else { return }
        let wait = retryAfter.timeIntervalSinceNow
        guard wait <= 0 else {
            model.message = "Try again in \(Int(wait.rounded(.up))) seconds."
            return
        }
        model.checking = true
        Task {
            let matches = await Task.detached(priority: .userInitiated) {
                PrivacyCurtain.passwordMatches(password)
            }.value
            guard isOn, model.unlocking else { return }
            model.checking = false
            if matches {
                unlocked()
            } else {
                // Each miss makes the next try wait longer.
                misses += 1
                retryAfter = Date(timeIntervalSinceNow: Double(min(30, misses * misses)))
                model.password = ""
                model.message = "That password isn't right."
            }
        }
    }

    /// Checks the password of the Mac's account (the one you log in with).
    nonisolated static func passwordMatches(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }

    private func unlocked() {
        Log.info("privacy screen: unlocked at the Mac")
        hide()
        onUnlocked?()
    }

    /// Back to the message after half a minute without a key.
    private func waitForIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.stopUnlocking()
        }
    }

    private func stopUnlocking() {
        idle?.cancel()
        idle = nil
        authentication?.invalidate()
        authentication = nil
        handBack()
        model.touchID = nil
        model.touchIDReady = nil
        model.unlocking = false
        model.password = ""
        model.message = nil
        model.checking = false
        tap?.unlocking = false
        // Given up, or half a minute without a key: black again (nothing, once it's down).
        shade.unlockingEnded(at: .now)
    }

    // MARK: Keeping the displays black

    /// Its windows are on screen, on the Space the Mac shows now.
    var isOnScreen: Bool {
        let ids = windowIDs
        guard !ids.isEmpty,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let shown = Set(list.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } })
        return ids.isSubset(of: shown)
    }

    /// Twice a second, menus open or not: black again where something put a display's table back, and a beat for the
    /// watchdog, which gives the displays back from its own thread if the main thread stops beating.
    private func startMonitoring() {
        stopMonitoring()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.shade.tick(at: .now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
        let blackout = shade.blackout
        let dog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agenthub.privacy-watchdog"))
        dog.schedule(deadline: .now() + 0.5, repeating: 0.5)
        dog.setEventHandler { blackout.watchdog(at: .now) }
        dog.resume()
        watchdog = dog
    }

    private func stopMonitoring() {
        monitor?.invalidate()
        monitor = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// Quitting, or being told to stop (launchd's SIGTERM when the hub is restarted), gives the displays back first.
    /// A crash or a SIGKILL can't: the next hub gives them back when it starts (`DisplayBlackout.recover`).
    private func watchForQuit() {
        guard quitWatch == nil else { return }
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        var sources: [DispatchSourceSignal] = []
        var signals: [Int32] = []
        for number in [SIGTERM, SIGINT] {
            // Only where the signal still does what it does by default (end the hub).
            let previous = signal(number, SIG_IGN)
            guard previous == nil else {
                signal(number, previous)
                continue
            }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.hide() }
                // Then as before: the hub ends, and launchd treats it as it did.
                signal(number, SIG_DFL)
                raise(number)
            }
            source.resume()
            sources.append(source)
            signals.append(number)
        }
        quitWatch = (observer, sources, signals)
    }

    private func stopWatchingForQuit() {
        guard let quitWatch else { return }
        self.quitWatch = nil
        NotificationCenter.default.removeObserver(quitWatch.observer)
        quitWatch.sources.forEach { $0.cancel() }
        for number in quitWatch.signals { signal(number, SIG_DFL) }
    }
}

/// The privacy screen's hold on the Mac's own mouse, trackpad and keyboard: an event tap on a thread of its own, so
/// input never waits on the hub's main thread.
final class CurtainTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var holdingKeys = false
    private let onWake: @Sendable () -> Void
    private let onKey: @Sendable (CurtainKey) -> Void

    init(onWake: @escaping @Sendable () -> Void, onKey: @escaping @Sendable (CurtainKey) -> Void) {
        self.onWake = onWake
        self.onKey = onKey
    }

    /// Whether someone at the Mac is unlocking: their keys go to the password.
    var unlocking: Bool {
        get { lock.withLock { holdingKeys } }
        set { lock.withLock { holdingKeys = newValue } }
    }

    /// Starts holding input; false if macOS refuses the tap (it needs Accessibility).
    func start() -> Bool {
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CurtainInput.mask, callback: curtainTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        lock.withLock { self.port = port }
        let ready = DispatchSemaphore(value: 0)
        // The thread keeps this object alive until its run loop stops.
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            lock.withLock { loop = CFRunLoopGetCurrent() }
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Agent Hub privacy screen"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.port = nil
                self.loop = nil
            }
            return (self.port, self.loop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns off a tap that was slow or interrupted: turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        switch CurtainInput.decide(type, own: InputInjector.isOwn(event), unlocking: unlocking) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .wake:
            onWake()
            return nil
        case .key:
            if let key = CurtainKey(event) { onKey(key) }
            return nil
        }
    }
}

private func curtainTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<CurtainTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}

/// A borderless window over one display, above everything (the menu bar and the Dock too) and on every Space. Clicks
/// go through it, so the phone's land on the apps underneath.
private final class CurtainWindow: NSWindow {
    init(frame: NSRect, content: some View) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        // A hair short of solid (0.001%, far below what a display can show): macOS then still counts the windows
        // under it as on screen, so their apps keep drawing for the phone's stream. Under a fully solid window
        // they're told they're hidden, and browsers, Electron apps and some terminals stop drawing (a frozen picture
        // on the phone). Marking it not opaque isn't enough: only the window's alpha counts.
        alphaValue = 0.99999
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = NSHostingView(rootView: content)
        setFrame(frame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// While someone at the Mac unlocks, the window with the unlock panel takes the keyboard focus (Touch ID answers
    /// only the app in front); otherwise it never does.
    var takesFocus = false

    var displayID: CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    override var canBecomeKey: Bool { takesFocus }
    override var canBecomeMain: Bool { false }
}

/// The pointer belongs to the window server: an app may hide it only while it's in front, unless it first asks to set
/// the pointer from the background. That request isn't public API (apps that hide the pointer have relied on it for
/// many years); if a macOS version drops it, the pointer simply stays visible.
private enum Pointer {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, UnsafeRawPointer, UnsafeRawPointer) -> Int32

    static func setFromBackground(_ on: Bool) -> Bool {
        let anywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(anywhere, "CGSMainConnectionID") ?? dlsym(anywhere, "_CGSDefaultConnection"),
              let setSymbol = dlsym(anywhere, "CGSSetConnectionProperty"),
              let value = on ? kCFBooleanTrue : kCFBooleanFalse else { return false }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let key = "SetsCursorInBackground" as CFString
        return withExtendedLifetime(key) {
            unsafeBitCast(setSymbol, to: SetProperty.self)(connection, connection,
                                                           Unmanaged.passUnretained(key).toOpaque(),
                                                           Unmanaged.passUnretained(value).toOpaque()) == 0
        }
    }
}

@MainActor
@Observable
private final class CurtainModel {
    var name = ""
    var unlocking = false
    /// What's typed so far (shown as dots).
    var password = ""
    var checking = false
    var message: String?
    /// The Touch ID (or Apple Watch) check under way, if the Mac has either.
    var touchID: LAContext?
    @ObservationIgnored var touchIDReady: (() -> Void)?
}

/// What people near the Mac see.
private struct CurtainView: View {
    let model: CurtainModel
    /// The unlock panel shows on the first display only.
    let unlockHere: Bool

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 30) {
                BlobView(mood: model.unlocking && unlockHere ? .attention : .working, animated: false)
                    .frame(width: 168, height: 168)
                VStack(spacing: 12) {
                    Text("\(model.name) is using this Mac remotely.")
                        .font(.system(size: 44, weight: .semibold))
                    Text("Please stay away from it.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                if unlockHere {
                    unlock
                        .frame(height: 150, alignment: .top)
                }
            }
            .multilineTextAlignment(.center)
            .padding(60)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var unlock: some View {
        if model.unlocking {
            VStack(spacing: 14) {
                if let context = model.touchID {
                    TouchIDView(authContext: context) { model.touchIDReady?() }
                        .id(ObjectIdentifier(context))
                        .frame(width: 60, height: 60)
                }
                // The password as dots: the keys come here, never to an app.
                Text(String(repeating: "●", count: model.password.count))
                    .font(.system(size: 18))
                    .tracking(4)
                    .frame(width: 300, height: 40)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 10))
                Text(model.message ?? (model.touchID != nil
                    ? "Use Touch ID, or type your password and press Return."
                    : "Type your password and press Return."))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("To use this Mac, press any key.")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The Touch ID (or Apple Watch) prompt, drawn in the curtain itself.
private struct TouchIDView: NSViewRepresentable {
    let authContext: LAContext
    /// Called once the view is in its window: only then may the check start.
    let onReady: () -> Void

    func makeNSView(context: Context) -> TouchIDHost {
        let host = TouchIDHost()
        let view = LAAuthenticationView(context: authContext, controlSize: .large)
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                                     view.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
        host.onReady = onReady
        return host
    }

    func updateNSView(_ host: TouchIDHost, context: Context) {}
}

private final class TouchIDHost: NSView {
    var onReady: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let onReady else { return }
        self.onReady = nil
        DispatchQueue.main.async(execute: onReady)
    }
}
