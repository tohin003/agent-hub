import Foundation
import Testing

@Suite("Reading agent conversations")
struct TranscriptTests {
    private func write(_ lines: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agenthub-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "11111111-2222-3333-4444-555555555555.jsonl")
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func claudeConversationWithToolsAndBackgroundWork() throws {
        let url = try write([
            ["type": "user", "uuid": "u1", "timestamp": "2026-11-01T10:00:00.000Z", "cwd": "/tmp/project",
             "message": ["role": "user", "content": "Fix the tests please"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-11-01T10:00:01.000Z",
             "message": ["role": "assistant", "model": "claude-opus-5-5", "content": [["type": "thinking", "thinking": "Let me look."]]]],
            ["type": "assistant", "uuid": "a2", "timestamp": "2026-11-01T10:00:02.000Z",
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Edit",
                                                            "input": ["file_path": "/tmp/project/a.swift", "old_string": "let a = 1", "new_string": "let a = 2"]]]]],
            ["type": "user", "uuid": "u2", "timestamp": "2026-11-01T10:00:03.000Z",
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "The file was updated."]]],
             "toolUseResult": ["filePath": "/tmp/project/a.swift",
                               "structuredPatch": [["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-let a = 1", "+let a = 2"]]]]],
            ["type": "assistant", "uuid": "a3", "timestamp": "2026-11-01T10:00:04.000Z",
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t2", "name": "Bash",
                                                            "input": ["command": "npm test", "description": "Run the tests", "run_in_background": true]]]]],
            ["type": "user", "uuid": "u3", "timestamp": "2026-11-01T10:00:05.000Z",
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2",
                                                      "content": "Command running in background with ID: b123. Output is being written to: /private/tmp/claude-501/x/s/tasks/b123.output. You will be notified."]]],
             "toolUseResult": ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "b123"]],
            ["type": "assistant", "uuid": "a4", "timestamp": "2026-11-01T10:00:06.000Z",
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t3", "name": "Agent",
                                                            "input": ["description": "Explore the parser", "subagent_type": "Explore", "prompt": "…", "run_in_background": true]]]]],
            ["type": "user", "uuid": "u4", "timestamp": "2026-11-01T10:00:07.000Z",
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t3", "content": [["type": "text", "text": "Async agent launched successfully.\nagentId: abc123"]]]]],
             "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "abc123"]],
            ["type": "user", "uuid": "u5", "timestamp": "2026-11-01T10:00:30.000Z",
             "message": ["role": "user", "content": "<task-notification>\n<task-id>b123</task-id>\n<tool-use-id>t2</tool-use-id>\n<status>completed</status>\n<summary>Background command \"Run the tests\" completed (exit code 0)</summary>\n</task-notification>"]],
            ["type": "assistant", "uuid": "a5", "timestamp": "2026-11-01T10:00:31.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "All **tests** pass now."]]]],
            ["type": "ai-title", "aiTitle": "Fix failing tests"],
            ["type": "permission-mode", "permissionMode": "acceptEdits"],
            ["type": "system", "subtype": "turn_duration", "durationMs": 31000, "uuid": "s1"],
        ])
        let reader = ClaudeTranscript(url: url)
        #expect(reader.poll())
        let items = reader.buffer.items
        #expect(items.first?.kind == .user)
        #expect(items.first?.text == "Fix the tests please")
        #expect(items.contains { $0.kind == .thinking })

        let edit = try #require(items.first { $0.id == "t1" }?.tool)
        #expect(edit.category == .edit)
        #expect(edit.status == .done)
        #expect(edit.diff?.additions == 1)
        #expect(edit.diff?.deletions == 1)

        let shell = try #require(items.first { $0.id == "t2" }?.tool)
        #expect(shell.taskId == "b123")
        #expect(shell.outputFile == "/private/tmp/claude-501/x/s/tasks/b123.output")
        #expect(shell.status == .done) // finished by the task notification

        let agent = try #require(items.first { $0.id == "t3" }?.tool)
        #expect(agent.agentId == "abc123")
        #expect(agent.status == .background)

        #expect(reader.tasks.first { $0.id == "b123" }?.status == .completed)
        #expect(reader.tasks.first { $0.id == "abc123" }?.kind == .agent)
        #expect(reader.info.title == "Fix failing tests")
        #expect(reader.info.model == "claude-opus-5-5")
        #expect(reader.info.permissionMode == "acceptEdits")
        #expect(reader.info.lastMessage == "All **tests** pass now.")
        #expect(items.contains { $0.kind == .task })
        #expect(items.last?.text == "Worked for 31s")
    }

    @Test func claudeReadsOnlyNewLines() throws {
        let url = try write([["type": "user", "uuid": "u1", "message": ["role": "user", "content": "one"]]])
        let reader = ClaudeTranscript(url: url)
        #expect(reader.poll())
        _ = reader.buffer.drainChanges()
        #expect(!reader.poll())
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}"#.utf8))
        handle.write(Data("\n".utf8))
        try handle.close()
        #expect(reader.poll())
        let changes = reader.buffer.drainChanges()
        #expect(changes.map(\.text) == ["two"])
    }

    @Test func codexRollout() throws {
        let url = try write([
            ["timestamp": "2026-11-01T10:00:00.000Z", "type": "session_meta", "payload": ["id": "019-abc", "cwd": "/tmp/p"]],
            ["timestamp": "2026-11-01T10:00:00.100Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>…</environment_context>"]]]],
            ["timestamp": "2026-11-01T10:00:01.000Z", "type": "event_msg", "payload": ["type": "user_message", "message": "List the files"]],
            ["timestamp": "2026-11-01T10:00:01.100Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "List the files"]]]],
            ["timestamp": "2026-11-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "function_call", "name": "shell", "call_id": "c1", "arguments": #"{"command":["bash","-lc","ls -la"]}"#]],
            ["timestamp": "2026-11-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "function_call_output", "call_id": "c1", "output": #"{"output":"a.txt\nb.txt","metadata":{"exit_code":0}}"#]],
            ["timestamp": "2026-11-01T10:00:04.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                         "input": "*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch"]],
            ["timestamp": "2026-11-01T10:00:05.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]],
        ])
        let reader = CodexTranscript(url: url)
        #expect(reader.poll())
        let items = reader.buffer.items
        #expect(items.filter { $0.kind == .user }.map(\.text) == ["List the files"])
        let shell = try #require(items.first { $0.id == "c1" }?.tool)
        #expect(shell.subtitle == "ls -la")
        #expect(shell.status == .done)
        #expect(shell.exitCode == 0)
        let patch = try #require(items.first { $0.id == "c2" }?.tool)
        #expect(patch.diff?.additions == 1)
        #expect(reader.info.agentSessionId == "019-abc")
        #expect(reader.info.title == "List the files")
    }

    @Test func applyPatchToDiffs() {
        let diffs = Diffs.fromApplyPatch("*** Begin Patch\n*** Add File: new.swift\n+line\n*** Update File: old.swift\n@@ fn\n-a\n+b\n c\n*** End Patch")
        #expect(diffs.count == 2)
        #expect(diffs[0].isNewFile)
        #expect(diffs[1].additions == 1)
        #expect(diffs[1].deletions == 1)
    }

    /// Parses the person's most recent real Claude Code conversations, if any exist on this Mac.
    @Test func realClaudeTranscriptsParse() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var files: [(URL, Date)] = []
        // Every Claude config folder on this Mac (~/.claude, ~/.claude-<account>); none: nothing to check.
        let configs = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
        for config in configs {
            let projects = URL(fileURLWithPath: "\(home)/\(config)/projects")
            guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { continue }
            for folder in folders {
                let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in entries where url.pathExtension == "jsonl" {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((url, date))
                }
            }
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(6) {
            let reader = ClaudeTranscript(url: url)
            _ = reader.poll()
            let tools = reader.buffer.items.compactMap(\.tool)
            // Every tool call gets a category and a title; nothing crashes on real data.
            #expect(tools.allSatisfy { !$0.title.isEmpty })
        }
    }
}
