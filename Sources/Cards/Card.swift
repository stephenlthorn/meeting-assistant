import Foundation

/// An instant card: something the user already knows and wants in front of
/// them the moment the other side says a trigger phrase. Cards live on this
/// Mac and are never sent anywhere.
struct Card: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var triggers: [String]
    /// Short Markdown, shown as written (inline formatting only).
    var body: String
    var isEnabled: Bool

    init(id: String = UUID().uuidString, title: String, triggers: [String], body: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.triggers = triggers
        self.body = body
        self.isEnabled = isEnabled
    }
}
