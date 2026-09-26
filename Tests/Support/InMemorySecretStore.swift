import Foundation

final class InMemorySecretStore: SecretStore {
    var values: [String: String]
    var failWrites = false
    private(set) var reads = 0

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ account: String) -> String? {
        reads += 1
        return values[account]
    }

    func contains(_ account: String) -> Bool {
        values[account] != nil
    }

    func write(_ value: String, for account: String) -> Bool {
        guard !failWrites else { return false }
        values[account] = value
        return true
    }

    func delete(_ account: String) {
        values[account] = nil
    }
}
