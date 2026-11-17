import UIKit
import Photos
#if !NOCTURNE_LEGACY
import PhotosUI
#endif
import AVFoundation

final class GalleryController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    let repository: PhotoRepository, storage: SecureStorage, clock: SessionClock
    let layout = GalleryLayout(), background = FlowBackground(), panel = PreparationPanel()
    private(set) var collection: UICollectionView!
    private let toolbar = UIStackView(), titleLabel = UILabel()
    private let toolbarGlass193 = NativeGlass193()
    private var shown: [MediaAsset193] = []
    private var filter = "all"
    private var sidebar193: UIView?
    private var sidebarRows193: [(String, String, () -> Void)] = []
    private var pinchPreset193 = 1
    private var pinchAnchor193: IndexPath?
    private var pinchOffset193: CGFloat = 0
    private var selecting193 = false, deleting193 = false
    private var selected193 = Set<String>()
    private var previews: [String: AVPlayer] = [:], requesting = Set<String>()
    private var display: CADisplayLink?
    private var sceneEpoch: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var previewScheduled = false
    private var backdropIdentity = ""
    private var wantedPreviewIDs = Set<String>()
    private var layerObservers: [String: NSKeyValueObservation] = [:]
    private var galleryVisible = false
    private var placedInsets193 = false
    private var videoWatermarkTick: CFTimeInterval = 0
    private var cycleStarted: [String: CFTimeInterval] = [:]
    private var previewSeeking = Set<String>()
    var locked: (() -> Void)?
    var openPrivate193: (() -> Void)?
    var importPrivate199: ((UIViewController, MediaAsset193) -> Void)?
    init(repository: PhotoRepository, storage: SecureStorage, clock: SessionClock) { self.repository = repository; self.storage = storage; self.clock = clock; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(background)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear; collection.alwaysBounceVertical = true
        collection.contentInsetAdjustmentBehavior = .never; collection.showsHorizontalScrollIndicator = false
        collection.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(resizeGrid193(_:))))
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(revealSidebar193(_:)))
        edge.edges = .left
        view.addGestureRecognizer(edge)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(openSidebarSwipe199))
        swipe.direction = .left
        collection.addGestureRecognizer(swipe)
        collection.panGestureRecognizer.require(toFail: edge)
        collection.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(reorder(_:))))
        collection.dataSource = self; collection.delegate = self; collection.prefetchDataSource = self; collection.allowsMultipleSelection = true
        collection.register(MediaCell.self, forCellWithReuseIdentifier: MediaCell.reuse)
        collection.register(CaptureDayHeader199.self, forSupplementaryViewOfKind: GalleryLayout.dayHeader, withReuseIdentifier: GalleryLayout.dayHeader)
        view.addSubview(collection)
        toolbar.axis = .horizontal; toolbar.alignment = .center; toolbar.spacing = 8; toolbar.distribution = .fill
        let nav = Theme.button("line.3.horizontal", target: self, action: #selector(navigate)); nav.widthAnchor.constraint(equalToConstant: 44).isActive = true
        toolbar.addArrangedSubview(nav)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold); titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(titleLabel)
        let mode = Theme.button("ellipsis", target: self, action: #selector(chooseMode)); mode.widthAnchor.constraint(equalToConstant: 44).isActive = true; toolbar.addArrangedSubview(mode)
        let sync = Theme.button("ellipsis", target: self, action: #selector(synchronize)); sync.widthAnchor.constraint(equalToConstant: 44).isActive = true; toolbar.addArrangedSubview(sync)
        toolbarGlass193.contentView.addSubview(toolbar); view.addSubview(toolbarGlass193); view.addSubview(panel)
        if #available(iOS 15, *) { for case let button as UIButton in toolbar.arrangedSubviews { var plain = UIButton.Configuration.plain(); plain.image = button.image(for: .normal); button.configuration = plain } }
        repository.changed = { [weak self] in self?.reload() }
        repository.progress = { [weak self] value, message in self?.panel.update(value, message: message) }
        applyTheme(); reload()
        NotificationCenter.default.addObserver(self, selector: #selector(enteredForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        background.frame = view.bounds
        let safe = view.safeAreaInsets
        toolbarGlass193.frame = CGRect(x: safe.left + 12, y: safe.top + 4, width: max(1, view.bounds.width - safe.left - safe.right - 24), height: 60)
        toolbar.frame = toolbarGlass193.contentView.bounds.insetBy(dx: 8, dy: 4)
        let previousTop = collection.contentInset.top, atTop = collection.contentOffset.y <= -collection.contentInset.top + 1
        collection.frame = CGRect(x: safe.left, y: 0, width: view.bounds.width - safe.left - safe.right, height: view.bounds.height)
        collection.contentInset.top = toolbarGlass193.frame.maxY + 8; collection.contentInset.bottom = safe.bottom + 12
        collection.scrollIndicatorInsets = UIEdgeInsets(top: collection.contentInset.top, left: 0, bottom: safe.bottom, right: 0)
        if !placedInsets193 || atTop { collection.contentOffset.y = -collection.contentInset.top }
        else if previousTop != collection.contentInset.top { collection.contentOffset.y += previousTop - collection.contentInset.top }
        placedInsets193 = true
        panel.restore(in: view)
        if let overlay = sidebar193 {
            overlay.frame = view.bounds
            overlay.subviews.first?.frame = overlay.bounds
            let width = min(320, max(200, view.bounds.width - safe.left - 52))
            overlay.subviews.last?.frame = CGRect(x: safe.left + 8, y: safe.top + 4, width: width,
                                                   height: max(1, view.bounds.height - safe.top - safe.bottom - 12))
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); galleryVisible = true; applyTheme(); startMotion(); updatePreviews() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); galleryVisible = false; stopMotion(); previews.values.forEach { $0.pause() } }
    deinit { display?.invalidate(); NotificationCenter.default.removeObserver(self) }
    private var dark: Bool {
        switch storage.state.settings.appearance { case .dark: return true; case .light: return false; case .system: if #available(iOS 13, *) { return traitCollection.userInterfaceStyle == .dark }; return false }
    }
    func applyTheme() {
        view.backgroundColor = Theme.background(dark); titleLabel.textColor = Theme.text(dark)
        if storage.state.settings.mode.rawValue > 1 { storage.update { $0.settings.mode = .galaxy }; try? storage.save() }
        let p = storage.state.settings; layout.square = p.squareTiles && p.mode == .tiles; layout.mode = p.mode; layout.sizePreset = p.sizePreset; layout.names = false
        if #available(iOS 13, *) { overrideUserInterfaceStyle = p.appearance == .system ? .unspecified : p.appearance == .dark ? .dark : .light }
        background.run(!p.reducedMotion && (p.chrome == .flowing || p.mode != .tiles)); background.isHidden = p.chrome == .theme && p.mode == .tiles
        collection.visibleCells.forEach { $0.transform = .identity; $0.layer.transform = CATransform3DIdentity }
        if let pulse = display { configureMotion(pulse) }
        backdropIdentity = ""; if p.chrome != .gallery { background.image(nil, radius: 0, dark: dark) } else { updateGalleryBackdrop() }
    }
    func reload() {
        let records = storage.state.records
        shown = repository.assets.filter { asset in
            switch filter { case "photos": return asset.mediaType == .image; case "videos": return asset.mediaType == .video; case "favorite": return records[asset.localIdentifier]?.favorite == true; case "star": return records[asset.localIdentifier]?.favorite == true; default: return true }
        }
        if filter == "star" {
            let order = GalleryRules122.ranking(shown.map(\.localIdentifier), records: records)
            let byID = Dictionary(uniqueKeysWithValues: shown.map { ($0.localIdentifier, $0) })
            shown = order.compactMap { byID[$0] }
        }
        let settings = storage.state.settings
        let sort = settings.sortGallery199 ?? 0
        if filter != "star" {
            switch sort {
            case 1: shown.sort { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }
            case 2: shown.sort { (records[$0.localIdentifier]?.views ?? 0) > (records[$1.localIdentifier]?.views ?? 0) }
            default: shown.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            }
        }
        var days: [Int: String] = [:]
        if (settings.groupDates199 ?? true) && filter != "star" && sort != 2 {
            let calendar = Calendar.current
            var previous: Date?
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd EEEE"
            for (index, item) in shown.enumerated() {
                let day = item.creationDate.map { calendar.startOfDay(for: $0) }
                if index == 0 || day != previous {
                    if let day = day { days[index] = calendar.isDateInToday(day) ? "今天" : calendar.isDateInYesterday(day) ? "昨天" : formatter.string(from: day) }
                    else { days[index] = "拍摄日期未知" }
                }
                previous = day
            }
        }
        layout.dayStarts = days
        layout.ratios = shown.map { CGFloat(max(1, $0.pixelWidth)) / CGFloat(max(1, $0.pixelHeight)) }
        titleLabel.text = ["all": Strings.all, "photos": Strings.photos, "videos": Strings.videos, "favorite": Strings.text("喜爱", "Favorites", "お気に入り", "喜愛"), "star": Strings.text("排行榜", "Ranking", "ランキング", "排行榜")][filter]
        selected193.formIntersection(Set(shown.map(\.localIdentifier)))
        collection.reloadData(); selectionHeader193(); updatePreviews()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GalleryLayout.dayHeader, for: indexPath) as! CaptureDayHeader199
        header.title.text = layout.dayStarts[indexPath.item]
        header.title.textColor = Theme.text(dark)
        return header
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaCell.reuse, for: indexPath) as! MediaCell
        let asset = shown[indexPath.item], id = asset.localIdentifier, record = storage.state.records[id], p = storage.state.settings
        cell.selection193(active: selecting193, selected: selected193.contains(id))
        if selecting193 && selected193.contains(id) { collectionView.selectItem(at: indexPath, animated: false, scrollPosition: []) }
        else { collectionView.deselectItem(at: indexPath, animated: false) }
        cell.represented = id; cell.showName = false; cell.contentView.layer.cornerRadius = layout.square ? (p.roundedSquare ? 10 : 0) : 16; cell.image.contentMode = layout.square ? .scaleAspectFill : .scaleAspectFit; cell.name.textColor = Theme.text(dark)
        cell.name.text = nil
        var facts: [String] = []
        if filter == "star" { facts.append("#\(indexPath.item + 1)") }
        if p.showDuration && asset.mediaType == .video { facts.append(time(previews[id]?.currentTime().seconds ?? 0) + " / " + time(asset.duration)) }
        if p.showViews { facts.append("\(record?.views ?? 0)×") }
        cell.facts.text = facts.joined(separator: " · "); cell.facts.isHidden = facts.isEmpty
        cell.protectedBadge193.isHidden = !storage.envelope.privateMode || asset.encrypted == nil
        cell.videoIcon.isHidden = asset.mediaType != .video
        repository.thumbnail(asset) { [weak cell] image in guard cell?.represented == id else { return }; cell?.image.image = image }
        bind(cell, player: previews[id], id: id)
        cell.accessibilityLabel = cell.name.text; cell.accessibilityTraits = .button
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !deleting193, shown.indices.contains(indexPath.item) else { return }
        let asset = shown[indexPath.item]
        if selecting193 { selected193.insert(asset.localIdentifier); (collectionView.cellForItem(at: indexPath) as? MediaCell)?.selection193(active: true, selected: true); selectionHeader193(); return }
        collectionView.deselectItem(at: indexPath, animated: false)
        storage.update { state in var record = state.records[asset.localIdentifier] ?? MediaRecord(); record.viewed(); state.records[asset.localIdentifier] = record }
        let viewer = ViewerController(assets: shown, selected: indexPath.item, repository: repository, storage: storage, clock: clock, initialPreviewReady: (collection.cellForItem(at: indexPath) as? MediaCell)?.videoLayer.isReadyForDisplay == true)
        viewer.addPrivate199 = importPrivate199
        viewer.modalPresentationStyle = .overFullScreen
        if let cell = collection.cellForItem(at: indexPath) as? MediaCell, let window = cell.window {
            viewer.openingFrame199 = cell.image.convert(cell.image.bounds, to: window)
            viewer.openingImage199 = cell.image.image
        }
        viewer.returnFrame199 = { [weak self] id, destination in
            guard let self = self, let index = self.shown.firstIndex(where: { $0.localIdentifier == id }),
                  let window = self.collection.window else { return nil }
            let path = IndexPath(item: index, section: 0)
            if let cell = self.collection.cellForItem(at: path) as? MediaCell {
                let frame = cell.image.convert(cell.image.bounds, to: window)
                let safe = self.collection.convert(self.collection.bounds, to: window)
                if frame.intersects(safe) { return destination.convert(frame, from: window) }
            }
            guard let geometry = self.layout.layoutAttributesForItem(at: path) else { return nil }
            var frame = self.collection.convert(geometry.frame, to: window)
            let visible = self.collection.convert(self.collection.bounds, to: window)
            frame.origin.y = frame.midY < visible.midY ? visible.minY - frame.height : visible.maxY
            return destination.convert(frame, from: window)
        }
        present(viewer, animated: false)
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) { for path in indexPaths where path.item < shown.count { repository.thumbnail(shown[path.item]) { _ in } } }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !previewScheduled else { return }; previewScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.previewScheduled = false; self?.updatePreviews() }
    }
    private func updateGalleryBackdrop() {
        guard isViewLoaded, storage.state.settings.chrome == .gallery else { return }
        let index = collection.indexPathsForVisibleItems.sorted().first?.item ?? 0
        guard shown.indices.contains(index) else { background.image(nil, radius: 0, dark: dark); return }
        let asset = shown[index], identity = asset.localIdentifier + "/" + String(storage.state.settings.blurRadius)
        guard identity != backdropIdentity else { return }; backdropIdentity = identity
        repository.thumbnail(asset) { [weak self] image in
            guard let self = self, self.backdropIdentity == identity else { return }
            self.background.image(image, radius: self.storage.state.settings.blurRadius, dark: self.dark)
        }
    }
    private func updatePreviews() {
        guard isViewLoaded, galleryVisible else { return }; updateGalleryBackdrop()
        let prefs = storage.state.settings
        var maximum = min(ProcessInfo.processInfo.activeProcessorCount <= 2 ? 2 : 16, max(1, prefs.maximumPreviews))
        if ProcessInfo.processInfo.isLowPowerModeEnabled { maximum = min(maximum, 2) }
        if ProcessInfo.processInfo.thermalState == .serious { maximum = min(maximum, 2) }
        if ProcessInfo.processInfo.thermalState == .critical { maximum = 1 }
        let candidates = collection.indexPathsForVisibleItems.sorted().filter {
            guard $0.item < shown.count, shown[$0.item].mediaType == .video, let cell = collection.cellForItem(at: $0) else { return false }
            let area = cell.frame.intersection(collection.bounds)
            let fraction = area.isNull ? 0 : area.width * area.height / max(1, cell.bounds.width * cell.bounds.height)
            return fraction >= (previews[shown[$0.item].localIdentifier] == nil ? 0.18 : 0.08)
        }
        let wanted = Set((prefs.previewVideos ? Array(candidates.prefix(maximum)) : []).map { shown[$0.item].localIdentifier })
        wantedPreviewIDs = wanted
        for id in Array(previews.keys) where !wanted.contains(id) { if let old = previews.removeValue(forKey: id) { old.pause(); layerObservers.removeValue(forKey: id); cycleStarted.removeValue(forKey: id); previewSeeking.remove(id); if let item = old.currentItem { NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item) } } }
        for case let cell as MediaCell in collection.visibleCells {
            bind(cell, player: previews[cell.represented], id: cell.represented)
        }
        for path in candidates {
            let asset = shown[path.item], id = asset.localIdentifier
            guard wanted.contains(id), previews[id] == nil, requesting.insert(id).inserted else { continue }
            repository.video(asset) { [weak self] item in
                guard let self = self else { return }; self.requesting.remove(id)
                guard let item = item, self.collection.indexPathsForVisibleItems.contains(path), self.wantedPreviewIDs.contains(id), self.galleryVisible, self.shown.indices.contains(path.item), self.shown[path.item].localIdentifier == id else { return }
                let player = AVPlayer(playerItem: item); item.preferredForwardBufferDuration = 0.6; player.isMuted = true; player.actionAtItemEnd = .none; self.previews[id] = player; self.cycleStarted[id] = CACurrentMediaTime()
                if let cell = self.collection.cellForItem(at: path) as? MediaCell, cell.represented == id {
                    self.bind(cell, player: player, id: id)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(loop(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
                if self.storage.state.settings.markerPreview122 == true, let mark = self.storage.state.records[id]?.mark {
                    let start = max(0, mark - self.storage.state.settings.markerLead)
                    player.seek(to: CMTime(seconds: start, preferredTimescale: 60000)) { [weak self] _ in
                        DispatchQueue.main.async { if self?.galleryVisible == true { player.play() } }
                    }
                } else { player.play() }
            }
        }
        for player in previews.values where player.rate == 0 && galleryVisible { player.play() }
    }
    private func bind(_ cell: MediaCell, player: AVPlayer?, id: String) {
        if cell.videoLayer.player === player && (player == nil || layerObservers[id] != nil) { return }
        layerObservers.removeValue(forKey: id); cell.videoLayer.player = player; cell.videoLayer.opacity = 0
        guard player != nil else { return }
        layerObservers[id] = cell.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak cell] layer, _ in
            DispatchQueue.main.async { guard let cell = cell, cell.represented == id else { return }; cell.videoLayer.opacity = layer.isReadyForDisplay ? 1 : 0 }
        }
    }
    @objc private func loop(_ note: Notification) {
        for (id, player) in previews where player.currentItem === note.object as? AVPlayerItem {
            let p = storage.state.settings
            let start = p.markerPreview122 == true ? (storage.state.records[id]?.mark ?? 0) : 0
            player.seek(to: CMTime(seconds: start, preferredTimescale: 60000)) { [weak self] _ in
                DispatchQueue.main.async { if self?.galleryVisible == true { player.play() } }
            }
        }
    }
    private func startMotion() {
        guard display == nil else { return }
        let pulse = CADisplayLink(target: self, selector: #selector(animate(_:)))
        configureMotion(pulse)
        pulse.add(to: .main, forMode: .common); display = pulse
    }
    private func configureMotion(_ pulse: CADisplayLink) {
        let motion = storage.state.settings.mode == .galaxy && !storage.state.settings.reducedMotion
        pulse.preferredFramesPerSecond = motion ? min(120, view.window?.screen.maximumFramesPerSecond ?? 60) : 4
        if #available(iOS 15, *) { pulse.preferredFrameRateRange = CAFrameRateRange(minimum: motion ? 30 : 1, maximum: Float(pulse.preferredFramesPerSecond), preferred: Float(pulse.preferredFramesPerSecond)) }
    }
    private func stopMotion() { display?.invalidate(); display = nil; background.run(false) }
    @objc private func animate(_ pulse: CADisplayLink) {
        let p = storage.state.settings
        let now = pulse.timestamp
        if now - videoWatermarkTick >= 0.25 {
            videoWatermarkTick = now
            if p.markerPreview122 == true {
                for (id, player) in previews where storage.state.records[id]?.mark != nil && now - (cycleStarted[id] ?? now) >= p.markerWindow {
                    guard previewSeeking.insert(id).inserted else { continue }
                    cycleStarted[id] = now
                    let mark = storage.state.records[id]!.mark!, target = max(0, mark - p.markerLead)
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 60000)) { [weak self] _ in
                        DispatchQueue.main.async { guard let self = self else { return }; self.previewSeeking.remove(id); if self.galleryVisible { player.play() } }
                    }
                }
            }
            for case let cell as MediaCell in collection.visibleCells {
                guard let path = collection.indexPath(for: cell), shown.indices.contains(path.item) else { continue }
                let asset = shown[path.item], id = asset.localIdentifier
                guard asset.mediaType == .video else { continue }
                var values: [String] = []
                if filter == "star" { values.append("#\(path.item + 1)") }
                if p.showDuration { values.append(time(previews[id]?.currentTime().seconds ?? 0) + " / " + time(asset.duration)) }
                if p.showViews { values.append("\(storage.state.records[id]?.views ?? 0)×") }
                cell.facts.text = values.joined(separator: " · "); cell.setNeedsLayout()
            }
        }
        guard p.mode == .galaxy, !p.reducedMotion else { return }
        if sceneEpoch == 0 { sceneEpoch = now }
        let t = (now - sceneEpoch) * p.sceneSpeed
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for cell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell) else { continue }
            let phase = t * 0.3 + Double(path.item) * 1.7
            cell.transform = CGAffineTransform(translationX: CGFloat(sin(phase * 0.8) * 2), y: CGFloat(cos(phase) * 3))
            cell.layer.zPosition = 0
        }
        CATransaction.commit()
    }
    @objc private func chooseMode() {
        if selecting193 { selected193 = selected193.count == shown.count ? [] : Set(shown.map(\.localIdentifier)); collection.reloadData(); selectionHeader193(); return }
        let alert = UIAlertController(title: "排布与显示", message: nil, preferredStyle: .actionSheet)
        let p = storage.state.settings
        func add(_ title: String, _ selected: Bool, _ change: @escaping (inout Preferences) -> Void) {
            alert.addAction(UIAlertAction(title: (selected ? "✓  " : "") + title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.storage.update { change(&$0.settings) }
                self.applyTheme(); self.reload(); try? self.storage.save()
            })
        }
        add("平铺", p.mode == .tiles) { $0.mode = .tiles }
        add("星河", p.mode == .galaxy) { $0.mode = .galaxy }
        add("按拍摄日期分组", p.groupDates199 ?? true) { $0.groupDates199 = !($0.groupDates199 ?? true); if $0.sortGallery199 == 2 { $0.sortGallery199 = 0 } }
        add("1:1 方形缩略图", p.squareTiles) { $0.squareTiles193 = !$0.squareTiles }
        add("方形卡片保留圆角", p.roundedSquare) { $0.roundedSquare193 = !$0.roundedSquare }
        add("显示视频时长", p.showDuration) { $0.showDuration.toggle() }
        add("显示观看次数", p.showViews) { $0.showViews.toggle() }
        for (index, title) in ["拍摄时间 · 新到旧", "拍摄时间 · 旧到新", "最多观看"].enumerated() {
            add(title, (p.sortGallery199 ?? 0) == index) { $0.sortGallery199 = index }
        }
        for (index, title) in ["密集", "紧凑", "均衡", "大图"].enumerated() {
            add(title, p.sizePreset == index) { $0.gallerySize122 = index }
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); anchor(alert); present(alert, animated: true)
    }
    @objc private func resizeGrid193(_ gesture: UIPinchGestureRecognizer) {
        guard !selecting193, sidebar193 == nil else { return }
        if gesture.state == .began {
            pinchPreset193 = layout.sizePreset
            let point = gesture.location(in: collection)
            pinchAnchor193 = collection.indexPathForItem(at: point)
            if let anchor = pinchAnchor193, let attributes = layout.layoutAttributesForItem(at: anchor) {
                pinchOffset193 = attributes.frame.midY - collection.contentOffset.y
            }
        }
        if gesture.state == .changed {
            let scale = Double(gesture.scale)
            guard scale.isFinite, scale > 0 else { return }
            let steps = Int(max(-3, min(3, (log(scale) / log(1.25)).rounded())))
            let preset = max(0, min(3, pinchPreset193 + steps))
            guard preset != layout.sizePreset else { return }
            layout.sizePreset = preset
            collection.layoutIfNeeded()
            if let anchor = pinchAnchor193, let attributes = layout.layoutAttributesForItem(at: anchor) {
                let minimum = -collection.contentInset.top
                let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + collection.contentInset.bottom)
                collection.contentOffset.y = min(maximum, max(minimum, attributes.frame.midY - pinchOffset193))
            }
        }
        if gesture.state == .ended || gesture.state == .cancelled {
            let preset = layout.sizePreset
            if storage.state.settings.sizePreset != preset {
                storage.update { $0.settings.gallerySize122 = preset }
                try? storage.save()
            }
            pinchAnchor193 = nil
        }
    }

    @objc private func openSidebarSwipe199() { if sidebar193 == nil && !selecting193 { navigate() } }

    @objc private func revealSidebar193(_ edge: UIScreenEdgePanGestureRecognizer) {
        if edge.state == .ended, edge.translation(in: view).x > 34, sidebar193 == nil { navigate() }
    }

    @objc private func navigate() {
        if selecting193 { selecting193 = false; selected193.removeAll(); reload(); return }
        if sidebar193 != nil { dismissSidebar193(); return }
        let privateMode = storage.envelope.privateMode
        let pages = [("all", Strings.all, "square.grid.2x2"), ("photos", Strings.photos, "photo"),
                     ("videos", Strings.videos, "video"), ("favorite", "喜爱", "heart"), ("star", "排行榜", "chart.bar")]
        sidebarRows193 = pages.map { id, label, icon in
            (label, icon, { [weak self] in self?.filter = id; self?.reload() })
        }
        sidebarRows193.append(("多选项目", "checkmark.circle", { [weak self] in self?.beginSelection193() }))
        if privateMode {
            #if !NOCTURNE_LEGACY
            sidebarRows193.append(("导入到 Private", "lock.shield", { [weak self] in
                if #available(iOS 14, *) { self?.choosePrivateOriginal193() }
            }))
            #endif
            sidebarRows193.append((clock.current == nil ? "开始观看计时" : "结束观看计时", "timer", { [weak self] in
                guard let self = self else { return }
                if let session = self.clock.finish() { self.storage.update { $0.sessions.append(session) } }
                else { self.clock.start(sequence: (self.storage.state.sessions.map(\.sequence).max() ?? 0) + 1) }
                try? self.storage.save()
            }))
            sidebarRows193.append(("锁定 Private", "lock", { [weak self] in self?.locked?() }))
        } else {
            #if !NOCTURNE_LEGACY
            sidebarRows193.append(("打开 Private", "lock.shield", { [weak self] in self?.openPrivate193?() }))
            sidebarRows193.append(("手机相册同步", "iphone.and.arrow.forward", { [weak self] in
                guard let self = self else { return }
                self.present(UINavigationController(rootViewController: AppleAlbumSyncController(storage: self.storage)), animated: true)
            }))
            #endif
        }
        sidebarRows193.append((Strings.settings, "gearshape", { [weak self] in self?.openSettings193() }))
        sidebarRows193.append(("浏览器", "globe", { [weak self] in self?.openBrowser() }))
        let overlay = UIView(frame: view.bounds)
        let scrim = UIControl(frame: overlay.bounds)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        scrim.accessibilityLabel = "关闭导航"
        scrim.addTarget(self, action: #selector(dismissSidebar193), for: .touchUpInside)
        overlay.addSubview(scrim)
        let surface = UIVisualEffectView(effect: UIBlurEffect(style: { if #available(iOS 13, *) { return .systemThickMaterial }; return .regular }()))
        surface.layer.cornerRadius = 24
        surface.clipsToBounds = true
        overlay.addSubview(surface)
        let scroll = UIScrollView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -28)
        ])
        let header = UILabel()
        header.text = privateMode ? "Nocturne Private" : "Nocturne"
        header.font = .preferredFont(forTextStyle: .title2)
        header.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(header)
        for (index, row) in sidebarRows193.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle("  " + row.0, for: .normal)
            if #available(iOS 13, *) { button.setImage(UIImage(systemName: row.1), for: .normal) }
            button.contentHorizontalAlignment = .leading
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.layer.cornerRadius = 12
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            if index < pages.count && pages[index].0 == filter {
                button.backgroundColor = Theme.blue.withAlphaComponent(0.15)
                button.accessibilityTraits.insert(.selected)
            }
            button.addTarget(self, action: #selector(selectSidebar193(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        overlay.accessibilityViewIsModal = true
        sidebar193 = overlay
        view.addSubview(overlay)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let close = UISwipeGestureRecognizer(target: self, action: #selector(dismissSidebar193))
        close.direction = .left; surface.addGestureRecognizer(close)
        scrim.alpha = 0
        surface.transform = CGAffineTransform(translationX: -surface.frame.maxX, y: 0)
        UIView.animate(withDuration: sidebarDuration193, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            scrim.alpha = 1
            surface.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: header)
    }

    private var sidebarDuration193: TimeInterval {
        UIAccessibility.isReduceMotionEnabled || storage.state.settings.reducedMotion ? 0 : 0.28
    }
    @objc private func dismissSidebar193() { closeSidebar193() }
    @objc private func selectSidebar193(_ sender: UIButton) {
        guard sidebarRows193.indices.contains(sender.tag) else { return }
        closeSidebar193(sidebarRows193[sender.tag].2)
    }
    private func closeSidebar193(_ completion: (() -> Void)? = nil) {
        guard let overlay = sidebar193, overlay.isUserInteractionEnabled else { return }
        overlay.isUserInteractionEnabled = false
        UIView.animate(withDuration: sidebarDuration193, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            overlay.alpha = 0
            overlay.subviews.last?.transform = CGAffineTransform(translationX: -overlay.bounds.width, y: 0)
        } completion: { [weak self] _ in
            overlay.removeFromSuperview()
            self?.sidebar193 = nil
            self?.sidebarRows193.removeAll()
            completion?()
        }
    }

    private func openSettings193() {
        let settings = SettingsController(storage: storage)
        settings.changed = { [weak self] in self?.applyTheme(); self?.reload() }
        settings.modeChanged = storage.envelope.privateMode ? locked : openPrivate193
        let navigation = UINavigationController(rootViewController: settings)
        present(navigation, animated: true)
        navigation.presentationController?.delegate = settings
    }
    private func openBrowser() {
        // WebKit receives only explicitly navigated web URLs; history persistence stays native and lease-bound.
        if #available(iOS 18.4, *) {
            let browser = BrowserController(storage: storage); browser.modalPresentationStyle = .fullScreen
            present(browser, animated: true)
        } else {
            let alert = UIAlertController(title: Strings.text("浏览器", "Browser", "ブラウザー", "瀏覽器"), message: Strings.text("内置浏览器需要 iOS / iPadOS 18.4 或以上，以可靠阻止网页文件上传。相册仍可正常使用。", "The in-app browser requires iOS / iPadOS 18.4 or later to reliably block web file uploads. The gallery remains available.", "Web ファイル送信を確実に遮断するため、内蔵ブラウザは iOS / iPadOS 18.4 以降が必要です。写真機能は使用できます。", "內建瀏覽器需 iOS / iPadOS 18.4 或以上，才能可靠阻止網頁檔案上傳；相簿仍可使用。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        }
    }
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { !selecting193 && filter == "star" && layout.mode == .tiles }
    func collectionView(_ collectionView: UICollectionView, moveItemAt source: IndexPath, to destination: IndexPath) {
        guard filter == "star", shown.indices.contains(source.item), shown.indices.contains(destination.item) else { return }
        let item = shown.remove(at: source.item); shown.insert(item, at: destination.item)
        storage.update { state in
            for (rank, asset) in shown.enumerated() { var record = state.records[asset.localIdentifier] ?? MediaRecord(); record.favoriteRank122 = rank; state.records[asset.localIdentifier] = record }
        }
        try? storage.save(); layout.ratios = shown.map { CGFloat(max(1, $0.pixelWidth)) / CGFloat(max(1, $0.pixelHeight)) }
        DispatchQueue.main.async { [weak self] in self?.collection.reloadData(); self?.updatePreviews() }
    }
    @objc private func reorder(_ gesture: UILongPressGestureRecognizer) {
        if filter != "star" || selecting193 {
            if gesture.state == .began, let path = collection.indexPathForItem(at: gesture.location(in: collection)), shown.indices.contains(path.item) { beginSelection193(); selected193.insert(shown[path.item].localIdentifier); collection.reloadData(); selectionHeader193() }
            return
        }
        guard filter == "star", layout.mode == .tiles else { return }
        switch gesture.state {
        case .began: if let path = collection.indexPathForItem(at: gesture.location(in: collection)) { collection.beginInteractiveMovementForItem(at: path) }
        case .changed: collection.updateInteractiveMovementTargetPosition(gesture.location(in: collection))
        case .ended: collection.endInteractiveMovement()
        default: collection.cancelInteractiveMovement()
        }
    }
    private func beginSelection193() {
        guard !deleting193 else { return }; selecting193 = true; selectionHeader193()
        // Keep the collection alive while UIKit starts its two-finger selection interaction.
        for case let cell as MediaCell in collection.visibleCells { cell.selection193(active: true, selected: selected193.contains(cell.represented)) }
    }
    private func selectionHeader193() {
        if selecting193 { titleLabel.text = "已选 \(selected193.count)" }
        let symbols = selecting193 ? [0: "xmark", 2: "checkmark.circle", 3: "ellipsis"] : [0: "line.3.horizontal", 2: "ellipsis", 3: "ellipsis"]
        toolbar.arrangedSubviews[3].isHidden = !selecting193
        for (index, symbol) in symbols {
            guard let button = toolbar.arrangedSubviews[index] as? UIButton else { continue }; button.isEnabled = !deleting193
            if #available(iOS 13, *) { let image = UIImage(systemName: symbol); button.setImage(image, for: .normal); if #available(iOS 15, *), var config = button.configuration { config.image = image; button.configuration = config } }
            else { button.setTitle(selecting193 ? (index == 0 ? "×" : index == 2 ? "✓" : "•••") : (index == 0 ? "☰" : index == 2 ? "▦" : "↻"), for: .normal) }
        }
    }
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard selecting193, shown.indices.contains(indexPath.item) else { return }; selected193.remove(shown[indexPath.item].localIdentifier)
        (collectionView.cellForItem(at: indexPath) as? MediaCell)?.selection193(active: true, selected: false); selectionHeader193()
    }
    @available(iOS 13, *)
    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool { !deleting193 && filter != "star" }
    @available(iOS 13, *)
    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) { beginSelection193() }
    private func selectionMenu193() {
        guard !selected193.isEmpty, !deleting193 else { return }
        let alert = UIAlertController(title: "已选 \(selected193.count) 项", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "加入喜爱", style: .default) { _ in
            self.storage.update { state in for id in self.selected193 { var value = state.records[id] ?? MediaRecord(); value.favorite = true; state.records[id] = value } }
            do { try self.storage.save(); self.reload() } catch { self.selectionFailure193(error) }
        })
        alert.addAction(UIAlertAction(title: "删除所选项目", style: .destructive) { _ in self.confirmBatchDelete193() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel)); anchor(alert); present(alert, animated: true)
    }
    private func confirmBatchDelete193() {
        let values = shown.filter { selected193.contains($0.localIdentifier) }
        let nativeCount = values.filter { $0.native != nil }.count
        let alert = UIAlertController(title: "删除 \(values.count) 个项目？", message: nativeCount > 0 ? "系统图库项目还需通过苹果相册的删除确认。应用内加密副本仅删除应用保存的内容。" : "仅删除应用内加密副本，不删除系统相册或其他导入原件。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            self.deleting193 = true; self.selectionHeader193()
            self.repository.deleteBatch193(values) { removed, error in
                self.deleting193 = false; self.selected193.subtract(removed); self.reload()
                if let error = error { self.selectionFailure193(error) }
            }
        }); present(alert, animated: true)
    }
    private func selectionFailure193(_ error: Error) {
        guard view.window != nil, storage.isUnlocked193 else { return }
        let alert = UIAlertController(title: "操作未全部完成", message: mediaFailure193(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true)
    }
    private func anchor(_ alert: UIAlertController) { alert.popoverPresentationController?.sourceView = toolbar; alert.popoverPresentationController?.sourceRect = toolbar.bounds }
    @objc private func synchronize() { if storage.envelope.privateMode && !selecting193 { repository.synchronize(); return }; if selecting193 { selectionMenu193(); return }; repository.requestAccess { [weak self] allowed in if allowed { self?.repository.synchronize() } else { self?.permissionNotice() } } }
    private func permissionNotice() { let alert = UIAlertController(title: Strings.photos, message: Strings.text("请在系统设置中允许读取照片。仅保存在 iCloud 的原片不会联网下载。", "Allow Photos access in Settings. iCloud-only originals are never downloaded by Nocturne.", "設定で写真へのアクセスを許可してください。iCloud のみの元ファイルはダウンロードしません。", "請在系統設定允許讀取照片。不會下載僅存在 iCloud 的原片。"), preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
    @objc private func enteredForeground() { if presentedViewController == nil && view.window != nil { galleryVisible = true; startMotion(); updatePreviews() } }
    @objc private func enteredBackground() { galleryVisible = false; stopMotion(); previews.values.forEach { $0.pause() }; if let record = clock.finish() { storage.update { $0.sessions.append(record) } }; try? storage.save() }
    func showRelease() {
        guard storage.state.settings.seenRelease != Release.version else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "Nocturne · " + Release.version, message: Release.notes, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.storage.update { $0.settings.seenRelease = Release.version }; try? self.storage.save() }); self.present(alert, animated: true)
        }
    }
    private func time(_ value: Double) -> String { String(format: "%02d:%02d", Int(value.isFinite ? max(0, value) : 0) / 60, Int(value.isFinite ? max(0, value) : 0) % 60) }
}

#if !NOCTURNE_LEGACY
@available(iOS 14, *)
extension GalleryController: PHPickerViewControllerDelegate {
    private func choosePrivateOriginal193() {
        repository.requestAccess { [weak self] allowed in
            guard let self = self, self.view.window != nil, self.storage.envelope.privateMode else { return }
            guard allowed else { self.permissionNotice(); return }
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.selectionLimit = 1
            configuration.filter = .any(of: [.images, .videos])
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            self.present(picker, animated: true)
        }
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self = self, self.view.window != nil, self.storage.envelope.privateMode,
                  self.storage.isUnlocked193, let result = results.first else { return }
            guard let identifier = result.assetIdentifier,
                  let original = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                self.permissionNotice()
                return
            }
            self.repository.moveToPrivate193(MediaAsset193(original), removeOriginal: false) { [weak self] result in
                if case .failure = result, let self = self, self.view.window != nil {
                    let notice = UIAlertController(title: "导入未完成", message: "系统原片仍保留。", preferredStyle: .alert)
                    notice.addAction(UIAlertAction(title: "好", style: .default))
                    self.present(notice, animated: true)
                }
            }
        }
    }
}
#endif
