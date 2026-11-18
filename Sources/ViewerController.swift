import UIKit
import Photos
import PhotosUI
import AVFoundation

final class ViewerController: UIViewController, UIScrollViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private var assets: [MediaAsset193]
    let repository: PhotoRepository, storage: SecureStorage, clock: SessionClock
    private var selected: Int
    private let live193 = PHLivePhotoView()
    private var liveRequest193: PHImageRequestID = PHInvalidImageRequestID
    private var liveHolding193 = false
    private var fullReady193 = false
    private weak var moreButton193: UIButton?
    private var moving193 = false
    private var privateLive193: AVPlayer?
    private var privateLiveObservation193: NSKeyValueObservation?
    private let stage = UIView(), backdrop = UIImageView(), blur = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    private let zoom = UIScrollView(), media = UIView(), image = UIImageView(), precision = UIImageView(), playerLayer = AVPlayerLayer()
    private let chrome = UIView(), controls = UIView(), actions = UIStackView(), timeline = FineTimeline122(), facts = UILabel()
    private var strip: UICollectionView!, play: UIButton!, favorite: UIButton!
    private var player: AVPlayer?, periodic: Any?, ending: NSObjectProtocol?, generator: AVAssetImageGenerator?
    private var request: PHImageRequestID = PHInvalidImageRequestID
    private var generation = 0, dragging = false, seekActive = false, pendingSeek: Double?, resumeAfterSeek = true
    private var fade: DispatchWorkItem?, imageWork = 0
    private var frameRate: Double = 30, rate: Float = 1
    private var markView = UIButton(type: .system)
    private let dateLabel = UILabel(), speedHint = UILabel()
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private var displayedCaptureDate: Date?
    private var displayedFavorite: Bool?
    private var displayedPlaying: Bool?
    private var jump: UIButton!
    private var initialPreviewReady: Bool
    private var holding = false, holdLocked = false, holdOriginLocked = false
    private var baseRate: Float = 1, basePlaying = true
    private var paging = false
    private var pageAnimationEpoch = 0
    private var adjacentPreview: DispatchWorkItem?
    private var backdropWork: DispatchWorkItem?
    private weak var liveButton199: UIButton?
    private var liveStop199: DispatchWorkItem?
    private let stripFeedback199 = UISelectionFeedbackGenerator()
    private var swipeDown199 = false
    private var closing199 = false
    private var immersive = false
    private var stripCommit: DispatchWorkItem?
    private var stripPreview = false
    private var lastStripFling: CFTimeInterval = 0
    private var lastStripDirection: CGFloat = 0
    private var stripFlingBoost: CGFloat = 1
    private let stripItemWidth: CGFloat = 48
    private let stripSpacing: CGFloat = 5
    var addPrivate199: ((UIViewController, MediaAsset193) -> Void)?
    var openingFrame199: CGRect?
    var openingImage199: UIImage?
    var returnFrame199: ((String, UIView) -> CGRect?)?
    init(assets: [MediaAsset193], selected: Int, repository: PhotoRepository, storage: SecureStorage, clock: SessionClock, initialPreviewReady: Bool = false) {
        self.assets = assets; self.selected = selected; self.repository = repository; self.storage = storage; self.clock = clock; self.initialPreviewReady = initialPreviewReady
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { immersive }
    override var prefersHomeIndicatorAutoHidden: Bool { immersive }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.36, alpha: 1)
        modalPresentationCapturesStatusBarAppearance = true
        backdrop.contentMode = .scaleAspectFill; backdrop.clipsToBounds = true; backdrop.alpha = 0.85
        view.addSubview(backdrop); blur.isHidden = true
        zoom.contentInsetAdjustmentBehavior = .never; zoom.minimumZoomScale = 1; zoom.maximumZoomScale = 8; zoom.delegate = self; zoom.showsHorizontalScrollIndicator = false; zoom.showsVerticalScrollIndicator = false
        zoom.addSubview(media); image.contentMode = .scaleAspectFit; precision.contentMode = .scaleAspectFit; precision.isHidden = true
        media.addSubview(image); media.layer.addSublayer(playerLayer); playerLayer.videoGravity = .resizeAspect; media.addSubview(precision); live193.contentMode = .scaleAspectFit; live193.alpha = 0; live193.isUserInteractionEnabled = false; media.addSubview(live193)
        stage.addSubview(zoom); view.addSubview(stage)
        let back = Theme.button("chevron.left", target: self, action: #selector(close)), more = Theme.button("ellipsis", target: self, action: #selector(menu))
        moreButton193 = more
        back.frame = CGRect(x: 12, y: 8, width: 48, height: 48); more.autoresizingMask = [.flexibleLeftMargin]; more.frame = CGRect(x: 260, y: 8, width: 48, height: 48)
        for button in [back, more] { button.tintColor = .white; button.backgroundColor = UIColor(white: 0, alpha: 0.25); button.layer.cornerRadius = 16; chrome.addSubview(button) }
        more.backgroundColor = UIColor(white: 0.14, alpha: 0.58)
        more.layer.cornerRadius = 24
        more.accessibilityLabel = "更多查看器选项"
        more.layer.shadowOpacity = 0
        if #available(iOS 15, *) {
            var plain = UIButton.Configuration.plain()
            plain.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            plain.baseForegroundColor = .white
            more.configuration = plain
        }
        stage.addSubview(chrome)
        facts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); facts.textColor = UIColor(white: 1, alpha: 0.75); facts.textAlignment = .right
        controls.addSubview(facts)
        dateLabel.font = .systemFont(ofSize: 11, weight: .medium); dateLabel.textColor = UIColor(white: 1, alpha: 0.75); controls.addSubview(dateLabel)
        timeline.framesPerSecond = { [weak self] in self?.frameRate ?? 30 }
        timeline.finePixels = storage.state.settings.finePixels
        controls.backgroundColor = .clear
        timeline.minimumValue = 0; timeline.minimumTrackTintColor = Theme.blue; timeline.maximumTrackTintColor = UIColor(white: 1, alpha: 0.20)
        timeline.onBegin = { [weak self] in self?.beginSeek() }; timeline.addTarget(self, action: #selector(changeSeek), for: .valueChanged)
        timeline.addTarget(self, action: #selector(endSeek), for: [.touchUpInside, .touchUpOutside, .touchCancel]); controls.addSubview(timeline)
        markView.backgroundColor = .white; markView.layer.cornerRadius = 3; markView.addTarget(self, action: #selector(jumpToMark), for: .touchUpInside); timeline.addSubview(markView)
        actions.axis = .horizontal; actions.spacing = 14; actions.distribution = .fillEqually
        let speed = Theme.button("speedometer", target: self, action: #selector(speedMenu(_:))), mark = Theme.button("scope", target: self, action: #selector(toggleMark))
        play = Theme.button("pause.fill", target: self, action: #selector(togglePlayback)); favorite = Theme.button("heart", target: self, action: #selector(toggleFavorite))
        jump = Theme.button("bookmark.fill", target: self, action: #selector(jumpToMark))
        for button in [speed, mark, play!, jump!] { button.backgroundColor = UIColor(white: 1, alpha: 0.10); button.layer.cornerRadius = 14; button.tintColor = .white; actions.addArrangedSubview(button) }
        if #available(iOS 15, *) {
            speed.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self = self else { completion([]); return }
                completion(self.playbackSpeeds.map { value in
                    UIAction(title: self.speedTitle(value), state: value == self.baseRate ? .on : .off) { [weak self] _ in
                        self?.applyPlaybackSpeed(value)
                    }
                })
            }])
            speed.showsMenuAsPrimaryAction = true
        }
        let live = Theme.button("livephoto", target: self, action: #selector(toggleLive199))
        live.accessibilityLabel = "播放实况照片"
        liveButton199 = live
        for button in [live, favorite!] {
            button.backgroundColor = UIColor(white: 0.15, alpha: 0.46)
            button.layer.cornerRadius = 19
            button.tintColor = .white
            chrome.addSubview(button)
        }
        controls.addSubview(actions); view.addSubview(controls)
        let stripLayout = UICollectionViewFlowLayout(); stripLayout.scrollDirection = .horizontal; stripLayout.minimumLineSpacing = stripSpacing; stripLayout.itemSize = CGSize(width: stripItemWidth, height: 52)
        strip = UICollectionView(frame: .zero, collectionViewLayout: stripLayout); strip.backgroundColor = .clear; strip.dataSource = self; strip.delegate = self; strip.showsHorizontalScrollIndicator = false; strip.decelerationRate = .fast
        strip.register(MediaCell.self, forCellWithReuseIdentifier: MediaCell.reuse); controls.addSubview(strip)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2; zoom.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls)); tap.require(toFail: doubleTap); zoom.addGestureRecognizer(tap)
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(pageSwipe(_:))); swipe.delegate = self; zoom.addGestureRecognizer(swipe)
        zoom.panGestureRecognizer.require(toFail: swipe)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdSpeed(_:))); hold.minimumPressDuration = 0.24; hold.allowableMovement = 18; hold.delegate = self; zoom.addGestureRecognizer(hold)
        speedHint.font = .systemFont(ofSize: 13, weight: .semibold); speedHint.textColor = .white; speedHint.textAlignment = .center; speedHint.backgroundColor = UIColor(white: 0, alpha: 0.45); speedHint.layer.cornerRadius = 14; speedHint.clipsToBounds = true; speedHint.isHidden = true; view.addSubview(speedHint)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        show(selected, count: false)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = max(1, view.bounds.width - safe.left - safe.right)
        let photo = assets.indices.contains(selected) && assets[selected].mediaType == .image
        let stripTop: CGFloat = photo ? 0 : 98
        let showStrip = storage.state.settings.showFilmstrip204 ?? true
        strip.isHidden = !showStrip
        let height: CGFloat = controls.isHidden ? 0 : stripTop + (showStrip ? 54 : 0) + safe.bottom
        controls.frame = CGRect(x: safe.left, y: view.bounds.height - height, width: width, height: height)
        timeline.frame = CGRect(x: 18, y: 20, width: width - 36, height: 32)
        actions.frame = CGRect(x: 12, y: 56, width: width - 24, height: 40)
        strip.frame = CGRect(x: 0, y: stripTop, width: width, height: 54)
        strip.contentInsetAdjustmentBehavior = .never
        if let flow = strip.collectionViewLayout as? UICollectionViewFlowLayout {
            let inset = UIEdgeInsets(top: 0, left: max(0, (width - stripItemWidth) / 2), bottom: 0, right: max(0, (width - stripItemWidth) / 2))
            if flow.sectionInset != inset { flow.sectionInset = inset }
        }
        let stageBottom = controls.isHidden ? view.bounds.height - safe.bottom : controls.frame.minY + (photo ? 0 : 20)
        stage.frame = CGRect(x: safe.left, y: safe.top, width: width, height: max(1, stageBottom - safe.top))
        if immersive { stage.frame = view.bounds }
        backdrop.frame = (storage.state.settings.viewerBackgroundAll122 ?? true) ? view.bounds : stage.frame
        blur.frame = stage.bounds; blur.alpha = CGFloat(max(0, min(1, storage.state.settings.blurRadius / 48))); zoom.frame = stage.bounds
        if zoom.zoomScale == 1 { media.frame = CGRect(origin: .zero, size: zoom.bounds.size); zoom.contentSize = media.bounds.size }
        image.frame = photo && !immersive ? fittedMediaRect(bottomAligned: true) : media.bounds
        precision.frame = media.bounds; live193.frame = image.frame; playerLayer.frame = photo ? image.frame : media.bounds
        chrome.frame = CGRect(x: 0, y: 0, width: width, height: 64)
        moreButton193?.frame = CGRect(x: width - 60, y: 8, width: 48, height: 48)
        favorite.frame = CGRect(x: width - 112, y: 8, width: 48, height: 48)
        liveButton199?.frame = CGRect(x: width - 164, y: 8, width: 48, height: 48)
        facts.frame = CGRect(x: width * 0.44, y: photo ? -20 : 0, width: width * 0.56 - 12, height: 20)
        dateLabel.frame = CGRect(x: 12, y: photo ? -20 : 0, width: width * 0.44 - 20, height: 20)
        speedHint.frame = CGRect(x: max(safe.left + 12, view.bounds.midX - 130), y: max(safe.top + 70, controls.frame.minY - 42), width: min(260, width - 24), height: 32)
        updateMark()
    }
    private func show(_ index: Int, count: Bool = true, centerStrip: Bool = true, posterOnly: Bool = false, keepingPoster: Bool = false) {
        guard !closing199, assets.indices.contains(index) else { return }
        if !posterOnly { stripCommit?.cancel(); stripPreview = false }
        generation += 1; let token = generation; selected = index; fullReady193 = false
        backdropWork?.cancel()
        adjacentPreview?.cancel()
        holding = false; holdLocked = false; speedHint.isHidden = true; rate = baseRate; media.transform = .identity
        stopPlayer(); repository.manager.cancelImageRequest(request)
        zoom.setZoomScale(1, animated: false)
        if !keepingPoster {
            let cell = strip.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaCell
            image.image = cell?.image.image ?? (count || posterOnly ? nil : openingImage199)
        }
        precision.image = nil
        precision.isHidden = true
        let asset = assets[index], id = asset.localIdentifier
        view.setNeedsLayout()
        if count { storage.update { state in var record = state.records[id] ?? MediaRecord(); record.viewed(); state.records[id] = record } }
        repository.thumbnail(asset, pixels: posterOnly ? 160 : 480) { [weak self] thumb in guard let self = self, self.generation == token else { return }; if !self.fullReady193, let thumb = thumb { self.image.image = thumb }
            if !posterOnly, let thumb = thumb {
                let radius = self.storage.state.settings.blurRadius
                let refresh = DispatchWorkItem { [weak self] in
                    guard let self = self, self.generation == token else { return }
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let softened = PhotoBlur120.render(thumb, radius: radius)
                        DispatchQueue.main.async { guard let self = self, self.generation == token else { return }; UIView.transition(with: self.backdrop, duration: self.storage.state.settings.reducedMotion ? 0 : 0.30, options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]) { self.backdrop.image = softened } }
                    }
                }
                self.backdropWork = refresh
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: refresh)
            } }
        let video = asset.mediaType == .video
        liveButton199?.isHidden = !asset.mediaSubtypes.contains(.photoLive)
        timeline.isHidden = !video; play.isHidden = !video; actions.arrangedSubviews[0].isHidden = !video; actions.arrangedSubviews[1].isHidden = !video; jump.isHidden = !video
        for case let cell as MediaCell in strip.visibleCells {
            cell.contentView.layer.borderWidth = strip.indexPath(for: cell)?.item == index ? 2 : 0
        }
        if posterOnly { return }
        let preload = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, !self.closing199 else { return }
            for adjacent in [index - 1, index + 1] where self.assets.indices.contains(adjacent) {
                self.repository.thumbnail(self.assets[adjacent], pixels: 480) { _ in }
            }
        }
        adjacentPreview = preload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: preload)
        if video {
            request = repository.video(asset) { [weak self] item in
                guard let self = self, self.generation == token, let item = item else { return }
                let player = AVPlayer(playerItem: item)
                player.isMuted = self.storage.state.settings.viewerMuted204 ?? false
                self.player = player; self.playerLayer.player = player
                self.frameRate = max(1, Double(item.asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30))
                self.timeline.maximumValue = Float(asset.duration)
                self.periodic = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                    guard let self = self, !self.dragging else { return }; self.timeline.value = Float(time.seconds); self.updateFacts(); self.updatePlayIcon()
                }
                self.ending = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.updatePlayIcon() }
                if !self.initialPreviewReady, self.storage.state.settings.openAtMarker122 ?? true, let mark = self.storage.state.records[id]?.mark {
                    let target = GalleryRules122.quantize(mark - self.storage.state.settings.markerLead, duration: asset.duration, fps: self.frameRate)
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async { guard let self = self, self.generation == token else { return }; player.playImmediately(atRate: self.rate) }
                    }
                } else { player.playImmediately(atRate: self.rate) }
                self.initialPreviewReady = false; self.updateMark()
            }
        } else {
            let scale = view.window?.screen.scale ?? UIScreen.main.scale
            request = repository.fullImage(asset, size: CGSize(width: max(600, stage.bounds.width * scale), height: max(600, stage.bounds.height * scale))) { [weak self] result in guard let self = self, self.generation == token else { return }; if let result = result { self.fullReady193 = true; UIView.transition(with: self.image, duration: self.storage.state.settings.reducedMotion ? 0 : 0.16, options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]) { self.image.image = result } } }
        }
        let preloadScale = view.window?.screen.scale ?? UIScreen.main.scale
        repository.prefetchAdjacent193(assets, selected: index, size: CGSize(width: max(600, stage.bounds.width * preloadScale), height: max(600, stage.bounds.height * preloadScale)))
        if centerStrip {
            strip.reloadData(); strip.layoutIfNeeded()
            if strip.bounds.width > 0 { strip.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false) }
        }
        updateFacts(); updatePlayIcon(); updateMark(); updateNativeMenu193(); activate()
    }
    private func updateFacts() {
        let asset = assets[selected], p = storage.state.settings, record = storage.state.records[asset.localIdentifier]
        var values: [String] = []
        if asset.mediaType == .video && p.showDuration { values.append(time(player?.currentTime().seconds ?? 0) + " / " + time(asset.duration)) }
        let edge = min(asset.pixelWidth, asset.pixelHeight); values.append(edge >= 2160 ? "4K" : "\(edge)p")
        if p.showViews { values.append("\(record?.views ?? 0)×") }
        let line = values.joined(separator: " · ")
        if facts.text != line { facts.text = line }
        let timestamp = (p.showDate122 ?? true) ? asset.creationDate : nil
        if timestamp != displayedCaptureDate {
            displayedCaptureDate = timestamp
            dateLabel.text = timestamp.map(dateFormatter.string(from:))
        }
        let liked = record?.favorite == true
        guard displayedFavorite != liked else { return }
        displayedFavorite = liked
        if #available(iOS 13, *) {
            let icon = UIImage(systemName: liked ? "heart.fill" : "heart")
            favorite.setImage(icon, for: .normal)
            if #available(iOS 15, *), var configuration = favorite.configuration {
                configuration.image = icon
                configuration.baseForegroundColor = liked ? .systemRed : .white
                favorite.configuration = configuration
            }
        }
        favorite.accessibilityLabel = liked ? "取消收藏" : "收藏"
        favorite.tintColor = liked ? UIColor(red: 0.92, green: 0.12, blue: 0.20, alpha: 1) : .white
    }
    private func updatePlayIcon() {
        let playing = (player?.rate ?? 0) > 0
        guard displayedPlaying != playing else { return }
        displayedPlaying = playing
        if #available(iOS 13, *) { play.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal) }
        else { play.setTitle(playing ? "Ⅱ" : "▶", for: .normal) }
        play.accessibilityLabel = playing ? "Pause" : "Play"
    }
    @objc private func beginSeek() { dragging = true; resumeAfterSeek = (player?.rate ?? 0) > 0 || (player?.currentTime().seconds ?? 0) >= assets[selected].duration - 0.05; player?.pause(); activate() }
    @objc private func changeSeek() {
        let seconds = Double(timeline.value), fps = max(1, frameRate)
        pendingSeek = GalleryRules122.quantize(seconds, duration: assets[selected].duration, fps: fps)
        drainSeek()
    }
    private func drainSeek() {
        guard !seekActive, let seconds = pendingSeek, let player = player else { return }
        pendingSeek = nil; seekActive = true
        let token = generation, target = CMTime(seconds: seconds, preferredTimescale: 60000)
        let tolerance = dragging ? CMTime(seconds: 0.5 / max(1, frameRate), preferredTimescale: 60000) : CMTime.zero
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                self.seekActive = false; self.updateFacts()
                if self.pendingSeek != nil { self.drainSeek() }
                else if !self.dragging && self.resumeAfterSeek { self.precision.isHidden = true; player.playImmediately(atRate: self.rate) }
            }
        }
        // AVPlayer supplies the seek frame; a second image generator would decode 4K twice.
    }
    @objc private func endSeek() { dragging = false; changeSeek(); precision.isHidden = true; if !seekActive && resumeAfterSeek { player?.playImmediately(atRate: rate) }; updatePlayIcon() }
    @objc private func togglePlayback() {
        guard let player = player else { return }
        if player.rate > 0 { player.pause() }
        else if player.currentTime().seconds >= assets[selected].duration - 0.05 { player.seek(to: .zero) { _ in player.playImmediately(atRate: self.rate) } }
        else { player.playImmediately(atRate: rate) }; updatePlayIcon(); activate()
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if assets[selected].mediaType == .video {
            guard storage.state.settings.videoDoubleTap204 ?? true else { return }
            let back = gesture.location(in: zoom).x < zoom.bounds.width / 2
            let p = storage.state.settings, delta = back ? -p.skipBackward : p.skipForward
            timeline.value = Float(max(0, min(assets[selected].duration, (player?.currentTime().seconds ?? 0) + delta))); beginSeek(); changeSeek(); endSeek()
        } else {
            let animated = !storage.state.settings.reducedMotion && !UIAccessibility.isReduceMotionEnabled
            if zoom.zoomScale > zoom.minimumZoomScale + 0.01 {
                zoom.setZoomScale(zoom.minimumZoomScale, animated: animated)
                return
            }
            let scale = min(zoom.maximumZoomScale, 2.5)
            let size = CGSize(width: zoom.bounds.width / scale, height: zoom.bounds.height / scale)
            let location = gesture.location(in: media)
            let origin = CGPoint(x: min(max(0, location.x - size.width / 2), max(0, media.bounds.width - size.width)),
                                 y: min(max(0, location.y - size.height / 2), max(0, media.bounds.height - size.height)))
            zoom.zoom(to: CGRect(origin: origin, size: size), animated: animated)
        }
    }
    @objc private func toggleMark() {
        let id = assets[selected].localIdentifier
        storage.update { state in var record = state.records[id] ?? MediaRecord(); record.toggleMark(player?.currentTime().seconds ?? 0); state.records[id] = record }
        try? storage.save(); updateMark()
    }
    private func updateMark() {
        guard assets.indices.contains(selected), let seconds = storage.state.records[assets[selected].localIdentifier]?.mark, assets[selected].duration > 0 else { markView.isHidden = true; jump?.isEnabled = false; return }
        jump.isEnabled = true
        markView.isHidden = false; markView.layer.cornerRadius = 4
        markView.frame = CGRect(x: 14 + (timeline.bounds.width - 28) * CGFloat(seconds / assets[selected].duration) - 4, y: 3, width: 8, height: 8)
    }
    @objc private func jumpToMark() {
        guard let seconds = storage.state.records[assets[selected].localIdentifier]?.mark else { return }
        beginSeek(); timeline.value = Float(seconds); endSeek()
    }
    @objc private func toggleFavorite() {
        let id = assets[selected].localIdentifier; storage.update { state in var record = state.records[id] ?? MediaRecord(); record.favorite.toggle(); state.records[id] = record }; try? storage.save(); updateFacts()
        UISelectionFeedbackGenerator().selectionChanged()
        if !UIAccessibility.isReduceMotionEnabled && !storage.state.settings.reducedMotion {
            favorite.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
            UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.56, initialSpringVelocity: 0) {
                self.favorite.transform = .identity
            }
        }
    }
    private let playbackSpeeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    private func speedTitle(_ value: Float) -> String { String(format: "%g×", Double(value)) }
    private func applyPlaybackSpeed(_ value: Float) {
        rate = value; baseRate = value; holdLocked = false; speedHint.isHidden = true
        if (player?.rate ?? 0) > 0 { player?.rate = value }
    }
    @objc private func speedMenu(_ sender: UIButton) {
        if #available(iOS 15, *) { return }
        let alert = UIAlertController(title: "播放速度", message: nil, preferredStyle: .actionSheet)
        for value in playbackSpeeds {
            alert.addAction(UIAlertAction(title: speedTitle(value), style: .default) { [weak self] _ in self?.applyPlaybackSpeed(value) })
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = sender
        alert.popoverPresentationController?.sourceRect = sender.bounds
        present(alert, animated: true)
    }
    private func restorePrivate193() {
        guard !moving193, let encrypted = assets[selected].encrypted else { return }
        let sourceID = assets[selected].localIdentifier
        let authorize: (String?) -> Void = { [weak self] password in
            guard let self = self else { return }
            self.storage.authorizeExport193(media: encrypted.id, password: password) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .failure(let error): self.showTransferNote193("身份验证未完成，加密原件保持不变。" + mediaFailure193(error))
                    case .success(let permit):
                        guard let item = self.assets.first(where: { $0.localIdentifier == sourceID }) else { return }
                        self.moving193 = true; self.moreButton193?.isEnabled = false
                        self.repository.restorePrivate193(item, permit: permit) { [weak self] result in
                            guard let self = self else { return }; self.moving193 = false; self.moreButton193?.isEnabled = true
                            switch result {
                            case .failure(let error): self.showTransferNote193("移出未完成，加密原件保留。" + mediaFailure193(error) + " 若系统相册已有新项目，请先检查。")
                            case .success(let native):
                                if let index = self.assets.firstIndex(where: { $0.localIdentifier == sourceID }) { self.assets[index] = native; if index == self.selected { self.show(index, count: false) } }
                                self.showTransferNote193(self.storage.exportCleanupPending193 == 0 ? "原始资源已完整恢复并校验，标点和观看等记录已保留。" : "已恢复并校验。受系统保护的移出临时文件尚待清理，已暂停新的移出操作。")
                            }
                        }
                    }
                }
            }
        }
        let alert = UIAlertController(title: "移出到系统相册", message: "请重新验证身份。移出后，系统相册及获准访问它的应用可读取内容；大视频仅在本次移出时使用受系统完整文件保护的临时原件，完成后清理。", preferredStyle: .alert)
        if storage.envelope.privateMode {
            alert.addTextField { $0.isSecureTextEntry = true; $0.textContentType = .password; $0.placeholder = "资料库密码" }
            alert.addAction(UIAlertAction(title: "使用密码继续", style: .default) { _ in let password = alert.textFields?.first?.text ?? ""; alert.textFields?.first?.text = nil; authorize(password) })
            if storage.envelope.biometric193 == true { alert.addAction(UIAlertAction(title: "使用Face ID／Touch ID", style: .default) { _ in authorize(nil) }) }
        } else { alert.addAction(UIAlertAction(title: "系统身份验证并继续", style: .default) { _ in authorize(nil) }) }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); present(alert, animated: true)
    }
    private func showTransferNote193(_ text: String) { let alert = UIAlertController(title: "私密相册", message: text, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true) }
    private func movePrivate193() {
        guard !moving193, assets[selected].native != nil, storage.envelope.privateMode else { return }
        moving193 = true; let sourceID = assets[selected].localIdentifier; moreButton193?.isEnabled = false
        repository.moveToPrivate193(assets[selected]) { [weak self] result in
            guard let self = self else { return }; self.moving193 = false; self.moreButton193?.isEnabled = true
            let note: String
            switch result {
            case .failure(let error): note = "转入未完成，系统原片保留。" + mediaFailure193(error)
            case .success(let value):
                if let index = self.assets.firstIndex(where: { $0.localIdentifier == sourceID }) { self.assets[index] = value.0; if index == self.selected { self.show(index, count: false) } }
                note = value.1 ? "完整原件已加密保存，系统原片已删除。系统最近删除与iCloud仍由照片App管理。" : "完整原件已加密保存；系统原片未删除，仍保留两份。"
            }
            let alert = UIAlertController(title: "私密相册", message: note, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "好", style: .default)); self.present(alert, animated: true)
        }
    }
    private func addToPrivate199() {
        guard let add = addPrivate199, assets.indices.contains(selected), assets[selected].native != nil,
              !storage.envelope.privateMode else { return }
        add(self, assets[selected])
    }
    private func updateNativeMenu193() {
        guard let button = moreButton193 else { return }
        if #available(iOS 13, *) {
            let icon = UIImage(systemName: storage.envelope.privateMode && assets[selected].encrypted != nil ? "shield" : "ellipsis")
            if #available(iOS 15, *), var style = button.configuration { style.image = icon; button.configuration = style } else { button.setImage(icon, for: .normal) }
        }
        if #available(iOS 14, *) {
            var entries: [UIMenuElement] = []
            if assets[selected].native != nil && !storage.envelope.privateMode && addPrivate199 != nil {
                entries.append(UIAction(title: "加入 Private（保留原片）", image: UIImage(systemName: "lock.shield")) { [weak self] _ in self?.addToPrivate199() })
            }
            if assets[selected].encrypted != nil { entries.append(UIAction(title: "移出到系统相册", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.restorePrivate193() }) }
            if assets[selected].native != nil && storage.envelope.privateMode { entries.append(UIAction(title: "转入私密相册并删除系统原片", image: UIImage(systemName: "lock.shield")) { [weak self] _ in self?.movePrivate193() }) }
            entries.append(UIAction(title: "下滑退出查看器", image: UIImage(systemName: "arrow.down"), state: (storage.state.settings.swipeDismiss199 ?? true) ? .on : .off) { [weak self] _ in
                guard let self = self else { return }
                self.storage.update { $0.settings.swipeDismiss199 = !($0.settings.swipeDismiss199 ?? true) }
                try? self.storage.save(); self.updateNativeMenu193()
            })
            entries.append(UIAction(title: "显示／隐藏控制栏", image: UIImage(systemName: "rectangle.expand.vertical")) { [weak self] _ in self?.toggleControls() })
            if assets[selected].mediaType == .video, storage.state.records[assets[selected].localIdentifier]?.mark != nil { entries.append(UIAction(title: "跳转标点", image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.jumpToMark() }) }
            entries.append(UIAction(title: assets[selected].encrypted == nil ? "删除系统原片" : "删除加密项目", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteOriginal() })
            button.removeTarget(self, action: #selector(menu), for: .touchUpInside)
            button.menu = UIMenu(children: entries); button.showsMenuAsPrimaryAction = true
        }
    }
    @objc private func menu() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if assets[selected].native != nil && !storage.envelope.privateMode && addPrivate199 != nil { alert.addAction(UIAlertAction(title: "加入 Private（保留原片）", style: .default) { [weak self] _ in self?.addToPrivate199() }) }
        if assets[selected].encrypted != nil { alert.addAction(UIAlertAction(title: "移出到系统相册", style: .default) { [weak self] _ in self?.restorePrivate193() }) }
        if assets[selected].native != nil && storage.envelope.privateMode { alert.addAction(UIAlertAction(title: "转入私密相册并删除系统原片", style: .default) { [weak self] _ in self?.movePrivate193() }) }
        if let mark = storage.state.records[assets[selected].localIdentifier]?.mark { alert.addAction(UIAlertAction(title: Strings.text("跳转标点", "Jump to bookmark", "マークへ移動", "跳轉標點") + " · " + time(mark), style: .default) { [weak self] _ in guard let self = self else { return }; self.timeline.value = Float(mark); self.beginSeek(); self.changeSeek(); self.endSeek() }) }
        alert.addAction(UIAlertAction(title: Strings.text("显示 / 隐藏控制栏", "Show / hide controls", "操作バーを表示 / 非表示", "顯示 / 隱藏控制列"), style: .default) { [weak self] _ in self?.toggleControls() })
        alert.addAction(UIAlertAction(title: Strings.text("删除本地原片…", "Delete original…", "元ファイルを削除…", "刪除本地原片…"), style: .destructive) { [weak self] _ in self?.deleteOriginal() })
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); anchor(alert); present(alert, animated: true)
    }
    private func deleteOriginal() {
        let alert = UIAlertController(title: Strings.text("删除原片？", "Delete original?", "元ファイルを削除しますか？", "刪除原片？"), message: Strings.text("系统照片会再次确认。不会删除其他项目。", "Photos will ask for confirmation. Other items are retained.", "写真アプリが確認します。他の項目は保持されます。", "系統照片會再次確認。其他項目保留。"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: Strings.text("删除", "Delete", "削除", "刪除"), style: .destructive) { [weak self] _ in guard let self = self else { return }; self.generation += 1; self.stopPlayer(); self.repository.manager.cancelImageRequest(self.request); self.repository.delete(self.assets[self.selected]) { success, _ in if success {
                    self.assets.remove(at: self.selected)
                    if self.assets.isEmpty { self.close() } else { self.show(min(self.selected, self.assets.count - 1)) }
                } else { self.show(self.selected, count: false) } } }); present(alert, animated: true)
    }
    private func anchor(_ alert: UIAlertController) { alert.popoverPresentationController?.sourceView = actions; alert.popoverPresentationController?.sourceRect = actions.bounds }
    @objc private func toggleControls() {
        immersive.toggle()
        controls.isHidden = immersive
        chrome.isHidden = immersive
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        view.setNeedsLayout()
        activate()
    }
    @objc private func activate() {
        fade?.cancel(); chrome.alpha = 1; facts.alpha = 1; dateLabel.alpha = 1
        let work = DispatchWorkItem { [weak self] in UIView.animate(withDuration: 0.32) { self?.facts.alpha = 0.65; self?.dateLabel.alpha = 0.45 } }
        fade = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture is UIPanGestureRecognizer {
            let velocity = (gesture as! UIPanGestureRecognizer).velocity(in: zoom)
            return zoom.zoomScale <= 1.01 && !dragging && (abs(velocity.x) > abs(velocity.y) || (velocity.y > 0 && (storage.state.settings.swipeDismiss199 ?? true)))
        }
        if gesture is UILongPressGestureRecognizer { return !dragging && (assets[selected].mediaSubtypes.contains(.photoLive) || (assets[selected].mediaType == .video && (storage.state.settings.holdSpeed122 ?? true))) }
        return true
    }
    @objc private func pageSwipe(_ gesture: UIPanGestureRecognizer) {
        guard !holding, !closing199 else { return }
        let dx = gesture.translation(in: zoom).x, width = max(1, zoom.bounds.width)
        if gesture.state == .began {
            pageAnimationEpoch += 1
            media.layer.removeAllAnimations()
            media.transform = .identity
            paging = true; fade?.cancel()
            let v = gesture.velocity(in: zoom)
            swipeDown199 = v.y > abs(v.x) && (storage.state.settings.swipeDismiss199 ?? true)
        }
        if swipeDown199 {
            let dy = max(0, gesture.translation(in: zoom).y)
            if gesture.state == .changed && !storage.state.settings.reducedMotion {
                let scale = max(0.72, 1 - dy / 780)
                media.transform = CGAffineTransform(translationX: dx * 0.30, y: dy).scaledBy(x: scale, y: scale)
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                paging = false; swipeDown199 = false
                if gesture.state == .ended && (dy > 95 || gesture.velocity(in: zoom).y > 640) { close() }
                else { UIView.animate(withDuration: storage.state.settings.reducedMotion ? 0 : 0.22) { self.media.transform = .identity } }
            }
            return
        }
        if gesture.state == .changed { media.transform = CGAffineTransform(translationX: dx * ((selected == 0 && dx > 0) || (selected == assets.count - 1 && dx < 0) ? 0.25 : 1), y: 0) }
        if gesture.state == .ended || gesture.state == .cancelled {
            let velocity = gesture.velocity(in: zoom).x
            let direction = abs(dx) >= 18 ? dx : velocity
            let destination = selected + (direction < 0 ? 1 : -1)
            let commit = gesture.state == .ended && assets.indices.contains(destination) && (abs(dx) > width * 0.17 || abs(velocity) > 570)
            let epoch = pageAnimationEpoch
            if commit {
                show(destination)
                if !storage.state.settings.reducedMotion {
                    media.transform = CGAffineTransform(translationX: direction < 0 ? width * 0.20 : -width * 0.20, y: 0)
                }
            }
            UIView.animate(withDuration: storage.state.settings.reducedMotion ? 0 : 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.media.transform = .identity
            } completion: { _ in
                guard epoch == self.pageAnimationEpoch else { return }
                self.paging = false
                self.activate()
            }
        }
    }
    @objc private func holdSpeed(_ gesture: UILongPressGestureRecognizer) {
        if assets[selected].mediaSubtypes.contains(.photoLive) { previewLive193(gesture); return }
        guard let player = player else { return }
        if gesture.state == .began {
            holding = true; holdOriginLocked = holdLocked
            if !holdLocked { baseRate = rate; basePlaying = player.rate > 0 }
            rate = 2; player.playImmediately(atRate: 2); speedHint.isHidden = false
        }
        let lock = gesture.location(in: view).y >= stage.frame.maxY - 80
        speedHint.text = lock ? Strings.text("松手锁定 / 取消 2×", "Release to lock / unlock 2×", "離して2倍速を固定 / 解除", "放開鎖定 / 取消 2×") : Strings.text("2× · 向下拖动可锁定", "2× · drag down to lock", "2倍速・下へ動かして固定", "2×・向下拖動可鎖定")
        if gesture.state == .ended || gesture.state == .cancelled {
            holding = false
            if gesture.state == .ended && lock { holdLocked = !holdOriginLocked } else { holdLocked = holdOriginLocked }
            if !holdLocked { rate = baseRate; if basePlaying { player.rate = rate } else { player.pause() } }
            speedHint.isHidden = !holdLocked; if holdLocked { speedHint.text = "2× · " + Strings.text("已锁定", "Locked", "固定中", "已鎖定") }
            updatePlayIcon(); activate()
        }
    }
    private func fittedMediaRect(bottomAligned: Bool) -> CGRect {
        guard assets.indices.contains(selected) else { return .zero }
        let item = assets[selected]
        let size = CGSize(width: max(1, item.pixelWidth), height: max(1, item.pixelHeight))
        var rect = AVMakeRect(aspectRatio: size, insideRect: media.bounds)
        if bottomAligned { rect.origin.y = media.bounds.maxY - rect.height }
        return rect
    }
    private func mediaFrame199() -> CGRect {
        guard assets.indices.contains(selected) else { return .zero }
        return media.convert(fittedMediaRect(bottomAligned: !immersive && assets[selected].mediaType == .image), to: view)
    }
    private func ghost199(_ photo: UIImage, at frame: CGRect) -> UIImageView {
        let ghost = UIImageView(image: photo)
        ghost.contentMode = .scaleAspectFill; ghost.clipsToBounds = true
        ghost.frame = frame; ghost.layer.cornerRadius = 10; view.addSubview(ghost)
        return ghost
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if strip.bounds.width > 0, assets.indices.contains(selected) {
            strip.scrollToItem(at: IndexPath(item: selected, section: 0), at: .centeredHorizontally, animated: false)
        }
        guard let photo = openingImage199, let origin = openingFrame199,
              let window = view.window, !storage.state.settings.reducedMotion else { return }
        openingImage199 = nil; openingFrame199 = nil
        let end = mediaFrame199(), ghost = ghost199(photo, at: view.convert(origin, from: window))
        guard !end.isEmpty else { ghost.removeFromSuperview(); return }
        media.alpha = 0; chrome.alpha = 0; controls.alpha = 0
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.87, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: {
            ghost.frame = end; ghost.layer.cornerRadius = 0
            self.chrome.alpha = 1; self.controls.alpha = 1
        }) { _ in self.media.alpha = 1; ghost.removeFromSuperview() }
    }
    @objc private func close() {
        guard !closing199 else { return }; closing199 = true
        stripCommit?.cancel()
        let photo = image.image ?? openingImage199
        let start = mediaFrame199()
        let target = assets.indices.contains(selected) ? returnFrame199?(assets[selected].localIdentifier, view) : nil
        generation += 1; stopPlayer(); repository.manager.cancelImageRequest(request)
        if let photo = photo, let target = target, !start.isEmpty, !storage.state.settings.reducedMotion {
            let ghost = ghost199(photo, at: start)
            ghost.layer.cornerRadius = 0; media.alpha = 0
            UIView.animate(withDuration: 0.31, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
                ghost.frame = target; ghost.layer.cornerRadius = 10
                self.backdrop.alpha = 0; self.view.backgroundColor = .clear
                self.chrome.alpha = 0; self.controls.alpha = 0
            }) { _ in self.dismiss(animated: false) }
        } else { dismiss(animated: false) }
        let storage = storage
        DispatchQueue.global(qos: .utility).async { try? storage.save() }
    }
    @objc private func toggleLive199() {
        liveStop199?.cancel()
        if liveHolding193 { setLive199(false); return }
        setLive199(true)
        let stop = DispatchWorkItem { [weak self] in self?.setLive199(false) }
        liveStop199 = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: stop)
    }
    private func previewLive193(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { setLive199(true) }
        else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { setLive199(false) }
    }
    private func setLive199(_ playing: Bool) {
        guard assets.indices.contains(selected) else { return }
        if assets[selected].encrypted != nil { previewPrivateLive193(playing); return }
        if playing {
            liveHolding193 = true; let token = generation
            let scale = view.window?.screen.scale ?? UIScreen.main.scale
            liveRequest193 = repository.livePhoto193(assets[selected], size: CGSize(width: max(600, media.bounds.width * scale), height: max(600, media.bounds.height * scale))) { [weak self] live in
                guard let self = self, self.generation == token, self.liveHolding193, let live = live else { return }
                self.live193.livePhoto = live; self.live193.startPlayback(with: .full)
                UIView.animate(withDuration: self.storage.state.settings.reducedMotion ? 0 : 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.live193.alpha = 1 }
            }
        } else {
            liveHolding193 = false; repository.manager.cancelImageRequest(liveRequest193)
            UIView.animate(withDuration: storage.state.settings.reducedMotion ? 0 : 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: { self.live193.alpha = 0 }) { _ in
                if !self.liveHolding193 { self.live193.stopPlayback(); self.live193.livePhoto = nil }
            }
        }
    }
    private func previewPrivateLive193(_ playing: Bool) {
        if playing {
            liveHolding193 = true; let token = generation
            repository.video(assets[selected]) { [weak self] item in
                guard let self = self, self.generation == token, self.liveHolding193, let item = item else { return }
                let clip = AVPlayer(playerItem: item)
                clip.isMuted = self.storage.state.settings.viewerMuted204 ?? false
                self.privateLive193 = clip
                CATransaction.begin(); CATransaction.setDisableActions(true); self.playerLayer.opacity = 0; self.playerLayer.player = clip; CATransaction.commit()
                self.privateLiveObservation193 = self.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == token, self.liveHolding193, layer.isReadyForDisplay else { return }
                        CATransaction.begin(); CATransaction.setAnimationDuration(self.storage.state.settings.reducedMotion ? 0 : 0.16); self.playerLayer.opacity = 1; CATransaction.commit()
                    }
                }; clip.play()
            }
        } else {
            liveHolding193 = false; privateLiveObservation193?.invalidate(); privateLiveObservation193 = nil
            CATransaction.begin(); CATransaction.setAnimationDuration(storage.state.settings.reducedMotion ? 0 : 0.18)
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self, !self.liveHolding193 else { return }; self.privateLive193?.pause(); self.privateLive193 = nil; self.playerLayer.player = self.player; self.playerLayer.opacity = 1
            }; playerLayer.opacity = 0; CATransaction.commit()
        }
    }
    private func stopPlayer() {
        liveStop199?.cancel()
        privateLiveObservation193?.invalidate(); privateLiveObservation193 = nil; privateLive193?.pause(); privateLive193 = nil; playerLayer.opacity = 1
        liveHolding193 = false; repository.manager.cancelImageRequest(liveRequest193); live193.layer.removeAllAnimations(); live193.stopPlayback(); live193.livePhoto = nil; live193.alpha = 0

        generator?.cancelAllCGImageGeneration(); generator = nil; seekActive = false; pendingSeek = nil; dragging = false
        if let periodic = periodic { player?.removeTimeObserver(periodic) }; periodic = nil
        if let ending = ending { NotificationCenter.default.removeObserver(ending) }; ending = nil
        player?.pause(); playerLayer.player = nil; player = nil
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView === zoom ? media : nil }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaCell.reuse, for: path) as! MediaCell, asset = assets[path.item], id = asset.localIdentifier
        cell.represented = id; cell.protectedBadge193.isHidden = true; cell.showName = false; cell.facts.isHidden = true; cell.videoIcon.isHidden = asset.mediaType != .video; cell.contentView.layer.cornerRadius = 8
        cell.contentView.layer.borderWidth = path.item == selected ? 2 : 0; cell.contentView.layer.borderColor = Theme.blue.cgColor
        repository.thumbnail(asset, pixels: 160) { [weak cell] image in if cell?.represented == id { cell?.image.image = image } }; return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        if path.item != selected { stripFeedback199.selectionChanged(); show(path.item) }
        else if stripPreview { finishStripSelection() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === strip { stripFeedback199.prepare() }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === strip, !storage.state.settings.reducedMotion, !UIAccessibility.isReduceMotionEnabled,
              abs(velocity.x) >= 0.45, assets.count > 1 else { return }
        let now = CACurrentMediaTime()
        let sign: CGFloat = velocity.x < 0 ? -1 : 1
        stripFlingBoost = now - lastStripFling < 0.7 && sign == lastStripDirection ? min(2.4, stripFlingBoost + 0.45) : 1
        lastStripDirection = sign
        lastStripFling = now
        let step = stripItemWidth + stripSpacing
        let additional = min(16 * step, abs(velocity.x) * step * stripFlingBoost)
        let projected = (targetContentOffset.pointee.x + sign * additional) / step
        targetContentOffset.pointee.x = min(CGFloat(assets.count - 1), max(0, projected.rounded())) * step
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === strip, strip.isTracking || strip.isDragging || strip.isDecelerating else { return }
        selectStripPreview()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === strip { selectStripPreview(); finishStripSelection() }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === strip && !decelerate { selectStripPreview(); finishStripSelection() }
    }
    private func selectStripPreview() {
        guard !assets.isEmpty, !closing199 else { return }
        let index = min(assets.count - 1, max(0, Int((strip.contentOffset.x / (stripItemWidth + stripSpacing)).rounded())))
        guard index != selected else { return }
        stripFeedback199.selectionChanged()
        stripFeedback199.prepare()
        stripCommit?.cancel()
        stripPreview = true
        show(index, count: false, centerStrip: false, posterOnly: true)
        let commit = DispatchWorkItem { [weak self] in
            guard let self = self, !self.strip.isTracking, !self.strip.isDragging, !self.strip.isDecelerating else { return }
            self.finishStripSelection()
        }
        stripCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: commit)
    }
    private func finishStripSelection() {
        guard stripPreview, !closing199 else { return }
        show(selected, centerStrip: false, keepingPoster: true)
    }
    private func time(_ value: Double) -> String { let seconds = value.isFinite ? max(0, Int(value)) : 0; return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    @objc private func backgrounded() { stripCommit?.cancel(); privateLiveObservation193?.invalidate(); privateLiveObservation193 = nil; privateLive193?.pause(); privateLive193 = nil; playerLayer.player = player; playerLayer.opacity = 1; liveHolding193 = false; repository.manager.cancelImageRequest(liveRequest193); live193.stopPlayback(); live193.livePhoto = nil; live193.alpha = 0; player?.pause(); holding = false; updatePlayIcon() }
    deinit { stripCommit?.cancel(); stopPlayer(); fade?.cancel(); NotificationCenter.default.removeObserver(self) }
}

// Accumulate every touch delta before quantization, including sub-frame movements.
final class FineTimeline122: UISlider {
    var onBegin: (() -> Void)?
    var framesPerSecond: () -> Double = { 30 }
    var finePixels: Double = 2
    private var previous = CGPoint.zero, anchor = CGPoint.zero, raw: Double = 0
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        onBegin?()
        anchor = touch.location(in: self); previous = anchor
        let track = trackRect(forBounds: bounds), fraction = max(0, min(1, (anchor.x - track.minX) / max(1, track.width)))
        raw = Double(minimumValue) + Double(maximumValue - minimumValue) * Double(fraction)
        value = Float(raw); sendActions(for: .valueChanged)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self), delta = Double(point.x - previous.x)
        let precision = abs(point.y - anchor.y) > 36
        let secondsPerPoint = precision ? 1 / (max(1, framesPerSecond()) * max(1, finePixels)) : Double(maximumValue - minimumValue) / Double(max(1, trackRect(forBounds: bounds).width))
        raw = max(Double(minimumValue), min(Double(maximumValue), raw + delta * secondsPerPoint)); previous = point
        value = Float(GalleryRules122.quantize(raw, duration: Double(maximumValue), fps: framesPerSecond())); sendActions(for: .valueChanged)
        return true
    }
}
