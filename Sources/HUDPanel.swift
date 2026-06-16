import AppKit
import QuartzCore

// A borderless, translucent panel that floats near the cursor and streams the
// answer in. Built for shoulder-surf resistance: in "private" mode the ENTIRE
// panel is hidden at rest (window alpha 0) and only fades into view while you
// hold ⌥ (Option) — release and the whole thing vanishes again. Nothing is on
// screen unless you're actively holding the key, so a bystander can't catch it.
//
// It's a .nonactivatingPanel (no dock bounce) that takes key focus so Esc, ⌘C
// (copy — works without revealing), the follow-up field, and the hold-to-reveal
// key all work. Clicking back into your work dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class GlanceHUD: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = GlanceHUD()

    var onFollowUp: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var panel: FloatingPanel?
    private var effect: NSVisualEffectView!
    private var spinner: NSProgressIndicator!
    private var hintLabel: NSTextField!
    private var closeButton: NSButton!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var followUp: NSTextField!
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var armed = false
    private var revealed = false
    private var privateOn = true

    private let width: CGFloat = 340
    private let margin: CGFloat = 11
    private let headerH: CGFloat = 16
    private let fieldH: CGFloat = 26
    private let gap: CGFloat = 7
    private let maxScroll: CGFloat = 240
    private let shownAlpha: CGFloat = 0.97   // window opacity when visible
    private let revealKey = "hold ⌥ to reveal"

    private var answerAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
    }
    private var userAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
         .foregroundColor: NSColor.tertiaryLabelColor]
    }
    private var errorAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed]
    }

    private var privateActive: Bool { privateOn && (panel?.isVisible ?? false) }

    // MARK: - Lifecycle

    func show(near point: NSPoint) {
        buildIfNeeded()
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        followUp.stringValue = ""
        setWaiting(true)

        privateOn = Config.privateMode
        revealed = false
        scrollView.alphaValue = 1
        hintLabel.isHidden = true
        // In private mode the ENTIRE panel is hidden at rest and only appears
        // while ⌥ is held; otherwise it's visible immediately.
        panel?.alphaValue = privateOn ? 0 : shownAlpha

        position(near: point)
        NSApp.activate(ignoringOtherApps: true)   // needed for key focus (no dock icon)
        panel?.makeKeyAndOrderFront(nil)
        fitToContent()
        armed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.armed = true }
    }

    func close() {
        guard let panel = panel, panel.isVisible else { return }
        armed = false
        panel.orderOut(nil)
        onFollowUp = nil
        let cb = onClose
        onClose = nil
        cb?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard armed else { return }
        close()
    }

    // MARK: - Streaming surface

    func setWaiting(_ waiting: Bool) {
        guard panel != nil else { return }
        if waiting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !waiting
    }

    func beginTurn(label: String) { appendString("\(label)\n", attrs: userAttrs) }

    func appendAnswer(_ chunk: String) {
        appendString(chunk, attrs: answerAttrs)
        fitToContent()
    }

    func finishTurn() {
        setWaiting(false)
        appendString("\n\n", attrs: answerAttrs)
        fitToContent()
        followUp.isEnabled = true
    }

    func showError(_ message: String) {
        setWaiting(false)
        appendString(message + "\n\n", attrs: errorAttrs)
        fitToContent()
        followUp.isEnabled = true
    }

    // MARK: - Privacy (hold ⌥ to reveal)

    private func setRevealed(_ reveal: Bool) {
        guard privateActive, reveal != revealed else { return }
        revealed = reveal
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = reveal ? shownAlpha : 0   // show whole panel only while held
        }
    }

    // MARK: - Build

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = shownAlpha
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel

        let effect = NSVisualEffectView(frame: panel.contentLayoutRect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        self.effect = effect

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        effect.addSubview(spinner)

        hintLabel = NSTextField(labelWithString: revealKey)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(hintLabel)

        closeButton = NSButton()
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        effect.addSubview(closeButton)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        effect.addSubview(scroll)
        self.scrollView = scroll
        self.textView = tv

        followUp = NSTextField()
        followUp.placeholderString = "follow-up…  ↵"
        followUp.font = .systemFont(ofSize: 11.5)
        followUp.bezelStyle = .roundedBezel
        followUp.focusRingType = .none
        followUp.delegate = self
        effect.addSubview(followUp)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true else { return event }
            if event.keyCode == 53 { self.close(); return nil }   // Esc
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "c",
               self.textView.selectedRange().length == 0,
               self.panel?.firstResponder !== self.followUp.currentEditor() {
                self.copyAnswer(); return nil
            }
            return event
        }
        // Hold ⌥ to reveal; release to re-frost.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true, self.privateOn else { return event }
            self.setRevealed(event.modifierFlags.contains(.option))
            return event
        }
    }

    // MARK: - Layout

    private func layout() {
        guard let effect = effect else { return }
        let b = effect.bounds
        let headerTop = b.maxY - margin

        spinner.frame = NSRect(x: margin, y: headerTop - headerH + 1, width: 13, height: 13)
        hintLabel.frame = NSRect(x: margin + 17, y: headerTop - headerH, width: b.width - 2 * margin - 17 - 22, height: headerH)
        closeButton.frame = NSRect(x: b.maxX - margin - 16, y: headerTop - headerH, width: 16, height: 16)

        followUp.frame = NSRect(x: margin, y: margin, width: b.width - 2 * margin, height: fieldH)

        let scrollY = margin + fieldH + gap
        let scrollTop = headerTop - headerH - gap
        let scrollFrame = NSRect(x: margin, y: scrollY,
                                 width: b.width - 2 * margin,
                                 height: max(20, scrollTop - scrollY))
        scrollView.frame = scrollFrame

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
    }

    private func measuredTextHeight() -> CGFloat {
        let textWidth = width - 2 * margin
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 40 }
        tc.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height) + 4
    }

    private func fitToContent() {
        guard let panel = panel else { return }
        let scrollH = min(max(measuredTextHeight(), 36), maxScroll)
        let newHeight = margin + fieldH + gap + scrollH + gap + headerH + margin

        var f = panel.frame
        let top = f.maxY
        f.size.height = newHeight
        f.size.width = width
        f.origin.y = top - newHeight

        if let screen = currentScreen(for: f.origin) {
            let vis = screen.visibleFrame
            if f.minY < vis.minY { f.origin.y = vis.minY + 6 }
            if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width - 6 }
            if f.minX < vis.minX { f.origin.x = vis.minX + 6 }
        }
        panel.setFrame(f, display: true)
        layout()
        scrollToBottom()
    }

    private func position(near point: NSPoint) {
        guard let panel = panel else { return }
        let screen = currentScreen(for: point) ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x + 12, y: point.y - panel.frame.height - 12)
        if origin.x + width > vis.maxX - 6 { origin.x = point.x - width - 12 }
        if origin.x < vis.minX + 6 { origin.x = vis.minX + 6 }
        if origin.y < vis.minY + 6 { origin.y = point.y + 12 }
        if origin.y + panel.frame.height > vis.maxY - 6 { origin.y = vis.maxY - panel.frame.height - 6 }
        panel.setFrameOrigin(origin)
    }

    private func currentScreen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func scrollToBottom() {
        guard let doc = scrollView.documentView else { return }
        doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - scrollView.contentSize.height)))
    }

    private func appendString(_ s: String, attrs: [NSAttributedString.Key: Any]) {
        textView.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
    }

    // MARK: - Actions

    private func copyAnswer() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashHint("copied ✓")
    }

    private func flashHint(_ text: String) {
        hintLabel.stringValue = text
        hintLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.hintLabel.stringValue == text else { return }
            self.hintLabel.stringValue = self.revealKey
            self.hintLabel.isHidden = true
        }
    }

    @objc private func closeTapped() { close() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let q = followUp.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            followUp.stringValue = ""
            followUp.isEnabled = false
            beginTurn(label: "› \(q)")
            setWaiting(true)
            fitToContent()
            onFollowUp?(q)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}
