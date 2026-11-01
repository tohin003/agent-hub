import Foundation

struct ProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
    var ok: Bool { status == 0 }
}

/// Runs command-line tools without blocking the main thread.
enum Shell {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String]? = nil, directory: String? = nil,
                    timeout: TimeInterval = 30) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(executable, arguments, input: input, environment: environment,
                                                       directory: directory, timeout: timeout))
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], input: Data? = nil,
                        environment: [String: String]? = nil, directory: String? = nil,
                        timeout: TimeInterval = 30) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { killTree(pid) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        if let inPipe, let input {
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Quotes a string for zsh/sh: 'it'\''s'.
    /// Ends a process and everything it started (SIGKILL), children first found with pgrep.
    static func killTree(_ pid: Int32) {
        var all: [Int32] = []
        var queue = [pid]
        while let next = queue.popLast(), all.count < 64 {
            all.append(next)
            let children = runSync("/usr/bin/pgrep", ["-P", String(next)], timeout: 5).out
                .split(separator: "\n").compactMap { Int32($0) }
            queue.append(contentsOf: children)
        }
        for process in all.reversed() { kill(process, SIGKILL) }
    }

    static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Finds an executable in the usual places, without relying on the GUI app's minimal PATH.
    static func which(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
            "\(home)/.opencode/bin", "\(home)/.cargo/bin",
        ]
        for dir in candidates {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
