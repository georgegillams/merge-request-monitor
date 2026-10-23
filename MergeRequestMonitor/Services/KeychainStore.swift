//
//  KeychainStore.swift
//  MergeRequestMonitor
//

import Foundation
import Security

enum TokenLookup: Equatable {
    case value(String)
    case missing
    /// The item cannot be read until this Mac is unlocked.
    case locked
}

struct KeychainStoreError: LocalizedError, Equatable {
    enum Operation: Equatable {
        case save
        case delete
    }

    let operation: Operation
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        switch operation {
        case .save:
            return "Couldn’t save the token in the Keychain (\(detail))."
        case .delete:
            return "Couldn’t delete the token from the Keychain (\(detail))."
        }
    }
}

/// GitLab personal access tokens.
///
/// Items are stored in the data protection keychain. The preferred class requires
/// a login password, is unreadable while the Mac is locked, never syncs, and is
/// dropped from backups. If this Mac has no password, the item falls back to
/// when-unlocked, this device only.
struct KeychainStore {
    private let service = "uk.co.georgegillams.gitlab-monitor.tokens"
    private let preferredAccessibility = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    private let fallbackAccessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    /// Set when this Mac has no password, so later writes skip the class the OS rejects.
    private var passcodeProtectionUnavailable = false

    mutating func saveToken(_ token: String, account: String) throws {
        let classes = passcodeProtectionUnavailable
            ? [fallbackAccessibility]
            : [preferredAccessibility, fallbackAccessibility]
        var lastStatus: OSStatus = errSecSuccess
        for accessibility in classes {
            lastStatus = write(token, account: account, accessibility: accessibility)
            if lastStatus == errSecSuccess {
                if accessibility as String != preferredAccessibility as String {
                    passcodeProtectionUnavailable = true
                }
                return
            }
            if accessibility as String == preferredAccessibility as String,
               isPasscodeProtectionUnavailable(lastStatus) {
                passcodeProtectionUnavailable = true
                continue
            }
            break
        }
        throw KeychainStoreError(operation: .save, status: lastStatus)
    }

    func readToken(account: String) -> TokenLookup {
        switch copy(account: account) {
        case .success(let token):
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .missing : .value(trimmed)
        case .failure(errSecInteractionNotAllowed):
            return .locked
        case .failure(errSecItemNotFound):
            return .missing
        case .failure(let status):
            gDebugPrint("Keychain read failed status=\(status)")
            return .missing
        }
    }

    func deleteToken(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: .delete, status: status)
        }
    }

    private func write(_ token: String, account: String, accessibility: CFString) -> OSStatus {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: accessibility,
            kSecAttrLabel as String: "Merge Request Monitor token",
            kSecAttrDescription as String: "GitLab personal access token"
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }

        var add = query
        for (key, value) in attributes {
            add[key] = value
        }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        return addStatus
    }

    private enum CopyOutcome {
        case success(String)
        case failure(OSStatus)
    }

    private func copy(account: String) -> CopyOutcome {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return .failure(errSecDecode)
        }
        return .success(token)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// `WhenPasscodeSetThisDeviceOnly` fails with `errSecAuthFailed` when this Mac
    /// has no login password. A decode failure is a different error, and following
    /// it with the weaker class would replace an item that is already stored.
    private func isPasscodeProtectionUnavailable(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
    }
}
