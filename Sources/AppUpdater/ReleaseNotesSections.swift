import Foundation

/// A release body split into a headline and titled sections of bullet points, ready for layout.
struct ReleaseNotesSections: Equatable {
    struct Section: Equatable {
        var title: String?
        var items: [String]
        var isBullets: Bool
    }

    var headline: String?
    var sections: [Section]

    init(markdown: String) {
        var headline: String?
        var sections: [Section] = []
        var current = Section(title: nil, items: [], isBullets: true)

        func flush() {
            if current.title != nil || !current.items.isEmpty { sections.append(current) }
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let title = ReleaseNotesRenderer.headingText(line) {
                // The first heading, when nothing precedes it, is the release headline.
                if headline == nil, sections.isEmpty, current.items.isEmpty, current.title == nil {
                    headline = title
                } else {
                    flush()
                    current = Section(title: title, items: [], isBullets: true)
                }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                current.items.append(String(line.dropFirst(2)))
            } else {
                if current.items.isEmpty { current.isBullets = false }
                current.items.append(line)
            }
        }
        flush()
        self.headline = headline
        self.sections = sections
    }
}
