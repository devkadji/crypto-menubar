import Foundation
import CryptoKit
import Security

// Encryption-at-rest for the portfolio file.
//
// Threat model: someone gets hold of the files on disk (stolen backup, disk
// image, malware that reads ~/Library without going through the Keychain).
// The holdings JSON is sealed with AES-256-GCM; the key lives ONLY in the
// user's login Keychain, which macOS gates behind the login password and a
// per-app access prompt. Without the Keychain item the file is opaque.
//
// What this does NOT protect against: an attacker who is already running
// code as you with the Keychain unlocked AND clicks "Allow" on the prompt.
// That's the same boundary Safari passwords / Mail accounts sit behind.
//
// Note on ad-hoc signed builds: the Keychain remembers WHICH binary created
// the key. Every rebuild has a new signature, so the first portfolio access
// after a rebuild pops a "CryptoMenubar wants to use your confidential
// information…" dialog — click "Always Allow". Users on a single released
// build see it at most once per update.

enum SecureStoreError: LocalizedError {
    case keychain(OSStatus)
    case corruptData
    case keyMissing

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
                return "Keychain access was denied (\(msg)). Re-open the portfolio and click “Allow” to unlock it."
            }
            return "Keychain error: \(msg)"
        case .corruptData:
            return "The portfolio file is corrupted or was encrypted with a different key."
        case .keyMissing:
            return "The portfolio file exists but its encryption key is missing from the Keychain."
        }
    }
}

enum SecureStore {
    static let service = "io.github.devkadji.cryptomenubar"
    static let account = "portfolio-encryption-key"
    // File header. Doubles as GCM additional-authenticated-data so a blob from
    // a future format version can't be silently decrypted as v1.
    private static let magic = Data("CMPF1".utf8)

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns the key if the Keychain has one; nil if none was ever created.
    /// Throws if the Keychain refused access (user clicked Deny, locked, …).
    static func fetchKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw SecureStoreError.corruptData
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.keychain(status)
        }
    }

    /// First save creates a fresh random 256-bit key and stores it.
    static func fetchOrCreateKey() throws -> SymmetricKey {
        if let existing = try fetchKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var attrs = baseQuery
        attrs[kSecAttrLabel as String] = "Crypto Menubar — portfolio encryption key"
        attrs[kSecAttrDescription as String] = "AES-256-GCM key protecting the local portfolio file"
        attrs[kSecValueData as String] = keyData
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try fetchKey() {
            return raced   // another thread/instance created it first — use theirs
        }
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        return key
    }

    /// Deletes the key. Only used by "Reset portfolio" when the file is
    /// unreadable — never called on a normal path.
    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: magic)
        guard let combined = box.combined else { throw SecureStoreError.corruptData }
        return magic + combined
    }

    static func decrypt(_ blob: Data, key: SymmetricKey) throws -> Data {
        guard blob.count > magic.count, blob.prefix(magic.count) == magic else {
            throw SecureStoreError.corruptData
        }
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst(magic.count))
            return try AES.GCM.open(box, using: key, authenticating: magic)
        } catch {
            throw SecureStoreError.corruptData
        }
    }
}

// The encrypted file itself: ~/Library/Application Support/CryptoMenubar/portfolio.v1.enc
enum PortfolioFile {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CryptoMenubar", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("portfolio.v1.enc") }

    /// nil when no portfolio has ever been saved.
    static func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
