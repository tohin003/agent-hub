import Foundation

/// Lists folders and makes new ones, for choosing where a session starts.
enum FileBrowser {
    static func list(_ params: FSListParams) throws -> FSListing {
        let path = expand(params.path)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WireError.notFound("\(url.path) isn't a folder on the Mac.")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = params.showHidden ? [] : [.skipsHiddenFiles]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        } catch {
            throw WireError.failed("The Mac didn't allow reading \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let entries: [FSEntry] = contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if params.directoriesOnly, !isDir { return nil }
            return FSEntry(name: item.lastPathComponent, path: item.path, isDirectory: isDir,
                           isHidden: values?.isHidden ?? item.lastPathComponent.hasPrefix("."),
                           isGitRepo: isDir && FileManager.default.fileExists(atPath: item.appending(path: ".git").path),
                           modified: values?.contentModificationDate, size: (values?.fileSize).map(Int64.init))
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let isGit = FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
        let parent = url.path == "/" ? nil : url.deletingLastPathComponent().path
        return FSListing(path: url.path, parent: parent, entries: entries, isGitRepo: isGit,
                         gitBranch: isGit ? gitBranch(url) : nil)
    }

    static func makeFolder(_ params: FSMkdirParams) throws -> FSEntry {
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") || name.count > 1 else {
            throw WireError.badRequest("Choose a folder name without slashes.")
        }
        let parent = URL(fileURLWithPath: expand(params.parent)).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard parent.path == home || parent.path.hasPrefix(home + "/") || parent.path.hasPrefix("/Volumes/") else {
            throw WireError.badRequest("New folders can only be made inside your home folder.")
        }
        let target = parent.appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw WireError.badRequest("\(name) already exists there.")
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw WireError.failed("The folder couldn't be made: \(error.localizedDescription)")
        }
        return FSEntry(name: name, path: target.path, isDirectory: true, isHidden: false, isGitRepo: false,
                       modified: .now, size: nil)
    }

    static func roots(recent: [String]) -> FSRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["Projects", "Developer", "Code", "Desktop", "Documents", "Downloads"]
        let places: [FSEntry] = [FSEntry(name: "Home", path: home, isDirectory: true, isHidden: false, isGitRepo: false,
                                         modified: nil, size: nil)]
            + candidates.compactMap { name in
                let path = "\(home)/\(name)"
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return FSEntry(name: name, path: path, isDirectory: true, isHidden: false, isGitRepo: false, modified: nil, size: nil)
            }
        let recents: [FSEntry] = recent.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let url = URL(fileURLWithPath: path)
            return FSEntry(name: url.lastPathComponent, path: path, isDirectory: true, isHidden: false,
                           isGitRepo: FileManager.default.fileExists(atPath: url.appending(path: ".git").path),
                           modified: nil, size: nil)
        }
        return FSRoots(home: home, places: places, recents: recents)
    }

    static func expand(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst()) }
        return path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : path
    }

    static func gitBranch(_ repo: URL) -> String? {
        guard let head = try? String(contentsOf: repo.appending(path: ".git/HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst(16)) }
        return String(line.prefix(8))
    }
}

/// The iPhone app's signing state, written by scripts/renew.sh.
enum RenewalState {
    static func read() -> RenewalInfo? {
        guard let data = FileManager.default.contents(atPath: HubPaths.renewState),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RenewalInfo(installedAt: nil, expiresAt: nil, lastAttempt: nil, lastResult: nil, lastSucceeded: nil,
                               running: isRunning, autoRenew: automatic)
        }
        return RenewalInfo(installedAt: Stamp.parse(object["installedAt"]), expiresAt: Stamp.parse(object["profileExpires"]),
                           lastAttempt: Stamp.parse(object["lastAttempt"]), lastResult: object["lastResult"] as? String,
                           lastSucceeded: object["lastSucceeded"] as? Bool, running: isRunning, autoRenew: automatic,
                           lastReason: object["lastReason"] as? String)
    }

    /// Whether renew-check.sh renews by itself (on unless switched off).
    static var automatic: Bool { !FileManager.default.fileExists(atPath: HubPaths.renewAutoOff) }

    static func setAutomatic(_ on: Bool) {
        if on {
            try? FileManager.default.removeItem(atPath: HubPaths.renewAutoOff)
        } else {
            try? FileManager.default.createDirectory(atPath: (HubPaths.renewAutoOff as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: HubPaths.renewAutoOff,
                                           contents: Data("Automatic renewal switched off in Agent Hub.\n".utf8))
        }
        Log.info("renew: automatic renewal \(on ? "on" : "off")")
    }

    static var isRunning: Bool {
        guard let pidText = try? String(contentsOfFile: "\(HubPaths.renewLock)/pid", encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    /// Starts scripts/renew.sh in the background (it builds, installs on the iPhone and records the new date).
    static func start(repoPath: String?, reason: String = "phone") throws {
        guard !isRunning else { throw WireError.failed("A renewal is already running.") }
        guard let repoPath, FileManager.default.isExecutableFile(atPath: "\(repoPath)/scripts/renew.sh") else {
            throw WireError.failed("The Agent Hub folder isn't known to the hub. Run scripts/install-mac.sh once.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\(Shell.quote(repoPath + "/scripts/renew.sh")) --reason \(reason) >> \(Shell.quote(HubPaths.home + "/Library/Logs/AgentHub/renew.log")) 2>&1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
