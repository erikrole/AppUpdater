// A bare AppKit host used by the tests: its delegate answers terminate with .terminateLater and replies from a main-actor
// task, like a real app that saves first. After a second it asks to quit from inside a main-actor task, the way the updater
// does: `--direct` calls NSApp.terminate there (this hangs), the default calls AppUpdater.requestQuit (this exits).
import AppKit
import AppUpdater

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        if direct { NSApp.terminate(nil) } else { AppUpdater.requestQuit() }
    }
    app.run()
    withExtendedLifetime(delegate) {}
}
