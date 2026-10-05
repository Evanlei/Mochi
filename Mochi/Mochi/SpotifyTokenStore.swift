import Foundation
import Security

@MainActor
protocol SpotifyTokenStoring {
    func load() throws -> SpotifyTokens?
    func save(_ tokens: SpotifyTokens) throws
    func delete() throws
}

@MainActor
final class SpotifyTokenStore: SpotifyTokenStoring {
    private let service: String
    private let account: String

    init(service: String = "com.evan.Mochi.spotify", account: String = SpotifyConfiguration.clientID) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> SpotifyTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpotifyAuthError.keychain(status) }
        guard let data = result as? Data,
              let tokens = try? JSONDecoder().decode(SpotifyTokens.self, from: data),
              !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty else {
            try delete()
            return nil
        }
        return tokens
    }

    func save(_ tokens: SpotifyTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SpotifyAuthError.keychain(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpotifyAuthError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpotifyAuthError.keychain(status)
        }
    }
}
