# Claude Apple Bridges — Developer Notes

## Compile All Bridges

```bash
# Reminders
cat > /tmp/reminders-info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Claude Code needs access to Reminders to manage tasks.</string>
</dict></plist>
EOF
swiftc reminders-bridge.swift -o ~/.claude/reminders-bridge -framework EventKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/reminders-info.plist
codesign --force --sign - --identifier com.claude.reminders-bridge ~/.claude/reminders-bridge

# Contacts
cat > /tmp/contacts-info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>NSContactsUsageDescription</key>
    <string>Claude Code needs access to Contacts.</string>
</dict></plist>
EOF
swiftc contacts-bridge.swift -o ~/.claude/contacts-bridge -framework Contacts \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/contacts-info.plist
codesign --force --sign - --identifier com.claude.contacts-bridge ~/.claude/contacts-bridge

# Calendar
cat > /tmp/calendar-info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Claude Code needs access to Calendar.</string>
</dict></plist>
EOF
swiftc calendar-bridge.swift -o ~/.claude/calendar-bridge -framework EventKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/calendar-info.plist
codesign --force --sign - --identifier com.claude.calendar-bridge ~/.claude/calendar-bridge

# Notes (no plist needed)
swiftc notes-bridge.swift -o ~/.claude/notes-bridge
codesign --force --sign - --identifier com.claude.notes-bridge ~/.claude/notes-bridge

# Mail (no plist needed)
swiftc mail-bridge.swift -o ~/.claude/mail-bridge
codesign --force --sign - --identifier com.claude.mail-bridge ~/.claude/mail-bridge

# tmux (no plist needed)
swiftc tmux-bridge.swift -o ~/.claude/tmux-bridge
codesign --force --sign - --identifier com.claude.tmux-bridge ~/.claude/tmux-bridge
```

## Quick Smoke Test

```bash
~/.claude/reminders-bridge lists
~/.claude/reminders-bridge today
~/.claude/reminders-bridge overdue
~/.claude/calendar-bridge today
~/.claude/calendar-bridge free-slots $(date +%Y-%m-%d)
~/.claude/contacts-bridge search "test"
~/.claude/contacts-bridge birthdays-upcoming 30
~/.claude/notes-bridge accounts
~/.claude/mail-bridge accounts
~/.claude/tmux-bridge sessions
```

## Branching

- `main` — stable releases
- `develop` — active development, PRs go here

## notes-bridge: HTML Formatting

The `add` and `append` commands support HTML — Notes.app renders it natively:

```bash
notes-bridge add "Work" "Title" "<b>Bold</b><br><ul><li>Item 1</li><li>Item 2</li></ul>"
notes-bridge append "Title" "<br><b>Update:</b> some text"
```

Supported tags: `<b>`, `<i>`, `<u>`, `<br>`, `<ul>`, `<ol>`, `<li>`, `<h1>`–`<h3>`, `<a href="...">`, `<p>`

`read` always returns plain text (HTML stripped).

## mail-bridge: Send Behavior

- **Without `--force`**: opens Mail.app compose window — user reviews and sends manually
- **With `--force`**: sends directly without UI (use only when explicitly requested)

### Markdown body (`--md` / `--md-file`)

`send` can take a **markdown** body, converted to HTML and delivered directly as
Mail's `html content` — no clipboard, no GUI paste, works headless with `--force`.

```bash
mail-bridge send to@x.y "Subject" "Hi **there**, see [doc](https://x.y)." --md
mail-bridge send to@x.y "Subject" --md-file /tmp/body.md --force
```

- `--md` treats the positional `<body>` as markdown; `--md-file <path>` reads it
  from a file. Either takes precedence over a plain body.
- Supports headings, ordered/unordered lists, paragraphs, and inline
  bold/italic/strikethrough/inline-code/links. All body text is HTML-escaped.
- This is the **direct (`html content`) path** — distinct from `reply`, which
  renders to RTF and pastes. Needs no Accessibility/Automation grant.

## mail-bridge: Reply Behavior

`reply` opens Mail's native reply window for a message located
by `--mid`, so the quoted original, recipients, subject, and threading headers
are preserved (never overwritten). The markdown body is rendered to rich text
(`AttributedString` → RTF) and pasted via ⌘V; the window is left open for
manual review/send — no auto-save, no auto-send.

```bash
mail-bridge reply --mid "abc123@example.com" --body "Hi **there**, see [doc](https://x.y)."
mail-bridge reply --mid "abc123@example.com" --body-file /tmp/reply.md --reply-all
echo "Thanks, **will do**." | mail-bridge reply --mid "abc123@example.com"
```

- Body precedence: `--body` > `--body-file` > stdin.
- Inline markdown (bold/italic/strikethrough/inline-code/links) renders reliably;
  headings/lists are weakly represented (inline-only RTF rendering).
- Requires two one-time grants (read/send commands need neither):
  - **Accessibility** (System Settings → Privacy & Security → Accessibility →
    mail-bridge) to post the ⌘V keystroke.
  - **Automation → System Events** (prompted on first `reply`) — used to detect
    when the reply window opens. If it's missing, `reply` aborts with a message
    pointing here rather than failing silently.

## Adding a New Bridge

1. Create `<name>-bridge.swift` in repo root
2. Add compile instructions to README.md and CLAUDE.md
3. Add permission grant step to README.md
4. Add to `settings.local.json` allowed tools
5. Add usage examples to README.md
