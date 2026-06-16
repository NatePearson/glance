import Foundation

// Drives the local `claude` CLI in headless mode instead of calling the
// Anthropic API directly. This means Glance rides on whatever auth Claude Code
// is configured with — a Claude subscription (OAuth) login needs no API key.
//
// We use stream-json on both ends:
//   • input  (stdin): one user message with text and/or image content blocks
//   • output (stdout): newline-delimited events; we stream `text_delta`s out
// and keep the returned session_id so follow-ups resume the same conversation.
//
// Trade-off vs. the raw API: every call boots the full Claude Code runtime
// (~16–18K tokens of tool/system context), so first-token latency is a few
// seconds and each question draws on your plan's usage. We trim what we can:
// override the system prompt, disable skills + MCP, disallow tools, and run in
// a clean temp dir so no project CLAUDE.md is pulled in.
enum ContentPart {
    case text(String)
    case image(base64: String, mediaType: String)
}

final class ClaudeCodeClient {
    private var sessionId: String?
    private var process: Process?
    private var cancelled = false
    private let parseQueue = DispatchQueue(label: "com.natep.glance.claude.parse")

    // Tools still load into context even when disallowed (only --bare strips
    // them, and --bare forces API-key auth), but disallowing prevents the model
    // from actually invoking them — we want plain answers, not agentic runs.
    private static let disallowedTools =
        "Bash Edit Write Read WebSearch WebFetch Glob Grep Task NotebookEdit MultiEdit"

    /// Send a user turn and stream the reply. Callbacks fire on the main queue.
    func send(_ parts: [ContentPart],
              onStart: @escaping () -> Void,
              onDelta: @escaping (String) -> Void,
              onDone: @escaping () -> Void,
              onError: @escaping (String) -> Void) {

        guard let claudePath = ClaudeLocator.path() else {
            DispatchQueue.main.async {
                onError("Couldn't find the `claude` command.\n\nInstall Claude Code, or set its path: run `which claude` in Terminal and put the result in ✨ ▸ Set Claude Path…")
            }
            return
        }

        guard let messageLine = Self.encodeMessageLine(parts) else {
            DispatchQueue.main.async { onError("Could not encode the request.") }
            return
        }

        var args = [
            "-p",
            "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--system-prompt", Config.systemPrompt,
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}",
            "--disallowed-tools", Self.disallowedTools,
            "--model", Config.model,
            "--effort", Config.effort,
        ]
        if let sid = sessionId {
            args += ["--resume", sid]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = args
        proc.currentDirectoryURL = ClaudeLocator.workingDirectory

        // Make sure the child can find `node` (claude's runtime) even when we
        // were launched from Finder with a bare PATH. Prepend claude's own dir.
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        let extra = "\(claudeDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        cancelled = false
        self.process = proc

        var buffer = Data()
        var streamedAny = false
        var started = false
        var resultText: String?
        var sawError: String?
        let nl = UInt8(0x0A)

        let main = DispatchQueue.main

        func handleLine(_ line: Data) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return }

            if self.sessionId == nil, let sid = obj["session_id"] as? String {
                self.sessionId = sid
            }

            guard let type = obj["type"] as? String else { return }
            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any],
                      event["type"] as? String == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return }
                streamedAny = true
                if !started { started = true; main.async { onStart() } }
                main.async { onDelta(text) }

            case "result":
                if let isErr = obj["is_error"] as? Bool, isErr {
                    sawError = (obj["result"] as? String) ?? "Claude Code reported an error."
                } else {
                    resultText = obj["result"] as? String
                }

            case "error":
                sawError = (obj["error"] as? [String: Any])?["message"] as? String
                    ?? (obj["message"] as? String) ?? "Claude Code reported an error."

            default:
                break
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.parseQueue.async {
                buffer.append(chunk)
                while let idx = buffer.firstIndex(of: nl) {
                    let line = buffer.subdata(in: buffer.startIndex..<idx)
                    buffer.removeSubrange(buffer.startIndex...idx)
                    handleLine(line)
                }
            }
        }

        proc.terminationHandler = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            self.parseQueue.async {
                if !buffer.isEmpty { handleLine(buffer); buffer.removeAll() }
                main.async {
                    self.process = nil
                    if self.cancelled { return }

                    if let err = sawError {
                        if !started { onStart() }
                        onError(err)
                        return
                    }
                    // If no deltas streamed (e.g. partial messages unavailable),
                    // fall back to the final result text.
                    if !streamedAny, let full = resultText, !full.isEmpty {
                        onStart(); onDelta(full); onDone(); return
                    }
                    if streamedAny { onDone(); return }

                    // Nothing at all — surface stderr if we have it.
                    let stderr = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !started { onStart() }
                    onError(stderr.isEmpty ? "Claude Code returned no answer." : stderr)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            self.process = nil
            DispatchQueue.main.async { onError("Couldn't launch claude: \(error.localizedDescription)") }
            return
        }

        // Feed the single user message, then EOF so the CLI processes one turn.
        let handle = inPipe.fileHandleForWriting
        handle.write(Data((messageLine + "\n").utf8))
        try? handle.close()
    }

    func cancel() {
        cancelled = true
        process?.terminate()
        process = nil
    }

    // MARK: - Encoding

    private static func encodeMessageLine(_ parts: [ContentPart]) -> String? {
        let content: [[String: Any]] = parts.map { part in
            switch part {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let b64, let media):
                return ["type": "image",
                        "source": ["type": "base64", "media_type": media, "data": b64]]
            }
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Locates the `claude` executable for a GUI app that doesn't inherit a shell PATH.
enum ClaudeLocator {
    private static var cached: String?

    static func path() -> String? {
        if let c = cached { return c }

        // 1. Explicit override.
        if let override = UserDefaults.standard.string(forKey: "claudePath"),
           FileManager.default.isExecutableFile(atPath: override) {
            cached = override; return override
        }
        // 2. Ask a login shell (picks up nvm / custom installs).
        if let viaShell = loginShellWhich(), FileManager.default.isExecutableFile(atPath: viaShell) {
            cached = viaShell; return viaShell
        }
        // 3. Known install locations.
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/node/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cached = c; return c
        }
        return nil
    }

    static func setOverride(_ path: String) {
        UserDefaults.standard.set(path, forKey: "claudePath")
        cached = nil
    }

    /// A neutral working directory so Claude Code doesn't auto-load a project
    /// CLAUDE.md from wherever we happen to be.
    static var workingDirectory: URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loginShellWhich() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }
}
