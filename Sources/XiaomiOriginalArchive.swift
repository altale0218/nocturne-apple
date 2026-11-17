import CryptoKit
import Foundation
import Photos

/// Stores the exact Xiaomi container alongside its optional native Photos representation.
final class XiaomiOriginalArchive {
    private struct Stored: Codable {
        let sha256: String
        let bytes: Int64
        let key: Data
    }

    struct NativeLink: Codable {
        let original: MobileAlbumManifest
        let nativeIdentifier: String
        let modified: Date?
    }

    private let storage: SecureStorage
    private let lease: Int
    private let manager = FileManager.default
    private static let chunkSize = 1_048_576

    init(storage: SecureStorage, lease: Int) {
        self.storage = storage
        self.lease = lease
    }

    private func check() throws {
        try Task.checkCancellation()
        try storage.validateResourceLease193(lease)
        guard !storage.envelope.privateMode else { throw MediaError193.wrongMode }
    }

    func remember(_ manifest: MobileAlbumManifest, peer: String) throws {
        try check()
        let key = record("relation", peer, manifest.id)
        if let known = try relation(peer: peer, peerItem: manifest.id) {
            guard known.key == manifest.key, known.embeddedMotion == manifest.embeddedMotion else {
                throw MediaError193.changed
            }
            return
        }
        try storage.writeAlbumSyncRecord(JSONEncoder().encode(manifest), name: key, lease: lease)
    }

    func relation(peer: String, peerItem: String) throws -> MobileAlbumManifest? {
        let key = record("relation", peer, peerItem)
        guard let data = try storage.albumSyncRecord(key, lease: lease) else { return nil }
        let item = try JSONDecoder().decode(MobileAlbumManifest.self, from: data)
        try item.validate()
        return item
    }

    func link(_ manifest: MobileAlbumManifest, to asset: PHAsset) throws {
        try check()
        let link = NativeLink(original: manifest, nativeIdentifier: asset.localIdentifier, modified: asset.modificationDate)
        try storage.writeAlbumSyncRecord(JSONEncoder().encode(link), name: record("native", asset.localIdentifier), lease: lease)
    }

    func original(for asset: PHAsset) throws -> MobileAlbumManifest? {
        let key = record("native", asset.localIdentifier)
        guard let bytes = try storage.albumSyncRecord(key, lease: lease) else { return nil }
        let link = try JSONDecoder().decode(NativeLink.self, from: bytes)
        guard link.nativeIdentifier == asset.localIdentifier, link.modified == asset.modificationDate,
              asset.mediaSubtypes.contains(.photoLive) else { return nil }
        try link.original.validate()
        return link.original
    }

    func preserve(_ original: URL, resource: PhotoSyncLibrary.Resource) throws {
        try check()
        try resource.validate()
        let key = record("raw", resource.sha256)
        let stored: Stored
        if let registration = try registration(resource) {
            stored = registration
        } else {
            stored = Stored(sha256: resource.sha256, bytes: resource.bytes, key: try AuthenticatedCipher.random(32))
            try storage.writeAlbumSyncRecord(JSONEncoder().encode(stored), name: key, lease: lease)
        }
        let final = try file(resource, createDirectory: true)
        if manager.fileExists(atPath: final.path) {
            try copy(stored, from: final, to: nil)
            return
        }
        let temp = final.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        guard manager.createFile(atPath: temp.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
              else { throw MediaError193.unavailable }
        defer { try? manager.removeItem(at: temp) }
        let input = try FileHandle(forReadingFrom: original), output = try FileHandle(forWritingTo: temp)
        defer { try? input.close(); try? output.close() }
        let cipher = SymmetricKey(data: stored.key)
        var hash = SHA256(), count: Int64 = 0, number = 0
        while count < resource.bytes {
            try check()
            let data = try read(input, count: Int(min(Int64(Self.chunkSize), resource.bytes - count)))
            hash.update(data: data)
            let boxed = try AES.GCM.seal(data, using: cipher, authenticating: context(stored, number: number, count: data.count))
            guard let sealed = boxed.combined, sealed.count == data.count + 28 else { throw MediaError193.verification }
            try output.write(contentsOf: sealed)
            number += 1
            count += Int64(data.count)
        }
        let extra = try input.read(upToCount: 1)
        guard extra?.isEmpty ?? true, AppleSyncTransport.hex(Data(hash.finalize())) == resource.sha256
              else { throw MediaError193.verification }
        try output.synchronize()
        try check()
        try manager.moveItem(at: temp, to: final)
    }

    func verify(_ resource: PhotoSyncLibrary.Resource) throws {
        guard let stored = try registration(resource) else { throw MediaError193.unavailable }
        try copy(stored, from: file(resource, createDirectory: false), to: nil)
    }

    func extract(_ resource: PhotoSyncLibrary.Resource, to output: FileHandle) throws {
        guard let stored = try registration(resource) else { throw MediaError193.unavailable }
        try copy(stored, from: file(resource, createDirectory: false), to: output)
        try output.synchronize()
    }

    private func copy(_ stored: Stored, from url: URL, to output: FileHandle?) throws {
        let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        let chunks = (stored.bytes + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)
        guard attributes.isSymbolicLink == false, attributes.isRegularFile == true,
              attributes.fileSize.map({ Int64($0) }) == stored.bytes + chunks * 28 else { throw MediaError193.verification }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let key = SymmetricKey(data: stored.key)
        var offset: Int64 = 0, index = 0, hash = SHA256()
        while offset < stored.bytes {
            try check()
            let size = Int(min(Int64(Self.chunkSize), stored.bytes - offset))
            let encrypted = try read(file, count: size + 28)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key,
                                        authenticating: context(stored, number: index, count: size))
            guard data.count == size else { throw MediaError193.verification }
            try output?.write(contentsOf: data)
            hash.update(data: data)
            offset += Int64(size)
            index += 1
        }
        guard AppleSyncTransport.hex(Data(hash.finalize())) == stored.sha256 else { throw MediaError193.verification }
    }

    private func registration(_ resource: PhotoSyncLibrary.Resource) throws -> Stored? {
        try check()
        try resource.validate()
        guard let data = try storage.albumSyncRecord(record("raw", resource.sha256), lease: lease) else { return nil }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.sha256 == resource.sha256, stored.bytes == resource.bytes, stored.key.count == 32 else {
            throw MediaError193.verification
        }
        return stored
    }

    private func file(_ resource: PhotoSyncLibrary.Resource, createDirectory: Bool) throws -> URL {
        let base = storage.root.appendingPathComponent("AlbumOriginals", isDirectory: true)
        if createDirectory && !manager.fileExists(atPath: base.path) {
            try manager.createDirectory(at: base, withIntermediateDirectories: false,
                                        attributes: [.protectionKey: FileProtectionType.complete])
        }
        let attributes = try base.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard attributes.isSymbolicLink == false, attributes.isDirectory == true else { throw MediaError193.verification }
        return base.appendingPathComponent(resource.sha256 + ".nca")
    }

    private func record(_ fields: String...) -> String {
        AppleSyncTransport.hash("xiaomi/archive/1|\(fields.joined(separator: "|"))")
    }

    private func context(_ stored: Stored, number: Int, count: Int) -> Data {
        Data("Nocturne/XiaomiOriginal/1|\(stored.sha256)|\(stored.bytes)|\(number)|\(count)".utf8)
    }

    private func read(_ input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let data = try input.read(upToCount: count - result.count), !data.isEmpty else { throw MediaError193.verification }
            result.append(data)
        }
        return result
    }
}
