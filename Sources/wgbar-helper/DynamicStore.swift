import Foundation
import SystemConfiguration

/// Minimal SCDynamicStore access. Values vanish when the helper exits, so a crash
/// never leaves stale IPv6 state behind.
enum DynamicStore {
    private static let store = SCDynamicStoreCreate(nil, "wgbar-helper" as CFString, nil, nil)

    @discardableResult
    static func set(_ key: String, _ value: [String: Any]) -> Bool {
        guard let store else { return false }
        return SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary)
    }

    static func remove(_ key: String) {
        guard let store else { return }
        SCDynamicStoreRemoveValue(store, key as CFString)
    }
}
