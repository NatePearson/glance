// Glance — a discreet, ambient Claude assistant for macOS.
//
// Lives in the menu bar (no dock icon). Global hotkeys grab context from
// whatever app you're in and float a translucent answer panel near your cursor.
// It runs through your local Claude Code CLI (`claude`), so it uses your Claude
// subscription / Claude Code login — no separate API key. AppKit, no deps.
//
//   ⌥⌘A  Ask about the current selection   (copies it, then answers)
//   ⌥⌘S  Ask about a screen region         (drag to capture, then answers)
//   ⌥⌘C  — clipboard ask is in the menu (avoids Finder's ⌥⌘C clash)
//
// Selection capture posts a synthetic ⌘C, which needs Accessibility permission.
// Screenshot capture uses Apple's `screencapture` (handles Screen Recording on
// its own). Rebuild with ./build.sh.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var currentClient: ClaudeCodeClient?

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        registerHotKeys()

        // First-run check: make sure we can find the claude CLI.
        if ClaudeLocator.path() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.warnClaudeNotFound()
            }
        }
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Glance")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Ask about Selection", action: #selector(askSelection),
                     keyEquivalent: "").setGlanceKey("a")
        menu.addItem(withTitle: "Screenshot a Question", action: #selector(askScreenshot),
                     keyEquivalent: "").setGlanceKey("s")
        // Clipboard is menu-only: a global ⌥⌘C clashes with Finder's "Copy as Pathname".
        menu.addItem(withTitle: "Ask about Clipboard", action: #selector(askClipboard),
                     keyEquivalent: "")

        menu.addItem(.separator())

        let priv = NSMenuItem(title: "Private — blur answer, hold ⌥ to read",
                              action: #selector(togglePrivate), keyEquivalent: "")
        priv.state = Config.privateMode ? .on : .off
        menu.addItem(priv)

        // Model ▸ Opus 4.8 / Sonnet 4.6
        let modelMenu = NSMenu()
        for (title, id) in [("Opus 4.8", Config.opus), ("Sonnet 4.6", Config.sonnet)] {
            let it = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
            it.representedObject = id
            it.state = (Config.model == id) ? .on : .off
            it.target = self
            modelMenu.addItem(it)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Mode ▸ Normal / Max
        let modeMenu = NSMenu()
        for (title, isMax) in [("Normal", false), ("Max (slower, deepest)", true)] {
            let it = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.representedObject = isMax
            it.state = (Config.maxMode == isMax) ? .on : .off
            it.target = self
            modeMenu.addItem(it)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(withTitle: "Set Claude Path…", action: #selector(setClaudePath), keyEquivalent: "")

        // A disabled status line showing what we're hooked up to.
        let status = NSMenuItem(title: claudeStatusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(withTitle: "About Glance", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Glance", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func claudeStatusLine() -> String {
        if let p = ClaudeLocator.path() {
            return "Claude Code: \((p as NSString).abbreviatingWithTildeInPath)"
        }
        return "Claude Code: not found"
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        HotKeyManager.shared.register(keyCode: HotKeyManager.keyA, modifiers: HotKeyManager.cmdOpt) {
            [weak self] in self?.askSelection()
        }
        HotKeyManager.shared.register(keyCode: HotKeyManager.keyS, modifiers: HotKeyManager.cmdOpt) {
            [weak self] in self?.askScreenshot()
        }
    }

    // MARK: - The three entry points

    @objc private func askSelection() {
        guard ensureAccessibility() else { return }
        guard let text = Capture.selectedText(), !text.isEmpty else {
            flashHUD(title: "Selection", message: "Couldn't read a selection. Select some text first, then press ⌥⌘A.")
            return
        }
        startSession(label: "Selection", parts: [.text(text)])
    }

    @objc private func askClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            flashHUD(title: "Clipboard", message: "The clipboard has no text. Copy something, then choose Ask about Clipboard.")
            return
        }
        startSession(label: "Clipboard", parts: [.text(text)])
    }

    @objc private func askScreenshot() {
        // Let the menu/hotkey UI settle before the capture overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            guard let shot = Capture.captureScreenRegion() else { return } // user cancelled
            self.startSession(label: "Screenshot",
                              parts: [.image(base64: shot.base64, mediaType: shot.mediaType),
                                      .text("Look at this screen capture and help. If a question, error, or problem is visible, answer or explain it concisely. Otherwise summarize what's shown and the key takeaway.")])
        }
    }

    // MARK: - Session orchestration

    private func startSession(label: String, parts: [ContentPart]) {
        currentClient?.cancel()
        let client = ClaudeCodeClient()
        currentClient = client

        let hud = GlanceHUD.shared
        hud.show(near: NSEvent.mouseLocation)
        hud.beginTurn(label: label)

        hud.onClose = { [weak self] in
            self?.currentClient?.cancel()
            self?.currentClient = nil
        }
        hud.onFollowUp = { [weak client] question in
            guard let client = client else { return }
            client.send([.text(question)],
                        onStart: { GlanceHUD.shared.setWaiting(true) },
                        onDelta: { GlanceHUD.shared.appendAnswer($0) },
                        onDone: { GlanceHUD.shared.finishTurn() },
                        onError: { GlanceHUD.shared.showError($0) })
        }

        client.send(parts,
                    onStart: { hud.setWaiting(false) },
                    onDelta: { hud.appendAnswer($0) },
                    onDone: { hud.finishTurn() },
                    onError: { hud.showError($0) })
    }

    /// Show the HUD with a one-off informational message (no Claude call).
    private func flashHUD(title: String, message: String) {
        let hud = GlanceHUD.shared
        hud.show(near: NSEvent.mouseLocation)
        hud.beginTurn(label: title)
        hud.appendAnswer(message)
        hud.finishTurn()
        hud.onFollowUp = nil
    }

    // MARK: - Permissions

    /// Returns true if Accessibility is granted; otherwise prompts and returns false.
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
        flashHUD(title: "Permission needed",
                 message: "Glance needs Accessibility access to read your selection (it sends a copy command).\n\nSystem Settings ▸ Privacy & Security ▸ Accessibility ▸ enable Glance, then try ⌥⌘A again.\n\n(Screenshot mode, ⌥⌘S, works without this.)")
        return false
    }

    // MARK: - Menu actions

    @objc private func togglePrivate() {
        Config.privateMode.toggle()
        rebuildMenu()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Config.model = id; rebuildMenu() }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        Config.maxMode = (sender.representedObject as? Bool) ?? false
        rebuildMenu()
    }

    @objc private func setClaudePath() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Path to the claude CLI"
        alert.informativeText = "Leave Glance to auto-detect, or paste a full path. Find it by running `which claude` in Terminal."
        alert.alertStyle = .informational

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "/Users/you/.local/node/bin/claude"
        if let p = ClaudeLocator.path() { field.stringValue = p }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let p = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { ClaudeLocator.setOverride(p) }
            rebuildMenu()
        }
    }

    private func warnClaudeNotFound() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Code not found"
        alert.informativeText = "Glance runs through the `claude` command, but couldn't find it.\n\nInstall Claude Code and sign in (`claude /login`), or set the path via the menu bar ✨ ▸ Set Claude Path…"
        alert.runModal()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Glance"
        alert.informativeText = """
        A discreet, ambient Claude assistant. Runs through your Claude Code login — no API key.

        ⌥⌘A   Ask about the current selection
        ⌥⌘S   Ask about a screen region
        Menu  Ask about the clipboard

        Private mode blurs the answer — hold ⌥ to read it.
        In the panel: type a follow-up and press ↵, ⌘C copies the answer, Esc closes.

        Model: \(Config.modelDisplayName(Config.model))  ·  Mode: \(Config.maxMode ? "Max" : "Normal")
        \(claudeStatusLine())
        """
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Helper: tag a menu item with a Glance hotkey hint shown on the right. In a
// status-bar menu these key equivalents are cosmetic when the menu is closed —
// the global Carbon hotkey owns the real binding, so there's no double-trigger.
private extension NSMenuItem {
    @discardableResult
    func setGlanceKey(_ key: String) -> NSMenuItem {
        keyEquivalent = key
        keyEquivalentModifierMask = [.command, .option]
        return self
    }
}

// Bootstrap.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
