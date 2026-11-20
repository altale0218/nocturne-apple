import AVFoundation
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Temporary originals are confined to one import/export, with device-unlock file protection.
final class PhotoAlbumStaging {
    let directory: URL
    private let manager = FileManager.default
    private static let preparation = NSLock()
    private static var preparedRoots = Set<String>()

    static func recoverAbandoned(in storageRoot: URL) throws {
        preparation.lock()
        defer { preparation.unlock() }
        let manager = FileManager.default
        let root = storageRoot.appendingPathComponent("AlbumStaging", isDirectory: true)
        let parent = try root.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink == false else { throw MediaError193.unavailable }
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                        attributes: [.protectionKey: FileProtectionType.complete])
        }
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink == false else { throw MediaError193.unavailable }
        if !Self.preparedRoots.contains(root.path) {
            var excluded = root, properties = URLResourceValues()
            properties.isExcludedFromBackup = true
            try excluded.setResourceValues(properties)
            // Only random per-transfer directories under AlbumStaging are abandoned at app startup.
            let owned = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for url in owned {
                guard let uuid = UUID(uuidString: url.lastPathComponent),
                      uuid.uuidString.lowercased() == url.lastPathComponent,
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink == false else { continue }
                try? manager.removeItem(at: url)
            }
            Self.preparedRoots.insert(root.path)
        }
    }

    init(storage: SecureStorage) throws {
        try Self.recoverAbandoned(in: storage.root)
        directory = storage.root.appendingPathComponent("AlbumStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.protectionKey: FileProtectionType.complete])
    }

    func requireSpace(_ bytes: Int64) throws {
        let attributes = try manager.attributesOfFileSystem(forPath: directory.path)
        guard let amount = attributes[.systemFreeSize] as? NSNumber,
              bytes <= amount.int64Value - 128 * 1024 * 1024 else { throw MediaError193.tooLarge }
    }

    func write(_ resource: PhotoSyncLibrary.Resource) throws -> (URL, FileHandle) {
        let ext = UTType(resource.uti)?.preferredFilenameExtension ?? (resource.filename as NSString).pathExtension
        let name = UUID().uuidString.lowercased()
        let safe = !ext.isEmpty && ext.utf8.count <= 12 && ext.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
        let url = directory.appendingPathComponent(safe ? name + "." + ext : name)
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
              else { throw MediaError193.unavailable }
        return (url, try FileHandle(forWritingTo: url))
    }

    func cleanup() { try? manager.removeItem(at: directory) }
    deinit { cleanup() }
}

final class PhotoAlbumSource: MobileAlbumTransfer.Source {
    fileprivate struct Row {
        let asset: PHAsset
        let manifest: MobileAlbumManifest
        let original: PhotoSyncLibrary.Item?
    }
    private let library: PhotoSyncLibrary
    private let storage: SecureStorage
    private let lease: Int
    private let allowICloud: Bool
    fileprivate let rows: [Row]
    private let byID: [String: Row]
    private var cursor = 0
    private var export: (id: String, zone: PhotoAlbumStaging, urls: [URL])?
    private(set) var confirmed = Set<String>()
    private(set) var unavailable: Int
    var count: Int { rows.count }
    var originalBytes: Int64? { rows.reduce(0) { $0 + $1.manifest.byteCount } }

    private init(storage: SecureStorage, library: PhotoSyncLibrary, lease: Int, allowICloud: Bool, rows: [Row], unavailable: Int) {
        self.storage = storage
        self.library = library
        self.lease = lease
        self.allowICloud = allowICloud
        self.rows = rows
        self.byID = Dictionary(rows.map { ($0.manifest.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.unavailable = unavailable
    }

    static func prepare(storage: SecureStorage, selected: PhotoSyncLibrary.Selection, namespace: String,
                        allowICloud: Bool, lease: Int, reusing prior: PhotoAlbumSource? = nil,
                        progress: (Int, Int) -> Void) async throws -> PhotoAlbumSource {
        let library = PhotoSyncLibrary(storage: storage)
        let archive = XiaomiOriginalArchive(storage: storage, lease: lease)
        var unavailable = selected.unavailable.count
        var identifiers = Set<String>()
        let assets = selected.visible.filter { identifiers.insert($0.localIdentifier).inserted }
        let previous = Dictionary((prior?.rows ?? []).map { ($0.asset.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = [Row?](repeating: nil, count: assets.count)
        try await withThrowingTaskGroup(of: (Int, Row?).self) { workers in
            @Sendable func inspect(_ offset: Int) async throws -> (Int, Row?) {
                try Task.checkCancellation()
                try storage.validateResourceLease193(lease)
                let asset = assets[offset]
                do {
                    let id = String(AppleSyncTransport.hash("album-original|\(namespace)|\(asset.localIdentifier)").prefix(32))
                    if let row = previous[asset.localIdentifier], NativeAssetRevision.same(row.asset, asset) {
                        let original = row.manifest
                        let manifest = try MobileAlbumManifest(id: id, layout: original.layout, captureMillis: original.captureMillis,
                            location: original.location, favorite: original.favorite, resources: original.resources,
                            embeddedMotion: original.embeddedMotion)
                        return (offset, Row(asset: asset, manifest: manifest, original: row.original))
                    }
                    if let related = try archive.original(for: asset) {
                        let archived = try MobileAlbumManifest(id: id, layout: .motion, captureMillis: related.captureMillis,
                            location: related.location, favorite: related.favorite, resources: related.resources,
                            embeddedMotion: related.embeddedMotion)
                        try archive.verify(archived.resources[0])
                        return (offset, Row(asset: asset, manifest: archived, original: nil))
                    }
                    let original = try await library.read(asset, lease: lease, allowICloud: allowICloud)
                    return (offset, Row(asset: asset, manifest: try MobileAlbumManifest(id: id, item: original), original: original))
                } catch {
                    try Task.checkCancellation()
                    try storage.validateResourceLease193(lease)
                    return (offset, nil)
                }
            }
            var next = min(allowICloud ? 2 : 3, assets.count), checked = 0
            for offset in 0..<next { workers.addTask { try await inspect(offset) } }
            while let (offset, row) = try await workers.next() {
                ordered[offset] = row
                if row == nil { unavailable += 1 }
                if next < assets.count {
                    let offset = next
                    next += 1
                    workers.addTask { try await inspect(offset) }
                }
                checked += 1
                if checked == assets.count || checked % 20 == 0 { progress(checked, assets.count) }
            }
        }
        let rows = ordered.compactMap { $0 }
        return PhotoAlbumSource(storage: storage, library: library, lease: lease, allowICloud: allowICloud, rows: rows, unavailable: unavailable)
    }

    func rewindForReconnect() {
        cursor = 0
        export = nil
        confirmed.removeAll(keepingCapacity: true)
    }

    func nextPage() async throws -> MobileAlbumManifest.Page? {
        try storage.validateResourceLease193(lease)
        if cursor >= rows.count { return nil }
        let start = cursor
        let maximum = min(start + MobileAlbumManifest.pageLimit, rows.count)
        // A RAW or edited asset can carry many resource headers. Size these pages by both entries and encoded bytes.
        var assets: [MobileAlbumManifest] = [], encodedBytes = 128
        while cursor < maximum {
            let item = rows[cursor].manifest
            let bytes = try JSONEncoder().encode(item).count + 1
            guard bytes < 700_000 else { throw MediaError193.tooLarge }
            if !assets.isEmpty && encodedBytes + bytes > 700_000 { break }
            assets.append(item); cursor += 1; encodedBytes += bytes
        }
        return MobileAlbumManifest.Page(schema: MobileAlbumManifest.schema, id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                                        assets: assets)
    }

    func open(_ asset: MobileAlbumManifest, part: Int) async throws -> FileHandle {
        try storage.validateResourceLease193(lease)
        guard let row = byID[asset.id], row.manifest.key == asset.key,
              row.manifest.resources.indices.contains(part) else { throw MediaError193.changed }
        if export?.id != asset.id {
            export = nil
            let zone = try PhotoAlbumStaging(storage: storage)
            try zone.requireSpace(asset.resources.reduce(0) { $0 + $1.bytes })
            var urls: [URL] = [], files: [FileHandle] = []
            defer { files.forEach { try? $0.close() } }
            for resource in asset.resources {
                let (url, handle) = try zone.write(resource)
                urls.append(url); files.append(handle)
            }
            if asset.layout == .motion {
                let archive = XiaomiOriginalArchive(storage: storage, lease: lease)
                guard let current = try library.select([row.asset.localIdentifier], lease: lease).visible.first,
                      NativeAssetRevision.same(row.asset, current),
                      let before = try archive.original(for: current), before.key == asset.key
                      else { throw MediaError193.changed }
                try archive.extract(asset.resources[0], to: files[0])
            } else {
                let handles = files
                let read = try await library.read(row.asset, lease: lease, allowICloud: allowICloud) { index, data in
                    guard handles.indices.contains(index) else { throw MediaError193.changed }
                    try handles[index].write(contentsOf: data)
                }
                let verified = try MobileAlbumManifest(id: asset.id, item: read)
                guard verified.resources == asset.resources, verified.captureMillis == asset.captureMillis,
                      verified.location == asset.location, verified.favorite == asset.favorite
                      else { throw MediaError193.changed }
                for file in files { try file.synchronize() }
            }
            export = (asset.id, zone, urls)
        }
        guard let export = export else { throw MediaError193.unavailable }
        return try FileHandle(forReadingFrom: export.urls[part])
    }

    func acknowledged(_ page: MobileAlbumManifest.Page, items: [String]) async throws {
        try storage.validateResourceLease193(lease)
        confirmed.formUnion(items)
        export = nil
    }
}

/// Hints for previously verified Photos originals, scoped to this ordinary library.
private final class KnownAlbumOriginals {
    private typealias Bucket = [String: [String]]
    private let storage: SecureStorage
    private let lease: Int
    private var loaded: [String: Bucket] = [:]
    private var pending: [String: [String: String]] = [:]

    init(storage: SecureStorage, lease: Int) {
        self.storage = storage
        self.lease = lease
    }

    private func key(_ asset: MobileAlbumManifest) -> (bucket: String, digest: String) {
        let digest = AppleSyncTransport.hash(asset.key)
        return (AppleSyncTransport.hash("ordinary-original-index/1/" + String(digest.prefix(2))), digest)
    }

    func candidates(_ asset: MobileAlbumManifest) throws -> [String] {
        let entry = key(asset)
        if loaded[entry.bucket] == nil {
            let data = try storage.albumSyncRecord(entry.bucket, lease: lease)
            loaded[entry.bucket] = try data.map { try JSONDecoder().decode(Bucket.self, from: $0) } ?? [:]
        }
        return loaded[entry.bucket]?[entry.digest] ?? []
    }

    func remember(_ asset: MobileAlbumManifest, identifier: String) {
        guard !identifier.isEmpty, identifier.utf8.count <= 256 else { return }
        let entry = key(asset)
        guard loaded[entry.bucket]?[entry.digest]?.first != identifier else { return }
        pending[entry.bucket, default: [:]][entry.digest] = identifier
    }

    func flush() {
        for (bucket, changes) in pending {
            do {
                try storage.updateAlbumSyncRecord(bucket, lease: lease) { data in
                    var items = try data.map { try JSONDecoder().decode(Bucket.self, from: $0) } ?? [:]
                    for (digest, identifier) in changes {
                        guard items[digest] != nil || items.count < 512 else { continue }
                        var identifiers = items[digest] ?? []
                        identifiers.removeAll { $0 == identifier }
                        identifiers.insert(identifier, at: 0)
                        items[digest] = Array(identifiers.prefix(3))
                    }
                    loaded[bucket] = items
                    return try JSONEncoder().encode(items)
                }
                pending.removeValue(forKey: bucket)
            } catch {
                // This index is optional. The per-source import receipt was written before the asset was accepted.
                loaded.removeValue(forKey: bucket)
            }
        }
    }
}

final class PhotoAlbumTarget: MobileAlbumTransfer.Target {
    private let library: PhotoSyncLibrary
    private let storage: SecureStorage
    private let albumID: String
    private var destinationAlbumID: String? { albumID == PhotoSyncLibrary.Album.all.identifier ? nil : albumID }
    private let peer: String
    private let lease: Int
    private let archive: XiaomiOriginalArchive
    private var index = MobileAlbumManifest.ExactIndex()
    private let knownOriginals: KnownAlbumOriginals
    private let allowICloud: Bool
    private var prepared: PhotoAlbumSource?
    private let progress: (Int, Int) -> Void
    private var originalAssets: [String: PHAsset] = [:]
    private var verifiedOriginals: [String: PhotoSyncLibrary.VerifiedRead] = [:]
    private var staged: (id: String, zone: PhotoAlbumStaging, urls: [URL])?
    private var confirmed = Set<String>()
    private var deferred = Set<String>()
    private var importedInSession = Set<String>()
    private(set) var imported = 0
    private(set) var reused = 0
    private(set) var unavailable = 0
    private(set) var metadataConflicts = 0
    private(set) var localUnverified = 0
    private(set) var pendingIssues: [String: String] = [:]
    private(set) var undated = 0
    private(set) var total = 0

    init(storage: SecureStorage, albumID: String, peer: String, lease: Int,
         allowICloud: Bool = false, prepared: PhotoAlbumSource? = nil, progress: @escaping (Int, Int) -> Void = { _, _ in }) {
        self.storage = storage
        self.library = PhotoSyncLibrary(storage: storage)
        self.albumID = albumID
        self.peer = peer
        self.lease = lease
        self.archive = XiaomiOriginalArchive(storage: storage, lease: lease)
        self.knownOriginals = KnownAlbumOriginals(storage: storage, lease: lease)
        self.allowICloud = allowICloud
        self.prepared = prepared
        self.progress = progress
    }

    func start(count: Int, unavailable: Int) async throws {
        self.unavailable = unavailable
        total = count + unavailable
        imported = 0
        reused = 0
        metadataConflicts = 0
        localUnverified = 0
        undated = 0
        pendingIssues.removeAll(keepingCapacity: true)
        guard count > 0 else { return }
        let selected = try library.albumContents(albumID, lease: lease)
        let known = try await PhotoAlbumSource.prepare(storage: storage, selected: selected,
            namespace: "received-album/" + albumID, allowICloud: allowICloud, lease: lease,
            reusing: prepared, progress: progress)
        prepared = known
        index = MobileAlbumManifest.ExactIndex()
        originalAssets.removeAll(keepingCapacity: true)
        verifiedOriginals.removeAll(keepingCapacity: true)
        localUnverified = known.unavailable
        for row in known.rows {
            index.add(row.manifest, localID: row.asset.localIdentifier, metadata: try metadataKey(row.manifest))
            originalAssets[row.asset.localIdentifier] = row.asset
            if let original = row.original {
                verifiedOriginals[row.asset.localIdentifier] = PhotoSyncLibrary.VerifiedRead(revision: row.asset, item: original)
            }
        }
    }

    // Preview never calls receive(), links an archive, or changes the Photos library.
    func preview(_ page: MobileAlbumManifest.Page) throws -> MobileAlbumTransfer.PreviewSelection {
        try storage.validateResourceLease193(lease)
        var pending: [String] = []
        var duplicate = 0
        var deferred = 0
        for item in page.assets {
            try Task.checkCancellation()
            if index.containsOriginal(item) {
                duplicate += 1
            } else if let receipt = try library.receipt(peer: peer, remoteID: item.id, lease: lease) {
                if receipt.state != .confirmedDeleted,
                   item.layout != .motion,
                   let actual = verifiedOriginals[receipt.identifier]?.item,
                   let verified = try? MobileAlbumManifest(id: item.id, item: actual),
                   verified.key == item.key {
                    duplicate += 1
                } else {
                    deferred += 1
                }
            } else if item.captureMillis == nil
                        || (item.layout != .motion && !PHAssetCreationRequest.supportsAssetResourceTypes(item.resources.map { NSNumber(value: $0.role) })) {
                deferred += 1
            } else {
                pending.append(item.id)
            }
        }
        return .init(pending: pending, duplicates: duplicate, deferred: deferred)
    }

    func plan(_ page: MobileAlbumManifest.Page) async throws -> [String] {
        confirmed.removeAll(keepingCapacity: true)
        deferred.removeAll(keepingCapacity: true)
        var wanted: [String] = []
        var scheduled: [String: String] = [:]
        for manifest in page.assets {
            try Task.checkCancellation()
            if manifest.captureMillis == nil {
                undated += 1
                deferItem(manifest, reason: "缺少可信拍摄日期")
                continue
            }
            if let receipt = try library.receipt(peer: peer, remoteID: manifest.id, lease: lease) {
                if receipt.state == .confirmedDeleted {
                    deferItem(manifest, reason: "以前已确认删除")
                    continue
                }
                do {
                    let native: PhotoSyncLibrary.Item
                    if manifest.layout == .motion {
                        guard let original = try archive.relation(peer: peer, peerItem: manifest.id),
                              original.key == manifest.key, original.embeddedMotion == manifest.embeddedMotion
                              else { throw MediaError193.changed }
                        try archive.verify(manifest.resources[0])
                        native = receipt.item
                    } else {
                        native = try manifest.nativeItem()
                    }
                    _ = try await library.receive(native, files: [], protectedDirectory: storage.root, albumID: destinationAlbumID,
                                                  peer: peer, remoteID: manifest.id, lease: lease,
                                                  proof: verifiedOriginals[receipt.identifier])
                    let assets = try library.select([receipt.identifier], lease: lease).visible
                    if let asset = assets.first {
                        if manifest.layout == .motion { try archive.link(manifest, to: asset) }
                        index.add(manifest, localID: asset.localIdentifier, metadata: try metadataKey(manifest))
                        originalAssets[asset.localIdentifier] = asset
                        knownOriginals.remember(manifest, identifier: asset.localIdentifier)
                    }
                    confirmed.insert(manifest.id)
                    if importedInSession.contains(manifest.id) { imported += 1 }
                    else { reused += 1 }
                } catch is PhotoSyncLibrary.CreatedButUnverified {
                    try Task.checkCancellation()
                    try storage.validateResourceLease193(lease)
                    deferItem(manifest, reason: "照片已写入，系统回读尚未通过")
                } catch MediaError193.changed {
                    deferItem(manifest, reason: "原件指纹与旧回执不符")
                }
                continue
            }
            let metadata = try metadataKey(manifest)
            if let id = index.match(manifest, metadata: metadata), let match = originalAssets[id] {
                do {
                    try await reuse(match, manifest: manifest)
                    continue
                } catch MediaError193.verification {
                    // The original was checked but Photos could not confirm an equivalent placement.
                }
            }
            if index.containsOriginal(manifest) {
                if destinationAlbumID == nil { confirmMetadataDifference(manifest) }
                else { deferItem(manifest, reason: "原件已存在，专辑位置或信息不同") }
                continue
            }
            if try await reuseKnownOriginal(manifest, metadata: metadata) {
                continue
            }
            if manifest.layout == .motion, try await restoreArchivedMotion(manifest) {
                continue
            }
            if manifest.layout != .motion,
               !PHAssetCreationRequest.supportsAssetResourceTypes(manifest.resources.map { NSNumber(value: $0.role) }) {
                deferItem(manifest)
                continue
            }
            if let placement = scheduled[manifest.transferKey] {
                if placement != metadata { deferItem(manifest, reason: "同批原件的拍摄信息不同") }
            } else {
                scheduled[manifest.transferKey] = metadata
                wanted.append(manifest.id)
            }
        }
        return wanted
    }

    private func confirmMetadataDifference(_ asset: MobileAlbumManifest) {
        if confirmed.insert(asset.id).inserted {
            metadataConflicts += 1
            reused += 1
        }
    }

    private func deferItem(_ asset: MobileAlbumManifest, reason: String = "系统无法读取或写入原件") {
        if deferred.insert(asset.id).inserted { unavailable += 1 }
        if pendingIssues.count < 100 {
            let date = asset.captureMillis.map {
                Date(timeIntervalSince1970: Double($0) / 1_000).formatted(date: .numeric, time: .shortened)
            } ?? "日期未知"
            pendingIssues[asset.id] = "\(date) · \(asset.layout.rawValue) · \(asset.id.prefix(8)) · \(reason)"
        }
    }

    private func reuseKnownOriginal(_ manifest: MobileAlbumManifest, metadata: String) async throws -> Bool {
        let candidates = try knownOriginals.candidates(manifest)
        guard !candidates.isEmpty else { return false }
        let selection = try library.select(Set(candidates), lease: lease)
        var conflict = false
        var unverified = selection.limited && !selection.unavailable.isEmpty
        for candidate in selection.visible {
            try Task.checkCancellation()
            do {
                if manifest.layout == .motion {
                    guard let original = try archive.original(for: candidate), original.key == manifest.key else { continue }
                    guard try metadataKey(original) == metadata else { conflict = true; continue }
                } else {
                    let item = try await library.read(candidate, lease: lease, allowICloud: allowICloud)
                    let local = try MobileAlbumManifest(id: manifest.id, item: item)
                    guard local.key == manifest.key else { continue }
                    guard try metadataKey(local) == metadata else { conflict = true; continue }
                    verifiedOriginals[candidate.localIdentifier] = PhotoSyncLibrary.VerifiedRead(revision: candidate, item: item)
                }
                try await reuse(candidate, manifest: manifest)
                index.add(manifest, localID: candidate.localIdentifier, metadata: metadata)
                originalAssets[candidate.localIdentifier] = candidate
                return true
            } catch {
                try Task.checkCancellation()
                try storage.validateResourceLease193(lease)
                unverified = true
            }
        }
        if conflict {
            if destinationAlbumID == nil { confirmMetadataDifference(manifest) }
            else { deferItem(manifest, reason: "原件已存在，专辑位置或信息不同") }
        }
        else if unverified { deferItem(manifest, reason: "本机候选原件暂不可读") }
        return conflict || unverified
    }

    private func restoreArchivedMotion(_ asset: MobileAlbumManifest) async throws -> Bool {
        guard let original = try archive.relation(peer: peer, peerItem: asset.id) else { return false }
        guard original.key == asset.key, try metadataKey(original) == metadataKey(asset) else {
            deferItem(asset, reason: "旧同步归档与对方当前原件不同")
            return true
        }
        // The protected original was already committed before a previous Photos import.
        // Restore its verified bytes locally so a retry only repeats the conversion.
        let zone = try PhotoAlbumStaging(storage: storage)
        try zone.requireSpace(asset.byteCount * 4)
        let (url, output) = try zone.write(asset.resources[0])
        do {
            defer { try? output.close() }
            try archive.extract(asset.resources[0], to: output)
        }
        defer { withExtendedLifetime(zone) {} }
        do {
            try await publish(asset, urls: [url], zone: zone)
        } catch is MobileAlbumTransfer.Unavailable {
            // The original is archived. A declined native import must not claim a Photos receipt.
        }
        return true
    }

    func stage(_ asset: MobileAlbumManifest, part: Int) async throws -> FileHandle {
        try storage.validateResourceLease193(lease)
        guard asset.resources.indices.contains(part) else { throw MediaError193.malformed }
        if part == 0 {
            guard staged == nil else { throw MediaError193.changed }
            let zone = try PhotoAlbumStaging(storage: storage)
            try zone.requireSpace(asset.resources.reduce(0) { $0 + $1.bytes } * (asset.layout == .motion ? 5 : 2))
            staged = (asset.id, zone, [])
        }
        guard let value = staged, value.id == asset.id, value.urls.count == part else { throw MediaError193.changed }
        let (url, output) = try value.zone.write(asset.resources[part])
        staged?.urls.append(url)
        return output
    }

    func commit(_ asset: MobileAlbumManifest) async throws {
        guard let value = staged, value.id == asset.id, value.urls.count == asset.resources.count
              else { throw MediaError193.changed }
        defer { staged = nil }
        if asset.layout == .motion {
            try archive.preserve(value.urls[0], resource: asset.resources[0])
            try archive.remember(asset, peer: peer)
        }
        try await publish(asset, urls: value.urls, zone: value.zone)
    }

    private func publish(_ asset: MobileAlbumManifest, urls: [URL], zone: PhotoAlbumStaging) async throws {
        let native: PhotoSyncLibrary.Item
        let files: [URL]
        if asset.layout == .motion {
            do {
                let converted = try await XiaomiLivePhoto.make(asset, from: urls[0], in: zone.directory)
                native = converted.item; files = converted.files
            } catch MediaError193.unavailable {
                deferItem(asset); throw MobileAlbumTransfer.Unavailable()
            } catch MediaError193.verification {
                deferItem(asset); throw MobileAlbumTransfer.Unavailable()
            } catch MediaError193.malformed {
                deferItem(asset); throw MobileAlbumTransfer.Unavailable()
            } catch let error as NSError where error.domain == AVFoundationErrorDomain {
                try Task.checkCancellation()
                deferItem(asset); throw MobileAlbumTransfer.Unavailable()
            }
        } else {
            native = try asset.nativeItem(); files = urls
        }
        let identifier: String
        do {
            identifier = try await library.receive(native, files: files, protectedDirectory: zone.directory,
                                                   albumID: destinationAlbumID, peer: peer, remoteID: asset.id, lease: lease)
        } catch is PhotoSyncLibrary.CreatedButUnverified {
            try Task.checkCancellation()
            try storage.validateResourceLease193(lease)
            deferItem(asset); throw MobileAlbumTransfer.Unavailable()
        } catch let error as PHPhotosError where [.invalidResource, .missingResource, .changeNotSupported, .requestNotSupportedForAsset].contains(error.code) {
            try Task.checkCancellation()
            try storage.validateResourceLease193(lease)
            deferItem(asset); throw MobileAlbumTransfer.Unavailable()
        }
        confirmed.insert(asset.id)
        importedInSession.insert(asset.id)
        imported += 1
        if let item = try library.select([identifier], lease: lease).visible.first {
            if asset.layout == .motion { try archive.link(asset, to: item) }
            knownOriginals.remember(asset, identifier: identifier)
            index.add(asset, localID: identifier, metadata: try metadataKey(asset))
            originalAssets[identifier] = item
        }
    }

    private func reuse(_ asset: PHAsset, manifest: MobileAlbumManifest) async throws {
        let native: PhotoSyncLibrary.Item
        if manifest.layout == .motion {
            guard let original = try archive.original(for: asset), original.key == manifest.key,
                  original.captureMillis == manifest.captureMillis, original.favorite == manifest.favorite,
                  original.location == manifest.location, original.embeddedMotion == manifest.embeddedMotion
                  else { throw MediaError193.verification }
            try archive.verify(manifest.resources[0])
            try archive.remember(manifest, peer: peer)
            native = try await library.read(asset, lease: lease)
        } else {
            native = try manifest.nativeItem()
        }
        try await library.useExisting(asset, item: native, peer: peer, remoteID: manifest.id, albumID: destinationAlbumID, lease: lease,
                                      proof: verifiedOriginals[asset.localIdentifier])
        knownOriginals.remember(manifest, identifier: asset.localIdentifier)
        confirmed.insert(manifest.id)
        reused += 1
    }

    private func metadataKey(_ asset: MobileAlbumManifest) throws -> String {
        struct Metadata: Codable {
            let date: Int64?
            let location: PhotoSyncLibrary.Location?
            let favorite: Bool
            let motion: MobileAlbumManifest.EmbeddedMotion?
        }
        let options = JSONEncoder()
        options.outputFormatting = [.sortedKeys]
        let plain = try options.encode(Metadata(date: asset.captureMillis, location: asset.location,
                                                favorite: asset.favorite, motion: asset.embeddedMotion))
        return AppleSyncTransport.hash(String(decoding: plain, as: UTF8.self))
    }

    func finish(_ page: MobileAlbumManifest.Page) async throws -> [String] {
        for manifest in page.assets where !confirmed.contains(manifest.id) && !deferred.contains(manifest.id) {
            if let match = index.match(manifest, metadata: try metadataKey(manifest)), let asset = originalAssets[match],
               try library.receipt(peer: peer, remoteID: manifest.id, lease: lease) == nil {
                do { try await reuse(asset, manifest: manifest) }
                catch MediaError193.verification { deferItem(manifest) }
            }
        }
        knownOriginals.flush()
        return confirmed.sorted()
    }

    func abort() async {
        staged = nil
        knownOriginals.flush()
    }
}

/// Exact matches use native original resources. Thumbnail fingerprints only produce suggestions.
enum PhotoAlbumDuplicates {
    struct Fingerprint {
        let tone: UInt64
        let edge: UInt64
        let average: Int

        init(tone: UInt64, edge: UInt64, average: Int) {
            self.tone = tone; self.edge = edge; self.average = average
        }

        init(_ pixels: [UInt8]) {
            let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
            var levels: UInt64 = 0, slopes: UInt64 = 0
            for row in 0..<8 {
                for column in 0..<8 {
                    let pixel = row * 9 + column
                    let bit = UInt64(1) << (row * 8 + column)
                    if Int(pixels[pixel]) > mean { levels |= bit }
                    if pixels[pixel] > pixels[pixel + 1] { slopes |= bit }
                }
            }
            self.init(tone: levels, edge: slopes, average: mean)
        }
    }

    struct Entry {
        let index: Int
        let raw: String?
        let footprint: Fingerprint?
        let video: Bool
        let aspect: Double
        let duration: Double
    }

    struct Group {
        let exact: Bool
        let members: [Int]
        let video: Bool
    }

    struct Results {
        let groups: [Group]
        let unavailable: Int
        let approximateIncomplete: Bool
    }

    static func groups(_ entries: [Entry], unavailable: Int) throws -> Results {
        var exact: [String: [Entry]] = [:], representatives: [Entry] = []
        for entry in entries {
            try Task.checkCancellation()
            if let raw = entry.raw { exact[raw, default: []].append(entry) }
            else { representatives.append(entry) }
        }
        var output: [Group] = []
        for bucket in exact.values {
            if bucket.count > 1 {
                output.append(Group(exact: true, members: bucket.map(\.index), video: bucket[0].video))
            }
            if let representative = bucket.first(where: { $0.footprint != nil }) ?? bucket.first {
                representatives.append(representative)
            }
        }
        representatives.sort { $0.index < $1.index }

        // Seven bands guarantee a candidate for any tone hash within six differing bits.
        var bands: [Int: [Int]] = [:], candidates: [[Entry]] = []
        var incomplete = false, comparisons = 0
        for entry in representatives {
            try Task.checkCancellation()
            guard let hash = entry.footprint else { incomplete = true; continue }
            let keys = (0..<7).map { band -> Int in
                let bits = band == 6 ? 10 : 9
                return (entry.video ? 8192 : 0) + (band << 10) + Int((hash.tone >> (band * 9)) & UInt64((1 << bits) - 1))
            }
            var possible = Set<Int>()
            for key in keys {
                for group in bands[key, default: []] { possible.insert(group) }
            }
            let ordered = possible.sorted()
            if ordered.count > 512 { incomplete = true }
            var match: Int?
            for index in ordered.prefix(512) {
                if candidates[index].count >= 128 { incomplete = true; continue }
                var close = true
                for member in candidates[index] {
                    comparisons += 1
                    if !similar(entry, member) { close = false; break }
                }
                if comparisons >= 2_000_000 { incomplete = true; break }
                if close { match = index; break }
            }
            if comparisons >= 2_000_000 { break }
            if let match = match { candidates[match].append(entry); continue }
            let identifier = candidates.count
            candidates.append([entry])
            for key in keys {
                if bands[key, default: []].count < 512 { bands[key, default: []].append(identifier) }
                else { incomplete = true }
            }
        }
        for candidate in candidates where candidate.count > 1 {
            output.append(Group(exact: false, members: candidate.map(\.index), video: candidate[0].video))
        }
        output.sort {
            if $0.exact != $1.exact { return $0.exact }
            return ($0.members.first ?? 0) < ($1.members.first ?? 0)
        }
        return Results(groups: output, unavailable: unavailable, approximateIncomplete: incomplete)
    }

    private static func similar(_ first: Entry, _ second: Entry) -> Bool {
        guard let a = first.footprint, let b = second.footprint, first.video == second.video,
              first.aspect.isFinite, second.aspect.isFinite, first.aspect > 0, second.aspect > 0
              else { return false }
        let ratio = first.aspect / second.aspect
        guard ratio >= 0.965, ratio <= 1.036, abs(a.average - b.average) <= 24,
              (a.tone ^ b.tone).nonzeroBitCount <= 6, (a.edge ^ b.edge).nonzeroBitCount <= 8
              else { return false }
        return !first.video || abs(first.duration - second.duration) <= max(0.25, 0.015 * max(first.duration, second.duration))
    }

    static func scan(storage: SecureStorage, albumID: String, lease: Int,
                     progress: (String, Int, Int) -> Void) async throws -> (assets: [PHAsset], result: Results, unreadable: [Int], visualUnavailable: [Int]) {
        let library = PhotoSyncLibrary(storage: storage)
        let selected = try library.albumContents(albumID, lease: lease)
        let source = try await PhotoAlbumSource.prepare(storage: storage, selected: selected,
                namespace: "review/" + albumID, allowICloud: false, lease: lease) { done, total in
            progress("核验原片", done, total)
        }
        let assets = selected.visible
        let byIdentifier = Dictionary(source.rows.map { ($0.asset.localIdentifier, $0.manifest.key) }, uniquingKeysWith: { first, _ in first })
        let raw = assets.map { byIdentifier[$0.localIdentifier] }
        let work = visualWorkItems(raw)
        let images = PHImageManager.default()
        let entries = try await withThrowingTaskGroup(of: [Entry].self) { workers in
            @Sendable func make(_ indexes: [Int]) async throws -> [Entry] {
                var representativeFound = false
                var entries: [Entry] = []
                entries.reserveCapacity(indexes.count)
                for index in indexes {
                    try Task.checkCancellation()
                    try storage.validateResourceLease193(lease)
                    let asset = assets[index]
                    let footprint = representativeFound ? nil : await thumbnail(asset, images: images)
                    if footprint != nil { representativeFound = true }
                    entries.append(Entry(index: index, raw: raw[index], footprint: footprint,
                        video: asset.mediaType == .video, aspect: Double(asset.pixelWidth) / Double(max(1, asset.pixelHeight)),
                        duration: asset.duration))
                }
                return entries
            }
            var next = min(3, work.count), reported = 0, entries: [Entry] = []
            for index in 0..<next { workers.addTask { try await make(work[index]) } }
            while let batch = try await workers.next() {
                entries.append(contentsOf: batch)
                if next < work.count {
                    let index = next
                    next += 1
                    workers.addTask { try await make(work[index]) }
                }
                if entries.count == assets.count || entries.count >= reported + 40 {
                    reported = entries.count
                    progress("匹配相似项目", entries.count, assets.count)
                }
            }
            return entries.sorted { $0.index < $1.index }
        }
        progress("比较相似指纹", 0, max(1, entries.count))
        let result = try groups(entries, unavailable: source.unavailable)
        progress("比较相似指纹", max(1, entries.count), max(1, entries.count))
        let visualUnavailable = work.compactMap { batch -> Int? in
            guard !batch.contains(where: { entries[$0].footprint != nil }) else { return nil }
            return batch.first
        }
        return (assets, result, entries.filter { $0.raw == nil }.map(\.index), visualUnavailable)
    }

    static func visualWorkItems(_ originals: [String?]) -> [[Int]] {
        var byOriginal: [String: Int] = [:]
        var batches: [[Int]] = []
        for (index, original) in originals.enumerated() {
            if let original, let batch = byOriginal[original] {
                batches[batch].append(index)
            } else {
                if let original { byOriginal[original] = batches.count }
                batches.append([index])
            }
        }
        return batches
    }

    private static func thumbnail(_ asset: PHAsset, images: PHImageManager) async -> Fingerprint? {
        await withCheckedContinuation { complete in
            DispatchQueue.global(qos: .utility).async {
                let request = PHImageRequestOptions()
                request.isSynchronous = true
                request.isNetworkAccessAllowed = false
                request.deliveryMode = .fastFormat
                request.resizeMode = .fast
                let result: Fingerprint? = autoreleasepool {
                    var fingerprint: Fingerprint?
                    images.requestImage(for: asset, targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFit, options: request) { image, _ in
                    guard let source = image?.cgImage else { return }
                    var luma = Array(repeating: UInt8(0), count: 72)
                    let drawn = luma.withUnsafeMutableBytes { bytes -> Bool in
                        guard let canvas = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                                      bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
                              else { return false }
                        canvas.interpolationQuality = .medium
                        canvas.draw(source, in: CGRect(x: 0, y: 0, width: 9, height: 8))
                        return true
                    }
                    if drawn { fingerprint = Fingerprint(luma) }
                    }
                    return fingerprint
                }
                complete.resume(returning: result)
            }
        }
    }
}
