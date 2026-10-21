import AppKit

/// The splash: app icon, the version change, the release notes, and one button to update.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    enum Mode {
        case available(ReleaseInfo)
        /// Shown once after an update, with what changed.
        case updated(ReleaseInfo)

        var release: ReleaseInfo {
            switch self { case let .available(release), let .updated(release): release }
        }
    }

    var onClose: (() -> Void)?
    private let mode: Mode
    private let updater: AppUpdater
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let updateButton = FilledButton()
    private let laterButton = NSButton()
    private let skipButton = NSButton()
    private var working = false
    private var installing = false
    private var installTask: Task<Void, Never>?
    private let viewButton = NSButton()

    init(mode: Mode, updater: AppUpdater) {
        self.mode = mode
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UpdateWindowController.windowWidth, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
                super.init(window: window)
        window.delegate = self
        let content = buildContent()
        window.contentView = content
        content.widthAnchor.constraint(equalToConstant: Self.windowWidth).isActive = true
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.windowWidth, height: max(content.fittingSize.height, 380)))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func bringToFront() { show() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A download can be abandoned by closing; once the new app is being put in place, wait.
        if working, !installing { installTask?.cancel(); return false }
        return !installing
    }

    override func cancelOperation(_ sender: Any?) { laterTapped() }

    // MARK: - Layout

    private var style: AppUpdater.Style { updater.configuration.style }
    private var accent: NSColor { style.accentColor ?? .controlAccentColor }

    private func buildContent() -> NSView {
        let release = mode.release
        let name = updater.configuration.displayName
        let isUpdated: Bool
        if case .updated = mode { isUpdated = true } else { isUpdated = false }

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.state = .active

        let icon = NSImageView(image: style.icon ?? NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        icon.setAccessibilityLabel("\(name) icon")

        let kicker = NSTextField(labelWithString: isUpdated ? "UPDATED" : "UPDATE AVAILABLE")
        kicker.font = .systemFont(ofSize: 11, weight: .semibold)
        kicker.textColor = style.kickerColor ?? accent
        let defaultTitle = isUpdated ? "\(name) is now \(release.version)." : "\(name) \(release.version) is ready."
        let title = NSTextField(wrappingLabelWithString: style.title?(release, isUpdated) ?? defaultTitle)
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.maximumNumberOfLines = 2
        let subtitle = NSTextField(wrappingLabelWithString: subtitleText(isUpdated: isUpdated))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let headline = NSStackView(views: [kicker, title, subtitle])
        headline.orientation = .vertical
        headline.alignment = .leading
        headline.spacing = 3
        let header = NSStackView(views: [icon, headline])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        let notes = notesView(for: release)

        configure(updateButton, title: style.primaryButtonTitle ?? (isUpdated ? "Continue" : "Update and Relaunch"), action: #selector(updateTapped), primary: true)
        configure(laterButton, title: "Later", action: #selector(laterTapped))
        configure(skipButton, title: "Skip This Version", action: #selector(skipTapped))
        for quiet in [laterButton, skipButton, viewButton] {
            quiet.isBordered = false
            quiet.contentTintColor = .secondaryLabelColor
            quiet.controlSize = .regular
            quiet.font = .systemFont(ofSize: 13)
        }
        laterButton.keyEquivalent = "\u{1b}"
        for single in [skipButton, laterButton, updateButton, viewButton] {
            // Buttons never wrap or shrink: the row sizes to fit them.
            single.lineBreakMode = .byClipping
            (single.cell as? NSButtonCell)?.wraps = false
            single.setContentCompressionResistancePriority(.required, for: .horizontal)
            single.setContentHuggingPriority(.required, for: .horizontal)
        }
        configure(viewButton, title: "View on GitHub", action: #selector(viewTapped))
        viewButton.isBordered = false
        viewButton.contentTintColor = .secondaryLabelColor
        viewButton.font = .systemFont(ofSize: 13)
        viewButton.isHidden = release.pageURL == nil
        updateButton.setAccessibilityLabel(updateButton.title)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityLabel("Update progress")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true
        statusLabel.setAccessibilityRole(.staticText)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: isUpdated ? [spacer, updateButton] : [skipButton, spacer, laterButton, updateButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12

        let stack = NSStackView(views: [header, notes, progress, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(20, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -24),
            notes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])
        return background
    }

    private func subtitleText(isUpdated: Bool) -> String {
        let release = mode.release
        var parts: [String] = []
        if !isUpdated { parts.append("You have \(updater.configuration.currentVersion).") }
        if let date = release.date { parts.append("Released \(date.formatted(date: .long, time: .omitted)).") }
        if !isUpdated { parts.append("It installs in a moment and \(updater.configuration.displayName) reopens by itself.") }
        return parts.joined(separator: " ")
    }

    /// Version header, then each section of the release notes as a titled list, in a scrolling card.
    /// Window 500, 28 margins, 1pt card border, 16 padding each side.
    static let windowWidth: CGFloat = 500
    static let notesTextWidth: CGFloat = windowWidth - 56 - 32

    private func wrap(_ label: NSTextField, width: CGFloat) {
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.preferredMaxLayoutWidth = width
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func notesView(for release: ReleaseInfo) -> NSView {
        let parsed = ReleaseNotesSections(markdown: updater.resolvedNotes(for: release))

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false

        // The title already names the version, so the card's top row only carries the link to the release page.
        let linkSpacer = NSView()
        linkSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        viewButton.translatesAutoresizingMaskIntoConstraints = false
        viewButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let versionRow = NSStackView(views: [linkSpacer, viewButton])
        versionRow.orientation = .horizontal
        versionRow.alignment = .centerY
        content.addArrangedSubview(versionRow)
        versionRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        if let headline = parsed.headline {
            let label = NSTextField(wrappingLabelWithString: headline)
            label.font = .systemFont(ofSize: 16, weight: .semibold)
            wrap(label, width: Self.notesTextWidth)
            content.addArrangedSubview(label)
            content.setCustomSpacing(12, after: label)
            label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        } else {
            content.setCustomSpacing(4, after: versionRow)
        }

        for section in parsed.sections {
            if let title = section.title {
                let label = NSTextField(wrappingLabelWithString: title)
                wrap(label, width: Self.notesTextWidth)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .secondaryLabelColor
                if let last = content.arrangedSubviews.last { content.setCustomSpacing(14, after: last) }
                content.addArrangedSubview(label)
            }
            for item in section.items {
                let row = noteRow(item)
                content.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Release notes for version \(release.version)")
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            card.heightAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        // Fit the notes when they are short; scroll when they are long.
        let natural = card.heightAnchor.constraint(equalTo: document.heightAnchor)
        natural.priority = .defaultHigh
        natural.isActive = true
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        return card
    }

    private func noteRow(_ item: ReleaseNotesSections.Item) -> NSView {
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let text = NSTextField(wrappingLabelWithString: "")
        if item.kind == .code {
            text.attributedStringValue = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor,
            ])
            text.isSelectable = true
            text.maximumNumberOfLines = 0
            text.preferredMaxLayoutWidth = Self.notesTextWidth - 16
            text.lineBreakMode = .byWordWrapping
            text.cell?.wraps = true
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.required, for: .vertical)
            let box = CodeBox()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                text.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
                text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
                text.widthAnchor.constraint(equalToConstant: Self.notesTextWidth - 16),
            ])
            return box
        }
        text.attributedStringValue = ReleaseNotesRenderer.inline(item.text, font: font, color: .labelColor, style: paragraph)
        text.isSelectable = true
        text.allowsEditingTextAttributes = true
        let indent = CGFloat(item.level) * 18
        if item.kind == .paragraph {
            wrap(text, width: Self.notesTextWidth)
            return text
        }
        let markerColumn: CGFloat = { if case .number = item.kind { 22 } else { 6 } }()
        wrap(text, width: Self.notesTextWidth - indent - markerColumn - 10)

        // Plain constraints, not a nested stack: the row's height is exactly the wrapped text's height.
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let marker: NSView
        let markerWidth: CGFloat
        let markerTop: CGFloat
        switch item.kind {
        case let .number(number):
            let label = NSTextField(labelWithString: number)
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            label.textColor = accent
            label.alignment = .left
            marker = label
            markerWidth = 22
            markerTop = 0
        default:
            marker = DotView(color: item.level == 0 ? accent : accent.withAlphaComponent(0.55))
            markerWidth = 6
            markerTop = 7
        }
        marker.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(marker)
        row.addSubview(text)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            marker.topAnchor.constraint(equalTo: row.topAnchor, constant: markerTop),
            marker.widthAnchor.constraint(equalToConstant: markerWidth),
            marker.heightAnchor.constraint(equalToConstant: marker is DotView ? 6 : 16),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent + markerWidth + 10),
            text.topAnchor.constraint(equalTo: row.topAnchor),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
        ])
        return row
    }

    private func configure(_ button: NSButton, title: String, action: Selector, primary: Bool = false) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        if primary {
            button.keyEquivalent = "\r"
            // A filled accent pill that looks the same whether or not the window is key.
            button.isBordered = false
            (button as? FilledButton)?.fill = accent
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            button.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            )
        }
    }

    // MARK: - Actions

    @objc private func laterTapped() {
        if working, installing, laterButton.title == "Don't Wait" {
            updater.cancelPendingQuit()
            installing = false
            setWorking(false, status: "Update stopped. \(updater.configuration.displayName) was not changed.")
            return
        }
        if working { if !installing { installTask?.cancel() }; return }
        window?.close()
    }

    @objc private func viewTapped() {
        if let url = mode.release.pageURL { NSWorkspace.shared.open(url) }
    }

    @objc private func skipTapped() {
        updater.skip(mode.release)
        window?.close()
    }

    @objc private func updateTapped() {
        if case .updated = mode { window?.close(); return }
        guard !working else { return }
        setWorking(true, status: "Downloading…")
        let release = mode.release
        installTask = Task {
            do {
                try await updater.install(
                    release,
                    progress: { fraction in
                        guard fraction >= self.progress.doubleValue else { return }
                        self.progress.doubleValue = fraction
                        self.statusLabel.stringValue = "Downloading… \(Int(fraction * 100))%"
                    },
                    status: { text in
                        self.installing = true
                        self.laterButton.isEnabled = false
                        self.progress.isIndeterminate = true
                        self.progress.startAnimation(nil)
                        self.statusLabel.stringValue = text
                    },
                    quitPending: {
                        // The app is still open: let the person stop waiting instead of leaving the splash stuck.
                        self.laterButton.title = "Don't Wait"
                        self.laterButton.isEnabled = true
                    }
                )
            } catch is CancellationError {
                setWorking(false, status: "")
                statusLabel.isHidden = true
            } catch {
                installing = false
                setWorking(false, status: error.localizedDescription)
                statusLabel.textColor = .systemOrange
                updateButton.attributedTitle = NSAttributedString(string: "Try Again", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            }
        }
    }

    private func setWorking(_ value: Bool, status: String) {
        working = value
        progress.isHidden = !value
        progress.isIndeterminate = false
        progress.stopAnimation(nil)
        progress.doubleValue = 0
        statusLabel.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = status
        updateButton.isEnabled = !value
        laterButton.isEnabled = true
        laterButton.title = value ? "Cancel" : "Later"
        skipButton.isEnabled = !value
        viewButton.isEnabled = !value
    }
}

/// A top-left-origin container, so scrolled content starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A filled pill in the accent colour that re-resolves when the appearance changes.
private final class FilledButton: NSButton {
    var fill: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        wantsLayer = true
        layer?.cornerRadius = 9
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isEnabled ? fill : fill.withAlphaComponent(0.45)).cgColor
        }
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
}

private final class DotView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// The notes card: rounded, bordered, and clipped, with colours that follow light and dark.
private final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        }
    }
}

/// A tinted rounded box for code in the notes; the tint follows light and dark.
private final class CodeBox: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    }
}
