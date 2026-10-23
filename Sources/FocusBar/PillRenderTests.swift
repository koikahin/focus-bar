import AppKit
import Darwin

/// Runs the real menu-bar renderer through all states without touching user
/// defaults or recording focus time. It temporarily adds a "test" pill.
@MainActor
enum PillRenderTests {
    static func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let renderer = PillRenderer(statusItem: item)
        let cases: [(String, Bool, TimeInterval)] = [
            ("idle", false, 0), ("tracking", true, 0),
            ("tracking complete", true, 60), ("idle complete", false, 60)
        ]
        var passed = true
        for (name, tracking, elapsed) in cases {
            let state = PillState(title: "test", isTracking: tracking, elapsed: elapsed, target: 60)
            renderer.render(state)
            let image = item.button?.image
            for _ in 0..<100 { renderer.render(state) }
            guard item.button?.image === image else {
                print("Unchanged pill state recreated its image")
                return false
            }
            RunLoop.main.run(until: Date.now.addingTimeInterval(1))
            let startCPU = Double(clock()) / Double(CLOCKS_PER_SEC)
            let startWall = ProcessInfo.processInfo.systemUptime
            RunLoop.main.run(until: Date.now.addingTimeInterval(3))
            let cpu = (Double(clock()) / Double(CLOCKS_PER_SEC) - startCPU)
                / (ProcessInfo.processInfo.systemUptime - startWall) * 100
            print(String(format: "%@: %.2f%% CPU", name, cpu))
            if cpu >= 5 { passed = false }
        }
        return passed
    }
}
