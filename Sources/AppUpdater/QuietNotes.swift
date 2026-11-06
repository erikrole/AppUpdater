import AppKit

/// Boils a GitHub release body down to the two to five lines the "What's new" popover can hold.
enum QuietNotes {
    static let limit = 5

    /// Top-level bullets and numbered steps first; plain paragraphs only when the notes have none. Headings are dropped.
    static func lines(from markdown: String) -> [String] {
        let sections = ReleaseNotesSections(markdown: markdown)
        let items = sections.sections.flatMap(\.items)
        let listed = items.filter { item in
            switch item.kind { case .bullet, .number: item.level == 0
            case .paragraph, .code: false }
        }
        let chosen = listed.isEmpty ? items.filter { $0.kind == .paragraph } : listed
        return Array(chosen.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(limit))
    }

    static func hasBullets(_ markdown: String) -> Bool { !lines(from: markdown).isEmpty }

    @MainActor
    static func bullets(from markdown: String) -> [NSAttributedString] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        return lines(from: markdown).map {
            ReleaseNotesRenderer.inline($0, font: .systemFont(ofSize: 12), color: .labelColor, style: style)
        }
    }
}
