# mail-bridge

Read and send Apple Mail messages from Claude Code via AppleScript.

**Binary:** `~/.claude/mail-bridge`

**Default mailbox:** `INBOX`

## Commands

### accounts

List all email accounts.

```bash
~/.claude/mail-bridge accounts
```

### mailboxes

List mailboxes for an account.

```bash
~/.claude/mail-bridge mailboxes [account]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `account` | No | Account name (default: first account) |

```bash
~/.claude/mail-bridge mailboxes
~/.claude/mail-bridge mailboxes "iCloud"
```

### list

List recent messages. Smart argument detection: if the second argument matches an account name, it's treated as the account (not a mailbox).

```bash
~/.claude/mail-bridge list [mailbox|account] [account] [count]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `mailbox` | No | Mailbox name (default: `INBOX`) |
| `account` | No | Account name (default: first account) |
| `count` | No | Number of messages to show (default: `20`) |

```bash
# Default: 20 most recent in INBOX
~/.claude/mail-bridge list

# Specific mailbox
~/.claude/mail-bridge list "Sent Messages"

# Account shortcut (auto-detected)
~/.claude/mail-bridge list "iCloud"

# Mailbox + account + count
~/.claude/mail-bridge list "INBOX" "iCloud" 50
```

Output format: `<index>. <subject> [UNREAD] — <sender> (<month>/<day>)`

### unread

List unread messages. Filter runs inside Mail.app via a `whose` clause, so it's fast even on large INBOXes. Same smart argument detection as `list`.

```bash
~/.claude/mail-bridge unread [mailbox|account] [account] [--all] [--max N] [--since <X>]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `mailbox` | No | Mailbox name (default: `INBOX`) |
| `account` | No | Account name (default: first account) |
| `--all` | No | Iterate every configured account, not just one |
| `--max N` | No | Limit number of results (default: 50) |
| `--since <X>` | No | Only messages within `Nd`/`Nw`/`Nm` or `YYYY-MM-DD` |

```bash
# Unread in the default account's INBOX
~/.claude/mail-bridge unread

# Specific account
~/.claude/mail-bridge unread "iCloud"

# Every account, newest 20, last week only
~/.claude/mail-bridge unread --all --max 20 --since 7d
```

### search

Search messages by subject and sender in INBOX. Supports unread-only and date-window filtering; both are executed inside Mail.app for speed.

```bash
~/.claude/mail-bridge search <query> [max_results] [account] [--unread] [--since <X>] [--max N]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `query` | Yes | Search term (matches subject and sender) |
| `max_results` | No | Legacy positional cap (default: 50) |
| `account` | No | Account name (default: all accounts) |
| `--unread` | No | Only include unread messages |
| `--since <X>` | No | Only messages within `Nd`/`Nw`/`Nm` or `YYYY-MM-DD` |
| `--max N` | No | Alternative to the positional `max_results` |

```bash
~/.claude/mail-bridge search "invoice"
~/.claude/mail-bridge search "invoice" "iCloud"
~/.claude/mail-bridge search "google" --unread --since 30d --max 10
```

### read

Read a message by its index number (from `list` output). Unread status is preserved by default.

```bash
~/.claude/mail-bridge read <index> [mailbox] [account] [--mark-read]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `index` | Yes | Message index (from `list` output) |
| `mailbox` | No | Mailbox name (default: `INBOX`) |
| `account` | No | Account name (default: first account) |
| `--mark-read` | No | Mark message as read after reading |

```bash
# Read without changing status
~/.claude/mail-bridge read 1

# Read and mark as read
~/.claude/mail-bridge read 3 --mark-read

# Specific mailbox
~/.claude/mail-bridge read 1 "Sent Messages" "iCloud"
```

### send

Compose and send an email. **Without `--force`**: opens a compose window in Mail.app for review. **With `--force`**: sends directly without UI.

The body can be **plain text**, **markdown** (`--md` / `--md-file`), or **HTML from a file** (`--html-file`). Markdown is converted to HTML and delivered directly as Mail's `html content` — no clipboard, no GUI paste, so it works headless with `--force`. With `--md-file` / `--html-file` the positional `<body>` is optional.

```bash
~/.claude/mail-bridge send <to> <subject> [body] [/path/to/attachment ...] [--from <email>] [--html-file <path> | --md | --md-file <path>] [--force]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `to` | Yes | Recipient email address |
| `subject` | Yes | Email subject |
| `body` | Conditional | Email body text (treated as markdown with `--md`). Optional when `--md-file` or `--html-file` is given |
| `/path/to/attachment ...` | No | One or more file attachment paths |
| `--from <email>` | No | Sender email address (default: first account's email) |
| `--md` | No | Treat the positional `<body>` as markdown → delivered as HTML |
| `--md-file <path>` | No | Read a markdown body from a file → delivered as HTML |
| `--html-file <path>` | No | Send a ready-made HTML body from a file |
| `--force` | No | Send directly without opening compose window |

Markdown support: headings, ordered/unordered lists, paragraphs, and inline bold/italic/strikethrough/inline-code/links. All body text is HTML-escaped, so the body can't break or inject markup.

```bash
# Open compose window for review (recommended)
~/.claude/mail-bridge send "heiko@web.de" "Meeting Notes" "Hi Heiko, here are the notes..."

# Send directly (use with care)
~/.claude/mail-bridge send "heiko@web.de" "Meeting Notes" "Hi Heiko, here are the notes..." --force

# With attachment and specific sender
~/.claude/mail-bridge send "heiko@web.de" "Report" "See attached." /tmp/report.pdf --from work@company.com

# Markdown body, delivered as formatted HTML (works headless with --force)
~/.claude/mail-bridge send "recipient@example.com" "Update" "Hi **there**, see [the doc](https://x.y)." --md --force

# Markdown body read from a file
~/.claude/mail-bridge send "recipient@example.com" "Update" --md-file /tmp/update.md --force
```

**Important:** Always prefer opening the compose window (without `--force`) unless the user explicitly asks to send directly.

### reply

Open a formatted reply to an existing message, located by its RFC822 message-id. Unlike `send`, this opens Mail's **native reply window**, so the quoted original, recipients, subject, and threading headers are preserved (never overwritten), and the reply is sent from the account that actually received the message. The markdown body is rendered to rich text (`AttributedString` → RTF) and pasted in via ⌘V; the window is **left open for manual review/send** — nothing is auto-sent.

Get the `<message-id>` from `search` output, which prints it as `<mid:...>`.

```bash
~/.claude/mail-bridge reply --mid <message-id> [--body <markdown> | --body-file <path>] [--reply-all]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `--mid <message-id>` | Yes | RFC822 message-id of the message to reply to (from `search` output) |
| `--body <markdown>` | Conditional | Reply body as markdown |
| `--body-file <path>` | Conditional | Read the markdown body from a file |
| `--reply-all` | No | Reply to all recipients instead of just the sender |

Body precedence: `--body` > `--body-file` > markdown piped on stdin. At least one must be provided.

Inline markdown (bold/italic/strikethrough/inline-code/links) renders reliably as rich text; headings and lists are only weakly represented (inline-only RTF) — for full block structure, prefer `send --md`.

```bash
# Formatted reply (opens Mail's reply window for review)
~/.claude/mail-bridge reply --mid "abc123@example.com" --body "Hi **there**, sounds good — see [the doc](https://x.y)."

# Reply-all from a file
~/.claude/mail-bridge reply --mid "abc123@example.com" --body-file /tmp/reply.md --reply-all

# Body piped on stdin
echo "Thanks, **will do**." | ~/.claude/mail-bridge reply --mid "abc123@example.com"
```

**One-time grants:** `reply` needs **Accessibility** (to post the ⌘V keystroke) and **Automation → System Events** (to detect when the reply window opens). It fails fast with guidance if either is missing. The `read`/`search`/`send` commands need neither.

### delete

Move a message to Trash. Dry-run by default — use `--force` to actually delete.

```bash
~/.claude/mail-bridge delete <index> [mailbox] [account] [--force]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `index` | Yes | Message index |
| `mailbox` | No | Mailbox name (default: `INBOX`) |
| `account` | No | Account name (default: first account) |
| `--force` | No | Actually move to Trash (without: dry-run preview) |

```bash
# Preview
~/.claude/mail-bridge delete 5

# Actually delete
~/.claude/mail-bridge delete 5 --force
```

## Common Workflows

### Check for new mail

```bash
~/.claude/mail-bridge unread
~/.claude/mail-bridge read 1
```

### Draft a formatted reply

```bash
# Find the message and grab its message-id from the <mid:...> in the output
~/.claude/mail-bridge search "quarterly report"

# Open a threaded, formatted reply in Mail.app for review (markdown → rich text)
~/.claude/mail-bridge reply --mid "abc123@example.com" --body "Thanks — **looks good**, see [notes](https://x.y)."
```

`reply` preserves the quote, recipients, subject, and threading, and sends from the receiving account — prefer it over `send` for replying to an existing message.

### Search and read

```bash
~/.claude/mail-bridge search "quarterly report"
~/.claude/mail-bridge read 1
```
