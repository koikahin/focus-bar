import Foundation

enum FocusPersistence {
    static let key = "focusbar.snapshot.v1"

    static func load(defaults: UserDefaults) throws -> FocusSnapshot? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(FocusSnapshot.self, from: data)
    }

    static func save(_ snapshot: FocusSnapshot, defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: key)
    }
}
