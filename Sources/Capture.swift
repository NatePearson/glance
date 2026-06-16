import AppKit

// Two ways to grab context from whatever app the user is in.
enum Capture {

    /// Grab the current selection by synthesizing ⌘C and reading the pasteboard.
    /// Requires Accessibility permission (posting keystrokes to other apps).
    /// Restores the previous pasteboard contents afterwards so we don't clobber
    /// the user's clipboard. Returns nil if nothing was copied.
    static func selectedText() -> String? {
        let pb = NSPasteboard.general
        let savedItems = snapshotPasteboard(pb)
        let beforeCount = pb.changeCount

        pressCommandC()

        // Yield the run loop so the frontmost app can service the copy and
        // update the system pasteboard. Poll up to ~0.7s.
        let deadline = Date().addingTimeInterval(0.7)
        while pb.changeCount == beforeCount && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let copied: String? = (pb.changeCount != beforeCount)
            ? pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        // Restore the user's original clipboard.
        restorePasteboard(pb, items: savedItems)

        if let copied = copied, !copied.isEmpty { return copied }
        return nil
    }

    /// Interactive screen-region capture via Apple's `screencapture` tool. The
    /// tool draws its own crosshair overlay and handles the Screen Recording
    /// permission prompt itself. Returns base64 PNG + media type, or nil if the
    /// user pressed Escape / selected nothing.
    static func captureScreenRegion() -> (base64: String, mediaType: String)? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glance-\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -x no sound, -t png
        proc.arguments = ["-i", "-x", "-t", "png", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
        return (data.base64EncodedString(), "image/png")
    }

    // MARK: - Helpers

    private static func pressCommandC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true) // 'C'
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [[String: Data]] {
        var saved: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var rep: [String: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { rep[type.rawValue] = d }
            }
            if !rep.isEmpty { saved.append(rep) }
        }
        return saved
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [[String: Data]]) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        let newItems: [NSPasteboardItem] = items.map { rep in
            let item = NSPasteboardItem()
            for (type, data) in rep {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}
