#!/usr/bin/env swift

// mail-bridge.swift
// A small CLI bridge for Claude Code to access Apple Mail via NSAppleScript.
// Copyright © 2026 Tobias Stöger (tstoegi). Licensed under the MIT License.
// Usage:
//   mail-bridge accounts                               - List all accounts
//   mail-bridge mailboxes [account]                    - List mailboxes (default: first account)
//   mail-bridge list [mailbox] [account] [count]       - List recent messages (default: INBOX, 20)
//   mail-bridge unread [mailbox] [account]             - List unread messages (default: INBOX)
//   mail-bridge search <query> [account]               - Search subject/sender in INBOX (output includes <mid:...>)
//   mail-bridge read <index> [mailbox] [account]       - Read message by index
//   mail-bridge read --mid <message-id> [account]      - Read by RFC822 message-id (from search output)
//   mail-bridge send <to> <subject> <body>             - Send a new email (plain text)
//   mail-bridge send <to> <subject> <body> --md         - Send markdown body as HTML (no copy-paste)
//   mail-bridge send <to> <subject> --md-file <path>    - Send markdown file as HTML
//   mail-bridge send <to> <subject> --html-file <path>  - Send HTML email from file
//   mail-bridge reply --mid <message-id> --body <md>    - Open a formatted reply (markdown→rich text)
//   mail-bridge delete <index> [mailbox] [account] [--force]  - Move message to Trash

import Foundation
import AppKit              // NSPasteboard, NSAttributedString, RTF export
import ApplicationServices // AXIsProcessTrusted(WithOptions), kAXTrustedCheckOptionPrompt
import CoreGraphics        // CGEvent / CGEventSource for the ⌘V paste

// MARK: - String Helpers

// Escape strings for safe interpolation inside AppleScript double-quoted strings.
func escapeForAppleScript(_ string: String) -> String {
    string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

// Parse --since values like "7", "7d", "1w", "1m" or a YYYY-MM-DD date.
// Returns number of days (0 = no filter). Anything unparseable yields 0.
func parseDaysArg(_ raw: String) -> Int {
    let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty { return 0 }
    // Bare integer or with suffix d/w/m
    if let n = Int(trimmed) { return max(0, n) }
    let suffix = trimmed.last!
    let body = String(trimmed.dropLast())
    if let n = Int(body) {
        switch suffix {
        case "d": return max(0, n)
        case "w": return max(0, n * 7)
        case "m": return max(0, n * 30)
        default: break
        }
    }
    // YYYY-MM-DD → days between then and today (never negative).
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    if let d = formatter.date(from: trimmed) {
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return max(0, days)
    }
    return 0
}

// Normalize typographic quotes to ASCII equivalents for reliable matching.
func normalizeQuotes(in string: String) -> String {
    string
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
}

// MARK: - AppleScript Runner

func runScript(_ source: String) -> NSAppleEventDescriptor? {
    var errorInfo: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let result = script.executeAndReturnError(&errorInfo)
    if let error = errorInfo {
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        fputs("AppleScript error: \(message)\n", stderr)
        return nil
    }
    return result
}

func descriptorToStrings(_ descriptor: NSAppleEventDescriptor?) -> [String] {
    guard let desc = descriptor else { return [] }
    if desc.numberOfItems > 0 {
        var items: [String] = []
        for i in 1...desc.numberOfItems {
            if let item = desc.atIndex(i)?.stringValue {
                items.append(item)
            }
        }
        return items
    }
    if let value = desc.stringValue, !value.isEmpty {
        return [value]
    }
    return []
}

// MARK: - Commands

func listAccounts() {
    let result = runScript("""
        tell application "Mail"
            set out to {}
            repeat with acc in accounts
                set end of out to name of acc
            end repeat
            return out
        end tell
    """)
    let accounts = descriptorToStrings(result)
    if accounts.isEmpty {
        print("No accounts found.")
    } else {
        accounts.forEach { print($0) }
    }
}

func listMailboxes(account: String) {
    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let result = runScript("""
        tell application "Mail"
            set out to {}
            repeat with mb in mailboxes of \(accountClause)
                set end of out to name of mb
            end repeat
            return out
        end tell
    """)
    let mailboxes = descriptorToStrings(result)
    if mailboxes.isEmpty {
        fputs("No mailboxes found\(account.isEmpty ? "" : " for '\(account)'")\n", stderr)
        exit(1)
    }
    mailboxes.forEach { print($0) }
}

func listMessages(mailbox: String, account: String, count: Int) {
    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let result = runScript("""
        tell application "Mail"
            set out to {}
            set acc to \(accountClause)
            set msgs to messages of mailbox "\(escapeForAppleScript(mailbox))" of acc
            set msgCount to count of msgs
            if msgCount is 0 then return out
            set endIdx to \(count)
            if endIdx > msgCount then set endIdx to msgCount
            repeat with i from 1 to endIdx
                set m to item i of msgs
                set isRead to read status of m
                set readMark to ""
                if isRead is false then set readMark to " [UNREAD]"
                set d to date received of m
                set mo to month of d as integer as string
                set da to day of d as string
                set entry to (i as text) & ". " & subject of m & readMark & " — " & sender of m & " (" & mo & "/" & da & ")"
                set end of out to entry
            end repeat
            return out
        end tell
    """)
    let messages = descriptorToStrings(result)
    if messages.isEmpty {
        print("No messages in '\(mailbox)'.")
    } else {
        messages.forEach { print($0) }
    }
}

// Ask Mail.app to filter unread messages itself via `whose read status is false`
// instead of iterating and checking every message from Swift. For large INBOXes
// this is orders of magnitude faster — each AppleScript property access is an
// IPC round-trip, so the old approach scaled linearly with total mail count.
// Batch-fetches subject/sender/date as lists so we pay 3 round-trips total.
func listUnreadForAccount(mailbox: String, accountClause: String, maxResults: Int, sinceDays: Int, accountPrefix: String) -> [String] {
    let dateFilter = sinceDays > 0
        ? " and date received ≥ ((current date) - \(sinceDays) * days)"
        : ""
    let prefixLiteral = accountPrefix.isEmpty ? "" : "[\(escapeForAppleScript(accountPrefix))] "

    let result = runScript("""
        tell application "Mail"
            set out to {}
            try
                set acc to \(accountClause)
            on error
                return out
            end try
            try
                set unreadMsgs to (messages of mailbox "\(escapeForAppleScript(mailbox))" of acc whose read status is false\(dateFilter))
            on error
                return out
            end try
            set n to count of unreadMsgs
            if n is 0 then return out
            set endIdx to \(maxResults)
            if endIdx > n then set endIdx to n
            -- Iterate the already-filtered list. Batch property fetch via
            -- `subject of unreadMsgs` would be fewer round-trips, but Mail's
            -- AppleScript dictionary throws on some IMAP accounts when you
            -- ask for a property of a whose-specifier — iterating is robust.
            repeat with i from 1 to endIdx
                try
                    set m to item i of unreadMsgs
                    set d to date received of m
                    set mo to month of d as integer as string
                    set da to day of d as string
                    set entry to "\(prefixLiteral)" & subject of m & " — " & sender of m & " (" & mo & "/" & da & ")"
                    set end of out to entry
                end try
            end repeat
            return out
        end tell
    """)
    return descriptorToStrings(result)
}

func listUnread(mailbox: String, account: String, maxResults: Int, sinceDays: Int, allAccounts: Bool) {
    let limit = maxResults > 0 ? maxResults : 50
    let sinceNote = sinceDays > 0 ? " (last \(sinceDays)d)" : ""

    if allAccounts {
        var all: [String] = []
        for accName in accountNames {
            let clause = "account \"\(escapeForAppleScript(accName))\""
            let rows = listUnreadForAccount(mailbox: mailbox, accountClause: clause, maxResults: limit, sinceDays: sinceDays, accountPrefix: accName)
            all.append(contentsOf: rows)
            if all.count >= limit { break }
        }
        let shown = Array(all.prefix(limit))
        if shown.isEmpty {
            print("No unread messages in '\(mailbox)' across all accounts\(sinceNote).")
        } else {
            print("Unread in '\(mailbox)' — all accounts (\(shown.count)):")
            shown.forEach { print("  " + $0) }
        }
        return
    }

    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let messages = listUnreadForAccount(mailbox: mailbox, accountClause: accountClause, maxResults: limit, sinceDays: sinceDays, accountPrefix: "")
    if messages.isEmpty {
        print("No unread messages in '\(mailbox)'\(sinceNote).")
    } else {
        print("Unread in '\(mailbox)' (\(messages.count)):")
        messages.forEach { print("  " + $0) }
    }
}

// Per-account search using a Mail.app `whose` filter. Same reasoning as
// listUnread: let Mail.app filter internally instead of iterating every
// message in Swift with per-property IPC calls. Supports optional
// --unread and --since date filters stacked into the same whose clause.
func searchMessagesForAccount(query: String, accountClause: String, maxResults: Int, onlyUnread: Bool, sinceDays: Int, accountLabel: String) -> [String] {
    let escapedQuery = escapeForAppleScript(query)
    let unreadFilter = onlyUnread ? " and read status is false" : ""
    let dateFilter = sinceDays > 0
        ? " and date received ≥ ((current date) - \(sinceDays) * days)"
        : ""
    let prefixLiteral = accountLabel.isEmpty ? "" : "[\(escapeForAppleScript(accountLabel))] "

    let result = runScript("""
        tell application "Mail"
            set out to {}
            try
                set acc to \(accountClause)
            on error
                return out
            end try
            try
                set matches to (messages of mailbox "INBOX" of acc whose (subject contains "\(escapedQuery)" or sender contains "\(escapedQuery)")\(unreadFilter)\(dateFilter))
            on error
                return out
            end try
            set n to count of matches
            if n is 0 then return out
            set endIdx to \(maxResults)
            if endIdx > n then set endIdx to n
            repeat with i from 1 to endIdx
                try
                    set m to item i of matches
                    set d to date received of m
                    set mo to month of d as integer as string
                    set da to day of d as string
                    set mid to ""
                    try
                        set mid to message id of m
                    end try
                    set entry to "\(prefixLiteral)<mid:" & mid & "> " & subject of m & " — " & sender of m & " (" & mo & "/" & da & ")"
                    set end of out to entry
                end try
            end repeat
            return out
        end tell
    """)
    return descriptorToStrings(result)
}

func searchMessages(query: String, account: String, maxResults: Int, onlyUnread: Bool, sinceDays: Int) {
    let limit = maxResults > 0 ? maxResults : 50
    let filterNote = [
        onlyUnread ? "unread" : nil,
        sinceDays > 0 ? "last \(sinceDays)d" : nil
    ].compactMap { $0 }.joined(separator: ", ")
    let suffix = filterNote.isEmpty ? "" : " (\(filterNote))"

    if account.isEmpty {
        var all: [String] = []
        for accName in accountNames {
            let clause = "account \"\(escapeForAppleScript(accName))\""
            let rows = searchMessagesForAccount(query: query, accountClause: clause, maxResults: limit, onlyUnread: onlyUnread, sinceDays: sinceDays, accountLabel: accName)
            all.append(contentsOf: rows)
            if all.count >= limit { break }
        }
        let shown = Array(all.prefix(limit))
        if shown.isEmpty {
            print("No messages matching '\(query)'\(suffix) across all accounts.")
        } else {
            print("Found \(shown.count) message(s)\(suffix):")
            shown.forEach { print("  " + $0) }
        }
    } else {
        let clause = "account \"\(escapeForAppleScript(account))\""
        let matches = searchMessagesForAccount(query: query, accountClause: clause, maxResults: limit, onlyUnread: onlyUnread, sinceDays: sinceDays, accountLabel: "")
        if matches.isEmpty {
            print("No messages matching '\(query)'\(suffix).")
        } else {
            print("Found \(matches.count) message(s)\(suffix):")
            matches.forEach { print("  " + $0) }
        }
    }
}

func readMessage(index: Int, mailbox: String, account: String, markRead: Bool, raw: Bool) {
    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let markReadScript = markRead ? "set read status of m to true" : ""
    let bodyProp = raw ? "source of m" : "content of m"
    let result = runScript("""
        tell application "Mail"
            set acc to \(accountClause)
            set msgs to messages of mailbox "\(escapeForAppleScript(mailbox))" of acc
            set msgCount to count of msgs
            if \(index) < 1 or \(index) > msgCount then
                return "INDEX_OUT_OF_RANGE"
            end if
            set m to item \(index) of msgs
            set d to date received of m
            set dateStr to date string of d & " " & time string of d
            set msgContent to "From: " & sender of m & "\\nDate: " & dateStr & "\\nSubject: " & subject of m & "\\n---\\n" & (\(bodyProp))
            \(markReadScript)
            return msgContent
        end tell
    """)
    guard let text = result?.stringValue else {
        fputs("Error reading message.\n", stderr)
        exit(1)
    }
    if text == "INDEX_OUT_OF_RANGE" {
        fputs("Message index \(index) is out of range.\n", stderr)
        exit(1)
    }
    print(text)
}

// Read a message by its RFC822 message-id (as returned by `search`).
// Triggers Mail.app to fetch the full body if it's only partial — the
// `source of m` property forces a download. Searches across all mailboxes
// of the given account (or first account if none given).
func readMessageByMid(messageId: String, account: String, markRead: Bool, raw: Bool) {
    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let markReadScript = markRead ? "set read status of m to true" : ""
    let bodyProp = raw ? "source of m" : "content of m"
    let escapedMid = escapeForAppleScript(messageId)
    let result = runScript("""
        tell application "Mail"
            set acc to \(accountClause)
            set foundMsg to missing value
            repeat with mb in (every mailbox of acc)
                try
                    set candidates to (messages of mb whose message id is "\(escapedMid)")
                    if (count of candidates) > 0 then
                        set foundMsg to item 1 of candidates
                        exit repeat
                    end if
                end try
            end repeat
            if foundMsg is missing value then
                return "MID_NOT_FOUND"
            end if
            set m to foundMsg
            set d to date received of m
            set dateStr to date string of d & " " & time string of d
            set msgContent to "From: " & sender of m & "\\nDate: " & dateStr & "\\nSubject: " & subject of m & "\\n---\\n" & (\(bodyProp))
            \(markReadScript)
            return msgContent
        end tell
    """)
    guard let text = result?.stringValue else {
        fputs("Error reading message.\n", stderr)
        exit(1)
    }
    if text == "MID_NOT_FOUND" {
        fputs("Message with id \(messageId) not found.\n", stderr)
        exit(1)
    }
    print(text)
}

func getDefaultSenderEmail() -> String {
    let result = runScript("""
        tell application "Mail"
            set acc to item 1 of accounts
            set addrs to email addresses of acc
            if (count of addrs) > 0 then
                return item 1 of addrs
            end if
            return ""
        end tell
    """)
    return result?.stringValue ?? ""
}

// MARK: - Markdown → HTML (for `send`, delivered as Mail `html content`)

// Unlike the reply path (which renders to RTF and pastes), `send` can set a
// message's `html content` directly via AppleScript — no clipboard, no GUI,
// works headless with --force. So markdown is converted to HTML here. Inline
// styling reuses Apple's markdown parser (the same intents the RTF path
// resolves); only the block structure (headings/lists/paragraphs) is handled
// directly. All user text is HTML-escaped, so the body can't break the markup.

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// Render one line of inline markdown (bold/italic/strikethrough/code/links) to
// inline HTML. Falls back to escaped plain text if the parser can't handle it.
func inlineMarkdownToHTML(_ line: String) -> String {
    if line.isEmpty { return "" }
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    guard let attributed = try? AttributedString(markdown: line, options: options) else {
        return htmlEscape(line)
    }
    let ns = NSAttributedString(attributed)
    let intentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    var html = ""
    ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
        var inner = htmlEscape((ns.string as NSString).substring(with: range))
        var raw: UInt? = nil
        if let n = attrs[intentKey] as? UInt { raw = n }
        else if let n = attrs[intentKey] as? NSNumber { raw = n.uintValue }
        if let raw = raw {
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) { inner = "<code>\(inner)</code>" }
            if intent.contains(.strikethrough) { inner = "<s>\(inner)</s>" }
            if intent.contains(.emphasized) { inner = "<em>\(inner)</em>" }
            if intent.contains(.stronglyEmphasized) { inner = "<strong>\(inner)</strong>" }
        }
        if let url = attrs[.link] as? URL {
            inner = "<a href=\"\(htmlEscape(url.absoluteString))\">\(inner)</a>"
        } else if let urlStr = attrs[.link] as? String {
            inner = "<a href=\"\(htmlEscape(urlStr))\">\(inner)</a>"
        }
        html += inner
    }
    return html
}

// Heading "# .. ###### " → (level, text); nil if not a heading.
func parseHeading(_ line: String) -> (level: Int, text: String)? {
    var level = 0
    for ch in line { if ch == "#" { level += 1 } else { break } }
    guard level >= 1, level <= 6 else { return nil }
    let after = line.index(line.startIndex, offsetBy: level)
    guard after < line.endIndex, line[after] == " " else { return nil }
    return (level, String(line[after...]).trimmingCharacters(in: .whitespaces))
}

// "- ", "* ", "+ " item → its text; nil otherwise.
func unorderedItemText(_ line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

// "1. " / "2) " item → its text; nil otherwise.
func orderedItemText(_ line: String) -> String? {
    var idx = line.startIndex
    var sawDigit = false
    while idx < line.endIndex, line[idx].isNumber { sawDigit = true; idx = line.index(after: idx) }
    guard sawDigit, idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return nil }
    let next = line.index(after: idx)
    guard next < line.endIndex, line[next] == " " else { return nil }
    return String(line[next...]).trimmingCharacters(in: .whitespaces)
}

// Convert a markdown document to a small HTML document for Mail's html content.
func markdownToHTML(_ markdown: String) -> String {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out = ""
    var paragraph: [String] = []
    func flushParagraph() {
        if !paragraph.isEmpty {
            out += "<p>" + paragraph.joined(separator: "<br>\n") + "</p>\n"
            paragraph.removeAll()
        }
    }
    var i = 0
    while i < lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        if line.isEmpty { flushParagraph(); i += 1; continue }
        if let h = parseHeading(line) {
            flushParagraph()
            out += "<h\(h.level)>\(inlineMarkdownToHTML(h.text))</h\(h.level)>\n"
            i += 1; continue
        }
        if unorderedItemText(line) != nil {
            flushParagraph()
            out += "<ul>\n"
            while i < lines.count, let t = unorderedItemText(lines[i].trimmingCharacters(in: .whitespaces)) {
                out += "<li>\(inlineMarkdownToHTML(t))</li>\n"; i += 1
            }
            out += "</ul>\n"; continue
        }
        if orderedItemText(line) != nil {
            flushParagraph()
            out += "<ol>\n"
            while i < lines.count, let t = orderedItemText(lines[i].trimmingCharacters(in: .whitespaces)) {
                out += "<li>\(inlineMarkdownToHTML(t))</li>\n"; i += 1
            }
            out += "</ol>\n"; continue
        }
        paragraph.append(inlineMarkdownToHTML(line))
        i += 1
    }
    flushParagraph()
    return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\n\(out)</body></html>"
}

func sendMessage(to recipient: String, subject: String, body: String, attachmentPaths: [String], fromEmail: String, force: Bool, htmlFilePath: String) {
    for path in attachmentPaths {
        if !FileManager.default.fileExists(atPath: path) {
            fputs("Attachment not found: \(path)\n", stderr)
            exit(1)
        }
    }
    if !htmlFilePath.isEmpty && !FileManager.default.fileExists(atPath: htmlFilePath) {
        fputs("HTML file not found: \(htmlFilePath)\n", stderr)
        exit(1)
    }
    let sender = fromEmail.isEmpty ? getDefaultSenderEmail() : fromEmail
    let senderProp = sender.isEmpty ? "" : ", sender:\"\(escapeForAppleScript(sender))\""
    let visibleProp = force ? "" : ", visible:true"

    // When using --html-file, read HTML from file inside AppleScript to avoid escaping issues.
    // The content property is set to empty string; html content overrides it.
    let contentValue = htmlFilePath.isEmpty ? escapeForAppleScript(body) : ""
    var script = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"\(escapeForAppleScript(subject))", content:"\(contentValue)"\(senderProp)\(visibleProp)}
            tell newMsg
                make new to recipient with properties {address:"\(escapeForAppleScript(recipient))"}
        """
    if !htmlFilePath.isEmpty {
        script += "\n        set html content of newMsg to (do shell script \"cat \" & quoted form of \"\(escapeForAppleScript(htmlFilePath))\")"
    }
    // Multiple attachments — one `make new attachment` line per file.
    // Mail.app appends them in order, so each shows up in the compose window.
    for path in attachmentPaths {
        script += "\n        make new attachment with properties {file name:POSIX file \"\(escapeForAppleScript(path))\"}"
    }
    if force {
        script += """

                end tell
                send newMsg
                return "SENT"
            end tell
        """
    } else {
        script += """

                end tell
            end tell
            activate
            return "OPENED"
        """
    }
    let result = runScript(script)
    let status = result?.stringValue
    if status == "SENT" {
        let sentAttach = attachmentPaths.isEmpty ? "" : ", with \(attachmentPaths.count) attachment\(attachmentPaths.count == 1 ? "" : "s")"
        let sentFrom = sender.isEmpty ? "" : " from \(sender)"
        print("Message sent to \(recipient)\(sentFrom)\(sentAttach).")
    } else if status == "OPENED" {
        let openAttach = attachmentPaths.isEmpty ? "" : " with \(attachmentPaths.count) attachment\(attachmentPaths.count == 1 ? "" : "s")"
        print("Compose window opened\(openAttach) — review and send manually in Mail.app.")
    } else {
        fputs("Failed to compose message.\n", stderr)
        exit(1)
    }
}

// MARK: - Reply (rich-text paste)

// Mail treats a reply's body as read-only — setting `content` destroys the
// quoted original. The only reliable way to get markdown-rendered rich text
// into a *threaded* reply is to open Mail's native reply window (which keeps
// the quote, recipients, subject, and threading headers) and paste an
// NSAttributedString onto it via the clipboard + a synthetic ⌘V.
//
// This path needs Accessibility permission (to post the keystroke); reading
// commands are unaffected. The window is left open for manual review/send.

// Markdown → NSAttributedString → RTF Data. Exits(1) on failure.
func makeRTF(fromMarkdown markdown: String) -> Data {
    let attributed: AttributedString
    do {
        var options = AttributedString.MarkdownParsingOptions()
        // Required: without this, newlines collapse and only the first
        // paragraph survives (the default initializer drops whitespace).
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        attributed = try AttributedString(markdown: markdown, options: options)
    } catch {
        fputs("Failed to parse markdown body: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    // AttributedString's markdown parser records inline styling as a *semantic*
    // attribute (NSInlinePresentationIntent), not concrete font/strikethrough
    // attributes. The RTF writer only understands concrete attributes, so bold/
    // italic/strikethrough/code would silently vanish. Resolve the intents into
    // real NSFont traits + strikethrough before serializing. (Links survive on
    // their own — NSLink is already a concrete attribute.)
    let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
    let range = NSRange(location: 0, length: mutable.length)

    let baseSize: CGFloat = 13
    let baseFont = NSFont.systemFont(ofSize: baseSize)
    let monoFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    let fontManager = NSFontManager.shared
    mutable.addAttribute(.font, value: baseFont, range: range)

    let intentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    mutable.enumerateAttribute(intentKey, in: range) { value, runRange, _ in
        let raw: UInt
        if let n = value as? UInt { raw = n }
        else if let n = value as? NSNumber { raw = n.uintValue }
        else { return }
        let intent = InlinePresentationIntent(rawValue: raw)
        var font = intent.contains(.code) ? monoFont : baseFont
        if intent.contains(.stronglyEmphasized) { font = fontManager.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = fontManager.convert(font, toHaveTrait: .italicFontMask) }
        mutable.addAttribute(.font, value: font, range: runRange)
        if intent.contains(.strikethrough) {
            mutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: runRange)
        }
        mutable.removeAttribute(intentKey, range: runRange)
    }

    guard let data = try? mutable.data(
        from: range,
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) else {
        fputs("Failed to render reply body to RTF.\n", stderr)
        exit(1)
    }
    return data
}

// Fail fast if Accessibility is not granted (needed to post ⌘V). Prompts once.
func ensureAccessibilityOrExit() {
    if AXIsProcessTrusted() { return }
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options: CFDictionary = [promptKey: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { return }
    fputs("""
    Accessibility permission required.

    mail-bridge needs Accessibility access to paste the formatted reply into
    Mail's compose window (it sends a Cmd-V keystroke).

    Grant it here:
      System Settings → Privacy & Security → Accessibility → enable "mail-bridge"

    Open directly:
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    Then re-run the same command.
    """, stderr)
    exit(1)
}

// Snapshot of the general pasteboard so we can restore the user's clipboard.
struct ClipboardSnapshot {
    let items: [(type: NSPasteboard.PasteboardType, data: Data)]

    static func capture() -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        var captured: [(NSPasteboard.PasteboardType, Data)] = []
        if let types = pb.types {
            for type in types {
                if let data = pb.data(forType: type) {
                    captured.append((type, data))
                }
            }
        }
        return ClipboardSnapshot(items: captured)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return } // was empty before — leave it empty
        pb.declareTypes(items.map { $0.type }, owner: nil)
        // clearContents() already wiped the user's clipboard; if a write-back
        // fails, their previous contents are gone, so warn instead of silently
        // leaving them with less than they started.
        var ok = true
        for (type, data) in items {
            if !pb.setData(data, forType: type) { ok = false }
        }
        if !ok {
            fputs("Warning: could not fully restore your previous clipboard contents.\n", stderr)
        }
    }
}

// Write RTF (richest) + plain-text fallback + a transient marker so clipboard
// managers ignore our temporary entry. Returns false if the RTF write failed —
// pasting then would land empty/stale, so the caller must not proceed.
func writeRTFToPasteboard(_ rtf: Data, plainTextFallback: String) -> Bool {
    let pb = NSPasteboard.general
    pb.clearContents()
    let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    pb.declareTypes([.rtf, .string, transient], owner: nil)
    let rtfOK = pb.setData(rtf, forType: .rtf)
    pb.setString(plainTextFallback, forType: .string)
    pb.setString("", forType: transient)
    return rtfOK
}

// Count Mail's top-level windows via System Events. Returns nil on error
// (e.g. the System Events Automation grant is missing, or the query times out)
// so callers never confuse "couldn't query" with a concrete count.
func mailComposeWindowCount() -> Int? {
    let result = runScript("""
        with timeout of 10 seconds
            tell application "System Events"
                if not (exists process "Mail") then return "0"
                return (count of windows of process "Mail") as text
            end tell
        end timeout
    """)
    guard let s = result?.stringValue, let n = Int(s) else { return nil }
    return n
}

// Locate the original by message-id (across all accounts) and open Mail's
// native reply window. Exits(1) on not-found or AppleScript error.
func openReplyWindow(messageId: String, replyAll: Bool) {
    let escapedMid = escapeForAppleScript(messageId)
    // The `and` is mandatory — "with opening window reply to all" is a -2741 error.
    let replyVerb = replyAll
        ? "reply bestMsg with opening window and reply to all"
        : "reply bestMsg with opening window"
    let result = runScript("""
        with timeout of 30 seconds
            tell application "Mail"
                -- A message-id can resolve to several copies (the received
                -- INBOX copy, a Sent copy on the sending account, a flagged/
                -- Starred copy, …). Replying on the wrong one picks the wrong
                -- From account (e.g. the Sent copy makes Mail reply *as* the
                -- sender, addressed back to yourself). So we identify the copy
                -- in the account that actually received the mail (owns an
                -- address in the original To/Cc), preferring INBOX over
                -- Sent/Drafts/Junk/Trash, and reply on that one.
                set bestMsg to missing value
                set bestAcct to missing value
                set bestScore to -1
                set origRcpts to {}
                set haveRcpts to false
                set searchErr to ""
                set warnings to ""

                -- Fast path: Mail's unified `inbox` is kept synced, so a single
                -- query across all account inboxes covers the common case
                -- (replying to a received message) without sweeping every
                -- server-side mailbox of every account — which is slow on IMAP.
                try
                    set inboxCands to (messages of inbox whose message id is "\(escapedMid)")
                    repeat with m in inboxCands
                        if not haveRcpts then
                            try
                                set origRcpts to (address of every to recipient of m) & (address of every cc recipient of m)
                                set haveRcpts to true
                            end try
                        end if
                        set acc to account of (mailbox of m)
                        set sc to 6 -- in an INBOX: +4 INBOX, +2 non-Sent
                        try
                            repeat with a in (email addresses of acc)
                                if (a as text) is in origRcpts then
                                    set sc to sc + 8
                                    exit repeat
                                end if
                            end repeat
                        end try
                        if sc > bestScore then
                            set bestScore to sc
                            set bestMsg to m
                            set bestAcct to acc
                        end if
                    end repeat
                end try

                -- Fallback: not in any inbox (e.g. filed into a subfolder) —
                -- sweep every mailbox of every account and score each copy.
                if bestMsg is missing value then
                    repeat with acc in accounts
                        set acctAddrs to {}
                        try
                            set acctAddrs to email addresses of acc
                        end try
                        repeat with mb in (every mailbox of acc)
                            try
                                set candidates to (messages of mb whose message id is "\(escapedMid)")
                                if (count of candidates) > 0 then
                                    set m to item 1 of candidates
                                    if not haveRcpts then
                                        try
                                            set origRcpts to (address of every to recipient of m) & (address of every cc recipient of m)
                                            set haveRcpts to true
                                        end try
                                    end if
                                    set sc to 0
                                    set mbName to (name of mb)
                                    if mbName is "INBOX" then set sc to sc + 4
                                    if mbName is not "Drafts" and mbName does not contain "Sent" and mbName does not contain "Junk" and mbName does not contain "Trash" then set sc to sc + 2
                                    repeat with a in acctAddrs
                                        if (a as text) is in origRcpts then
                                            set sc to sc + 8
                                            exit repeat
                                        end if
                                    end repeat
                                    if sc > bestScore then
                                        set bestScore to sc
                                        set bestMsg to m
                                        set bestAcct to acc
                                    end if
                                end if
                            on error errMsg
                                set searchErr to errMsg
                            end try
                        end repeat
                    end repeat
                end if

                if bestMsg is missing value then
                    if searchErr is not "" then return "SEARCH_ERROR: " & searchErr
                    return "MID_NOT_FOUND"
                end if
                -- A copy was found, but a mailbox errored during the sweep, so a
                -- higher-scoring copy elsewhere may have been skipped — the chosen
                -- copy (hence From account) may not be the best one. Warn, don't hide.
                if searchErr is not "" then
                    set warnings to warnings & "Some mailboxes could not be searched (" & searchErr & "); the chosen reply copy may not be the best one — verify the From field before sending. "
                end if
                -- The original recipients never resolved, so the From account was
                -- scored by mailbox name alone (the +8 \"received here\" signal was
                -- lost) and may be wrong.
                if not haveRcpts then
                    set warnings to warnings & "Could not read the original recipients, so the From account was chosen by mailbox only and may be wrong — verify the From field before sending. "
                end if
                set newReply to (\(replyVerb))
                -- Send FROM the receiving account, not Mail's default. Prefer the
                -- bestAcct address that was actually addressed (handles aliases);
                -- fall back to that account's primary address.
                try
                    set senderAddr to ""
                    set acctAddrs to email addresses of bestAcct
                    if acctAddrs is not missing value and (count of acctAddrs) > 0 then
                        repeat with a in acctAddrs
                            if (a as text) is in origRcpts then
                                set senderAddr to (a as text)
                                exit repeat
                            end if
                        end repeat
                        if senderAddr is "" then set senderAddr to ((item 1 of acctAddrs) as text)
                        if senderAddr is not "" then set sender of newReply to senderAddr
                    else
                        set warnings to warnings & "Could not determine the receiving account's send address; the reply uses Mail's default From — verify it before sending. "
                    end if
                on error errMsg
                    -- Setting the From to the receiving identity failed (often an
                    -- alias that isn't a configured send-from address). Don't let
                    -- the reply go out from the wrong account unannounced.
                    set warnings to warnings & "Could not set the From account to the receiving identity (" & errMsg & "); verify the From field before sending. "
                end try
                activate
                if warnings is not "" then return "REPLY_OPENED ||WARN|| " & warnings
                return "REPLY_OPENED"
            end tell
        end timeout
    """)
    guard let status = result?.stringValue else {
        fputs("Failed to open reply window.\n", stderr)
        exit(1)
    }
    if status.hasPrefix("SEARCH_ERROR:") {
        let detail = String(status.dropFirst("SEARCH_ERROR:".count)).trimmingCharacters(in: .whitespaces)
        fputs("Could not search every mailbox for message id \(messageId): \(detail)\n", stderr)
        fputs("The message may live in a mailbox that is offline or mid-sync — check the account is online and try again.\n", stderr)
        exit(1)
    }
    if status == "MID_NOT_FOUND" {
        fputs("Message with id \(messageId) not found in any mailbox.\n", stderr)
        exit(1)
    }
    if status.hasPrefix("REPLY_OPENED") {
        // The reply opened, but the script may have appended non-fatal warnings
        // (after a "||WARN||" marker) about a possibly-wrong From account — the
        // window stays open for review, so surface them rather than letting a
        // silently mis-addressed reply slip past.
        if let r = status.range(of: "||WARN||") {
            let warn = String(status[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !warn.isEmpty { fputs("Warning: \(warn)\n", stderr) }
        }
        return
    }
    fputs("Unexpected reply status: \(status)\n", stderr)
    exit(1)
}

// Bounded poll: true as soon as Mail has more windows than before, else false
// after timeout — reacting the moment the window exists rather than waiting a
// fixed interval. Errored polls (nil) are treated as "unknown" and skipped, so
// a transient System Events failure can never be read as a new window.
func waitForNewComposeWindow(afterCount: Int, timeout: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let count = mailComposeWindowCount(), count > afterCount { return true }
        usleep(200_000) // poll every 200ms
    }
    return false
}

// Post ⌘V via CGEvent; fall back to System Events keystroke. Returns whether
// the keystroke was dispatched (not whether text actually landed).
func sendCommandV() -> Bool {
    let kVK_ANSI_V: CGKeyCode = 0x09
    if let source = CGEventSource(stateID: .combinedSessionState),
       let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false) {
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(20_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
    // Fallback: System Events keystroke (also requires the Accessibility grant).
    let result = runScript("""
        with timeout of 10 seconds
            tell application "System Events"
                keystroke "v" using command down
            end tell
        end timeout
    """)
    return result != nil
}

func replyMessage(messageId: String, markdownBody: String, replyAll: Bool) {
    ensureAccessibilityOrExit()                       // fail fast if no AX grant
    let rtfData = makeRTF(fromMarkdown: markdownBody) // parse markdown → RTF (may exit)

    // Window count BEFORE reply. nil means System Events couldn't be reached —
    // almost always a missing Automation grant — so surface that precisely
    // instead of letting it later masquerade as "window never appeared".
    guard let beforeCount = mailComposeWindowCount() else {
        fputs("""
        Could not query Mail's windows via System Events. Nothing was pasted.

        mail-bridge needs Automation access to System Events to detect when the
        reply window opens. Grant it in:
          System Settings → Privacy & Security → Automation → mail-bridge → enable "System Events"

        Then re-run the same command.
        """, stderr)
        exit(1)
    }
    openReplyWindow(messageId: messageId, replyAll: replyAll) // may exit: MID_NOT_FOUND

    guard waitForNewComposeWindow(afterCount: beforeCount, timeout: 10.0) else {
        fputs("Reply window did not appear within 10s. Nothing was pasted.\n", stderr)
        exit(1)
    }

    // Window exists. Only now do we touch the clipboard.
    let snapshot = ClipboardSnapshot.capture()
    guard writeRTFToPasteboard(rtfData, plainTextFallback: markdownBody) else {
        snapshot.restore()
        fputs("Failed to place the formatted reply on the clipboard. The reply window is open, but nothing was pasted.\n", stderr)
        exit(1)
    }
    usleep(200_000) // settle — let the GUI focus the body field before ⌘V
    let pasted = sendCommandV()

    if pasted {
        usleep(250_000)    // let the paste land before mutating the clipboard
        snapshot.restore()
        // sendCommandV only confirms the keystroke was dispatched, not that it
        // landed in the body field — so guide the user to verify rather than
        // asserting the paste succeeded.
        print("Reply window opened in Mail and the formatted text was pasted in — review the body and send manually. (If the body looks empty, the paste missed; re-run this command.)")
    } else {
        // Skip restore: leave the formatted text on the clipboard for manual ⌘V.
        fputs("Reply window opened, but automatic paste failed. The formatted reply is on your clipboard — click the body and press Cmd-V, then review and send.\n", stderr)
        exit(1)
    }
}

func deleteMessage(index: Int, mailbox: String, account: String, force: Bool) {
    if !force {
        print("Dry-run: would move message #\(index) in '\(mailbox)' to Trash. Use --force to actually delete.")
        exit(0)
    }
    let accountClause = account.isEmpty
        ? "item 1 of accounts"
        : "account \"\(escapeForAppleScript(account))\""
    let result = runScript("""
        tell application "Mail"
            set acc to \(accountClause)
            set msgs to messages of mailbox "\(escapeForAppleScript(mailbox))" of acc
            set msgCount to count of msgs
            if \(index) < 1 or \(index) > msgCount then
                return "INDEX_OUT_OF_RANGE"
            end if
            delete item \(index) of msgs
            return "OK"
        end tell
    """)
    let status = result?.stringValue
    if status == "INDEX_OUT_OF_RANGE" {
        fputs("Message index \(index) is out of range.\n", stderr)
        exit(1)
    } else if status == "OK" {
        print("Moved message #\(index) to Trash.")
    } else {
        fputs("Failed to delete message.\n", stderr)
        exit(1)
    }
}

// MARK: - Main

let args = CommandLine.arguments

guard args.count >= 2 else {
    print("Usage:")
    print("  mail-bridge accounts")
    print("  mail-bridge mailboxes [account]")
    print("  mail-bridge list [mailbox] [account] [count]")
    print("  mail-bridge unread [mailbox] [account] [--all] [--max N] [--since <Nd|YYYY-MM-DD>]")
    print("  mail-bridge search <query> [max_results] [account] [--unread] [--since <Nd|YYYY-MM-DD>] [--max N]")
    print("  mail-bridge read <index> [mailbox] [account] [--mark-read] [--raw]")
    print("  mail-bridge read --mid <message-id> [account] [--mark-read] [--raw]")
    print("  mail-bridge send <to> <subject> <body> [/path/to/attachment ...] [--from <email>] [--html-file <path> | --md | --md-file <path>] [--force]")
    print("  mail-bridge reply --mid <message-id> [--body <md> | --body-file <path>] [--reply-all]   (or pipe md on stdin)")
    print("  mail-bridge delete <index> [mailbox] [account] [--force]")
    exit(0)
}

let command = args[1]
let defaultMailbox = "INBOX"

// Get all account names for smart argument detection
func getAccountNames() -> [String] {
    let result = runScript("""
        tell application "Mail"
            set out to {}
            repeat with acc in accounts
                set end of out to name of acc
            end repeat
            return out
        end tell
    """)
    return descriptorToStrings(result)
}

let accountNames = getAccountNames()

// Check if a string is an account name (not a mailbox)
func isAccountName(_ name: String) -> Bool {
    let normalized = normalizeQuotes(in: name)
    return accountNames.contains(where: { normalizeQuotes(in: $0) == normalized })
}

switch command {

case "accounts":
    listAccounts()

case "mailboxes":
    let account = args.count >= 3 ? args[2] : ""
    listMailboxes(account: account)

case "list":
    var mailbox = defaultMailbox
    var account = ""
    var count = 20
    if args.count >= 3 {
        if let num = Int(args[2]) {
            // list <count>
            count = num
        } else if isAccountName(args[2]) {
            // list <account> [count]
            account = args[2]
            count = args.count >= 4 ? (Int(args[3]) ?? 20) : 20
        } else {
            // list <mailbox> [count | account] [count]
            mailbox = args[2]
            if args.count >= 4 {
                if let num = Int(args[3]) {
                    count = num
                } else if isAccountName(args[3]) {
                    account = args[3]
                    count = args.count >= 5 ? (Int(args[4]) ?? 20) : 20
                }
            }
        }
    }
    listMessages(mailbox: mailbox, account: account, count: count)

case "unread":
    var mailbox = defaultMailbox
    var account = ""
    var unreadMax = 50
    var unreadSinceDays = 0
    var allAccounts = false
    // Parse flags and strip them so positional detection below still works.
    var unreadPositional: [String] = []
    var i = 2
    while i < args.count {
        let a = args[i]
        switch a {
        case "--all":
            allAccounts = true
            i += 1
        case "--max":
            if i + 1 < args.count, let n = Int(args[i + 1]) { unreadMax = n }
            i += 2
        case "--since":
            if i + 1 < args.count { unreadSinceDays = parseDaysArg(args[i + 1]) }
            i += 2
        default:
            unreadPositional.append(a)
            i += 1
        }
    }
    if let first = unreadPositional.first {
        if isAccountName(first) {
            account = first
        } else {
            mailbox = first
            if unreadPositional.count >= 2 { account = unreadPositional[1] }
        }
    }
    listUnread(mailbox: mailbox, account: account, maxResults: unreadMax, sinceDays: unreadSinceDays, allAccounts: allAccounts)

case "search":
    guard args.count >= 3 else {
        fputs("Usage: mail-bridge search <query> [max_results] [account] [--unread] [--since <Nd|YYYY-MM-DD>]\n", stderr)
        exit(1)
    }
    var searchAccount = ""
    var searchMax = 50
    var searchUnread = false
    var searchSinceDays = 0
    // Parse flags first, then treat the remaining positional args as before.
    var searchPositional: [String] = [args[2]]
    var j = 3
    while j < args.count {
        let a = args[j]
        switch a {
        case "--unread":
            searchUnread = true
            j += 1
        case "--max":
            if j + 1 < args.count, let n = Int(args[j + 1]) { searchMax = n }
            j += 2
        case "--since":
            if j + 1 < args.count { searchSinceDays = parseDaysArg(args[j + 1]) }
            j += 2
        default:
            searchPositional.append(a)
            j += 1
        }
    }
    // Legacy positional form: search <query> [max_results] [account]
    if searchPositional.count >= 2 {
        if let num = Int(searchPositional[1]) {
            searchMax = num
            if searchPositional.count >= 3 { searchAccount = searchPositional[2] }
        } else if isAccountName(searchPositional[1]) {
            searchAccount = searchPositional[1]
        }
    }
    searchMessages(query: searchPositional[0], account: searchAccount, maxResults: searchMax, onlyUnread: searchUnread, sinceDays: searchSinceDays)

case "read":
    let markRead = args.contains("--mark-read")
    let raw = args.contains("--raw")
    // --mid <message-id>: lookup directly via RFC822 message-id (from `search` output)
    if let midIdx = args.firstIndex(of: "--mid"), midIdx + 1 < args.count {
        let mid = args[midIdx + 1]
        // optional account positional: any arg after args[1]="read" that isn't a known flag/value
        var midAccount = ""
        let skipNext = ["--mid"]
        var i = 2
        while i < args.count {
            let a = args[i]
            if skipNext.contains(a) { i += 2; continue }
            if a == "--mark-read" || a == "--raw" { i += 1; continue }
            midAccount = a
            break
        }
        readMessageByMid(messageId: mid, account: midAccount, markRead: markRead, raw: raw)
        break
    }
    guard args.count >= 3, let index = Int(args[2]) else {
        fputs("Usage: mail-bridge read <index> [mailbox] [account] [--mark-read] [--raw]\n", stderr)
        fputs("       mail-bridge read --mid <message-id> [account] [--mark-read] [--raw]\n", stderr)
        exit(1)
    }
    let readArgs = args.filter { $0 != "--mark-read" && $0 != "--raw" }
    let mailbox = readArgs.count >= 4 ? readArgs[3] : defaultMailbox
    let account = readArgs.count >= 5 ? readArgs[4] : ""
    readMessage(index: index, mailbox: mailbox, account: account, markRead: markRead, raw: raw)

case "send":
    let force = args.contains("--force")
    var fromEmail = ""
    if let fromIdx = args.firstIndex(of: "--from"), fromIdx + 1 < args.count {
        fromEmail = args[fromIdx + 1]
    }
    var htmlFilePath = ""
    if let htmlIdx = args.firstIndex(of: "--html-file"), htmlIdx + 1 < args.count {
        htmlFilePath = args[htmlIdx + 1]
    }
    // Markdown → HTML, delivered directly as Mail `html content` (no copy-paste,
    // works headless with --force). --md treats the positional body as markdown;
    // --md-file reads markdown from a file. Either takes precedence over plain
    // body; the converted HTML is staged in a temp file reusing the html path.
    var mdFilePath = ""
    var markdownSource: String? = nil
    if let mdIdx = args.firstIndex(of: "--md-file"), mdIdx + 1 < args.count {
        mdFilePath = args[mdIdx + 1]
        guard let contents = try? String(contentsOfFile: mdFilePath, encoding: .utf8) else {
            fputs("Markdown file not found or unreadable: \(mdFilePath)\n", stderr)
            exit(1)
        }
        markdownSource = contents
    } else if args.contains("--md") {
        // Positional body is markdown — but only if it's actually present and
        // not itself a flag (e.g. `send to subj --md` has no body at args[4]).
        markdownSource = (args.count >= 5 && !args[4].hasPrefix("--")) ? args[4] : ""
    }
    var tempHTMLPath = ""
    if let md = markdownSource {
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("No markdown body provided. Use --md with a body, or --md-file <path>.\n", stderr)
            exit(1)
        }
        tempHTMLPath = NSTemporaryDirectory() + "mail-bridge-send-\(ProcessInfo.processInfo.globallyUniqueString).html"
        do {
            try markdownToHTML(md).write(toFile: tempHTMLPath, atomically: true, encoding: .utf8)
        } catch {
            fputs("Failed to prepare HTML body: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        htmlFilePath = tempHTMLPath
        // sendMessage() calls exit() on its error paths, which bypasses defer —
        // so register the cleanup with atexit_b to remove the staged HTML body
        // (the email content) on every exit path, success or failure.
        let cleanupPath = tempHTMLPath
        atexit_b { try? FileManager.default.removeItem(atPath: cleanupPath) }
    }
    // With --html-file / --md / --md-file, body is optional (only to/subject required)
    let minArgs = htmlFilePath.isEmpty ? 5 : 4
    guard args.count >= minArgs else {
        fputs("Usage: mail-bridge send <to> <subject> [body] [/path/to/attachment ...] [--from <email>] [--html-file <path> | --md | --md-file <path>] [--force]\n", stderr)
        exit(1)
    }
    let body = args.count >= 5 ? args[4] : ""
    let flagArgs = Set(["--force", "--from", fromEmail, "--html-file", htmlFilePath, "--md", "--md-file", mdFilePath].filter { !$0.isEmpty })
    // Alle positionalen Args nach to/subject/body sind Attachment-Pfade
    // (mehrere möglich, z.B. `send to subj body f1.pdf f2.pdf f3.pdf --force`).
    let positional = args.dropFirst(min(5, args.count)).filter { !flagArgs.contains($0) }
    let attachmentPaths = Array(positional)
    sendMessage(to: args[2], subject: args[3], body: body, attachmentPaths: attachmentPaths, fromEmail: fromEmail, force: force, htmlFilePath: htmlFilePath)
    // Temp HTML body (if any) is removed by the atexit_b handler registered above,
    // which also covers sendMessage's exit() error paths.

case "reply":
    guard let midIdx = args.firstIndex(of: "--mid"), midIdx + 1 < args.count else {
        fputs("Usage: mail-bridge reply --mid <message-id> [--body <markdown> | --body-file <path>] [--reply-all]\n", stderr)
        fputs("       (body may also be piped on stdin)\n", stderr)
        exit(1)
    }
    let replyMid = args[midIdx + 1]
    let replyAll = args.contains("--reply-all")
    // Body precedence: --body > --body-file > stdin.
    var replyBody: String? = nil
    if let bIdx = args.firstIndex(of: "--body"), bIdx + 1 < args.count {
        replyBody = args[bIdx + 1]
    } else if let fIdx = args.firstIndex(of: "--body-file"), fIdx + 1 < args.count {
        let path = args[fIdx + 1]
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("Body file not found or unreadable: \(path)\n", stderr)
            exit(1)
        }
        replyBody = contents
    } else if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
        // Body piped on stdin (only when stdin is NOT a terminal, else we'd block).
        let data = FileHandle.standardInput.readDataToEndOfFile()
        replyBody = String(data: data, encoding: .utf8)
    }
    let replyText = (replyBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !replyText.isEmpty else {
        fputs("No reply body provided. Use --body, --body-file, or pipe markdown on stdin.\n", stderr)
        exit(1)
    }
    replyMessage(messageId: replyMid, markdownBody: replyText, replyAll: replyAll)

case "delete":
    guard args.count >= 3, let index = Int(args[2]) else {
        fputs("Usage: mail-bridge delete <index> [mailbox] [account] [--force]\n", stderr)
        exit(1)
    }
    let force = args.contains("--force")
    let filteredArgs = args.filter { $0 != "--force" }
    let mailbox = filteredArgs.count >= 4 ? filteredArgs[3] : defaultMailbox
    let account = filteredArgs.count >= 5 ? filteredArgs[4] : ""
    deleteMessage(index: index, mailbox: mailbox, account: account, force: force)

default:
    fputs("Unknown command: \(command)\n", stderr)
    exit(1)
}
