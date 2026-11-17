import Foundation
import UIKit
import Photos
import AVFoundation
import ImageIO
import CommonCrypto
import ObjectiveC
import CoreLocation
import Darwin

struct EncryptedPart193: Codable {
    var id: String
    var role: Int
    var filename: String
    var uti: String
    var bytes: Int64
    var sha256: String
    var chunks: Int
}
struct SourceMetadata193: Codable {
    var sourceID: String
    var creation: Date?
    var modification: Date?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var favorite: Bool
    var hidden: Bool
    var filenames: [String]
}
struct EncryptedMedia193: Codable {
    var id: String
    var sourceIDs: [String]
    var kind: Int
    var width: Int
    var height: Int
    var duration: Double
    var creation: Date?
    var modification: Date?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var live: Bool
    var parts: [EncryptedPart193]
    var imported: Date
    var sourceMetadata193: [SourceMetadata193]? = nil
    /// Reject malformed descriptors before allocation, export or registration; no perceptual hash authorizes reuse.
    func validate193() throws {
        let maximum: Int64 = 120 * 1024 * 1024 * 1024
        guard UUID(uuidString: id) != nil, [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue].contains(kind),
              width > 0, height > 0, width <= 65536, height <= 65536,
              Int64(width) * Int64(height) <= 1_000_000_000,
              duration.isFinite, duration >= 0, duration <= 315_360_000,
              !parts.isEmpty, parts.count <= 64, Set(parts.map { $0.id }).count == parts.count,
              sourceIDs.count <= 4096, sourceIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }),
              (sourceMetadata193?.count ?? 0) <= 4096 else { throw MediaError193.malformed }
        if let lat = latitude { guard lat.isFinite, (-90...90).contains(lat), longitude != nil else { throw MediaError193.malformed } }
        if let lon = longitude { guard lon.isFinite, (-180...180).contains(lon), latitude != nil else { throw MediaError193.malformed } }
        if let value = altitude { guard value.isFinite else { throw MediaError193.malformed } }
        for date in [creation, modification, Optional(imported)] { if let date = date { guard date.timeIntervalSince1970.isFinite else { throw MediaError193.malformed } } }
        var total: Int64 = 0
        for part in parts {
            guard UUID(uuidString: part.id) != nil, PHAssetResourceType(rawValue: part.role) != nil,
                  !part.filename.isEmpty, part.filename.utf8.count <= 4096,
                  !part.filename.contains("/"), !part.filename.contains("\\"), !part.filename.contains("\0"),
                  !part.uti.isEmpty, part.uti.utf8.count <= 256, !part.uti.contains("\0"),
                  part.bytes > 0, part.bytes <= maximum - total,
                  part.chunks == Int((part.bytes + Int64(PrivateReader193.chunk) - 1) / Int64(PrivateReader193.chunk)),
                  part.sha256.utf8.count == 64, part.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MediaError193.malformed }
            total += part.bytes
        }
        for metadata in sourceMetadata193 ?? [] {
            guard sourceIDs.contains(metadata.sourceID), metadata.filenames.count <= 64,
                  metadata.filenames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") }) else { throw MediaError193.malformed }
            if let lat = metadata.latitude { guard lat.isFinite, (-90...90).contains(lat), metadata.longitude != nil else { throw MediaError193.malformed } }
            if let lon = metadata.longitude { guard lon.isFinite, (-180...180).contains(lon), metadata.latitude != nil else { throw MediaError193.malformed } }
            if let altitude = metadata.altitude { guard altitude.isFinite else { throw MediaError193.malformed } }
            for date in [metadata.creation, metadata.modification] { if let date = date { guard date.timeIntervalSince1970.isFinite else { throw MediaError193.malformed } } }
        }
        guard (kind == PHAssetMediaType.image.rawValue ? cover != nil : video != nil) else { throw MediaError193.malformed }
        if live { guard kind == PHAssetMediaType.image.rawValue, video != nil else { throw MediaError193.malformed } }
    }
    var rawIdentity193: String {
        let rows = parts.map { String($0.role) + ":" + String($0.bytes) + ":" + $0.sha256 }.sorted()
        return AuthenticatedCipher.digest(Data(rows.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var localIdentifier: String { "private193:" + id }
    var cover: EncryptedPart193? {
        parts.first { $0.role == PHAssetResourceType.fullSizePhoto.rawValue } ?? parts.first { $0.role == PHAssetResourceType.photo.rawValue }
    }
    var video: EncryptedPart193? {
        if kind == PHAssetMediaType.video.rawValue { return parts.first { $0.role == PHAssetResourceType.fullSizeVideo.rawValue } ?? parts.first { $0.role == PHAssetResourceType.video.rawValue } }
        return parts.first { $0.role == PHAssetResourceType.fullSizePairedVideo.rawValue } ?? parts.first { $0.role == PHAssetResourceType.pairedVideo.rawValue }
    }
}
struct MediaAsset193 {
    let native: PHAsset?
    let encrypted: EncryptedMedia193?
    init(_ asset: PHAsset) { native = asset; encrypted = nil }
    init(_ asset: EncryptedMedia193) { native = nil; encrypted = asset }
    var localIdentifier: String { native?.localIdentifier ?? encrypted!.localIdentifier }
    var mediaType: PHAssetMediaType { native?.mediaType ?? PHAssetMediaType(rawValue: encrypted!.kind) ?? .unknown }
    var mediaSubtypes: PHAssetMediaSubtype { native?.mediaSubtypes ?? (encrypted!.live ? .photoLive : []) }
    var pixelWidth: Int { native?.pixelWidth ?? encrypted!.width }
    var pixelHeight: Int { native?.pixelHeight ?? encrypted!.height }
    var duration: Double { native?.duration ?? encrypted!.duration }
    var creationDate: Date? { native?.creationDate ?? encrypted?.creation }
    var modificationDate: Date? { native?.modificationDate ?? encrypted?.modification }
}
enum NativeAssetRevision {
    static func same(_ expected: PHAsset, _ current: PHAsset) -> Bool {
        expected.localIdentifier == current.localIdentifier &&
            expected.modificationDate == current.modificationDate &&
            expected.creationDate == current.creationDate &&
            expected.pixelWidth == current.pixelWidth &&
            expected.pixelHeight == current.pixelHeight &&
            expected.mediaType == current.mediaType &&
            expected.mediaSubtypes == current.mediaSubtypes &&
            expected.duration == current.duration &&
            expected.isFavorite == current.isFavorite &&
            expected.isHidden == current.isHidden &&
            sameLocation(expected.location, current.location)
    }

    static func delete(_ originals: [PHAsset], check: @escaping () throws -> Void,
                       completion: @escaping (Result<Set<String>, Error>) -> Void) {
        let ids = Set(originals.map(\.localIdentifier))
        guard !ids.isEmpty else { completion(.success([])); return }
        var rejection: Error?
        PHPhotoLibrary.shared().performChanges({
            do {
                try check()
                let status: PHAuthorizationStatus
                if #available(iOS 14, *) { status = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
                else { status = PHPhotoLibrary.authorizationStatus() }
                var readable = status == .authorized
                if #available(iOS 14, *) { readable = readable || status == .limited }
                guard readable else { throw MediaError193.unavailable }

                let results = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
                var current: [String: PHAsset] = [:]
                results.enumerateObjects { value, _, _ in current[value.localIdentifier] = value }
                guard current.count == ids.count else { throw MediaError193.unavailable }
                for original in originals {
                    guard let fresh = current[original.localIdentifier], same(original, fresh) else {
                        throw MediaError193.changed
                    }
                    guard fresh.canPerform(.delete) else { throw MediaError193.unavailable }
                }
                try check()
                PHAssetChangeRequest.deleteAssets(Array(current.values) as NSArray)
            } catch { rejection = error }
        }) { success, error in
            let result: Result<Set<String>, Error>
            if success, rejection == nil { result = .success(ids) }
            else { result = .failure(rejection ?? error ?? MediaError193.cancelled) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func sameLocation(_ expected: CLLocation?, _ current: CLLocation?) -> Bool {
        guard let expected = expected, let current = current else {
            return expected == nil && current == nil
        }
        return expected.coordinate.latitude == current.coordinate.latitude &&
            expected.coordinate.longitude == current.coordinate.longitude &&
            expected.altitude == current.altitude
    }
}
enum MediaError193: Error { case malformed, changed, unavailable, cancelled, tooLarge, verification, wrongMode }
final class SHA193 {
    private var value = CC_SHA256_CTX()
    init() { CC_SHA256_Init(&value) }
    func append(_ bytes: Data) { bytes.withUnsafeBytes { _ = CC_SHA256_Update(&value, $0.baseAddress, CC_LONG(bytes.count)) } }
    func finish() -> String {
        var bytes = [UInt8](repeating: 0, count: 32); CC_SHA256_Final(&bytes, &value)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
final class PrivateReader193 {
    static let chunk = 1_048_576
    let storage: SecureStorage, media: EncryptedMedia193, lease: Int
    private let cache = NSCache<NSString, NSData>()
    init(storage: SecureStorage, media: EncryptedMedia193, lease: Int? = nil) throws {
        self.storage = storage; self.media = media; self.lease = try lease ?? storage.resourceLease193()
        try media.validate193()
        cache.totalCostLimit = 16 * Self.chunk; cache.countLimit = 16
    }
    func partURL(_ part: EncryptedPart193, index: Int) throws -> URL {
        guard UUID(uuidString: part.id) != nil, index >= 0, index < part.chunks,
              part.bytes >= 0, part.bytes <= 120 * 1024 * 1024 * 1024,
              part.chunks == Int((part.bytes + Int64(Self.chunk) - 1) / Int64(Self.chunk)) else { throw MediaError193.malformed }
        return storage.root.appendingPathComponent("Media193").appendingPathComponent(media.id).appendingPathComponent(part.id).appendingPathComponent(String(format: "%08x.nce", index))
    }
    func read(_ part: EncryptedPart193, index: Int) throws -> Data {
        try storage.validateResourceLease193(lease)
        guard media.parts.contains(where: { $0.id == part.id && $0.sha256 == part.sha256 && $0.bytes == part.bytes }) else { throw MediaError193.malformed }
        let key = (part.id + "/" + String(index)) as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let result = try storage.readResourceChunk193(try partURL(part, index: index), media: media.id, part: part.id, index: index, lease: lease)
        let size = Int(min(Int64(Self.chunk), part.bytes - Int64(index) * Int64(Self.chunk)))
        guard result.count == size else { throw MediaError193.verification }
        cache.setObject(result as NSData, forKey: key, cost: result.count)
        return result
    }
    func verify(_ part: EncryptedPart193) throws {
        let hash = SHA193(); var size: Int64 = 0
        for index in 0..<part.chunks { let bytes = try read(part, index: index); hash.append(bytes); size += Int64(bytes.count) }
        guard size == part.bytes, hash.finish() == part.sha256 else { throw MediaError193.verification }
    }
    func data(_ part: EncryptedPart193, maximum: Int = 128 * 1024 * 1024) throws -> Data {
        guard part.bytes > 0, part.bytes <= Int64(maximum) else { throw MediaError193.tooLarge }
        var value = Data(); value.reserveCapacity(Int(part.bytes))
        for index in 0..<part.chunks { value.append(try read(part, index: index)) }
        return value
    }
    func image(pixels: Int) throws -> UIImage {
        guard let cover = media.cover, let source = CGImageSourceCreateWithData(try data(cover) as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(64, min(16384, pixels))] as CFDictionary) else { throw MediaError193.unavailable }
        return UIImage(cgImage: image)
    }
}
final class PrivateVideoLoader193: NSObject, AVAssetResourceLoaderDelegate {
    private static var association: UInt8 = 0
    private let reader: PrivateReader193, part: EncryptedPart193
    private let queue = DispatchQueue(label: "com.nocturne.private-playback193", qos: .userInitiated)
    private init(reader: PrivateReader193, part: EncryptedPart193) { self.reader = reader; self.part = part }
    static func item(storage: SecureStorage, media: EncryptedMedia193) throws -> AVPlayerItem {
        guard let part = media.video else { throw MediaError193.unavailable }
        let reader = try PrivateReader193(storage: storage, media: media)
        let loader = PrivateVideoLoader193(reader: reader, part: part)
        let url = URL(string: "nocturne-private193://" + media.id + "/" + part.id)!
        let asset = AVURLAsset(url: url); asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(asset, &association, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return AVPlayerItem(asset: asset)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            try reader.storage.validateResourceLease193(reader.lease)
            guard request.request.url?.host?.lowercased() == reader.media.id.lowercased(), request.request.url?.path == "/" + part.id else { throw MediaError193.malformed }
            request.contentInformationRequest?.contentType = part.uti
            request.contentInformationRequest?.contentLength = part.bytes
            request.contentInformationRequest?.isByteRangeAccessSupported = true
            if let target = request.dataRequest {
                var offset = max(target.requestedOffset, target.currentOffset)
                guard offset >= 0, offset <= part.bytes, target.requestedLength >= 0 else { throw MediaError193.malformed }
                guard target.requestedOffset >= 0, target.requestedOffset <= part.bytes else { throw MediaError193.malformed }
                let end = target.requestsAllDataToEndOfResource ? part.bytes : target.requestedOffset + min(Int64(target.requestedLength), part.bytes - target.requestedOffset)
                guard offset <= end else { throw MediaError193.malformed }
                while offset < end {
                    if request.isCancelled { throw MediaError193.cancelled }
                    let index = Int(offset / Int64(PrivateReader193.chunk)), inside = Int(offset % Int64(PrivateReader193.chunk))
                    let value = try reader.read(part, index: index), count = min(value.count - inside, Int(min(Int64(PrivateReader193.chunk), end - offset)))
                    guard count > 0 else { throw MediaError193.verification }
                    target.respond(with: value.subdata(in: inside..<(inside + count))); offset += Int64(count)
                }
            }
            request.finishLoading()
        } catch { request.finishLoading(with: NSError(domain: "NocturnePrivateMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "加密媒体暂不可用或已经锁定。"])) }
        return true
    }
}


private final class PartWriter193 {
    let storage: SecureStorage, media: String, id = UUID().uuidString.lowercased(), lease: Int
    let directory: URL
    private var buffer = Data(), hash = SHA193(), bytes: Int64 = 0, chunks = 0
    init(storage: SecureStorage, media: String, lease: Int) throws {
        self.storage = storage; self.media = media; self.lease = lease
        directory = storage.root.appendingPathComponent("Media193").appendingPathComponent(media).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
    }
    func append(_ data: Data) throws {
        try storage.validateResourceLease193(lease)
        guard Int64(data.count) <= 120 * 1024 * 1024 * 1024 - bytes else { throw MediaError193.tooLarge }
        hash.append(data); bytes += Int64(data.count)
        var at = 0
        while at < data.count {
            let count = min(PrivateReader193.chunk - buffer.count, data.count - at)
            buffer.append(data.subdata(in: at..<(at + count))); at += count
            if buffer.count == PrivateReader193.chunk { try flush() }
        }
    }
    private func flush() throws {
        guard !buffer.isEmpty else { return }
        let url = directory.appendingPathComponent(String(format: "%08x.nce", chunks))
        try storage.writeResourceChunk193(buffer, to: url, media: media, part: id, index: chunks, lease: lease)
        buffer.resetBytes(in: 0..<buffer.count); buffer.removeAll(keepingCapacity: true); chunks += 1
    }
    func finish(_ resource: PHAssetResource) throws -> EncryptedPart193 {
        try flush()
        return EncryptedPart193(id: id, role: resource.type.rawValue, filename: String(resource.originalFilename.prefix(1024)), uti: String(resource.uniformTypeIdentifier.prefix(256)), bytes: bytes, sha256: hash.finish(), chunks: chunks)
    }
    deinit { buffer.resetBytes(in: 0..<buffer.count) }
}
final class PrivateImport193 {
    private let storage: SecureStorage, asset: PHAsset, lease: Int, media = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "com.nocturne.private-import193", qos: .userInitiated)
    private let resources: [PHAssetResource]
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var parts: [EncryptedPart193] = [], cancelled = false, ended = false
    private var request: PHAssetResourceDataRequestID?, failure: Error?
    private let progress: (Double, String) -> Void
    private let completion: (Result<MediaAsset193, Error>) -> Void
    init(storage: SecureStorage, asset: PHAsset, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<MediaAsset193, Error>) -> Void) throws {
        guard storage.envelope.privateMode else { throw MediaError193.wrongMode }
        self.storage = storage; self.asset = asset; self.progress = progress; self.completion = completion
        queue.setSpecific(key: queueKey, value: 1)
        lease = try storage.resourceLease193(); resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty, resources.count <= 64 else { throw MediaError193.unavailable }
    }
    func start() { queue.async { self.next() } }
    func cancel() { queue.async { self.cancelled = true; if let request = self.request { PHAssetResourceManager.default().cancelDataRequest(request) } else { self.finish(.failure(MediaError193.cancelled)) } } }
    private func next() {
        guard !ended else { return }
        do {
            try storage.validateResourceLease193(lease); guard !cancelled else { throw MediaError193.cancelled }
            guard parts.count < resources.count else { try commit(); return }
            let resource = resources[parts.count], writer = try PartWriter193(storage: storage, media: media, lease: lease)
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            let index = parts.count
            DispatchQueue.main.async { self.progress(Double(index) / Double(self.resources.count), "正在加密原始资源 \(index + 1)/\(self.resources.count)") }
            let received = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { [weak self] data in
                guard let self = self else { return }
                let append = { () -> Bool in
                    guard !self.ended, !self.cancelled, self.failure == nil else { return true }
                    do { try writer.append(data) } catch { self.failure = error }
                    return self.failure != nil
                }
                let failed = DispatchQueue.getSpecific(key: self.queueKey) != nil ? append() : self.queue.sync(execute: append)
                if failed { self.queue.async { if let id = self.request { PHAssetResourceManager.default().cancelDataRequest(id) } } }
            }, completionHandler: { [weak self] error in
                self?.queue.async {
                    guard let self = self, !self.ended else { return }; self.request = nil
                    if let failure = self.failure ?? error { self.finish(.failure(failure)); return }
                    do { guard !self.cancelled else { throw MediaError193.cancelled }; self.parts.append(try writer.finish(resource)); self.next() }
                    catch { self.finish(.failure(error)) }
                }
            })
            request = received
        } catch { finish(.failure(error)) }
    }
    private func commit() throws {
        guard !cancelled, parts.count == resources.count else { throw MediaError193.cancelled }
        try storage.validateResourceLease193(lease)
        let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject
        guard let fresh = fresh, NativeAssetRevision.same(asset, fresh) else { throw MediaError193.changed }
        let location = asset.location
        var value = EncryptedMedia193(id: media, sourceIDs: [asset.localIdentifier], kind: asset.mediaType.rawValue, width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration, creation: asset.creationDate, modification: asset.modificationDate, latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude, altitude: location?.altitude, live: asset.mediaSubtypes.contains(.photoLive), parts: parts, imported: Date())
        value.sourceMetadata193 = [SourceMetadata193(sourceID: asset.localIdentifier, creation: asset.creationDate, modification: asset.modificationDate, latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude, altitude: location?.altitude, favorite: asset.isFavorite, hidden: asset.isHidden, filenames: resources.map { $0.originalFilename })]
        // Do not retire/delete a Photos asset before every original component has been read back and authenticated.
        let reader = try PrivateReader193(storage: storage, media: value, lease: lease)
        for part in parts { try reader.verify(part) }
        for existing in try storage.exactPrivateMatches193(for: value, lease: lease) {
            do { let original = try PrivateReader193(storage: storage, media: existing, lease: lease); for part in existing.parts { try original.verify(part) } }
            catch StorageError.locked { throw StorageError.locked }
            catch { continue }
            let reused = try storage.attachImportedReference193(existing: existing, incoming: value, sourceRecord: storage.state.records[asset.localIdentifier], lease: lease)
            try? storage.discardUncommitted193(media, lease: lease)
            finish(.success(MediaAsset193(reused))); return
        }
        try storage.registerMedia193(value, sourceRecord: storage.state.records[asset.localIdentifier], lease: lease)
        finish(.success(MediaAsset193(value)))
    }
    private func finish(_ result: Result<MediaAsset193, Error>) {
        guard !ended else { return }; ended = true
        if case .failure = result { try? storage.discardUncommitted193(media, lease: lease) }
        DispatchQueue.main.async { self.completion(result) }
    }
}


/// Restore uses original bytes, never a poster or re-encoded image. PhotoKit resource compatibility is checked first.
final class PrivateRestore193 {
    let storage: SecureStorage, media: EncryptedMedia193, lease: Int
    private let queue = DispatchQueue(label: "com.nocturne.restore193", qos: .userInitiated)
    private var complete = false, resources: [PHAssetResource] = [], verified = Set<Int>(), targetID = ""
    private let completion: (Result<MediaAsset193, Error>) -> Void
    private let permit: ExportPermit193
    private var temporary193: URL?
    private let progress: (Double, String) -> Void
    init(storage: SecureStorage, media: EncryptedMedia193, permit: ExportPermit193, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<MediaAsset193, Error>) -> Void) throws {
        self.storage = storage; self.media = media; self.permit = permit; self.progress = progress; self.lease = try storage.consumeExportPermit193(permit, media: media); self.completion = completion
    }
    func start() { queue.async { self.begin() } }
    private func begin() {
        do {
            try storage.validateResourceLease193(lease)
            if let previous = storage.state.restoredAssets193?[media.id], let asset = PHAsset.fetchAssets(withLocalIdentifiers: [previous], options: nil).firstObject {
                targetID = previous; resources = PHAssetResource.assetResources(for: asset); verifyNext(); return
            }
            let types = media.parts.map { NSNumber(value: $0.role) }
            guard PHAssetCreationRequest.supportsAssetResourceTypes(types) else { throw MediaError193.unavailable }
            let maximum = min(UInt64(256 * 1024 * 1024), max(UInt64(48 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 24))
            var total: Int64 = 0
            for part in media.parts { guard part.bytes >= 0, part.bytes <= 120 * 1024 * 1024 * 1024 - total else { throw MediaError193.tooLarge }; total += part.bytes }
            let reader = try PrivateReader193(storage: storage, media: media, lease: lease)
            var contents: [(EncryptedPart193, Data)] = [], files: [(EncryptedPart193, URL)] = []
            if total > Int64(maximum) {
                // User-authorized exception: only this explicit authenticated Photos export may stage decoded originals.
                let directory = try storage.beginProtectedExport193(permit, media: media); temporary193 = directory
                var done: Int64 = 0, last = ProcessInfo.processInfo.systemUptime
                for part in media.parts {
                    let url = directory.appendingPathComponent(part.id).appendingPathExtension("ncexport")
                    guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw MediaError193.unavailable }
                    var excluded = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
                    let handle = try FileHandle(forWritingTo: url)
                    let hash = SHA193(); var count: Int64 = 0
                    do {
                        for index in 0..<part.chunks {
                            let data = try reader.read(part, index: index); try writeHandle193(handle, data: data); hash.append(data); count += Int64(data.count); done += Int64(data.count)
                            if ProcessInfo.processInfo.systemUptime - last >= 0.1 {
                                let fraction = Double(done) / Double(max(1, total)); last = ProcessInfo.processInfo.systemUptime
                                DispatchQueue.main.async { self.progress(fraction * 0.65, "正在解密移出原件 · \(Int(fraction * 100))%") }
                            }
                        }
                        try synchronizeHandle193(handle); handle.closeFile()
                    } catch { handle.closeFile(); throw error }
                    let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                    let value = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
                    guard count == part.bytes, hash.finish() == part.sha256, value == FileProtectionType.complete.rawValue else { throw MediaError193.verification }
                    files.append((part, url))
                }
            } else {
                for part in media.parts { try reader.verify(part); contents.append((part, try reader.data(part, maximum: Int(maximum)))) }
            }
            try storage.validateResourceLease193(lease)
            var created: String?, transactionError: Error?
            PHPhotoLibrary.shared().performChanges({
                do {
                    try self.storage.validateResourceLease193(self.lease)
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = self.media.creation
                    if let original = self.media.sourceMetadata193?.first { request.isFavorite = original.favorite; request.isHidden = original.hidden }
                    if let lat = self.media.latitude, let lon = self.media.longitude { request.location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: self.media.altitude ?? 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: self.media.creation ?? Date()) }
                    for (part, data) in contents {
                        guard let type = PHAssetResourceType(rawValue: part.role) else { throw MediaError193.malformed }
                        let options = PHAssetResourceCreationOptions(); options.originalFilename = part.filename; options.uniformTypeIdentifier = part.uti
                        request.addResource(with: type, data: data, options: options)
                    }
                    for (part, file) in files {
                        guard let type = PHAssetResourceType(rawValue: part.role) else { throw MediaError193.malformed }
                        let options = PHAssetResourceCreationOptions(); options.originalFilename = part.filename; options.uniformTypeIdentifier = part.uti; options.shouldMoveFile = true
                        request.addResource(with: type, fileURL: file, options: options)
                    }
                    created = request.placeholderForCreatedAsset?.localIdentifier
                } catch { transactionError = error }
            }) { success, error in
                self.queue.async {
                    guard success, transactionError == nil, let identifier = created else { self.finish(.failure(transactionError ?? error ?? MediaError193.unavailable)); return }
                    do {
                        try self.storage.rememberRestore193(media: self.media.id, nativeID: identifier, lease: self.lease)
                        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw MediaError193.verification }
                        self.targetID = identifier; self.resources = PHAssetResource.assetResources(for: asset); self.verifyNext()
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }
    private func verifyNext() {
        guard !complete else { return }
        do {
            try storage.validateResourceLease193(lease)
            if verified.count == media.parts.count {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [targetID], options: nil).firstObject else { throw MediaError193.verification }
                // Native originals remain; only retire the owned encrypted copy after every original resource matches.
                try storage.retireRestoredMedia193(media, nativeID: targetID, lease: lease); finish(.success(MediaAsset193(asset))); return
            }
            let index = (0..<media.parts.count).first { !verified.contains($0) }!, part = media.parts[index]
            let choices = resources.filter { $0.type.rawValue == part.role && $0.originalFilename == part.filename }
            guard choices.count == 1 else { throw MediaError193.verification }
            let hash = SHA193(), gate = NSLock(); var size: Int64 = 0, invalid = false
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().requestData(for: choices[0], options: options, dataReceivedHandler: { data in
                gate.lock(); defer { gate.unlock() }
                guard !invalid, Int64(data.count) <= part.bytes - size else { invalid = true; return }; hash.append(data); size += Int64(data.count)
            }) { error in
                self.queue.async {
                    gate.lock(); let matches = !invalid && size == part.bytes && hash.finish() == part.sha256; gate.unlock()
                    if let error = error { self.finish(.failure(error)); return }
                    guard matches else { self.finish(.failure(MediaError193.verification)); return }
                    self.verified.insert(index); let fraction = Double(self.verified.count) / Double(self.media.parts.count)
                    DispatchQueue.main.async { self.progress(0.7 + fraction * 0.3, "正在核验已恢复的原始资源") }; self.verifyNext()
                }
            }
        } catch { finish(.failure(error)) }
    }
    private func finish(_ value: Result<MediaAsset193, Error>) {
        guard !complete else { return }; complete = true
        if let directory = temporary193 { storage.finishProtectedExport193(directory); temporary193 = nil }
        DispatchQueue.main.async { self.completion(value) }
    }
}

func mediaFailure193(_ failure: Error) -> String {
    if let value = failure as? MediaError193 {
        switch value {
        case .malformed: return "资源格式或身份描述无效（R193-01）"
        case .changed: return "处理期间原件发生变化，已停止删除（R193-02）"
        case .unavailable: return "原始资源不可本地读取，或系统不支持该资源组合（R193-03）"
        case .cancelled: return "操作已取消（R193-04）"
        case .tooLarge: return "资源大小超出当前安全处理范围（R193-05）"
        case .verification: return "完整原件回读校验未通过，保留原件（R193-06）"
        case .wrongMode: return "需启用Private，且不能同时启动另一个转移（R193-07）"
        }
    }
    if let value = failure as? StorageError {
        switch value {
        case .locked: return "应用已锁定或操作会话过期（R193-08）"
        case .invalidCredentials: return "密码验证未通过（R193-09）"
        case .keychain(let status): return "系统钥匙串验证未完成（状态码\(status)）"
        case .authentication: return "认证或资源绑定校验失败（R193-10）"
        default: return "加密存储未完成（R193-11）"
        }
    }
    let error = failure as NSError
    if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return "存储空间不足，未删除原件（R193-12）" }
    if error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return "存储空间不足，未删除原件（R193-12）" }
    if error.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue].contains(error.code) { return "文件访问权限不足，未删除原件（R193-13）" }
    // Never echo framework exception messages: they may contain filenames or source paths.
    return "系统未完成操作（错误码\(error.code)，R193-14）"
}

/// Error-returning I/O keeps disk-full failures on the preserve-original path, including the Legacy target.
func writeHandle193(_ handle: FileHandle, data: Data) throws {
    if #available(iOS 13.4, *) { try handle.write(contentsOf: data); return }
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(handle.fileDescriptor, base.advanced(by: offset), buffer.count - offset)
            if count < 0 { let code = errno; if code == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            guard count > 0 else { throw MediaError193.unavailable }; offset += count
        }
    }
}
func synchronizeHandle193(_ handle: FileHandle) throws {
    while Darwin.fsync(handle.fileDescriptor) != 0 { let code = errno; if code == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}
