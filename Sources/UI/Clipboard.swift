import AppKit

enum Clipboard {
    /// Replaces the pasteboard's contents with `text`; empty text changes nothing.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
