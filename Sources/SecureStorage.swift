import Foundation
import Security
import CommonCrypto
import LocalAuthentication

enum StorageError: Error { case random, cryptography, authentication, invalidCredentials, invalidFormat, keychain(OSStatus), locked }
enum AuthenticatedCipher {
    static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw StorageError.random }
        return bytes
    }
    static func digest(_ input: Data) -> Data {
        var result = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        result.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in
            _ = CC_SHA256(source.baseAddress, CC_LONG(input.count), out.bindMemory(to: UInt8.self).baseAddress)
        }}
        return result
    }
    static func derive(password: String, salt: Data) throws -> Data {
        var result = Data(count: 64)
        let pass = Array(password.utf8)
        let status = result.withUnsafeMutableBytes { out in salt.withUnsafeBytes { saltBytes in pass.withUnsafeBytes { passBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passBytes.bindMemory(to: Int8.self).baseAddress, pass.count,
                                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                600_000, out.bindMemory(to: UInt8.self).baseAddress, 64)
        }}}
        guard status == kCCSuccess else { throw StorageError.cryptography }
        return result
    }
    static func mac(_ value: Data, _ key: Data) -> Data {
        var result = Data(count: 32)
        result.withUnsafeMutableBytes { out in key.withUnsafeBytes { k in value.withUnsafeBytes { data in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, data.baseAddress, value.count, out.baseAddress)
        }}}
        return result
    }
    static func crypt(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw StorageError.invalidFormat }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { data in key.withUnsafeBytes { k in iv.withUnsafeBytes { vector in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count,
                    vector.baseAddress, data.baseAddress, input.count, out.baseAddress, capacity, &moved)
        }}}}
        guard status == kCCSuccess else { throw StorageError.cryptography }
        output.count = moved
        return output
    }
    // Encrypt-then-MAC: independent 32-byte AES and HMAC keys; authenticate before decrypting.
    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 64 else { throw StorageError.invalidFormat }
        let iv = try random(16)
        var envelope = Data("NCI1".utf8)
        envelope.append(iv)
        envelope.append(try crypt(plaintext, key: Data(key.prefix(32)), iv: iv, operation: CCOperation(kCCEncrypt)))
        envelope.append(mac(envelope, Data(key.suffix(32))))
        return envelope
    }
    static func open(_ envelope: Data, key: Data) throws -> Data {
        guard key.count == 64, envelope.count >= 68, envelope.prefix(4) == Data("NCI1".utf8), (envelope.count - 52) % 16 == 0 else { throw StorageError.invalidFormat }
        let body = Data(envelope.dropLast(32))
        let expected = mac(body, Data(key.suffix(32)))
        let actual = Array(envelope.suffix(32)), wanted = Array(expected)
        var difference: UInt8 = 0
        for n in 0..<32 { difference |= actual[n] ^ wanted[n] }
        guard difference == 0 else { throw StorageError.authentication }
        return try crypt(Data(body.dropFirst(20)), key: Data(key.prefix(32)), iv: Data(body[4..<20]), operation: CCOperation(kCCDecrypt))
    }
}
struct LibraryEnvelope: Codable { var privateMode: Bool; var salt: Data?; var wrappedKey: Data?; var biometric193: Bool? = nil }
final class ExportPermit193 {
    fileprivate let owner: UUID, media: String, stamp: Data, lease: Int, expires: TimeInterval
    fileprivate var consumed = false
    fileprivate var temporaryStarted = false
    fileprivate init(owner: UUID, media: String, stamp: Data, lease: Int) { self.owner = owner; self.media = media; self.stamp = stamp; self.lease = lease; expires = ProcessInfo.processInfo.systemUptime + 120 }
}
final class SecureStorage {
    let root: URL
    private var master: Data?
    private var sessionEpoch193 = 0
    private let exportOwner193 = UUID()
    private var liveExports193 = Set<String>()
    private(set) var exportCleanupPending193 = 0
    private(set) var envelope: LibraryEnvelope
    private let gate = NSRecursiveLock()
    private var stateValue = LibraryState()
    private var ordinaryAlbumWriters = Set<UUID>()
    private var albumPhotosChanged = false
    static let albumPhotosWriteFinished = Notification.Name("NocturneAlbumPhotosWriteFinished")
    private var privateMediaByDigest193: [String: Set<String>]?
    var isUnlocked193: Bool { gate.lock(); defer { gate.unlock() }; return master != nil }
    var state: LibraryState { gate.lock(); defer { gate.unlock() }; return stateValue }
    func update(_ body: (inout LibraryState) -> Void) { gate.lock(); defer { gate.unlock() }; body(&stateValue) }
    private let service = "com.nocturne.gallery.key.v1"
    private let account: String
    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Nocturne", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        account = root?.lastPathComponent ?? "master"
        let header = self.root.appendingPathComponent("mode.json")
        if FileManager.default.fileExists(atPath: header.path) { envelope = try JSONDecoder().decode(LibraryEnvelope.self, from: Data(contentsOf: header)) }
        else { envelope = LibraryEnvelope(privateMode: false, salt: nil, wrappedKey: nil) }
        var excluded = self.root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
        cleanupAbandonedExports193()
    }
    private func query() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    private func deviceKey() throws -> Data {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 64 { return key }
        guard status == errSecItemNotFound, !FileManager.default.fileExists(atPath: root.appendingPathComponent("library.ncv").path) else { throw StorageError.keychain(status) }
        let key = try AuthenticatedCipher.random(64); try storeDeviceKey(key); return key
    }
    private func storeDeviceKey(_ key: Data) throws {
        let update: [String: Any] = [kSecValueData as String: key, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { var q = query(); update.forEach { q[$0.key] = $0.value }; status = SecItemAdd(q as CFDictionary, nil) }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
    }
    func unlock(password: String? = nil) throws { gate.lock(); defer { gate.unlock() };
        if envelope.privateMode {
            guard let password = password, let salt = envelope.salt, let wrapped = envelope.wrappedKey else { throw StorageError.locked }
            do { master = try AuthenticatedCipher.open(wrapped, key: AuthenticatedCipher.derive(password: password, salt: salt)) } catch StorageError.authentication { throw StorageError.invalidCredentials }
        } else { master = try deviceKey() }
        guard master?.count == 64 else { master = nil; throw StorageError.invalidFormat }
        let library = root.appendingPathComponent("library.ncv")
        do { if FileManager.default.fileExists(atPath: library.path) { stateValue = try JSONDecoder().decode(LibraryState.self, from: read(library)) } } catch { master = nil; stateValue = LibraryState(); throw error }
        privateMediaByDigest193 = nil
        Strings.language = "zh-Hans"
        try maintainCaches()
        if !FileManager.default.fileExists(atPath: library.path) { try save() }
    }
    func enablePrivate(password: String) throws { gate.lock(); defer { gate.unlock() };
        guard let master = master, password.count >= 10 else { throw StorageError.locked }
        let salt = try AuthenticatedCipher.random(24)
        let changed = LibraryEnvelope(privateMode: true, salt: salt, wrappedKey: try AuthenticatedCipher.seal(master, key: AuthenticatedCipher.derive(password: password, salt: salt)))
        let previous = envelope
        try writeHeader(changed)
        let removed = SecItemDelete(query() as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { try? writeHeader(previous); throw StorageError.keychain(removed) }
        envelope = changed; sessionEpoch193 += 1; try? removeBiometricKey193()
    }
    func enableOrdinary(password: String) throws { gate.lock(); defer { gate.unlock() };
        guard let master = master, let salt = envelope.salt, let wrapped = envelope.wrappedKey else { throw StorageError.locked }
        let checked = try AuthenticatedCipher.open(wrapped, key: AuthenticatedCipher.derive(password: password, salt: salt))
        guard checked == master else { throw StorageError.authentication }
        try storeDeviceKey(master)
        let changed = LibraryEnvelope(privateMode: false, salt: nil, wrappedKey: nil)
        do { try writeHeader(changed) }
        catch {
            let removed = SecItemDelete(query() as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw StorageError.keychain(removed) }
            throw error
        }
        envelope = changed; sessionEpoch193 += 1; try? removeBiometricKey193()
    }
    private func writeHeader(_ value: LibraryEnvelope) throws {
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("mode.json"), options: [.atomic, .completeFileProtection])
    }
    func read(_ url: URL) throws -> Data { gate.lock(); defer { gate.unlock() };
        guard let key = master else { throw StorageError.locked }
        return try AuthenticatedCipher.open(Data(contentsOf: url), key: key)
    }
    func write(_ data: Data, to url: URL) throws { gate.lock(); defer { gate.unlock() };
        guard let key = master else { throw StorageError.locked }
        let encrypted = try AuthenticatedCipher.seal(data, key: key)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
    }
    func save() throws { gate.lock(); defer { gate.unlock() }; try write(JSONEncoder().encode(stateValue), to: root.appendingPathComponent("library.ncv")); try writeHeader(envelope) }
    func thumbnailURL(for identifier: String, pixels: Int, owner: String? = nil) throws -> URL { gate.lock(); defer { gate.unlock() };
        let directory = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = AuthenticatedCipher.digest(Data((identifier + "/" + String(pixels)).utf8)).map { String(format: "%02x", $0) }.joined() + ".nct"
        stateValue.cacheGenerations[name] = Release.version
        if let owner = owner { if stateValue.cacheOwners123 == nil { stateValue.cacheOwners123 = [:] }; stateValue.cacheOwners123?[name] = owner }
        return directory.appendingPathComponent(name)
    }
    private func maintainCaches() throws { gate.lock(); defer { gate.unlock() };
        stateValue.cacheVersions.removeAll { $0 == Release.version }; stateValue.cacheVersions.append(Release.version)
        // Version numbers are not cache-format identifiers. Preserve compatible authenticated cache files.
        stateValue.cacheVersions = Array(stateValue.cacheVersions.suffix(3))
    }

    func removeInaccessibleCaches(accessible: Set<String>) {
        gate.lock(); defer { gate.unlock() }
        let directory = root.appendingPathComponent("Cache", isDirectory: true)
        for (name, owner) in stateValue.cacheOwners123 ?? [:] where !accessible.contains(owner) {
            guard name.range(of: "^[a-f0-9]{64}\\.nct$", options: .regularExpression) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; stateValue.cacheOwners123?.removeValue(forKey: name); stateValue.cacheGenerations.removeValue(forKey: name) } catch { continue }
        }
    }
    func lock() { gate.lock(); defer { gate.unlock() }; sessionEpoch193 += 1; if let count = master?.count { master!.resetBytes(in: 0..<count) }; master = nil; stateValue = LibraryState(); privateMediaByDigest193 = nil; ordinaryAlbumWriters.removeAll(); albumPhotosChanged = false }
    private struct BiometricKey193: Codable { var binding: Data; var key: Data }
    private func biometricQuery193() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".biometric193", kSecAttrAccount as String: account]
    }
    private func removeBiometricKey193() throws {
        let status = SecItemDelete(biometricQuery193() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
    }
    func disableBiometric193() throws {
        gate.lock(); defer { gate.unlock() }
        guard master != nil else { throw StorageError.locked }
        try removeBiometricKey193(); var next = envelope; next.biometric193 = false
        try writeHeader(next); envelope = next
    }
    func enableBiometric193() throws {
        gate.lock()
        guard let key = master, envelope.privateMode, let wrapped = envelope.wrappedKey else { gate.unlock(); throw StorageError.locked }
        let epoch = sessionEpoch193, binding = AuthenticatedCipher.digest(wrapped)
        gate.unlock()
        let context = LAContext(); context.localizedFallbackTitle = "使用资料库密码"
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &failure) else { throw failure ?? NSError(domain: "NocturneBiometric", code: 1) }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &accessError) else { throw StorageError.cryptography }
        let data = try JSONEncoder().encode(BiometricKey193(binding: binding, key: key))
        // Adding does not prove user presence: immediately read through the biometric ACL before committing the flag.
        try removeBiometricKey193()
        var query = biometricQuery193(); query[kSecAttrAccessControl as String] = access; query[kSecValueData as String] = data
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw StorageError.keychain(added) }
        do {
            let checked = try biometricValue193(context: context)
            guard checked.binding == binding, checked.key == key else { throw StorageError.authentication }
            gate.lock(); defer { gate.unlock() }
            guard epoch == sessionEpoch193, master == key, envelope.privateMode else { throw StorageError.locked }
            var next = envelope; next.biometric193 = true; try writeHeader(next); envelope = next
        } catch { try? removeBiometricKey193(); throw error }
    }
    private func biometricValue193(context: LAContext) throws -> BiometricKey193 {
        var query = biometricQuery193(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        context.localizedReason = "解锁Nocturne Private"
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, var bytes = result as? Data else { throw StorageError.keychain(status) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try JSONDecoder().decode(BiometricKey193.self, from: bytes)
    }
    func unlockBiometric193() throws {
        gate.lock(); let epoch = sessionEpoch193, snapshot = envelope; gate.unlock()
        guard snapshot.privateMode, snapshot.biometric193 == true, let wrapped = snapshot.wrappedKey else { throw StorageError.locked }
        let context = LAContext(); context.localizedFallbackTitle = "使用资料库密码"
        let value = try biometricValue193(context: context)
        gate.lock(); defer { gate.unlock() }
        guard epoch == sessionEpoch193, envelope.wrappedKey == wrapped, value.key.count == 64,
              value.binding == AuthenticatedCipher.digest(wrapped) else { throw StorageError.authentication }
        master = value.key
        privateMediaByDigest193 = nil
        do { stateValue = try JSONDecoder().decode(LibraryState.self, from: read(root.appendingPathComponent("library.ncv"))) }
        catch { master = nil; stateValue = LibraryState(); throw error }
    }

    func browserEntries193(favorites: Bool, lease: Int) throws -> [BrowserEntry193] {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        return favorites ? stateValue.browserFavorites193 ?? [] : stateValue.browserHistory193 ?? []
    }
    func saveBrowserEntry193(_ entry: BrowserEntry193, favorite: Bool, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard entry.url.utf8.count <= 4096, let url = URL(string: entry.url), WebPolicy123.allowed(url),
              entry.title.count <= 200, entry.visited.timeIntervalSince1970.isFinite else { throw StorageError.invalidFormat }
        let before = stateValue
        var entries = favorite ? stateValue.browserFavorites193 ?? [] : stateValue.browserHistory193 ?? []
        entries.removeAll { $0.url == entry.url }; entries.insert(entry, at: 0)
        entries = Array(entries.prefix(favorite ? 64 : 300))
        if favorite { stateValue.browserFavorites193 = entries } else { stateValue.browserHistory193 = entries }
        do { try save() } catch { stateValue = before; throw error }
    }
    func clearBrowserHistory193(lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease); let before = stateValue
        stateValue.browserHistory193 = []
        do { try save() } catch { stateValue = before; throw error }
    }

    func resourceLease193() throws -> Int { gate.lock(); defer { gate.unlock() }; guard master != nil else { throw StorageError.locked }; return sessionEpoch193 }
    func validateResourceLease193(_ lease: Int) throws { gate.lock(); defer { gate.unlock() }; guard lease == sessionEpoch193, master != nil else { throw StorageError.locked } }
    private func resourcePath193(_ url: URL) throws {
        let base = root.standardizedFileURL, target = url.standardizedFileURL
        guard target.path.hasPrefix(base.appendingPathComponent("Media193").path + "/") else { throw StorageError.invalidFormat }
        var at = target
        while at.path != base.path {
            if FileManager.default.fileExists(atPath: at.path), try at.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw StorageError.invalidFormat }
            let parent = at.deletingLastPathComponent(); guard parent.path != at.path else { throw StorageError.invalidFormat }; at = parent
        }
    }
    private func resourceBinding193(media: String, part: String, index: Int) throws -> Data {
        guard UUID(uuidString: media) != nil, UUID(uuidString: part) != nil, index >= 0, index < 122_880 else { throw StorageError.invalidFormat }
        return AuthenticatedCipher.digest(Data(("Nocturne resource193|" + media + "|" + part + "|" + String(index)).utf8))
    }
    func writeResourceChunk193(_ data: Data, to url: URL, media: String, part: String, index: Int, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease); try resourcePath193(url)
        guard data.count > 0, data.count <= 1_048_576, !FileManager.default.fileExists(atPath: url.path) else { throw StorageError.invalidFormat }
        var body = try resourceBinding193(media: media, part: part, index: index); body.append(data)
        defer { body.resetBytes(in: 0..<body.count) }
        try write(body, to: url)
        let handle = try FileHandle(forWritingTo: url); defer { handle.closeFile() }; try synchronizeHandle193(handle)
    }
    func readResourceChunk193(_ url: URL, media: String, part: String, index: Int, lease: Int) throws -> Data {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease); try resourcePath193(url)
        let length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard length >= 100, length <= 1_048_576 + 116 else { throw StorageError.invalidFormat }
        let binding = try resourceBinding193(media: media, part: part, index: index)
        var data = try read(url); defer { data.resetBytes(in: 0..<data.count) }
        guard data.count > binding.count, data.prefix(binding.count) == binding else { throw StorageError.authentication }
        return Data(data.dropFirst(binding.count))
    }
    func beginAlbumPhotosWrite(lease: Int) throws -> UUID {
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        guard !envelope.privateMode else { throw StorageError.locked }
        let token = UUID()
        ordinaryAlbumWriters.insert(token)
        return token
    }

    func deferAlbumPhotosRefresh() -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard !ordinaryAlbumWriters.isEmpty else { return false }
        albumPhotosChanged = true
        return true
    }

    func finishAlbumPhotosWrite(_ token: UUID) {
        gate.lock()
        let shouldNotify = ordinaryAlbumWriters.remove(token) != nil && ordinaryAlbumWriters.isEmpty && albumPhotosChanged
        if shouldNotify { albumPhotosChanged = false }
        gate.unlock()
        if shouldNotify { NotificationCenter.default.post(name: Self.albumPhotosWriteFinished, object: self) }
    }

    func markConfirmedAlbumDeletions(_ ids: Set<String>, lease: Int) throws {
        guard !ids.isEmpty else { return }
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        guard !envelope.privateMode else { return }
        let old = stateValue.confirmedAlbumDeletions
        stateValue.confirmedAlbumDeletions = (old ?? []).union(ids)
        do { try save() }
        catch { stateValue.confirmedAlbumDeletions = old; throw error }
    }

    func hasConfirmedAlbumDeletion(_ id: String, lease: Int) throws -> Bool {
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        return stateValue.confirmedAlbumDeletions?.contains(id) == true
    }

    private func albumSyncRecordURL(_ name: String, create: Bool) throws -> URL {
        guard name.utf8.count == 64,
              name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
              else { throw StorageError.invalidFormat }
        let directory = root.appendingPathComponent("AlbumSync", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink == false else { throw StorageError.invalidFormat }
        } else if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
        }
        return directory.appendingPathComponent(name + ".ncs")
    }

    func albumSyncRecord(_ name: String, lease: Int) throws -> Data? {
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        guard !envelope.privateMode else { throw StorageError.locked }
        let url = try albumSyncRecordURL(name, create: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink == false,
              (attributes.fileSize ?? Int.max) <= 512 * 1024 else { throw StorageError.invalidFormat }
        let authenticated = try read(url), binding = Data(("Nocturne/AlbumSync|" + name + "|").utf8)
        guard authenticated.starts(with: binding), authenticated.count > binding.count else { throw StorageError.authentication }
        return Data(authenticated.dropFirst(binding.count))
    }

    func updateAlbumSyncRecord(_ name: String, lease: Int, merge: (Data?) throws -> Data?) throws {
        gate.lock()
        defer { gate.unlock() }
        let previous = try albumSyncRecord(name, lease: lease)
        if let value = try merge(previous), value != previous {
            try writeAlbumSyncRecord(value, name: name, lease: lease)
        }
    }

    func writeAlbumSyncRecord(_ data: Data, name: String, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        guard !envelope.privateMode, !data.isEmpty, data.count < 500 * 1024 else { throw StorageError.invalidFormat }
        let url = try albumSyncRecordURL(name, create: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink == false else { throw StorageError.invalidFormat }
        }
        var payload = Data(("Nocturne/AlbumSync|" + name + "|").utf8)
        payload.append(data)
        defer { payload.resetBytes(in: 0..<payload.count) }
        try write(payload, to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { file.closeFile() }
        try synchronizeHandle193(file)
    }

    func exactPrivateMatches193(for incoming: EncryptedMedia193, lease: Int) throws -> [EncryptedMedia193] {
        gate.lock(); defer { gate.unlock() }
        try validateResourceLease193(lease)
        if privateMediaByDigest193 == nil {
            var index: [String: Set<String>] = [:]
            for (id, media) in stateValue.internalMedia193 ?? [:] {
                index[media.rawIdentity193, default: []].insert(id)
            }
            privateMediaByDigest193 = index
        }
        let ids = privateMediaByDigest193?[incoming.rawIdentity193] ?? []
        return ids.sorted().compactMap { stateValue.internalMedia193?[$0] }
    }

    private func removeFromPrivateMediaIndex193(_ media: EncryptedMedia193) {
        guard privateMediaByDigest193 != nil else { return }
        let identity = media.rawIdentity193
        privateMediaByDigest193?[identity]?.remove(media.id)
        if privateMediaByDigest193?[identity]?.isEmpty == true { privateMediaByDigest193?.removeValue(forKey: identity) }
    }

    func registerMedia193(_ value: EncryptedMedia193, sourceRecord: MediaRecord?, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        try value.validate193()
        guard envelope.privateMode, stateValue.internalMedia193?[value.id] == nil else { throw StorageError.invalidFormat }
        let before = stateValue
        if stateValue.internalMedia193 == nil { stateValue.internalMedia193 = [:] }
        stateValue.internalMedia193?[value.id] = value
        stateValue.records[value.localIdentifier] = sourceRecord ?? MediaRecord()
        do { try save() } catch { stateValue = before; throw error }
        if privateMediaByDigest193 != nil { privateMediaByDigest193![value.rawIdentity193, default: []].insert(value.id) }
    }
    func removePrivateMedia193(_ id: String, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard let value = stateValue.internalMedia193?[id] else { throw StorageError.invalidFormat }
        let directory = root.appendingPathComponent("Media193").appendingPathComponent(id); try resourcePath193(directory)
        let before = stateValue
        stateValue.internalMedia193?.removeValue(forKey: id); stateValue.records.removeValue(forKey: value.localIdentifier)
        do { try save() } catch { stateValue = before; throw error }
        removeFromPrivateMediaIndex193(value)
        // Only owned encrypted resources; external Photos assets are never touched by this method.
        try? FileManager.default.removeItem(at: directory)
    }
    func discardUncommitted193(_ id: String, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard UUID(uuidString: id) != nil, stateValue.internalMedia193?[id] == nil else { return }
        let library = root.appendingPathComponent("library.ncv")
        if FileManager.default.fileExists(atPath: library.path) {
            let disk = try JSONDecoder().decode(LibraryState.self, from: read(library))
            guard disk.internalMedia193?[id] == nil else { return }
        }
        let directory = root.appendingPathComponent("Media193").appendingPathComponent(id); try resourcePath193(directory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func verifyExportPassword193(_ password: String, lease: Int) throws {
        gate.lock()
        guard let current = master, envelope.privateMode, let salt = envelope.salt, let wrapped = envelope.wrappedKey else { gate.unlock(); throw StorageError.locked }
        gate.unlock()
        var checked: Data
        do { checked = try AuthenticatedCipher.open(wrapped, key: AuthenticatedCipher.derive(password: password, salt: salt)) }
        catch StorageError.authentication { throw StorageError.invalidCredentials }
        defer { checked.resetBytes(in: 0..<checked.count) }
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard envelope.wrappedKey == wrapped, checked.count == current.count else { throw StorageError.authentication }
        var different: UInt8 = 0
        for index in 0..<current.count { different |= current[index] ^ checked[index] }
        guard different == 0 else { throw StorageError.authentication }
    }
    func verifyExportBiometric193(lease: Int) throws {
        let context = LAContext(); context.localizedFallbackTitle = "使用资料库密码"
        let value = try biometricValue193(context: context)
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard envelope.privateMode, envelope.biometric193 == true, let wrapped = envelope.wrappedKey,
              value.binding == AuthenticatedCipher.digest(wrapped), value.key == master else { throw StorageError.authentication }
    }
    func rememberRestore193(media: String, nativeID: String, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard stateValue.internalMedia193?[media] != nil, !nativeID.isEmpty, nativeID.count <= 2048 else { throw StorageError.invalidFormat }
        let before = stateValue
        if stateValue.restoredAssets193 == nil { stateValue.restoredAssets193 = [:] }
        stateValue.restoredAssets193?[media] = nativeID
        do { try save() } catch { stateValue = before; throw error }
    }

    private func exportStamp193(_ value: EncryptedMedia193) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AuthenticatedCipher.digest(try encoder.encode(value))
    }
    func authorizeExport193(media: String, password: String?, completion: @escaping (Result<ExportPermit193, Error>) -> Void) {
        let lease: Int, snapshot: EncryptedMedia193, privateMode: Bool
        do {
            gate.lock(); defer { gate.unlock() }; lease = try resourceLease193()
            guard let value = stateValue.internalMedia193?[media] else { throw StorageError.invalidFormat }
            snapshot = value; privateMode = envelope.privateMode
        } catch { completion(.failure(error)); return }
        let issue: () -> Void = {
            do {
                self.gate.lock(); defer { self.gate.unlock() }; try self.validateResourceLease193(lease)
                let stamp = try self.exportStamp193(snapshot)
                guard let current = self.stateValue.internalMedia193?[media], try self.exportStamp193(current) == stamp else { throw MediaError193.changed }
                completion(.success(ExportPermit193(owner: self.exportOwner193, media: media, stamp: stamp, lease: lease)))
            } catch { completion(.failure(error)) }
        }
        if privateMode {
            DispatchQueue.global(qos: .userInitiated).async {
                do { if let password = password { try self.verifyExportPassword193(password, lease: lease) } else { try self.verifyExportBiometric193(lease: lease) }; issue() }
                catch { completion(.failure(error)) }
            }
        } else {
            let context = LAContext()
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证身份并将加密原件恢复到系统相册") { success, error in
                _ = context // Keep the system authentication context alive until its reply.
                guard success else { completion(.failure(error ?? StorageError.authentication)); return }; issue()
            }
        }
    }
    func consumeExportPermit193(_ permit: ExportPermit193, media: EncryptedMedia193) throws -> Int {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(permit.lease)
        guard !permit.consumed, permit.owner == exportOwner193, permit.media == media.id,
              ProcessInfo.processInfo.systemUptime <= permit.expires,
              try exportStamp193(media) == permit.stamp,
              let current = stateValue.internalMedia193?[media.id], try exportStamp193(current) == permit.stamp else { throw StorageError.authentication }
        permit.consumed = true; return permit.lease
    }

    private func protectedExportRoot193() -> URL { root.appendingPathComponent("ProtectedExport193", isDirectory: true) }
    func beginProtectedExport193(_ permit: ExportPermit193, media: EncryptedMedia193) throws -> URL {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(permit.lease)
        guard permit.owner == exportOwner193, permit.consumed, !permit.temporaryStarted, permit.media == media.id,
              ProcessInfo.processInfo.systemUptime <= permit.expires, exportCleanupPending193 == 0,
              try exportStamp193(media) == permit.stamp else { throw StorageError.authentication }
        let parent = protectedExportRoot193()
        if FileManager.default.fileExists(atPath: parent.path) {
            guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true,
                  try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw StorageError.invalidFormat }
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: parent.path)
        var excludedParent = parent; var parentValues = URLResourceValues(); parentValues.isExcludedFromBackup = true; try excludedParent.setResourceValues(parentValues)
        let directory = parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        let marker = directory.appendingPathComponent(".owner193")
        try Data("NCEXP193".utf8).write(to: marker, options: [.atomic, .completeFileProtection])
        permit.temporaryStarted = true; liveExports193.insert(directory.lastPathComponent); return directory
    }
    private func removeExportDirectory193(_ directory: URL) throws {
        let parent = protectedExportRoot193().standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == parent, UUID(uuidString: directory.lastPathComponent) != nil,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw StorageError.invalidFormat }
        let marker = directory.appendingPathComponent(".owner193")
        guard (try marker.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])).isSymbolicLink != true,
              (try marker.resourceValues(forKeys: [.fileSizeKey])).fileSize == 8,
              try Data(contentsOf: marker) == Data("NCEXP193".utf8) else { throw StorageError.invalidFormat }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  child.lastPathComponent == ".owner193" || child.pathExtension == "ncexport" && UUID(uuidString: child.deletingPathExtension().lastPathComponent) != nil else { throw StorageError.invalidFormat }
        }
        try FileManager.default.removeItem(at: directory)
    }
    func finishProtectedExport193(_ directory: URL) {
        gate.lock(); defer { gate.unlock() }; liveExports193.remove(directory.lastPathComponent)
        do { if FileManager.default.fileExists(atPath: directory.path) { try removeExportDirectory193(directory) } }
        catch { exportCleanupPending193 += 1 }
    }
    func cleanupAbandonedExports193() {
        gate.lock(); defer { gate.unlock() }; exportCleanupPending193 = 0
        let directory = protectedExportRoot193()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw StorageError.invalidFormat }
            for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard !liveExports193.contains(folder.lastPathComponent) else { continue }
                do { try removeExportDirectory193(folder) } catch { exportCleanupPending193 += 1 }
            }
        } catch { exportCleanupPending193 += 1 }
    }

    func retireRestoredMedia193(_ media: EncryptedMedia193, nativeID: String, lease: Int) throws {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard let current = stateValue.internalMedia193?[media.id], try exportStamp193(current) == exportStamp193(media),
              stateValue.restoredAssets193?[media.id] == nativeID else { throw StorageError.authentication }
        let directory = root.appendingPathComponent("Media193").appendingPathComponent(media.id); try resourcePath193(directory)
        let before = stateValue
        if var old = stateValue.records[media.localIdentifier] {
            if let added = stateValue.records[nativeID] { old.views = max(old.views, added.views); old.favorite = old.favorite || added.favorite; old.star = old.star || added.star }
            stateValue.records[nativeID] = old
        }
        stateValue.internalMedia193?.removeValue(forKey: media.id)
        // Keep historical private record as an archived identity; it grants no media access after retirement.
        do { try save() } catch { stateValue = before; throw error }
        removeFromPrivateMediaIndex193(current)
        try? FileManager.default.removeItem(at: directory)
    }

    func attachImportedReference193(existing: EncryptedMedia193, incoming: EncryptedMedia193, sourceRecord: MediaRecord?, lease: Int) throws -> EncryptedMedia193 {
        gate.lock(); defer { gate.unlock() }; try validateResourceLease193(lease)
        guard envelope.privateMode, var current = stateValue.internalMedia193?[existing.id],
              try exportStamp193(current) == exportStamp193(existing), current.rawIdentity193 == incoming.rawIdentity193,
              current.sourceIDs.count <= 4096 else { throw StorageError.authentication }
        let before = stateValue
        current.sourceIDs = Array(Set(current.sourceIDs + incoming.sourceIDs)).sorted()
        for metadata in incoming.sourceMetadata193 ?? [] {
            if current.sourceMetadata193 == nil { current.sourceMetadata193 = [] }
            if !current.sourceMetadata193!.contains(where: { $0.sourceID == metadata.sourceID }) { current.sourceMetadata193?.append(metadata) }
        }
        if current.latitude == nil { current.latitude = incoming.latitude; current.longitude = incoming.longitude; current.altitude = incoming.altitude }
        stateValue.internalMedia193?[current.id] = current
        if let incoming = sourceRecord {
            var record = stateValue.records[current.localIdentifier] ?? MediaRecord()
            record.views = max(record.views, incoming.views); record.favorite = record.favorite || incoming.favorite; record.star = record.star || incoming.star
            if record.mark == nil { record.mark = incoming.mark }; if record.folder.isEmpty { record.folder = incoming.folder }
            if record.favoriteRank122 == nil { record.favoriteRank122 = incoming.favoriteRank122 }
            stateValue.records[current.localIdentifier] = record
        }
        do { try save() } catch { stateValue = before; throw error }
        return current
    }

}
