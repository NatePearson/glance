# Glance

A discreet, ambient **Claude assistant** for macOS that lives in your menu bar — no terminal, no window switching. Hit a hotkey from any app, and a small translucent panel floats in near your cursor with the answer.

Glance runs through your **local Claude Code CLI** (`claude`) in headless mode, so it uses whatever Claude Code is signed in with — a **Claude subscription needs no API key**. AppKit/Swift, no runtime dependencies. Sibling project to DripWriter — same `build.sh` workflow.

---

## What it does

| Hotkey | Action |
| --- | --- |
| **⌥⌘A** | **Ask about the selection.** Glance copies whatever text is selected in the current app and answers/explains/acts on it. |
| **⌥⌘S** | **Screenshot a question.** Drag to select a screen region; Glance sends the image to Claude (vision) and answers what's shown — an error, a chart, a paragraph, a UI. |
| *(menu)* | **Ask about the clipboard.** Same as selection but uses whatever's already copied. (Menu-only — a global ⌥⌘C clashes with Finder's "Copy as Pathname".) |

In the answer panel:

- **Hold ⌥ (Option) to read.** In private mode the answer is frosted at rest — a soft, unreadable smudge to anyone glancing at your screen. Hold ⌥ to bring it into focus; release and it re-frosts. (See *Private mode* below.)
- **Type a follow-up** and press **↵** — the conversation keeps context (it resumes the same `claude` session).
- **⌘C** copies the answer (works without revealing it).
- **Esc**, the ✕ button, or **clicking back into your work** dismisses it.

No dock icon, no app window — just the ✨ in your menu bar and the overlay when you summon it.

### Private mode (shoulder-surf resistance)

On by default. The answer renders behind a native frosted-glass layer, so someone looking over your shoulder sees only a blurred patch — never the text. You hold **⌥** to read it, release to hide it again. Copying (⌘C) still works while it's frosted.

Toggle it off in the menu (✨ ▸ *Private — blur answer, hold ⌥ to read*) if you'd rather see the answer plainly.

> This is **privacy from a casual bystander, not security.** It does not defend against screenshots, screen recording, or someone who can see your screen clearly while you're holding ⌥. Don't treat it as protection for genuinely sensitive data.

---

## Requirements (read this first)

Glance is a thin front-end for **Claude Code** — it doesn't talk to any API itself. So to use it you need:

- **macOS 13+** (Apple Silicon or Intel).
- **Claude Code installed and signed in.** Run `claude` in a terminal once and make sure it answers (`claude /login` if needed). Glance shells out to that same `claude`, so **its auth = your auth, and your questions count against your own Claude plan.** No API key, but **no Claude Code = Glance can't answer.**

Glance auto-detects `claude` (login-shell `PATH`, then common install dirs). If it can't find it, set the path via the menu: ✨ ▸ **Set Claude Path…** (`which claude` in Terminal tells you where it is).

---

## Install

### Option A — download the prebuilt app (quickest)

1. Grab `Glance.zip` from the [latest release](../../releases/latest) and unzip it.
2. Because it's a free, **unsigned** app (not notarized by Apple), Gatekeeper will block a normal double-click. Clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/Glance.app
   ```
   (Adjust the path to wherever you put it.) Then double-click to launch.
3. Optional: drag it to `/Applications` and add it to **System Settings ▸ General ▸ Login Items**.

### Option B — build from source (most trustworthy)

No Gatekeeper hassle, and you can read every line first. Needs Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/NatePearson/glance.git
cd glance
./build.sh
open Glance.app
```

`build.sh` compiles a universal (arm64 + x86_64) binary, assembles `Glance.app`, and ad-hoc signs it locally. Re-run after any change to `Sources/*.swift`.

---

## First run / permissions

- **Accessibility (for ⌥⌘A only).** Selection capture works by sending a synthetic ⌘C, gated behind Accessibility. The first time you use ⌥⌘A, Glance prompts you — enable **Glance** under *System Settings ▸ Privacy & Security ▸ Accessibility*, then try again.
- **⌥⌘S (screenshot) needs no permission from Glance** — Apple's `screencapture` tool handles its own Screen Recording prompt.

Usage counts against your Claude plan, exactly as if you'd asked Claude Code.

---

## The trade-off (read this)

Riding the `claude` CLI is what lets Glance skip an API key — but every question boots the full Claude Code runtime, which loads **~16–18K tokens** of tool/scaffolding context before answering. Consequences:

- **First word in ~2–9s**, not instant. Back-to-back questions are faster (Claude Code caches the context for ~5 min); a cold question after idle pays the full startup.
- **Each question draws on your plan's usage** (a trivial question can cost what ~15–20K input tokens would). Fine for occasional glances; heavy rapid-fire use will eat into a Max plan's 5-hour window.

Glance trims what it can — it overrides the system prompt, disables skills + MCP, disallows tools, and runs in a clean temp dir so no project `CLAUDE.md` is pulled in — but it can't strip the tool context without `--bare`, and `--bare` would force API-key auth (defeating the point).

**If you want it genuinely snappy**, the alternative is a direct API call with a key — roughly 1–2s and a fraction of the tokens. That's a small change in `ClaudeCodeClient` (swap the CLI for an HTTPS call). Ask and it can be added as an optional mode.

---

## Settings & customization

Menu bar ✨:

- **Private** — on by default. Frost the answer; hold ⌥ to read. See *Private mode* above.
- **Model ▸** — **Opus 4.8** (default, most capable) or **Sonnet 4.6** (faster, lighter).
- **Mode ▸** — **Normal** (default, `--effort low`: snappy, terse) or **Max** (`--effort max`: deepest, slowest).
- **Set Claude Path…** — override auto-detection.
- A status line shows which `claude` it's using.

In code (then re-run `build.sh`):

- **Hotkeys** — `Sources/main.swift`, `registerHotKeys()`.
- **Model / mode / system prompt** — `Sources/Config.swift`.
- **CLI flags** — `Sources/ClaudeCodeClient.swift` (`send`).
- **Panel size / position / styling** — `Sources/HUDPanel.swift`.

---

## How it's wired

```
hotkey (Carbon)  ─▶  Capture            ─▶  ClaudeCodeClient            ─▶  GlanceHUD
⌥⌘A / ⌥⌘S            selection / region      `claude -p` (stream-json in/out)   floating panel
                     (clipboard / vision)     subscription auth, no API key      streams + follow-ups
                                              keeps session_id → --resume
```

- `Sources/HotKeyManager.swift` — global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility needed for the hotkey itself).
- `Sources/Capture.swift` — selection/clipboard capture (preserves & restores your clipboard) and `screencapture -i` region grab.
- `Sources/ClaudeCodeClient.swift` — spawns the `claude` CLI in headless `--print` mode, feeds a stream-json user message (text and/or image content blocks) on stdin, parses streamed `text_delta` events from stdout, and keeps `session_id` so follow-ups `--resume` the same conversation. `ClaudeLocator` finds the binary for a GUI app with no shell `PATH`.
- `Sources/HUDPanel.swift` — the borderless, translucent, auto-sizing `NSPanel`.
- `Sources/main.swift` — menu-bar status item, menu, orchestration.

---

## Troubleshooting

- **"Claude Code not found"** — install Claude Code / sign in, or set the path via ✨ ▸ Set Claude Path… (`which claude`).
- **Slow first answer** — expected; see the trade-off above. Use Normal mode (not Max), or pick Sonnet 4.6 in the Model menu.
- **⌥⌘A says it can't read a selection** — grant Accessibility, and make sure text is actually selected in the front app.
- **Auth errors / "Invalid API key"** — your Claude Code login may have expired. Run `claude` in Terminal and re-login (`claude /login`); Glance uses the same credentials.
- **Nothing happens on a hotkey** — another app may have grabbed the same global shortcut. Change the binding in `registerHotKeys()` and rebuild.
- **Screenshot capture does nothing** — pressing Esc during the crosshair cancels (expected). If the crosshair never appears, grant Screen Recording when macOS prompts.
- **Panel closes too eagerly** — it dismisses when it loses focus (click-away). Click the panel (or its follow-up field) to keep interacting.

---

## Notes & limits

- v1 keeps answers short by design (concise system prompt, `--effort low`). Switch to Max mode or edit `Config.systemPrompt` for longer outputs.
- Glance briefly takes key focus when the panel appears (so the follow-up field, ⌘C, and Esc work). It's an `.accessory` app — no dock icon, no menu-bar takeover. To never take focus, that's a one-line change in `HUDPanel.show(near:)`.
- Each query spawns a short-lived `claude` process in a temp working directory; nothing is written to your projects.
