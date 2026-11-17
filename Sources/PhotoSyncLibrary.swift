import Foundation
import Photos
import CoreLocation

/// Ordinary-library PhotoKit operations for the album sync transport.
final class PhotoSyncLibrary {
    static let maximumAssetBytes: Int64 = 120 * 1024 * 1024 * 1024

    struct Location: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?

        init(_ location: CLLocation) {
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
            altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        }

        init(latitude: Double, longitude: Double, altitude: Double?) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }

        func validated() throws -> CLLocationCoordinate2D {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate),
                  altitude?.isFinite ?? true else { throw MediaError193.malformed }
            return coordinate
        }
    }

    struct Resource: Codable, Equatable {
        let role: Int
        let filename: String
        let uti: String
        let bytes: Int64
        let sha256: String

        var byteIdentity: String { "\(role):\(bytes):\(sha256)" }

        func validate() throws {
            guard PHAssetResourceType(rawValue: role) != nil, !filename.isEmpty, filename.utf8.count <= 4096,
                  filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
                  !filename.utf8.contains(0), !uti.isEmpty, uti.utf8.count <= 256, !uti.utf8.contains(0),
                  bytes > 0, bytes <= PhotoSyncLibrary.maximumAssetBytes, sha256.utf8.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                  else { throw MediaError193.malformed }
        }
    }

    struct Item: Codable {
        let kind: Int
        let live: Bool
        let creation: Date?
        let location: Location?
        let favorite: Bool
        let resources: [Resource]

        var byteIdentity: [String] { resources.map(\.byteIdentity).sorted() }

        func validate() throws {
            guard [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue].contains(kind),
                  !resources.isEmpty, resources.count <= 64, creation?.timeIntervalSince1970.isFinite ?? true
                  else { throw MediaError193.malformed }
            _ = try location?.validated()
            var total: Int64 = 0
            var types = Set<Int>()
            for resource in resources {
                try resource.validate()
                guard resource.bytes <= PhotoSyncLibrary.maximumAssetBytes - total else { throw MediaError193.tooLarge }
                total += resource.bytes
                types.insert(resource.role)
            }
            let photo = types.contains(PHAssetResourceType.photo.rawValue) ||
                types.contains(PHAssetResourceType.fullSizePhoto.rawValue)
            let video = types.contains(PHAssetResourceType.video.rawValue) ||
                types.contains(PHAssetResourceType.fullSizeVideo.rawValue)
            let motion = types.contains(PHAssetResourceType.pairedVideo.rawValue) ||
                types.contains(PHAssetResourceType.fullSizePairedVideo.rawValue) ||
                types.contains(PHAssetResourceType.adjustmentBasePairedVideo.rawValue)
            guard kind == PHAssetMediaType.image.rawValue ? photo && live == motion : video && !live && !motion
                  else { throw MediaError193.malformed }
        }
    }

    struct Selection {
        let visible: [PHAsset]
        let unavailable: Set<String>
        let limited: Bool
    }

    struct CreatedButUnverified: Error {
        let localIdentifier: String
        let underlying: Error
    }

    private let storage: SecureStorage

    init(storage: SecureStorage) { self.storage = storage }

    static func allowsReadWrite(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    private func check(_ lease: Int) throws {
        try storage.validateResourceLease193(lease)
        guard !storage.envelope.privateMode else { throw MediaError193.wrongMode }
        guard Self.allowsReadWrite(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            throw MediaError193.unavailable
        }
    }

    func select(_ ids: Set<String>, lease: Int) throws -> Selection {
        try check(lease)
        guard ids.count <= 100_000, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else {
            throw MediaError193.malformed
        }
        let ordered = ids.sorted()
        var found: [PHAsset] = []
        for start in stride(from: 0, to: ordered.count, by: 256) {
            try check(lease)
            let end = min(start + 256, ordered.count)
            let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(ordered[start..<end]), options: nil)
            result.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video { found.append(asset) }
            }
        }
        try check(lease)
        return Selection(visible: found.sorted { $0.localIdentifier < $1.localIdentifier },
                         unavailable: ids.subtracting(found.map(\.localIdentifier)),
                         limited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited)
    }

    struct Album {
        let identifier: String
        let title: String
        var isLibraryScope: Bool { identifier == Self.all.identifier || identifier == Self.recent.identifier }
        static let all = Album(identifier: "nocturne:photos:all", title: "全部照片与视频（仅发送）")
        static let recent = Album(identifier: "nocturne:photos:recent", title: "最近拍摄 · 30 天（仅发送）")
    }

    func albums(lease: Int) throws -> [Album] {
        try check(lease)
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var values: [Album] = []
        result.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle {
                values.append(Album(identifier: collection.localIdentifier, title: title))
            }
        }
        return values.sorted { ($0.title, $0.identifier) < ($1.title, $1.identifier) }
    }

    func albumContents(_ identifier: String, lease: Int) throws -> Selection {
        try check(lease)
        let source: PHFetchResult<PHAsset>
        if identifier == Album.all.identifier {
            source = PHAsset.fetchAssets(with: nil)
        } else if identifier == Album.recent.identifier {
            let options = PHFetchOptions()
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            options.predicate = NSPredicate(format: "creationDate >= %@", cutoff as NSDate)
            source = PHAsset.fetchAssets(with: options)
        } else {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
                  else { throw MediaError193.unavailable }
            source = PHAsset.fetchAssets(in: album, options: nil)
        }
        guard source.count <= 100_000 else { throw MediaError193.tooLarge }
        var assets: [PHAsset] = []
        source.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video { assets.append(asset) }
        }
        return Selection(visible: assets, unavailable: [],
                         limited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited)
    }

    func createAlbum(_ title: String, lease: Int) async throws -> Album {
        try check(lease)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256,
              title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
              else { throw MediaError193.malformed }
        return try await withCheckedThrowingContinuation { continuation in
            var identifier: String?
            var rejection: Error?
            PHPhotoLibrary.shared().performChanges({
                do {
                    try self.check(lease)
                    let change = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    identifier = change.placeholderForCreatedAssetCollection.localIdentifier
                } catch { rejection = error }
            }) { success, error in
                if success, rejection == nil, let identifier = identifier {
                    continuation.resume(returning: Album(identifier: identifier, title: title))
                } else {
                    continuation.resume(throwing: rejection ?? error ?? MediaError193.unavailable)
                }
            }
        }
    }

    func removeAlbumMembership(_ originals: [PHAsset], albumID: String, lease: Int) async throws {
        try check(lease)
        let ids = Set(originals.map(\.localIdentifier))
        guard !ids.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var rejection: Error?
            PHPhotoLibrary.shared().performChanges({
                do {
                    try self.check(lease)
                    let current = try self.select(ids, lease: lease)
                    let byID = Dictionary(uniqueKeysWithValues: current.visible.map { ($0.localIdentifier, $0) })
                    guard current.unavailable.isEmpty,
                          originals.allSatisfy({ original in
                              byID[original.localIdentifier].map { NativeAssetRevision.same(original, $0) } == true
                          }),
                          let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                          album.canPerform(.removeContent),
                          let change = PHAssetCollectionChangeRequest(for: album) else { throw MediaError193.unavailable }
                    try self.check(lease)
                    change.removeAssets(current.visible as NSArray)
                } catch { rejection = error }
            }) { success, error in
                if success, rejection == nil { continuation.resume() }
                else { continuation.resume(throwing: rejection ?? error ?? MediaError193.unavailable) }
            }
        }
    }

    func deleteSystemOriginals(_ originals: [PHAsset], lease: Int) async throws -> Set<String> {
        try check(lease)
        try Task.checkCancellation()
        let removed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
            NativeAssetRevision.delete(originals, check: { try self.check(lease) }) { continuation.resume(with: $0) }
        }
        try storage.markConfirmedAlbumDeletions(removed, lease: lease)
        return removed
    }

    func read(_ asset: PHAsset, lease: Int, allowICloud: Bool = false,
              consume: ((Int, Data) throws -> Void)? = nil) async throws -> Item {
        try check(lease)
        guard let current = try select([asset.localIdentifier], lease: lease).visible.first,
              NativeAssetRevision.same(asset, current) else { throw MediaError193.changed }
        let parts = PHAssetResource.assetResources(for: current)
        guard !parts.isEmpty, parts.count <= 64 else { throw MediaError193.unavailable }
        var remaining = Self.maximumAssetBytes
        var resources: [Resource] = []
        for (index, part) in parts.enumerated() {
            let request = ResourceRead(maximum: remaining) { data in
                try self.check(lease)
                try consume?(index, data)
            }
            let digest = try await request.run(part, allowICloud: allowICloud)
            remaining -= digest.bytes
            resources.append(Resource(role: part.type.rawValue, filename: part.originalFilename,
                                      uti: part.uniformTypeIdentifier, bytes: digest.bytes, sha256: digest.sha256))
        }
        try check(lease)
        guard let latest = try select([asset.localIdentifier], lease: lease).visible.first,
              NativeAssetRevision.same(current, latest) else { throw MediaError193.changed }
        let item = Item(kind: latest.mediaType.rawValue, live: latest.mediaSubtypes.contains(.photoLive),
                        creation: latest.creationDate, location: latest.location.map(Location.init),
                        favorite: latest.isFavorite, resources: resources)
        try item.validate()
        return item
    }

    struct VerifiedRead {
        let revision: PHAsset
        let item: Item
    }

    func verifyCreated(_ identifier: String, against expected: Item, lease: Int, proof: VerifiedRead? = nil) async throws {
        guard let asset = try select([identifier], lease: lease).visible.first else { throw MediaError193.verification }
        let actual: Item
        if let proof = proof, NativeAssetRevision.same(proof.revision, asset) {
            actual = proof.item
        } else {
            actual = try await read(asset, lease: lease)
        }
        guard actual.kind == expected.kind, actual.live == expected.live, actual.byteIdentity == expected.byteIdentity,
              actual.favorite == expected.favorite, Self.sameDate(actual.creation, expected.creation),
              Self.sameLocation(actual.location, expected.location) else { throw MediaError193.verification }
    }

    static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return lhs == nil && rhs == nil }
        return (lhs.timeIntervalSince1970 * 1_000).rounded() == (rhs.timeIntervalSince1970 * 1_000).rounded()
    }

    private static func sameLocation(_ lhs: Location?, _ rhs: Location?) -> Bool {
        guard let rhs = rhs else { return lhs == nil }
        guard let lhs = lhs, abs(lhs.latitude - rhs.latitude) < 0.000000001,
              abs(lhs.longitude - rhs.longitude) < 0.000000001 else { return false }
        guard let altitude = rhs.altitude else { return true }
        guard let value = lhs.altitude else { return false }
        return abs(value - altitude) < 0.001
    }

    /// A recorded PhotoKit identifier allows a retry to verify the existing asset before importing again.
    func create(_ item: Item, files: [URL], protectedDirectory: URL, albumID: String?, lease: Int,
                recordCreated: (String) throws -> Void) async throws -> String {
        try item.validate()
        try check(lease)
        try Task.checkCancellation()
        // Photos may supply an import time when creationDate is omitted. Leave undated originals on the source.
        guard let captured = item.creation else { throw MediaError193.unavailable }
        guard files.count == item.resources.count, Set(files).count == files.count,
              PHAssetCreationRequest.supportsAssetResourceTypes(item.resources.map { NSNumber(value: $0.role) })
              else { throw MediaError193.unavailable }
        let base = protectedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = try base.resourceValues(forKeys: [.isDirectoryKey])
        guard base.isFileURL, directory.isDirectory == true else { throw MediaError193.unavailable }
        var parts: [(PHAssetResourceType, Resource, URL)] = []
        let coordinate = try item.location?.validated()
        for (part, file) in zip(item.resources, files) {
            let url = file.standardizedFileURL
            guard url.isFileURL, url.resolvingSymlinksInPath().deletingLastPathComponent() == base,
                  let role = PHAssetResourceType(rawValue: part.role)
                  else { throw MediaError193.malformed }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = attributes[.protectionKey]
            let protectionName = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  values.fileSize.map({ Int64($0) }) == part.bytes,
                  protectionName == FileProtectionType.complete.rawValue else { throw MediaError193.verification }
            let hash = SHA193()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes: Int64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try check(lease)
                try Task.checkCancellation()
                guard Int64(data.count) <= part.bytes - bytes else { throw MediaError193.verification }
                bytes += Int64(data.count)
                hash.append(data)
            }
            guard bytes == part.bytes, hash.finish() == part.sha256 else { throw MediaError193.verification }
            parts.append((role, part, url))
        }

        let checkedParts = parts
        let identifier = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var identifier: String?
            var rejection: Error?
            PHPhotoLibrary.shared().performChanges({
                do {
                    try self.check(lease)
                    var albumChange: PHAssetCollectionChangeRequest?
                    if let albumID = albumID {
                        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
                        guard let album = albums.firstObject, album.canPerform(.addContent),
                              let request = PHAssetCollectionChangeRequest(for: album)
                              else { throw MediaError193.unavailable }
                        albumChange = request
                    }
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = captured
                    request.isFavorite = item.favorite
                    request.location = coordinate.map { coordinate in
                        CLLocation(coordinate: coordinate, altitude: item.location?.altitude ?? 0,
                                                      horizontalAccuracy: 0, verticalAccuracy: item.location?.altitude == nil ? -1 : 0,
                                                      timestamp: captured)
                    }
                    for (role, part, file) in checkedParts {
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = part.filename
                        options.uniformTypeIdentifier = part.uti
                        options.shouldMoveFile = false
                        request.addResource(with: role, fileURL: file, options: options)
                    }
                    if let placeholder = request.placeholderForCreatedAsset {
                        identifier = placeholder.localIdentifier
                        albumChange?.addAssets([placeholder] as NSArray)
                    }
                } catch { rejection = error }
            }) { success, error in
                if success, rejection == nil, let id = identifier { continuation.resume(returning: id) }
                else { continuation.resume(throwing: rejection ?? error ?? MediaError193.unavailable) }
            }
        }

        do {
            try recordCreated(identifier)
            try await verifyCreated(identifier, against: item, lease: lease)
            return identifier
        } catch {
            throw CreatedButUnverified(localIdentifier: identifier, underlying: error)
        }
    }

    enum ReceiptState: String, Codable {
        case waitingForVerification, verified, reusedOriginal, confirmedDeleted
    }

    struct ImportReceipt: Codable {
        let identifier: String
        let item: Item
        let albumID: String?
        let state: ReceiptState
    }

    private func receiptKey(peer: String, remoteID: String) throws -> String {
        guard AppleSyncTransport.isHex(peer, length: 32), AppleSyncTransport.isHex(remoteID, length: 32)
              else { throw MediaError193.malformed }
        return AppleSyncTransport.hash("receipt/\(peer)/\(remoteID)")
    }

    func receipt(peer: String, remoteID: String, lease: Int) throws -> ImportReceipt? {
        let key = try receiptKey(peer: peer, remoteID: remoteID)
        guard let data = try storage.albumSyncRecord(key, lease: lease) else { return nil }
        let record = try JSONDecoder().decode(ImportReceipt.self, from: data)
        if record.state != .confirmedDeleted,
           try storage.hasConfirmedAlbumDeletion(record.identifier, lease: lease),
           try select([record.identifier], lease: lease).visible.isEmpty {
            return ImportReceipt(identifier: record.identifier, item: record.item,
                                 albumID: record.albumID, state: .confirmedDeleted)
        }
        return record
    }

    private func put(_ receipt: ImportReceipt, peer: String, remoteID: String, lease: Int) throws {
        let key = try receiptKey(peer: peer, remoteID: remoteID)
        try storage.writeAlbumSyncRecord(JSONEncoder().encode(receipt), name: key, lease: lease)
    }

    func receive(_ item: Item, files: [URL], protectedDirectory: URL, albumID: String?,
                 peer: String, remoteID: String, lease: Int, proof: VerifiedRead? = nil) async throws -> String {
        try check(lease)
        if let previous = try receipt(peer: peer, remoteID: remoteID, lease: lease) {
            guard previous.state != .confirmedDeleted, previous.item.byteIdentity == item.byteIdentity
                  else { throw MediaError193.changed }
            do {
                try await verifyCreated(previous.identifier, against: item, lease: lease, proof: proof)
                if let destination = albumID, previous.albumID != destination {
                    guard let asset = try select([previous.identifier], lease: lease).visible.first
                          else { throw MediaError193.unavailable }
                    try await addExisting(asset, to: destination, lease: lease)
                }
                if previous.state == .waitingForVerification {
                    try put(ImportReceipt(identifier: previous.identifier, item: item, albumID: previous.albumID, state: .verified),
                            peer: peer, remoteID: remoteID, lease: lease)
                }
                return previous.identifier
            } catch {
                throw CreatedButUnverified(localIdentifier: previous.identifier, underlying: error)
            }
        }
        let identifier = try await create(item, files: files, protectedDirectory: protectedDirectory, albumID: albumID,
                                          lease: lease) { identifier in
            try self.put(ImportReceipt(identifier: identifier, item: item, albumID: albumID, state: .waitingForVerification),
                         peer: peer, remoteID: remoteID, lease: lease)
        }
        try put(ImportReceipt(identifier: identifier, item: item, albumID: albumID, state: .verified),
                peer: peer, remoteID: remoteID, lease: lease)
        return identifier
    }

    func useExisting(_ asset: PHAsset, item: Item, peer: String, remoteID: String,
                     albumID: String?, lease: Int, proof: VerifiedRead? = nil) async throws {
        guard try receipt(peer: peer, remoteID: remoteID, lease: lease) == nil else { throw MediaError193.changed }
        // Record different remote memberships without granting permission to delete a pre-existing original.
        try await verifyCreated(asset.localIdentifier, against: item, lease: lease, proof: proof)
        if let albumID = albumID {
            try await addExisting(asset, to: albumID, lease: lease)
        }
        try put(ImportReceipt(identifier: asset.localIdentifier, item: item, albumID: albumID, state: .reusedOriginal),
                peer: peer, remoteID: remoteID, lease: lease)
    }

    private func addExisting(_ asset: PHAsset, to albumID: String, lease: Int) async throws {
        try check(lease)
        guard let existing = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
              else { throw MediaError193.unavailable }
        let member = PHAsset.fetchAssets(in: existing, options: nil).index(of: asset)
        if member != NSNotFound { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var rejection: Error?
            PHPhotoLibrary.shared().performChanges({
                do {
                    try self.check(lease)
                    guard let current = try self.select([asset.localIdentifier], lease: lease).visible.first,
                          NativeAssetRevision.same(asset, current),
                          let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
                          album.canPerform(.addContent),
                          let change = PHAssetCollectionChangeRequest(for: album) else { throw MediaError193.unavailable }
                    change.addAssets([current] as NSArray)
                } catch { rejection = error }
            }) { success, error in
                if success, rejection == nil { continuation.resume() }
                else { continuation.resume(throwing: rejection ?? error ?? MediaError193.unavailable) }
            }
        }
    }

    /// Only a synced copy created here may be removed. A receiver must review the exact item, then accept the system prompt.
    func deleteReceived(peer: String, remoteID: String, expected: Item, lease: Int,
                        approve: (PHAsset) async -> Bool) async throws {
        try check(lease)
        guard let previous = try receipt(peer: peer, remoteID: remoteID, lease: lease),
              previous.item.byteIdentity == expected.byteIdentity else { throw MediaError193.unavailable }
        if previous.state == .confirmedDeleted { return }
        guard previous.state == .verified,
              let asset = try select([previous.identifier], lease: lease).visible.first
              else { throw MediaError193.unavailable }
        try await verifyCreated(asset.localIdentifier, against: expected, lease: lease)
        guard await approve(asset) else { throw MediaError193.cancelled }
        try Task.checkCancellation()
        let removed = try await deleteSystemOriginals([asset], lease: lease)
        guard removed.contains(previous.identifier) else { throw MediaError193.verification }
        try put(ImportReceipt(identifier: previous.identifier, item: previous.item, albumID: previous.albumID, state: .confirmedDeleted),
                peer: peer, remoteID: remoteID, lease: lease)
    }

    private final class ResourceRead {
        struct Digest { let sha256: String; let bytes: Int64 }
        private let lock = NSLock()
        private let maximum: Int64
        private let consume: (Data) throws -> Void
        private let hash = SHA193()
        private var bytes: Int64 = 0
        private var failure: Error?
        private var id: PHAssetResourceDataRequestID?
        private var complete = false

        init(maximum: Int64, consume: @escaping (Data) throws -> Void) {
            self.maximum = maximum
            self.consume = consume
        }

        func run(_ resource: PHAssetResource, allowICloud: Bool) async throws -> Digest {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = allowICloud
                    let manager = PHAssetResourceManager.default()
                    let request = manager.requestData(for: resource, options: options, dataReceivedHandler: received) { error in
                        self.lock.lock()
                        self.complete = true
                        self.id = nil
                        let result: Result<Digest, Error>
                        if let failure = self.failure ?? error { result = .failure(failure) }
                        else if self.bytes == 0 { result = .failure(MediaError193.unavailable) }
                        else { result = .success(Digest(sha256: self.hash.finish(), bytes: self.bytes)) }
                        self.lock.unlock()
                        continuation.resume(with: result)
                    }
                    self.lock.lock()
                    let abort = self.failure != nil && !self.complete
                    if !self.complete && !abort { self.id = request }
                    self.lock.unlock()
                    if abort { manager.cancelDataRequest(request) }
                }
            }, onCancel: { self.cancel() })
        }

        private func received(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !complete, failure == nil, !data.isEmpty else { return }
            do {
                guard Int64(data.count) <= maximum - bytes else { throw MediaError193.tooLarge }
                try consume(data)
                hash.append(data)
                bytes += Int64(data.count)
            } catch {
                failure = error
                if let id = id {
                    self.id = nil
                    DispatchQueue.global(qos: .utility).async {
                        PHAssetResourceManager.default().cancelDataRequest(id)
                    }
                }
            }
        }

        private func cancel() {
            lock.lock()
            if !complete, failure == nil { failure = MediaError193.cancelled }
            let request = id
            id = nil
            lock.unlock()
            if let request = request { PHAssetResourceManager.default().cancelDataRequest(request) }
        }
    }
}
