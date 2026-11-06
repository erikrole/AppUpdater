import AppKit

/// What the pill shows right now. Copy stays this short on purpose.
struct PillContent: Equatable {
    enum Indicator: Equatable { case spinner, dot, warning, check }
    var indicator: Indicator
    var text: String
    /// Replaces `text` while the pointer is over the pill ("Installing v1.5.3").
    var hoverText: String?
    /// Whether clicking does anything. A spinner-only pill ignores clicks.
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

/// The small floating pill anchored to the top-right of the host's window or view (or under a menu bar item).
/// It is a borderless child panel, so it never takes focus, never changes the host's layout and follows the window.
@MainActor
final class PillController: NSObject, NSPopoverDelegate {
    static let height: CGFloat = 26
    static let inset: CGFloat = 12

    var onClick: (() -> Void)?
    /// Asked for the popover's content when the pill opens the notes. Return nil for nothing to show.
    var notesProvider: (() -> NotesPopoverContent?)?
    var onNotesOpened: (() -> Void)?
    var onNotesClosed: (() -> Void)?
    var anchorView: () -> NSView? = { nil }
    var accent: () -> NSColor = { .controlAccentColor }

    private(set) var content: PillContent?
    private var panel: NSPanel?
    private var pillView: PillView?
    private weak var parent: NSWindow?
    private var hovering = false
    private var popover: NSPopover?
    private var hoverTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
    }

    isolated deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    var isVisible: Bool { panel?.isVisible == true }
    var panelWindow: NSWindow? { panel }
    var isPopoverShown: Bool { popover?.isShown == true }
    var view: NSView? { pillView }

    // MARK: - Content

    func set(_ new: PillContent?) {
        guard new != content else { return }
        let hadPill = content != nil
        content = new
        guard let new else { hide(); return }
        hovering = false
        ensurePanel()
        pillView?.apply(new, hovering: false, accent: accent())
        resize(animated: hadPill)
        reposition()
        if !hadPill || panel?.isVisible != true { fadeIn() }
    }

    /// Re-reads the accent colour and anchor, for example after the host changed `hostView`.
    func refresh() {
        guard let content else { return }
        pillView?.apply(content, hovering: hovering, accent: accent())
        reposition()
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let view = PillView()
        view.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        view.onClick = { [weak self] in self?.clicked() }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = view
        self.panel = panel
        pillView = view
    }

    private func hide() {
        hoverTask?.cancel()
        popover?.close()
        guard let panel else { return }
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let self, let panel, self.content == nil else { return }
            self.parent?.removeChildWindow(panel)
            self.parent = nil
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        if Self.reduceMotion || !panel.isVisible { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    private func fadeIn() {
        guard let panel else { return }
        panel.alphaValue = Self.reduceMotion ? 1 : 0
        reposition()
        if !Self.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func resize(animated: Bool) {
        guard let panel, let pillView else { return }
        let size = pillView.fittingSize
        var frame = panel.frame
        // Keep the right edge in place when the text changes.
        frame.origin.x += frame.width - size.width
        frame.size = size
        panel.setFrame(frame, display: true, animate: animated && !Self.reduceMotion && panel.isVisible)
    }

    // MARK: - Anchoring

    /// The view the pill hangs from: the host's `hostView`, else the main (or key, or first visible) window's content.
    private func anchor() -> NSView? {
        if let view = anchorView(), view.window != nil { return view }
        let windows = NSApp.windows.filter { $0 !== panel && $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) && $0.contentView != nil }
        let chosen = NSApp.mainWindow.flatMap { main in windows.first { $0 === main } }
            ?? NSApp.keyWindow.flatMap { key in windows.first { $0 === key } }
            ?? windows.first
        return chosen?.contentView
    }

    func reposition() {
        guard content != nil, let panel else { return }
        guard let view = anchor(), let window = view.window else {
            parent?.removeChildWindow(panel)
            parent = nil
            panel.orderOut(nil)
            return
        }
        let size = panel.frame.size
        let isStatusItem = window.level.rawValue >= NSWindow.Level.statusBar.rawValue || window.className.contains("StatusBar")
        var rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        if view === window.contentView { rect = window.convertToScreen(window.contentLayoutRect) }
        var origin: NSPoint
        if isStatusItem {
            // Right-aligned under the menu bar item.
            origin = NSPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 4)
            if let screen = window.screen ?? NSScreen.main {
                origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
            }
            if let parent { parent.removeChildWindow(panel); self.parent = nil }
            panel.level = .statusBar
        } else {
            origin = NSPoint(x: rect.maxX - size.width - Self.inset, y: rect.maxY - size.height - Self.inset)
            panel.level = window.level
            if parent !== window {
                parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
                parent = window
            }
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    // MARK: - Interaction

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard let content else { return }
        pillView?.apply(content, hovering: inside, accent: accent())
        resize(animated: true)
        reposition()
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
        guard let pillView, !isPopoverShown, let notes = notesProvider?() else { return }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !Self.reduceMotion
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

/// The capsule itself: material background, an indicator and one line of text.
@MainActor
final class PillView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let dot = DotIndicator()
    private var tracking: NSTrackingArea?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
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
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: PillController.height),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: PillContent, hovering: Bool, accent: NSColor) {
        let text = (hovering ? content.hoverText : nil) ?? content.text
        label.stringValue = text
        setAccessibilityLabel(text)
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
    }

    override var fittingSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: max(stack.fittingSize.width, 60), height: PillController.height)
    }

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
