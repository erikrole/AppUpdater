import AppKit

/// Turns the short Markdown a GitHub release body holds (headings, bullets, bold, code) into styled text.
enum ReleaseNotesRenderer {
    @MainActor
    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let textColor = NSColor.labelColor
        var previousBlank = true

        func paragraph(indent: CGFloat = 0, hanging: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 4) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineSpacing = 2
            return style
        }

        func append(_ line: String, font: NSFont, color: NSColor, style: NSParagraphStyle, prefix: String = "") {
            let attributed = NSMutableAttributedString(
                string: prefix, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
            )
            attributed.append(inline(line, font: font, color: color, style: style))
            attributed.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            result.append(attributed)
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { previousBlank = true; continue }
            if let heading = headingText(line) {
                append(heading, font: .systemFont(ofSize: 14, weight: .semibold), color: textColor,
                       style: paragraph(before: result.length == 0 ? 0 : 10, after: 4))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                append(String(line.dropFirst(2)), font: body, color: textColor,
                       style: paragraph(indent: 4, hanging: 14), prefix: "•  ")
            } else {
                append(line, font: body, color: previousBlank ? textColor : textColor,
                       style: paragraph(after: 6))
            }
            previousBlank = false
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Bold, italics, code and links inside one line.
    @MainActor
    private static func inline(_ text: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color, .paragraphStyle: style]
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}
