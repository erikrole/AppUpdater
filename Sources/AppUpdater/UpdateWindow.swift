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
    private unowned let updater: AppUpdater
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton()
    private let laterButton = NSButton()
    private let skipButton = NSButton()
    private var working = false

    init(mode: Mode, updater: AppUpdater) {
        self.mode = mode
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func bringToFront() { show() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !working }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let release = mode.release
        let name = updater.configuration.displayName
        let isUpdated: Bool
        if case .updated = mode { isUpdated = true } else { isUpdated = false }

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.state = .active

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let kicker = NSTextField(labelWithString: isUpdated ? "UPDATED" : "UPDATE AVAILABLE")
        kicker.font = .systemFont(ofSize: 11, weight: .semibold)
        kicker.textColor = .controlAccentColor
        let title = NSTextField(labelWithString: isUpdated ? "\(name) is now \(release.version)." : "\(name) \(release.version) is ready.")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        let subtitle = NSTextField(labelWithString: subtitleText(isUpdated: isUpdated))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let headline = NSStackView(views: [kicker, title, subtitle])
        headline.orientation = .vertical
        headline.alignment = .leading
        headline.spacing = 4
        let header = NSStackView(views: [icon, headline])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        let notesHeading = NSTextField(labelWithString: "What's new")
        notesHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let notes = notesView(release)

        configure(updateButton, title: isUpdated ? "Continue" : "Update and Relaunch", action: #selector(updateTapped), primary: true)
        configure(laterButton, title: "Later", action: #selector(laterTapped))
        configure(skipButton, title: "Skip This Version", action: #selector(skipTapped))
        skipButton.isBordered = false
        skipButton.contentTintColor = .secondaryLabelColor
        laterButton.keyEquivalent = "\u{1b}"

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true

        let spacer = NSView()
        let buttons = NSStackView(views: isUpdated ? [spacer, updateButton] : [skipButton, spacer, laterButton, updateButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, notesHeading, notes, progress, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(20, after: header)
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
        ])
        return background
    }

    private func subtitleText(isUpdated: Bool) -> String {
        let release = mode.release
        var parts: [String] = []
        if !isUpdated { parts.append("You have \(updater.configuration.currentVersion).") }
        if let date = release.date { parts.append("Released \(date.formatted(date: .long, time: .omitted)).") }
        if !isUpdated { parts.append("Updating takes a moment and \(updater.configuration.displayName) relaunches by itself.") }
        return parts.joined(separator: " ")
    }

    private func notesView(_ release: ReleaseInfo) -> NSView {
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        if release.notes.isEmpty {
            text.textStorage?.setAttributedString(NSAttributedString(
                string: "Improvements and fixes.",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        } else {
            text.textStorage?.setAttributedString(ReleaseNotesRenderer.render(release.notes))
        }
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return scroll
    }

    private func configure(_ button: NSButton, title: String, action: Selector, primary: Bool = false) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        if primary { button.keyEquivalent = "\r" }
    }

    // MARK: - Actions

    @objc private func laterTapped() { window?.close() }

    @objc private func skipTapped() {
        updater.skip(mode.release)
        window?.close()
    }

    @objc private func updateTapped() {
        if case .updated = mode { window?.close(); return }
        guard !working else { return }
        setWorking(true, status: "Downloading…")
        let release = mode.release
        Task {
            do {
                try await updater.install(
                    release,
                    progress: { fraction in
                        self.progress.doubleValue = fraction
                        self.statusLabel.stringValue = "Downloading… \(Int(fraction * 100))%"
                    },
                    status: { text in
                        self.progress.isIndeterminate = true
                        self.progress.startAnimation(nil)
                        self.statusLabel.stringValue = text
                    }
                )
            } catch {
                setWorking(false, status: error.localizedDescription)
                statusLabel.textColor = .systemOrange
                updateButton.title = "Try Again"
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
        laterButton.isEnabled = !value
        skipButton.isEnabled = !value
    }
}
