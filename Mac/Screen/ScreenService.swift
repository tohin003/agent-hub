import AppKit
import CoreGraphics

/// Shares each display's stream between the phones watching it, and stops a stream when nobody watches.
@MainActor
final class ScreenService {
    private var streamers: [CGDirectDisplayID: ScreenStreamer] = [:]
    private var viewers: [CGDirectDisplayID: Set<UUID>] = [:]
    private var clients: [UUID: ClientConnection] = [:]

    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("Privacy_Accessibility")
        }
    }

    static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Agent Hub's own switch for the live screen. Off: nothing is captured and watching is refused.
    var enabled = true {
        didSet { if !enabled { stopAll() } }
    }

    /// Ends every stream (the screen switch was turned off).
    func stopAll() {
        for client in clients.values { client.screenDisplay = nil }
        clients.removeAll()
        viewers.removeAll()
        let running = streamers.values
        streamers.removeAll()
        for streamer in running { Task { await streamer.stop() } }
    }

    /// Starts (or switches) the stream a screen connection receives.
    func watch(client: ClientConnection, params: ScreenStartParams) async throws {
        guard enabled else {
            throw WireError(code: "screen_off", message: "The live screen is turned off in Agent Hub.")
        }
        guard Self.screenRecordingAllowed else {
            Self.requestScreenRecording()
            throw WireError(code: "screen_recording",
                            message: "Allow Agent Hub in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
        let display = params.displayId.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        stopWatching(client: client)
        clients[client.id] = client
        client.screenDisplay = display
        client.screenSettings = params
        viewers[display, default: []].insert(client.id)
        if let streamer = streamers[display] {
            if let frame = streamer.latestFrame { client.sendScreenFrame(frame) }
            // The newest watcher's quality wins.
            await streamer.update(maxPixels: params.maxPixels, fps: params.fps, quality: params.quality)
            return
        }
        let streamer = ScreenStreamer(displayID: display)
        streamer.onFrame = { [weak self] frame in
            Task { @MainActor in self?.deliver(frame, display: display) }
        }
        streamer.onStop = { [weak self] _ in
            Task { @MainActor in self?.streamers[display] = nil }
        }
        streamers[display] = streamer
        do {
            try await streamer.start(maxPixels: params.maxPixels, fps: params.fps, quality: params.quality)
        } catch {
            if streamers[display] === streamer { streamers[display] = nil }
            throw WireError.failed("The screen couldn't be captured: \(error.localizedDescription)")
        }
        // Everyone left (or sharing was turned off) while it was starting: stop it now.
        if streamers[display] !== streamer || viewers[display]?.isEmpty ?? true || !enabled {
            if streamers[display] === streamer { streamers[display] = nil }
            await streamer.stop()
        }
    }

    func stopWatching(client: ClientConnection) {
        guard let display = client.screenDisplay else { return }
        client.screenDisplay = nil
        viewers[display]?.remove(client.id)
        clients[client.id] = nil
        if viewers[display]?.isEmpty ?? true, let streamer = streamers.removeValue(forKey: display) {
            Task { await streamer.stop() }
        }
    }

    private func deliver(_ frame: Data, display: CGDirectDisplayID) {
        for id in viewers[display] ?? [] {
            clients[id]?.sendScreenFrame(frame)
        }
    }
}
