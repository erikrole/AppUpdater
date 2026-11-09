import AppKit

/// What the update button shows right now. Copy stays this short on purpose.
struct PillContent: Equatable {
    enum Indicator: Equatable { case spinner, dot, warning, check }
    var indicator: Indicator
    var text: String
    /// Replaces `text` while the pointer is over the button ("Installing v1.5.3").
    var hoverText: String?
    /// Whether clicking does anything. A spinner-only button ignores clicks.
    var clickable: Bool
    /// Whether hovering or clicking opens the release-notes popover.
    var opensNotes: Bool = false
}

/// What the "What's new" popover shows.
struct NotesPopoverContent {
    var version: String
    var bullets: [NSAttributedString]
    var pageURL: URL?
}

/// The update button: a small capsule in the trailing side of the host window's title bar, a dedicated spot that never
/// floats over content, never takes focus and stays put on resize. It is a title bar accessory, so hosts add no layout code.
/// Apps with no window (menu bar apps) show nothing here; they mirror `state` in their menu instead.
@MainActor
final class PillController: NSObject, NSPopoverDelegate {
    static let height: CGFloat = 22
    static let barHeight: CGFloat = 30
    static let trailingInset: CGFloat = 10

    var onClick: (() -> Void)?
    /// Asked for the popover's content when the button opens the notes. Return nil for nothing to show.
    var notesProvider: (() -> NotesPopoverContent?)?
    var onNotesOpened: (() -> Void)?
    var onNotesClosed: (() -> Void)?
    /// A view in the window to host the button (the deprecated `hostView`). Unset: the main, else key, else first titled window.
    var anchorView: () -> NSView? = { nil }
    var accent: () -> NSColor = { .controlAccentColor }

    private(set) var content: PillContent?
    private var accessory: NSTitlebarAccessoryViewController?
    private var pillView: PillView?
    private weak var hostWindow: NSWindow?
    private var hovering = false
    private var popover: NSPopover?
    private var hoverTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
    }

    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// Whether the button is installed in a window's title bar.
    var isVisible: Bool { accessory?.parent != nil && hostWindow?.isVisible == true }
    /// The window whose title bar holds the button.
    var buttonWindow: NSWindow? { accessory?.parent != nil ? hostWindow : nil }
    var isPopoverShown: Bool { popover?.isShown == true }
    var view: NSView? { pillView }

    // MARK: - Content

    func set(_ new: PillContent?) {
        guard new != content else { return }
        content = new
        guard let new else { hide(); return }
        hovering = false
        ensureAccessory()
        pillView?.apply(new, hovering: false, accent: accent())
        resize()
        reposition()
    }

    /// Re-reads the accent colour and window, for example after the host changed `hostView`.
    func refresh() {
        guard let content else { return }
        pillView?.apply(content, hovering: hovering, accent: accent())
        resize()
        reposition()
    }

    // MARK: - Title bar accessory

    private func ensureAccessory() {
        guard accessory == nil else { return }
        let view = PillView()
        view.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        view.onClick = { [weak self] in self?.clicked() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: Self.barHeight))
        container.addSubview(view)
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .trailing
        controller.view = container
        accessory = controller
        pillView = view
    }

    private func hide() {
        hoverTask?.cancel()
        popover?.close()
        detach()
        accessory = nil
        pillView = nil
    }

    private func detach() {
        if accessory?.parent != nil { accessory?.removeFromParent() }
        hostWindow = nil
    }

    private func resize() {
        guard let accessory, let pillView else { return }
        let size = pillView.fittingSize
        let width = size.width + Self.trailingInset * 2
        accessory.view.setFrameSize(NSSize(width: width, height: Self.barHeight))
        pillView.frame = NSRect(x: Self.trailingInset, y: (Self.barHeight - Self.height) / 2, width: size.width, height: Self.height)
    }

    private func targetWindow() -> NSWindow? {
        if let window = anchorView()?.window, window.styleMask.contains(.titled) { return window }
        let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        return NSApp.mainWindow.flatMap { main in windows.first { $0 === main } }
            ?? NSApp.keyWindow.flatMap { key in windows.first { $0 === key } }
            ?? windows.first
    }

    func reposition() {
        guard content != nil, let accessory else { return }
        guard let window = targetWindow() else {
            // Nothing to hang from (a menu bar app, or every window closed): the host's menu carries the state.
            if hostWindow?.isVisible != true { popover?.close(); detach() }
            return
        }
        if hostWindow === window, accessory.parent != nil { return }
        detach()
        window.addTitlebarAccessoryViewController(accessory)
        hostWindow = window
    }

    // MARK: - Interaction

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard let content else { return }
        pillView?.apply(content, hovering: inside, accent: accent())
        resize()
        hoverTask?.cancel()
        if content.opensNotes, inside, !isPopoverShown {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.showNotes()
            }
        }
    }

    private func clicked() {
        guard let content, content.clickable || content.opensNotes else { return }
        if content.opensNotes {
            if isPopoverShown { popover?.close() } else { showNotes() }
        } else {
            onClick?()
        }
    }

    func showNotes() {
        guard let pillView, pillView.window != nil, !isPopoverShown, let notes = notesProvider?() else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = NotesPopoverController(notes: notes)
        self.popover = popover
        popover.show(relativeTo: pillView.bounds, of: pillView, preferredEdge: .minY)
        onNotesOpened?()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            onNotesClosed?()
        }
    }
}

@MainActor
private final class NotesPopoverController: NSViewController {
    private let notes: NotesPopoverContent

    init(notes: NotesPopoverContent) {
        self.notes = notes
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 300
        let title = NSTextField(labelWithString: "What's new")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let version = NSTextField(labelWithString: "v\(notes.version)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, version])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .firstBaseline

        var rows: [NSView] = [header]
        for bullet in notes.bullets {
            let dot = NSTextField(labelWithString: "•")
            dot.font = .systemFont(ofSize: 12)
            dot.textColor = .secondaryLabelColor
            dot.setContentHuggingPriority(.required, for: .horizontal)
            let text = NSTextField(labelWithAttributedString: bullet)
            text.cell?.wraps = true
            text.maximumNumberOfLines = 4
            text.lineBreakMode = .byTruncatingTail
            text.preferredMaxLayoutWidth = width - 52
            text.isSelectable = true
            text.allowsEditingTextAttributes = true
            let row = NSStackView(views: [dot, text])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            rows.append(row)
        }
        if notes.pageURL != nil {
            let link = NSButton(title: "Full notes", target: self, action: #selector(openNotes))
            link.isBordered = false
            link.font = .systemFont(ofSize: 12)
            link.contentTintColor = .linkColor
            link.setAccessibilityLabel("Full notes on GitHub")
            rows.append(link)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width),
        ])
        view = root
    }

    @objc private func openNotes() {
        if let url = notes.pageURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        view.window?.close()
    }
}


/// The button itself: a quiet capsule tint, an indicator and one line of text.
@MainActor
final class PillView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let dot = DotIndicator()
    private var tracking: NSTrackingArea?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PillController.height / 2
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var hoverHighlight = false

    func apply(_ content: PillContent, hovering: Bool, accent: NSColor) {
        let text = (hovering ? content.hoverText : nil) ?? content.text
        label.stringValue = text
        setAccessibilityLabel(text)
        hoverHighlight = hovering && content.clickable
        spinner.stopAnimation(nil)
        let indicator: NSView
        switch content.indicator {
        case .spinner: indicator = spinner; spinner.startAnimation(nil)
        case .dot: dot.color = accent; indicator = dot
        case .warning: dot.color = .systemOrange; indicator = dot
        case .check: dot.color = .systemGreen; indicator = dot
        }
        stack.setViews([indicator, label], in: .leading)
        needsLayout = true
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: max(stack.fittingSize.width, 60), height: PillController.height)
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hoverHighlight ? 0.14 : 0.07).cgColor
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class DotIndicator: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}
