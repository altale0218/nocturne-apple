import Foundation
import Photos

/// Wire format shared by the Android and iOS ordinary album adapters.
struct MobileAlbumManifest: Codable {
    static let schema = 1
    static let pageLimit = 128
    static let minCaptureMillis: Int64 = -62_135_596_800_000
    static let maxCaptureMillis: Int64 = 253_402_300_799_999

    enum Layout: String, Codable { case image, video, live, motion }

    struct PlacementBucket: Hashable {
        let layout: Layout
        let captureMillis: Int64
        let favorite: Bool
    }

    static func captureMilliseconds(_ date: Date?) throws -> Int64? {
        guard let capture = date?.timeIntervalSince1970 else { return nil }
        guard capture.isFinite, capture >= Double(minCaptureMillis) / 1000, capture <= Double(maxCaptureMillis) / 1000
              else { throw MediaError193.malformed }
        return Int64((capture * 1000).rounded())
    }

    struct EmbeddedMotion: Codable, Equatable {
        let offset: Int64
        let length: Int64
        let presentationUs: Int64

        func validate(containerBytes: Int64) throws {
            guard offset >= 16, length >= 16, offset <= containerBytes, length <= containerBytes - offset,
                  (-1...600_000_000).contains(presentationUs) else { throw MediaError193.malformed }
        }
    }

    let id: String
    let layout: Layout
    let captureMillis: Int64?
    let location: PhotoSyncLibrary.Location?
    let favorite: Bool
    let resources: [PhotoSyncLibrary.Resource]
    let embeddedMotion: EmbeddedMotion?

    var byteCount: Int64 { resources.reduce(0) { $0 + $1.bytes } }

    var key: String { layout.rawValue + "|" + resources.map(\.byteIdentity).sorted().joined(separator: "|") }

    var transferKey: String {
        guard let motion = embeddedMotion else { return key }
        return "\(key)/\(motion.offset)/\(motion.length)/\(motion.presentationUs)"
    }
    var placementBucket: PlacementBucket? {
        captureMillis.map { PlacementBucket(layout: layout, captureMillis: $0, favorite: favorite) }
    }

    init(id: String, item: PhotoSyncLibrary.Item) throws {
        self.id = id
        layout = item.live ? .live : item.kind == PHAssetMediaType.video.rawValue ? .video : .image
        captureMillis = try Self.captureMilliseconds(item.creation)
        location = item.location
        favorite = item.favorite
        resources = item.resources
        embeddedMotion = nil
        try validate()
    }

    init(id: String, layout: Layout, captureMillis: Int64?, location: PhotoSyncLibrary.Location?, favorite: Bool,
         resources: [PhotoSyncLibrary.Resource], embeddedMotion: EmbeddedMotion? = nil) throws {
        self.id = id
        self.layout = layout
        self.captureMillis = captureMillis
        self.location = location
        self.favorite = favorite
        self.resources = resources
        self.embeddedMotion = embeddedMotion
        try validate()
    }

    func validate() throws {
        guard AppleSyncTransport.isHex(id, length: 32),
              captureMillis.map({ (Self.minCaptureMillis...Self.maxCaptureMillis).contains($0) }) ?? true,
              resources.allSatisfy({ (1...12).contains($0.role) })
              else { throw MediaError193.malformed }
        if layout == .motion {
            guard resources.count == 1, resources[0].role == PHAssetResourceType.photo.rawValue,
                  let embeddedMotion = embeddedMotion else { throw MediaError193.malformed }
            try resources[0].validate()
            try embeddedMotion.validate(containerBytes: resources[0].bytes)
            _ = try location?.validated()
        } else {
            guard embeddedMotion == nil else { throw MediaError193.malformed }
            try nativeItem().validate()
        }
    }

    func nativeItem() throws -> PhotoSyncLibrary.Item {
        guard layout != .motion else { throw MediaError193.unavailable }
        return PhotoSyncLibrary.Item(kind: layout == .video ? PHAssetMediaType.video.rawValue : PHAssetMediaType.image.rawValue,
                                     live: layout == .live, creation: captureMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                     location: location, favorite: favorite, resources: resources)
    }

    struct Page: Codable {
        let schema: Int
        let id: String
        let assets: [MobileAlbumManifest]

        func validate() throws {
            guard schema == MobileAlbumManifest.schema, AppleSyncTransport.isHex(id, length: 32),
                  assets.count <= MobileAlbumManifest.pageLimit, Set(assets.map(\.id)).count == assets.count
                  else { throw MediaError193.malformed }
            for asset in assets { try asset.validate() }
        }
    }

    /// Still/motion bytes determine identity. Only album placement also considers Photos metadata.
    struct ExactIndex {
        private var existing: [String: [String: String]] = [:]
        mutating func add(_ asset: MobileAlbumManifest, localID: String, metadata: String = "") {
            let key = asset.key
            if let current = existing[key]?[metadata], current <= localID { return }
            existing[key, default: [:]][metadata] = localID
        }
        func match(_ asset: MobileAlbumManifest, metadata: String = "") -> String? { existing[asset.key]?[metadata] }
        func containsOriginal(_ asset: MobileAlbumManifest) -> Bool { existing[asset.key] != nil }
    }
}
