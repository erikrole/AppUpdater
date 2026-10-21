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
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        if direct { NSApp.terminate(nil) }
        else if stalled { await AppUpdater.requestQuit(fallbackAfter: .seconds(2), safeToExit: { safe }) }
        else { AppUpdater.requestQuit() }
    }
    app.run()
    withExtendedLifetime(delegate) {}
}
