import UIKit
import Photos
import AVFoundation

final class PhotoRepository: NSObject, PHPhotoLibraryChangeObserver {
    let storage: SecureStorage
    let manager = PHCachingImageManager()
    let memory = NSCache<NSString, UIImage>()
    private let viewerMemory193 = NSCache<NSString, UIImage>()
    private var adjacentRequests193: [PHImageRequestID] = []
    private var importing193: PrivateImport193?
    private var restoring193: PrivateRestore193?
    private let disk = DispatchQueue(label: "com.nocturne.thumbnail-cache", qos: .utility)
    private(set) var assets: [MediaAsset193] = []
    private var result: PHFetchResult<PHAsset>?
    var changed: (() -> Void)?
    var progress: ((Double, String) -> Void)?
    private var epoch = 0
    private var externalChange: DispatchWorkItem?
    private var preparationFailed = 0
    private var inFlight: [NSString: [(UIImage?) -> Void]] = [:]
    init(storage: SecureStorage) {
        self.storage = storage
        super.init()
        memory.totalCostLimit = Int(min(UInt64(512 * 1024 * 1024), max(UInt64(96 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 32)))
        memory.countLimit = 400
        viewerMemory193.totalCostLimit = Int(min(UInt64(512 * 1024 * 1024), max(UInt64(64 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 16)))
        viewerMemory193.countLimit = 4
        PHPhotoLibrary.shared().register(self)
        NotificationCenter.default.addObserver(self, selector: #selector(albumPhotosWriteFinished(_:)),
                                               name: SecureStorage.albumPhotosWriteFinished, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self); NotificationCenter.default.removeObserver(self) }
    @objc private func memoryPressure() { viewerMemory193.removeAllObjects(); cancelAdjacent193(); memory.removeAllObjects(); manager.stopCachingImagesForAllAssets() }
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        let finish: (PHAuthorizationStatus) -> Void = { status in
            var allowed = status == .authorized
            if #available(iOS 14, *) { allowed = allowed || status == .limited }
            DispatchQueue.main.async { completion(allowed) }
        }
        if #available(iOS 14, *) { PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: finish) }
        else { PHPhotoLibrary.requestAuthorization(finish) }
    }
    func synchronize() {
        externalChange?.cancel()
        externalChange = nil
        guard storage.isUnlocked193 else { return }
        epoch += 1
        let abandoned = inFlight.values.flatMap { $0 }; inFlight.removeAll()
        abandoned.forEach { $0(nil) }
        let privateMode = storage.envelope.privateMode
        let snapshot = storage.state
        var values: [MediaAsset193] = []
        if privateMode {
            result = nil
            values = (snapshot.internalMedia193 ?? [:]).values.map(MediaAsset193.init)
            values.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        } else {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let found = PHAsset.fetchAssets(with: options)
            found.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video { values.append(MediaAsset193(asset)) }
            }
            result = found
        }
        assets = values
        let accessible = Set(values.map(\.localIdentifier))
        let missing = accessible.filter { snapshot.records[$0] == nil }
        // A limited-library permission change is not an original deletion. Preserve its records.
        if !missing.isEmpty {
            storage.update { state in
                for id in missing where state.records[id] == nil { state.records[id] = MediaRecord() }
            }
            try? storage.save()
        }
        // This cache may hold entries for both modes. A single-mode snapshot is not a deletion inventory.
        changed?()
        prepareThumbnails()
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.storage.isUnlocked193 else { return }
            if let result = self.result, changeInstance.changeDetails(for: result) == nil { return }
            guard !self.storage.deferAlbumPhotosRefresh() else { return }
            self.schedulePhotosRefresh()
        }
    }
    @objc private func albumPhotosWriteFinished(_ notice: Notification) {
        guard (notice.object as? SecureStorage) === storage else { return }
        DispatchQueue.main.async { [weak self] in self?.schedulePhotosRefresh() }
    }
    private func schedulePhotosRefresh() {
        externalChange?.cancel()
        let changed = DispatchWorkItem { [weak self] in self?.synchronize() }
        externalChange = changed
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: changed)
    }
    private func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        return options
    }
    @discardableResult func thumbnail(_ asset: MediaAsset193, pixels: Int = 480, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        // Callers and callbacks are confined to main; disk crypto and JPEG work are not.
        dispatchPrecondition(condition: .onQueue(.main))
        let identifier = asset.localIdentifier + "/" + String(asset.modificationDate?.timeIntervalSince1970 ?? 0), key = (identifier + "/" + String(pixels)) as NSString
        if let image = memory.object(forKey: key) { completion(image); return PHInvalidImageRequestID }
        if inFlight[key] != nil { inFlight[key]?.append(completion); return PHInvalidImageRequestID }
        inFlight[key] = [completion]
        let token = epoch
        disk.async { [weak self] in
            guard let self = self else { return }
            let url = try? self.storage.thumbnailURL(for: identifier, pixels: pixels, owner: asset.localIdentifier)
            let image = url.flatMap { try? self.storage.read($0) }.flatMap(UIImage.init(data:)).map(self.decoded)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.epoch == token else { return }
                if let image = image { self.finishThumbnail(key, image: image, token: token); return }
                if let value = asset.encrypted {
                    self.disk.async {
                        let ready = try? PrivateReader193(storage: self.storage, media: value).image(pixels: pixels)
                        if let ready = ready, let url = url, let data = ready.jpegData(compressionQuality: 0.86) { try? self.storage.write(data, to: url) }
                        DispatchQueue.main.async { self.finishThumbnail(key, image: ready, token: token) }
                    }
                    return
                }
                guard let native = asset.native else { self.finishThumbnail(key, image: nil, token: token); return }
                self.manager.requestImage(for: native, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit, options: self.options()) { [weak self] image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    DispatchQueue.main.async {
                        guard let self = self, self.epoch == token else { return }
                        guard let image = image else { self.finishThumbnail(key, image: nil, token: token); return }
                        self.disk.async {
                            let decoded = self.decoded(image)
                            if let url = url, let data = decoded.jpegData(compressionQuality: 0.86) { try? self.storage.write(data, to: url) }
                            DispatchQueue.main.async { self.finishThumbnail(key, image: decoded, token: token) }
                        }
                    }
                }
            }
        }
        return PHInvalidImageRequestID
    }
    private func finishThumbnail(_ key: NSString, image: UIImage?, token: Int) {
        guard epoch == token else { return }
        if let image = image { remember(image, key: key) }
        let waiters = inFlight.removeValue(forKey: key) ?? []
        for callback in waiters { callback(image) }
    }
    private func decoded(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage, let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard let output = context.makeImage() else { return image }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
    private func remember(_ image: UIImage, key: NSString) {
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
    private func fullTarget193(_ asset: MediaAsset193, size: CGSize) -> CGSize {
        let physical = ProcessInfo.processInfo.physicalMemory
        let fullPixels = Double(asset.pixelWidth) * Double(asset.pixelHeight)
        if physical >= 6 * 1024 * 1024 * 1024 && fullPixels <= 48_000_000 {
            return CGSize(width: CGFloat(max(1, asset.pixelWidth)), height: CGFloat(max(1, asset.pixelHeight)))
        }
        return CGSize(width: min(CGFloat(asset.pixelWidth), max(600, ceil(size.width))), height: min(CGFloat(asset.pixelHeight), max(600, ceil(size.height))))
    }
    func fullImage(_ asset: MediaAsset193, size: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        dispatchPrecondition(condition: .onQueue(.main))
        let target = fullTarget193(asset, size: size), token = epoch
        // Explicit intermediate types avoid Swift's overload-solving timeout on iPad.
        let identifier: String = asset.localIdentifier
        let modified: TimeInterval = asset.modificationDate?.timeIntervalSince1970 ?? 0
        let modificationKey: String = String(modified)
        let widthKey: String = String(Int(target.width))
        let heightKey: String = String(Int(target.height))
        let dimensions: String = widthKey + "x" + heightKey
        let cacheKey: String = [identifier, modificationKey, "full193", dimensions].joined(separator: "/")
        let key: NSString = cacheKey as NSString
        if let cached = viewerMemory193.object(forKey: key) { completion(cached); return PHInvalidImageRequestID }
        if let encrypted = asset.encrypted {
            disk.async { [weak self] in
                guard let self = self else { return }
                let image = try? PrivateReader193(storage: self.storage, media: encrypted).image(pixels: Int(max(target.width, target.height)))
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.epoch == token else { return }
                    if let image = image { self.viewerMemory193.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)) }
                    completion(image)
                }
            }
            return PHInvalidImageRequestID
        }
        guard let native = asset.native else { completion(nil); return PHInvalidImageRequestID }
        let options = self.options(); options.deliveryMode = .highQualityFormat; options.resizeMode = .exact
        return manager.requestImage(for: native, targetSize: target, contentMode: .aspectFit, options: options) { [weak self] image, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            guard let image = image else { DispatchQueue.main.async { if self?.epoch == token { completion(nil) } }; return }
            self?.disk.async { [weak self] in
                guard let self = self else { return }; let ready = self.decoded(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.epoch == token else { return }
                    self.viewerMemory193.setObject(ready, forKey: key, cost: Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4))
                    completion(ready)
                }
            }
        }
    }
    private func cancelAdjacent193() { adjacentRequests193.forEach { manager.cancelImageRequest($0) }; adjacentRequests193.removeAll() }
    func prefetchAdjacent193(_ values: [MediaAsset193], selected: Int, size: CGSize) {
        dispatchPrecondition(condition: .onQueue(.main)); cancelAdjacent193()
        for index in [selected - 1, selected + 1] where values.indices.contains(index) {
            let asset = values[index]
            if asset.mediaType == .image { adjacentRequests193.append(fullImage(asset, size: size) { _ in }) }
            else { thumbnail(asset, pixels: 640) { _ in } }
        }
    }
    func livePhoto193(_ asset: MediaAsset193, size: CGSize, completion: @escaping (PHLivePhoto?) -> Void) -> PHImageRequestID {
        let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = false; options.deliveryMode = .highQualityFormat
        let token = epoch
        guard let native = asset.native else { completion(nil); return PHInvalidImageRequestID }
        return manager.requestLivePhoto(for: native, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] live, info in
            guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            DispatchQueue.main.async { if self?.epoch == token { completion(live) } }
        }
    }
    @discardableResult
    func video(_ asset: MediaAsset193, completion: @escaping (AVPlayerItem?) -> Void) -> PHImageRequestID {
        let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false; options.deliveryMode = .automatic
        if let encrypted = asset.encrypted {
            let token = epoch
            disk.async { [weak self] in
                guard let self = self else { return }; let item = try? PrivateVideoLoader193.item(storage: self.storage, media: encrypted)
                DispatchQueue.main.async { if self.epoch == token { completion(item) } }
            }; return PHInvalidImageRequestID
        }
        guard let native = asset.native else { completion(nil); return PHInvalidImageRequestID }
        return manager.requestPlayerItem(forVideo: native, options: options) { item, _ in DispatchQueue.main.async { completion(item) } }
    }
    func delete(_ asset: MediaAsset193, completion: @escaping (Bool, Error?) -> Void) {
        deleteBatch193([asset]) { removed, error in completion(removed.contains(asset.localIdentifier), error) }
    }

    private func deleteNative193(_ originals: [PHAsset], lease: Int, completion: @escaping (Result<Set<String>, Error>) -> Void) {
        NativeAssetRevision.delete(originals, check: { try self.storage.validateResourceLease193(lease) }, completion: completion)
    }

    /// A denied or uncommitted Photos transaction never authorizes deletion of the accompanying encrypted copies.
    func deleteBatch193(_ selected: [MediaAsset193], completion: @escaping (Set<String>, Error?) -> Void) {
        let lease: Int
        do { lease = try storage.resourceLease193() } catch { completion([], error); return }
        let native = selected.compactMap { $0.native }
        let encrypted = selected.compactMap { $0.encrypted }
        deleteNative193(native, lease: lease) { result in
            var removed: Set<String>
            switch result {
            case .failure(let error): completion([], error); return
            case .success(let ids): removed = ids
            }
            var failure: Error?
            do {
                try self.storage.validateResourceLease193(lease)
                try self.storage.markConfirmedAlbumDeletions(removed, lease: lease)
                var visited = Set<String>()
                for value in encrypted where visited.insert(value.id).inserted {
                    try self.storage.removePrivateMedia193(value.id, lease: lease)
                    removed.insert(value.localIdentifier)
                }
            } catch { failure = error }
            // Photos may have delivered a change observation before its completion callback.
            if (try? self.storage.validateResourceLease193(lease)) != nil { self.synchronize() }
            completion(removed, failure)
        }
    }

    func restorePrivate193(_ value: MediaAsset193, permit: ExportPermit193, completion: @escaping (Result<MediaAsset193, Error>) -> Void) {
        guard let encrypted = value.encrypted, restoring193 == nil else { completion(.failure(MediaError193.unavailable)); return }
        do {
            let lease = try storage.resourceLease193()
            let operation = try PrivateRestore193(storage: storage, media: encrypted, permit: permit, progress: { [weak self] value, text in self?.progress?(value, text) }) { [weak self] result in
                guard let self = self else { return }; self.restoring193 = nil
                guard (try? self.storage.validateResourceLease193(lease)) != nil else { completion(.failure(StorageError.locked)); return }
                self.progress?(1, { if case .success = result { return "移出完成 · 原始资源已校验" }; return "移出未完成 · 加密原件保留" }())
                self.synchronize(); completion(result)
            }
            restoring193 = operation; progress?(0, "正在恢复原件到系统相册…"); operation.start()
        } catch { completion(.failure(error)) }
    }
    func moveToPrivate193(_ value: MediaAsset193, removeOriginal: Bool = true, completion: @escaping (Result<(MediaAsset193, Bool), Error>) -> Void) {
        guard let native = value.native, storage.envelope.privateMode, importing193 == nil else { completion(.failure(MediaError193.wrongMode)); return }
        do {
            let lease = try storage.resourceLease193()
            let operation = try PrivateImport193(storage: storage, asset: native, progress: { [weak self] value, note in self?.progress?(value, note) }) { [weak self] result in
                guard let self = self else { return }; self.importing193 = nil
                guard (try? self.storage.validateResourceLease193(lease)) != nil else { completion(.failure(StorageError.locked)); return }
                switch result {
                case .failure(let error):
                    self.progress?(1, "转入未完成，系统原片保留")
                    completion(.failure(error))
                case .success(let encrypted):
                    guard removeOriginal else {
                        self.progress?(1, "已加密保存 · 系统原片保留")
                        self.synchronize()
                        completion(.success((encrypted, false)))
                        return
                    }
                    self.deleteNative193([native], lease: lease) { deletion in
                        let removed = (try? deletion.get().contains(native.localIdentifier)) == true
                        guard (try? self.storage.validateResourceLease193(lease)) != nil else { completion(.failure(StorageError.locked)); return }
                        self.progress?(1, removed ? "转入完成 · 系统原片已删除" : "已加密保存 · 系统原片仍保留")
                        self.synchronize()
                        completion(.success((encrypted, removed)))
                    }
                }
            }
            importing193 = operation; progress?(0, "正在加密原件…"); operation.start()
        } catch { completion(.failure(error)) }
    }
    func prepareThumbnails() {
        let token = epoch, list = assets, started = ProcessInfo.processInfo.systemUptime
        preparationFailed = 0
        guard !list.isEmpty else { progress?(1, ""); return }
        var next = 0, done = 0, completedWeight = 0.0
        func weight(_ asset: MediaAsset193) -> Double {
            let megapixels = Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000
            return (asset.mediaType == .video ? 4 : 1) + sqrt(max(0, megapixels)) * 0.3
        }
        let totalWeight = list.reduce(0.0) { $0 + weight($1) }
        // Bounded preparation: 2 requests, never one decoder per asset in a large library.
        func lane() {
            guard token == epoch, next < list.count else { return }
            let item = list[next]; next += 1
            var completed = false
            thumbnail(item) { [weak self] image in
                guard let self = self, token == self.epoch, !completed else { return }
                completed = true; done += 1; completedWeight += weight(item); if image == nil { self.preparationFailed += 1 }
                let elapsed = max(0.1, ProcessInfo.processInfo.systemUptime - started)
                let remaining = elapsed / max(0.1, completedWeight) * max(0, totalWeight - completedWeight)
                self.progress?(completedWeight / max(1, totalWeight), Strings.text("准备缩略图", "Preparing thumbnails", "サムネイルを準備中", "準備縮圖") + " · \(Int(ceil(remaining))) s")
                if done == list.count {
                    try? self.storage.save()
                    let title = Strings.text("缩略图准备完成", "Thumbnails ready", "サムネイル準備完了", "縮圖準備完成")
                    let details = self.preparationFailed == 0 ? title : title + " · \(self.preparationFailed) " + Strings.text("项不可用（可能为云端原片或权限受限）", "unavailable (possibly cloud-only or restricted)", "項目利用不可（クラウドまたは権限制限の可能性）", "項目無法取得（可能僅存在雲端或權限受限）")
                    self.progress?(1, details)
                }
                DispatchQueue.main.async { lane() }
            }
        }
        lane(); lane()
    }
    func lock() { externalChange?.cancel(); externalChange = nil; epoch += 1; importing193?.cancel(); importing193 = nil; cancelAdjacent193(); viewerMemory193.removeAllObjects(); inFlight.removeAll(); manager.stopCachingImagesForAllAssets(); memory.removeAllObjects(); assets = []; result = nil }
}
