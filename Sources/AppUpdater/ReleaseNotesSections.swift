import Foundation

/// A release body split into a headline and titled sections of bullets, numbered steps, paragraphs and code,
/// ready for layout.
struct ReleaseNotesSections: Equatable {
    struct Item: Equatable, ExpressibleByStringLiteral {
        enum Kind: Equatable { case paragraph, bullet, number(String), code }
        var text: String
        var kind: Kind = .bullet
        /// 0 for top level; nested lists indent two spaces (or a tab) per level, up to 2.
        var level = 0

        init(_ text: String, kind: Kind = .bullet, level: Int = 0) {
            self.text = text
            self.kind = kind
            self.level = level
        }
        init(stringLiteral value: String) { self.init(value) }
    }

    struct Section: Equatable {
        var title: String?
        var items: [Item]
    }

    var headline: String?
    var sections: [Section]

    init(markdown: String) {
        var headline: String?
        var sections: [Section] = []
        var current = Section(title: nil, items: [])
        var codeLines: [String]?

        func flush() {
            if current.title != nil || !current.items.isEmpty { sections.append(current) }
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    current.items.append(Item(lines.joined(separator: "\n"), kind: .code))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil { codeLines?.append(line); continue }
            if trimmed.isEmpty { continue }
            if let title = ReleaseNotesRenderer.headingText(trimmed) {
                // The first heading, when nothing precedes it, is the release headline.
                if headline == nil, sections.isEmpty, current.items.isEmpty, current.title == nil {
                    headline = title
                } else {
                    flush()
                    current = Section(title: title, items: [])
                }
                continue
            }
            let level = min(2, Self.indentWidth(line) / 2)
            if let bullet = Self.bulletText(trimmed) {
                current.items.append(Item(bullet, kind: .bullet, level: level))
            } else if let (number, text) = Self.numbered(trimmed) {
                current.items.append(Item(text, kind: .number(number), level: level))
            } else {
                current.items.append(Item(trimmed, kind: .paragraph))
            }
        }
        if let lines = codeLines { current.items.append(Item(lines.joined(separator: "\n"), kind: .code)) }
        flush()
        self.headline = headline
        self.sections = sections
    }

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 2 } else { break }
        }
        return width
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return String(line.dropFirst(2)) }
        return nil
    }

    private static func numbered(_ line: String) -> (String, String)? {
        guard let match = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) else { return nil }
        let marker = line[match].trimmingCharacters(in: .whitespaces)
        return (marker, String(line[match.upperBound...]))
    }
}
