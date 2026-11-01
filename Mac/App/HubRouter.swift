import AppKit

/// Answers the phone's requests.
extension Hub {
    func handle(_ frame: ClientFrame, from client: ClientConnection) async {
        do {
            if client.channel == .unknown, frame.method != Method.hello {
                throw WireError.badRequest("Say hello first.")
            }
            try await route(frame, client: client)
        } catch {
            client.fail(frame.id, error)
        }
    }

    private func params<T: Decodable>(_ frame: ClientFrame, _ type: T.Type) throws -> T {
        guard let params = frame.params else { throw WireError.badRequest("\(frame.method) needs parameters.") }
        do {
            return try params.decode(type)
        } catch {
            throw WireError.badRequest("\(frame.method): \(error.localizedDescription)")
        }
    }

    private func manager() throws -> SessionManager {
        guard let sessions else { throw WireError.failed(problem ?? "Sessions aren't available on the Mac.") }
        return sessions
    }

    private func route(_ frame: ClientFrame, client: ClientConnection) async throws {
        let id = frame.id
        switch frame.method {
        case Method.hello:
            let hello = try params(frame, HelloParams.self)
            guard hello.protocolVersion == WireProtocol.version else {
                throw WireError(code: "version", message: "Update Agent Hub on the iPhone or the Mac: they speak different versions.")
            }
            client.identify(channel: hello.channel == "screen" ? .screen : .control, device: hello.device)
            updateDevices()
            Log.info("hub: \(hello.device) connected (\(hello.channel)) from \(client.remote)")
            client.respond(id, HelloResult(hub: hubInfo, accounts: accounts, sessions: sessions?.sessions ?? []))

        case Method.ping:
            client.respond(id, OKResult())

        case Method.sessionsList:
            client.respond(id, sessions?.sessions ?? [])

        case Method.sessionCreate:
            let create = try params(frame, CreateSessionParams.self)
            let info = try await manager().create(create)
            client.subscribe(info.id, terminal: false)
            client.respond(id, info)

        case Method.sessionKill:
            let kill = try params(frame, KillParams.self)
            try await manager().kill(kill.sessionId, closeWindow: kill.closeWindow)
            client.respond(id, OKResult())

        case Method.sessionRemove:
            let ref = try params(frame, SessionRef.self)
            try await manager().remove(ref.sessionId)
            client.respond(id, OKResult())

        case Method.sessionRename:
            let rename = try params(frame, RenameParams.self)
            try await manager().rename(rename.sessionId, title: rename.title)
            client.respond(id, OKResult())

        case Method.sessionSend:
            let send = try params(frame, SendParams.self)
            try await manager().send(send.sessionId, text: send.text, submit: send.submit)
            client.respond(id, OKResult())

        case Method.sessionKeys:
            let keys = try params(frame, KeysParams.self)
            try await manager().keys(keys.sessionId, keys: keys.keys)
            client.respond(id, OKResult())

        case Method.sessionAnswer:
            let answer = try params(frame, AnswerParams.self)
            try await manager().answer(answer.sessionId, signature: answer.signature, optionIndex: answer.optionIndex,
                                       key: answer.key)
            client.respond(id, OKResult())

        case Method.sessionAnswerText:
            let answer = try params(frame, AnswerTextParams.self)
            try await manager().answerText(answer)
            client.respond(id, OKResult())

        case Method.sessionModel:
            let change = try params(frame, SessionModelParams.self)
            let manager = try manager()
            guard let session = manager.sessions.first(where: { $0.id == change.sessionId }) else {
                throw WireError.notFound("That session isn't running.")
            }
            let account = accounts.first { $0.id == session.accountId }
            try await manager.setModel(change, catalog: account.flatMap { modelCatalogs?.cached($0) })
            client.respond(id, OKResult())

        case Method.accountUsage:
            let ref = try params(frame, AccountParams.self)
            guard let account = accounts.first(where: { $0.id == ref.accountId }) else {
                throw WireError.notFound("That account isn't on this Mac.")
            }
            client.respond(id, try await accountUsage.usage(for: account, refresh: ref.refresh == true))

        case Method.accountModels:
            let ref = try params(frame, AccountParams.self)
            guard let account = accounts.first(where: { $0.id == ref.accountId }) else {
                throw WireError.notFound("That account isn't on this Mac.")
            }
            guard let catalogs = modelCatalogs else { throw WireError.failed(problem ?? "Sessions aren't available on the Mac.") }
            client.respond(id, try await catalogs.catalog(for: account, refresh: ref.refresh == true))

        case Method.accountCommands:
            let ref = try params(frame, AccountParams.self)
            guard let account = accounts.first(where: { $0.id == ref.accountId }) else {
                throw WireError.notFound("That account isn't on this Mac.")
            }
            guard let commands = accountCommands else { throw WireError.failed(problem ?? "Sessions aren't available on the Mac.") }
            client.respond(id, await commands.commands(for: account, refresh: ref.refresh == true))

        case Method.screenSharing:
            let change = try params(frame, ScreenSharingParams.self)
            setScreenSharing(change.enabled)
            client.respond(id, hubInfo)

        case "session.restart":
            let ref = try params(frame, SessionRef.self)
            try await manager().restart(ref.sessionId)
            client.respond(id, OKResult())

        case Method.sessionSubscribe:
            let subscribe = try params(frame, SubscribeParams.self)
            client.subscribe(subscribe.sessionId, terminal: subscribe.terminal)
            client.respond(id, try await manager().subscribe(subscribe))

        case Method.sessionUnsubscribe:
            let ref = try params(frame, SessionRef.self)
            client.unsubscribe(ref.sessionId)
            client.respond(id, OKResult())

        case Method.sessionPage:
            client.respond(id, try manager().page(try params(frame, PageParams.self)))

        case Method.sessionTool:
            client.respond(id, try manager().tool(try params(frame, ToolParams.self)))

        case Method.sessionSubagent:
            client.respond(id, try manager().subagent(try params(frame, SubagentParams.self)))

        case Method.sessionTaskOutput:
            client.respond(id, try manager().taskOutput(try params(frame, TaskOutputParams.self)))

        case Method.sessionWindow:
            try await manager().window(try params(frame, WindowParams.self))
            client.respond(id, OKResult())

        case Method.sessionScrollback:
            client.respond(id, try await manager().scrollback(try params(frame, ScrollbackParams.self)))

        case Method.sessionUpload:
            client.respond(id, try manager().upload(try params(frame, UploadParams.self)))

        case Method.historyList:
            let history = try params(frame, HistoryParams.self)
            guard let account = accounts.first(where: { $0.id == history.accountId }) else {
                throw WireError.notFound("That account isn't set up on the Mac.")
            }
            let entries = await Task.detached(priority: .userInitiated) {
                TranscriptLocator.history(for: account, limit: max(1, min(history.limit, 200)))
            }.value
            client.respond(id, entries)

        case Method.historyTimeline:
            let request = try params(frame, HistoryTimelineParams.self)
            guard let account = accounts.first(where: { $0.id == request.accountId }) else {
                throw WireError.notFound("That account isn't set up on the Mac.")
            }
            let items: [TimelineItem]? = await Task.detached(priority: .userInitiated) {
                guard let reader = TranscriptLocator.reader(for: account, conversationId: request.id) else { return nil }
                _ = reader.poll()
                return Array(reader.buffer.items.suffix(600))
            }.value
            guard let items else { throw WireError.notFound("That conversation can't be read here.") }
            client.respond(id, PageResult(items: items, hasEarlier: false))

        case Method.fsList:
            client.respond(id, try FileBrowser.list(try params(frame, FSListParams.self)))

        case Method.fsMkdir:
            client.respond(id, try FileBrowser.makeFolder(try params(frame, FSMkdirParams.self)))

        case Method.fsRoots:
            client.respond(id, FileBrowser.roots(recent: config.recentFolders))

        case Method.screenDisplays:
            client.respond(id, Spaces.displays())

        case Method.screenInput:
            let input = try params(frame, ScreenInputParams.self)
            try InputInjector.perform(input)
            client.respond(id, OKResult())

        case Method.screenSpace:
            let space = try params(frame, ScreenSpaceParams.self)
            guard InputInjector.trusted else {
                ScreenService.requestAccessibility()
                throw WireError(code: "accessibility", message: "Allow Agent Hub in Accessibility to switch Spaces.")
            }
            let display = CGDirectDisplayID(space.displayId)
            if space.missionControl == true {
                Spaces.missionControl()
            } else if let step = space.step {
                await Spaces.move(display: display, steps: step)
            } else if let target = space.targetIndex,
                      let info = Spaces.displays().first(where: { $0.id == space.displayId }),
                      let current = info.currentSpaceIndex {
                await Spaces.move(display: display, steps: target - current)
            }
            try? await Task.sleep(for: .milliseconds(250))
            client.respond(id, Spaces.displays())

        case Method.screenStart:
            let start = try params(frame, ScreenStartParams.self)
            try await screen.watch(client: client, params: start)
            client.respond(id, OKResult())

        case Method.screenStop:
            screen.stopWatching(client: client)
            client.respond(id, OKResult())

        case Method.macStatus:
            client.respond(id, hubInfo)

        case Method.macRenew:
            try RenewalState.start(repoPath: config.repoPath)
            client.respond(id, OKResult(message: "Renewing: the Mac is building Agent Hub and installing it on your iPhone."))

        case Method.macRenewAuto:
            let change = try params(frame, ScreenSharingParams.self)
            RenewalState.setAutomatic(change.enabled)
            broadcast(Event.hub, hubInfo)
            client.respond(id, hubInfo)

        case Method.macPermission:
            let permission = try params(frame, PermissionParams.self)
            switch permission.kind {
            case "screen": ScreenService.requestScreenRecording()
            case "accessibility": ScreenService.requestAccessibility()
            default: throw WireError.badRequest("Unknown permission \(permission.kind).")
            }
            client.respond(id, OKResult(message: "macOS is asking on the Mac. Use the Screen tab to answer it."))

        case "mac.ntfy":
            let value = frame.params?["url"]?.stringValue
            setNtfy(value)
            client.respond(id, OKResult())

        default:
            throw WireError.badRequest("Unknown request \(frame.method).")
        }
    }
}
