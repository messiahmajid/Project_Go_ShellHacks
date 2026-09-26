//
//  ApprovalRulesKeychainStore.swift
//  Go
//
//  "Always allow" rules, stored in the data-protection Keychain. Items there
//  are scoped to Go's code signature, so another process can't read, write or
//  shadow them.
//

import Foundation
import Security

nonisolated struct ApprovalRulesKeychainStore {
    static let productionServiceName = "Go.approval-rules"
    static let accountName = "rules"

    let serviceName: String

    init(serviceName: String = ApprovalRulesKeychainStore.productionServiceName) {
        self.serviceName = serviceName
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Self.accountName,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// No item means no rules. A failed read is an error, never an empty list.
    func load() -> Result<[HarnessConfirmations.ApprovalRule], HarnessAppPolicy.ParseFailure> {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success([]) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(.init(reason: "keychain \(serviceName): read failed, OSStatus \(status)"))
        }
        return HarnessConfirmations.parseApprovals(data).mapError {
            .init(reason: "keychain \(serviceName): \($0.reason)")
        }
    }

    func save(_ rules: [HarnessConfirmations.ApprovalRule]) -> OSStatus {
        guard let data = try? JSONEncoder().encode(rules) else { return errSecParam }
        return write(data)
    }

    /// Update, or add when there is nothing to update.
    func write(_ data: Data) -> OSStatus {
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        // Readable only while unlocked, never synced to another device.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Never rewrite an item we couldn't read.
    func remove(_ rule: HarnessConfirmations.ApprovalRule) -> OSStatus {
        guard case .success(let rules) = load() else { return errSecDecode }
        return save(rules.filter { $0 != rule })
    }

    func deleteItem() -> OSStatus {
        SecItemDelete(itemQuery as CFDictionary)
    }
}
