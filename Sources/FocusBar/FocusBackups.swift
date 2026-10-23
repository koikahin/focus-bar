import Foundation

/// Independent copies of the complete saved state, one per completed focus day.
struct FocusBackups {
    let directory: URL
    private let prefix = "focusbar-v1-"

    static var live: FocusBackups {
        FocusBackups(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusBar/Backups", isDirectory: true))
    }

    func save(_ snapshot: FocusSnapshot) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // The ISO focus-day key identifies a version independently of when a
        // delayed rollover runs. Repeating a rollover cannot rotate it twice.
        let name = prefix + snapshot.dayKey.replacingOccurrences(of: ":", with: "-") + ".json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent(name), options: .atomic)

        let versions = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        // Write the new copy before pruning so a failed write never removes
        // either existing backup.
        for old in versions.dropFirst(2) { try manager.removeItem(at: old) }
    }
}
