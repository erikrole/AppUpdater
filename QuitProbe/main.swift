// A bare AppKit host used by the tests: its delegate answers terminate with .terminateLater and replies from a main-actor
// task, like a real app that saves first. After a second it asks to quit from inside a main-actor task, the way the updater
// does: `--direct` calls NSApp.terminate there (this hangs), the default calls AppUpdater.requestQuit (this exits).
import AppKit
import AppUpdater

let stalled = CommandLine.arguments.contains("--stalled")
let safe = !CommandLine.arguments.contains("--not-safe")

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `--stalled`: a quit that never completes (cancelled, as an unanswered or declined quit would be).
        if stalled { return .terminateCancel }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.prohibited)
    let direct = CommandLine.arguments.contains("--direct")
    let cancelFallback = CommandLine.arguments.contains("--cancel-fallback")
    let cancelDuringSave = CommandLine.arguments.contains("--cancel-during-save")
    let sheetDuringSave = CommandLine.arguments.contains("--sheet-during-save")
    let parent = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
    let sheet = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        if direct { NSApp.terminate(nil) }
        else if stalled {
            let quit = Task { @MainActor in
                await AppUpdater.requestQuit(fallbackAfter: .seconds(2), safeToExit: {
                    if cancelDuringSave { withUnsafeCurrentTask { $0?.cancel() } }
                    if sheetDuringSave { parent.beginSheet(sheet) }
                    return safe
                })
            }
            if cancelFallback {
                try? await Task.sleep(for: .milliseconds(100))
                quit.cancel()
            }
            await quit.value
        }
        else { AppUpdater.requestQuit() }
    }
    app.run()
    withExtendedLifetime(delegate) {}
}
