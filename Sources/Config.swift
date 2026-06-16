import Foundation

// Glance configuration.
//
// Glance runs through your local Claude Code CLI (`claude`), so it uses whatever
// auth Claude Code is logged in with — a Claude subscription needs no API key.
// Make sure `claude` works in your terminal first (`claude /login` if needed).
enum Config {
    // Private mode (default ON): keep the answer hidden at rest so a bystander
    // can't read it; the text appears only while you hold ⌥, then vanishes again.
    static var privateMode: Bool {
        get { UserDefaults.standard.object(forKey: "privateMode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "privateMode") }
    }

    // Model to use, picked from the menu. Default Opus 4.8.
    static let opus = "claude-opus-4-8"
    static let sonnet = "claude-sonnet-4-6"
    static var model: String {
        get { UserDefaults.standard.string(forKey: "model") ?? opus }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    static func modelDisplayName(_ id: String) -> String {
        id == sonnet ? "Sonnet 4.6" : "Opus 4.8"
    }

    // Mode → effort level, picked from the menu. Normal = "low" (snappy, the
    // default for a quick-glance tool). Max = "max" (deepest, slowest).
    static var maxMode: Bool {
        get { UserDefaults.standard.bool(forKey: "maxMode") }
        set { UserDefaults.standard.set(newValue, forKey: "maxMode") }
    }
    static var effort: String { maxMode ? "max" : "low" }

    // Passed as --system-prompt, which *replaces* Claude Code's default agent
    // prompt — keeping the context small and the behavior a plain assistant.
    static let systemPrompt = """
    You are Glance, a discreet on-screen assistant. The user has selected text, \
    copied something, or captured part of their screen, and wants a fast, direct answer \
    in a small floating panel.

    Rules:
    - Answer immediately with the substance. No preamble, no "Here is", no restating \
    the question, no sign-off.
    - If the input is a question, answer it. If it's an error or stack trace, give the \
    likely cause and the fix in 1–3 sentences. If it's text to act on (translate, \
    summarize, define, rewrite, explain), just do it.
    - Be concise — usually a sentence or two. Expand only when the question genuinely \
    needs it.
    - Plain text only. No markdown headings, no LaTeX, no tables unless asked.
    - You are a single-shot assistant: do not try to use tools, run commands, or read \
    files. Answer from what you're given.
    - If you truly cannot tell what is being asked, say so in one line and suggest what \
    to ask.
    """
}
