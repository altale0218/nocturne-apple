import UIKit
import Photos
import Network
import Darwin

struct AppleAlbumTransferMetrics {
    let done: Int64
    let total: Int64
    let inventory: Int64?
    let bytesPerSecond: Int64?
    let secondsRemaining: Int?

    init?(done: Int64, total: Int64, rate: Double, inventory: Int64?) {
        let limit: Int64 = 1 << 50
        guard total > 0, total <= limit, done >= 0, done <= total else { return nil }
        self.done = done
        self.total = total
        self.inventory = inventory.flatMap { (total...limit).contains($0) ? $0 : nil }
        if done > 0, done < total, rate.isFinite, rate >= 1 {
            bytesPerSecond = Int64(min(rate, 1_000_000_000_000))
            secondsRemaining = Int(ceil(min(3_599_999, Double(total - done) / rate)))
        } else {
            bytesPerSecond = nil
            secondsRemaining = nil
        }
    }

    var fraction: Float { Float(Double(done) / Double(total)) }
}

/// The user opens a single, foreground session and selects the ordinary albums before any originals are read.
private struct AppleAlbumSession {
    struct Settings: Codable {
        let id: String
        let pin: String
        var peer: StoredPeer?
    }
    struct StoredPeer: Codable {
        let id: String
        let name: String
        let pin: String
        let key: Data
        let address: String
        let trusted: Bool

        init(_ peer: AppleSyncTransport.Peer, trusted: Bool) {
            id = peer.identity.id
            name = peer.identity.name
            pin = peer.identity.pin
            key = peer.key
            address = peer.address
            self.trusted = trusted
        }

        func connect(address current: String) throws -> AppleSyncTransport.Peer {
            guard trusted, key.count == 32 else { throw AppleSyncTransport.Failure.authentication }
            let identity = try AppleSyncTransport.Identity(id: id, name: name, pin: pin)
            return AppleSyncTransport.Peer(identity: identity, key: key, address: current)
        }
    }

    struct TransferStatus {
        let message: String
        var metrics: AppleAlbumTransferMetrics? = nil
        var inventory: Int64? = nil
        var itemProgress: Float? = nil
    }

    let storage: SecureStorage
    let lease: Int

    private var key: String { AppleSyncTransport.hash("mobile-album-credentials-v1") }

    func settings() throws -> Settings {
        if let data = try storage.albumSyncRecord(key, lease: lease) {
            return try JSONDecoder().decode(Settings.self, from: data)
        }
        let pin = AppleSyncTransport.hex(try AuthenticatedCipher.random(32))
        let value = Settings(id: Self.identifier(), pin: pin)
        try save(value)
        return value
    }

    func save(_ value: Settings) throws {
        try storage.writeAlbumSyncRecord(JSONEncoder().encode(value), name: key, lease: lease)
    }

    @MainActor func local(_ settings: Settings) throws -> AppleSyncTransport.Identity {
        try AppleSyncTransport.Identity(id: settings.id, name: UIDevice.current.model, pin: settings.pin)
    }

    static func identifier() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    func transfer(peer: AppleSyncTransport.Peer, local: AppleSyncTransport.Identity, album: PhotoSyncLibrary.Album,
                  sendTo androidTarget: String?, receiveFrom androidSource: String?, allowICloud: Bool,
                  progress: @escaping (TransferStatus) -> Void) async throws -> String {
        guard androidTarget != nil || androidSource != nil else { throw MediaError193.malformed }
        guard album.identifier != PhotoSyncLibrary.Album.recent.identifier || androidSource == nil else { throw MediaError193.unavailable }
        let library = PhotoSyncLibrary(storage: storage)
        var source: PhotoAlbumSource?
        if androidTarget != nil {
            let selected = try library.albumContents(album.identifier, lease: lease)
            progress(TransferStatus(message: "正在检查 \(selected.visible.count) 项原始资源…"))
            let namespace = "android-peer/" + peer.identity.id
            source = try await PhotoAlbumSource.prepare(storage: storage, selected: selected, namespace: namespace,
                                                        allowICloud: allowICloud, lease: lease) { done, total in
                progress(TransferStatus(message: "核验原片 \(done)/\(total)"))
            }
        }
        let target = androidSource.map { _ in
            PhotoAlbumTarget(storage: storage, albumID: album.identifier, peer: peer.identity.id,
                             lease: lease, allowICloud: allowICloud, prepared: source) { done, total in
                progress(TransferStatus(message: "核对本机相册原件 \(done)/\(total)"))
            }
        }
        let resume = TransferAttempt()
        do {
            return try await transferPass(peer: peer, local: local, source: source, target: target,
                androidTarget: androidTarget, androidSource: androidSource, attempt: resume, progress: progress)
        } catch {
            guard resume.scopeCommitted, Self.canReconnect(error) else { throw error }
            try Task.checkCancellation()
            try storage.validateResourceLease193(lease)
            progress(TransferStatus(message: "连接中断，正在重新连接。已保存的原件会先核对。"))
            try await Task.sleep(nanoseconds: 1_250_000_000)
            try storage.validateResourceLease193(lease)
            source?.rewindForReconnect()
            return try await transferPass(peer: peer, local: local, source: source, target: target,
                androidTarget: androidTarget, androidSource: androidSource, attempt: TransferAttempt(),
                resuming: true, progress: progress)
        }
    }

    private final class TransferAttempt { var scopeCommitted = false }

    fileprivate static func canReconnect(_ error: Error) -> Bool {
        switch error {
        case AppleSyncTransport.Failure.closed, AppleSyncTransport.Failure.timeout: return true
        case let NWError.posix(code):
            return [.ECONNABORTED, .ECONNRESET, .ENOTCONN, .EPIPE, .ENETDOWN, .ENETUNREACH, .ETIMEDOUT].contains(code)
        default: return false
        }
    }

    private func transferPass(peer: AppleSyncTransport.Peer, local: AppleSyncTransport.Identity,
                              source: PhotoAlbumSource?, target: PhotoAlbumTarget?,
                              androidTarget: String?, androidSource: String?,
                              attempt: TransferAttempt, resuming: Bool = false,
                              progress: @escaping (TransferStatus) -> Void) async throws -> String {
        try Task.checkCancellation()
        try storage.validateResourceLease193(lease)
        progress(TransferStatus(message: "等待 Android 确认相册范围…"))
        let channel = try await AppleSyncTransport.authenticate(peer, local: local, resuming: resuming)
        do {
            let job = Self.identifier(), epoch = Self.identifier()
            var request: [String: Any] = ["job": job, "epoch": epoch, "scope": "ordinary195"]
            request["op"] = "scope195"; request["platform"] = "ios"; request["operation"] = "album1"
            if let androidTarget = androidTarget { request["upload"] = androidTarget }
            if let androidSource = androidSource { request["download"] = androidSource }
            try await channel.sendObject(1, request)
            let ready = try await channel.receiveObject(1)
            let context: [String: String] = ["job": job, "epoch": epoch, "scope": "ordinary195"]
            try Self.checkContext(ready, context)
            switch ready["op"] as? String {
            case "scope-busy195": throw AppleSyncTransport.Failure.rejected("busy")
            case "scope-denied200":
                if let reason = ready["operation"] as? String, reason == "mode173" || reason == "consent173" {
                    throw AppleSyncTransport.Failure.rejected(reason)
                }
                throw AppleSyncTransport.Failure.declined
            default:
                guard ready["op"] as? String == "scope-ready195", ready["operation"] as? String == "album1",
                      ready["platform"] as? String == "android" else { throw MediaError193.verification }
            }
            try await channel.sendObject(1, Self.control("scope-commit195", context))
            attempt.scopeCommitted = true
            var details: [String] = []
            if let source = source {
                progress(TransferStatus(message: "正在发送 \(source.count) 项…"))
                var inventory: Int64?
                try await MobileAlbumTransfer.send(source, channel: channel, onInventory: {
                    inventory = $0
                    progress(TransferStatus(message: "正在与 Android 核对原件…", inventory: inventory))
                }, onPayload: { done, total, rate in
                    progress(Self.payloadLabel(done, total: total, rate: rate, inventory: inventory))
                }) { done, total in
                    progress(TransferStatus(message: "Android 已核对 \(done)/\(total) 项",
                                            inventory: inventory, itemProgress: Self.itemProgress(done, total)))
                }
                details.append("Android 已核对 \(source.confirmed.count) 项，共 \(source.count + source.unavailable) 项")
            }
            if let target = target {
                let writing = try storage.beginAlbumPhotosWrite(lease: lease)
                defer { storage.finishAlbumPhotosWrite(writing) }
                progress(TransferStatus(message: "正在接收 Android 相册…"))
                var inventory: Int64?
                try await MobileAlbumTransfer.receive(target, channel: channel, onInventory: {
                    inventory = $0
                    progress(TransferStatus(message: "正在核对相册中的原件…", inventory: inventory))
                }, onPayload: { done, total, rate in
                    progress(Self.payloadLabel(done, total: total, rate: rate, inventory: inventory))
                }) { done, total in
                    progress(TransferStatus(message: "本机已核对 \(done)/\(total) 项",
                                            inventory: inventory, itemProgress: Self.itemProgress(done, total)))
                }
                let completed = target.imported + target.reused
                details.append("iOS 新增 \(target.imported) 项，复用 \(target.reused) 项，待处理 \(max(0, target.total - completed)) 项")
                if target.undated > 0 { details.append("其中 \(target.undated) 项无可确认的拍摄时间，未写入系统相册") }
                if target.metadataConflicts > 0 {
                    details.append("其中 \(target.metadataConflicts) 项原件已存在，拍摄信息或收藏状态需核对，已保留现有项目。")
                }
                if target.localUnverified > 0 {
                    details.append("本机相册有 \(target.localUnverified) 项原件暂时不可核验，请检查照片授权或 iCloud 下载状态。")
                }
            }
            try await channel.sendObject(1, Self.control("scope-done195", context))
            let done = try await channel.receiveObject(1)
            try Self.checkContext(done, context)
            guard done["op"] as? String == "scope-done195" else { throw MediaError193.verification }
            await channel.close()
            return details.joined(separator: "\n")
        } catch {
            await channel.close()
            throw error
        }
    }

    private static func itemProgress(_ checked: Int, _ total: Int) -> Float? {
        guard total > 0, (0...total).contains(checked) else { return nil }
        return Float(checked) / Float(total)
    }

    private static func payloadLabel(_ done: Int64, total: Int64, rate: Double, inventory: Int64?) -> TransferStatus {
        let metrics = AppleAlbumTransferMetrics(done: done, total: total, rate: rate, inventory: inventory)
        let message = done == total
            ? Strings.text("正在校验写入", "Verifying and saving", "検証して保存中", "正在驗證並寫入")
            : Strings.text("正在加密传输", "Transferring securely", "暗号化して転送中", "正在加密傳輸")
        return TransferStatus(message: message, metrics: metrics)
    }

    private static func control(_ operation: String, _ context: [String: String]) -> [String: Any] {
        var value: [String: Any] = context
        value["op"] = operation
        return value
    }

    private static func checkContext(_ value: [String: Any], _ context: [String: String]) throws {
        guard context.allSatisfy({ key, expected in value[key] as? String == expected })
              else { throw MediaError193.changed }
    }
}

final class AppleAlbumSyncController: UIViewController, NetServiceBrowserDelegate, NetServiceDelegate {
    private let nearbyDevices = UIStackView()
    private var deviceBrowser: NetServiceBrowser?
    private var presenceService: NetService?
    private var resolvingDevices: [String: NetService] = [:]
    private var nearbyAddresses: [String: String] = [:]
    private var visibleForDiscovery = false
    private let storage: SecureStorage
    private let album = UIButton(type: .system), pairing = UIButton(type: .system), start = UIButton(type: .system)
    private let manage = UIButton(type: .system)
    private let address = UITextField(), androidAlbum = UITextField()
    private let direction = UISegmentedControl(items: ["发送到 Android", "接收至 iOS", "双向"])
    private let useCloud = UISwitch(), status = UILabel()
    private let syncProgress = UIProgressView(progressViewStyle: .default)
    private let statusCard = UIStackView()
    private let metricsStack = UIStackView()
    private var metricsRows: [UIStackView] = []
    private var metricValues: [UILabel] = []
    private let byteFormatter = ByteCountFormatter()
    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private var statusEpoch = 0
    private var chosen: PhotoSyncLibrary.Album?
    private var job: Task<Void, Never>?
    private var codeReply: CheckedContinuation<Bool, Never>?
    private static var wakeLeases = 0
    private static var previousIdleTimer = false

    init(storage: SecureStorage) { self.storage = storage; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "手机相册同步"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        address.placeholder = "Android 的局域网 IP"
        address.textContentType = nil
        address.keyboardType = .numbersAndPunctuation
        address.autocorrectionType = .no
        androidAlbum.placeholder = "Android 相册名称"
        direction.selectedSegmentIndex = 2
        for field in [address, androidAlbum] {
            field.borderStyle = .roundedRect
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }
        address.accessibilityLabel = "Android 的局域网 IP 地址"
        androidAlbum.accessibilityLabel = "Android 相册名称"
        address.addTarget(self, action: #selector(scopeChanged), for: .editingChanged)
        androidAlbum.addTarget(self, action: #selector(scopeChanged), for: .editingChanged)
        direction.accessibilityLabel = "相册同步方向"
        direction.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        useCloud.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        album.configuration = Self.action(title: "选择 iOS 相册", symbol: "photo.on.rectangle.angled")
        album.addTarget(self, action: #selector(choose), for: .touchUpInside)
        manage.setTitle("管理 iOS 相册内容", for: .normal)
        manage.addTarget(self, action: #selector(manageAlbum), for: .touchUpInside)
        manage.isHidden = true
        pairing.configuration = Self.action(title: "配对 Android", symbol: "link")
        pairing.addTarget(self, action: #selector(pair), for: .touchUpInside)
        start.configuration = Self.action(title: "开始同步", symbol: "arrow.left.arrow.right", primary: true)
        start.addTarget(self, action: #selector(run), for: .touchUpInside)
        for button in [album, manage, pairing, start] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        }
        let cloudLabel = Self.label("允许从 iCloud 下载所选原片", style: .subheadline)
        useCloud.accessibilityLabel = cloudLabel.text
        useCloud.setContentCompressionResistancePriority(.required, for: .horizontal)
        let cloud = UIStackView(arrangedSubviews: [cloudLabel, useCloud])
        cloud.alignment = .center
        cloud.spacing = 10
        status.numberOfLines = 0
        status.textColor = .label
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.adjustsFontForContentSizeCategory = true
        let progressTitle = Self.label("同步状态", style: .headline)
        progressTitle.accessibilityTraits.insert(.header)
        configureMetrics()
        Self.styleCard(statusCard, views: [progressTitle, status, syncProgress, metricsStack])
        syncProgress.isHidden = true
        syncProgress.accessibilityLabel = "本批次影像传输进度"
        nearbyDevices.axis = .vertical
        nearbyDevices.spacing = 8
        let pairCard = Self.card("连接设备", fields: [nearbyDevices, address, pairing])
        refreshNearbyDevices()
        NotificationCenter.default.addObserver(self, selector: #selector(stopDiscovery),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(startDiscovery),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        let albumCard = Self.card("同步范围", fields: [album, manage, androidAlbum, direction, cloud])
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView(arrangedSubviews: [pairCard, albumCard, start, statusCard])
        stack.axis = .vertical; stack.spacing = 14
        view.addSubview(scroll); scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            preferredWidth
        ])
        if let lease = try? storage.resourceLease193(),
           let peer = try? AppleAlbumSession(storage: storage, lease: lease).settings().peer, peer.trusted {
            address.text = peer.address
            status.text = "已配对 \(peer.name)"
        } else {
            status.text = "在 Android 打开「同步设备」，确保两台设备连接同一个局域网。"
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelActive),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            layoutMetrics()
        }
    }

    private func configureMetrics() {
        byteFormatter.countStyle = .file
        metricsStack.axis = .vertical
        metricsStack.spacing = 8
        metricsStack.isHidden = true
        let captions = [
            Strings.text("已传输 / 批次容量", "Transferred / batch size", "転送済み / バッチ容量", "已傳輸 / 批次容量"),
            Strings.text("相册原件总量", "Total originals", "アルバム原本の容量", "相簿原始檔總量"),
            Strings.text("当前速率", "Current rate", "現在の転送速度", "目前速率"),
            Strings.text("本批次预计剩余", "Batch time left", "バッチの残り時間", "本批次預計剩餘")
        ]
        for start in [0, 2] {
            let row = UIStackView()
            row.spacing = 8
            for caption in captions[start..<(start + 2)] {
                let label = Self.label(caption, style: .caption1)
                label.textColor = .secondaryLabel
                let value = Self.label("—", style: .subheadline)
                let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
                value.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: font)
                let tile = UIStackView()
                Self.styleCard(tile, views: [label, value])
                tile.backgroundColor = .tertiarySystemGroupedBackground
                tile.layer.cornerRadius = 12
                tile.spacing = 3
                tile.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
                value.accessibilityLabel = caption
                label.isAccessibilityElement = false
                row.addArrangedSubview(tile)
                metricValues.append(value)
            }
            metricsRows.append(row)
            metricsStack.addArrangedSubview(row)
        }
        layoutMetrics()
    }

    private func layoutMetrics() {
        let vertical = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in metricsRows {
            row.axis = vertical ? .vertical : .horizontal
            row.distribution = vertical ? .fill : .fillEqually
        }
    }

    private func clearTransferMetrics() {
        syncProgress.isHidden = true
        syncProgress.progress = 0
        metricsStack.isHidden = true
    }

    private func showTransfer(_ update: AppleAlbumSession.TransferStatus) {
        if status.text != update.message { status.text = update.message }
        func bytes(_ count: Int64) -> String {
            byteFormatter.string(fromByteCount: count)
        }
        guard let metrics = update.metrics else {
            if let capacity = update.inventory {
                showMetricValues(["—", bytes(capacity), "—", "—"])
            } else {
                metricsStack.isHidden = true
            }
            syncProgress.isHidden = update.itemProgress == nil
            syncProgress.setProgress(update.itemProgress ?? 0, animated: false)
            return
        }
        let rate = metrics.bytesPerSecond.map { bytes($0) + "/s" } ?? "—"
        let time: String
        if let seconds = metrics.secondsRemaining {
            let duration = seconds < 60 ? seconds : ((seconds + 59) / 60) * 60
            durationFormatter.allowedUnits = duration < 60 ? [.second] : duration < 3600 ? [.minute] : [.hour, .minute]
            time = durationFormatter.string(from: TimeInterval(duration)) ?? "—"
        } else {
            time = "—"
        }
        showMetricValues(["\(bytes(metrics.done)) / \(bytes(metrics.total))", metrics.inventory.map(bytes) ?? "—", rate, time])
        syncProgress.isHidden = false
        syncProgress.setProgress(metrics.fraction, animated: !UIAccessibility.isReduceMotionEnabled
            && metrics.fraction > syncProgress.progress)
    }

    private func showMetricValues(_ values: [String]) {
        for (label, value) in zip(metricValues, values) where label.text != value {
            label.text = value
            label.accessibilityValue = value
        }
        metricsStack.isHidden = false
    }

    private static func action(title: String, symbol: String, primary: Bool = false) -> UIButton.Configuration {
        var action: UIButton.Configuration
        if #available(iOS 26.0, *) {
            action = primary ? .prominentGlass() : .glass()
        } else {
            action = primary ? .filled() : .tinted()
        }
        action.title = title
        action.image = UIImage(systemName: symbol)
        action.imagePadding = 8
        action.cornerStyle = .capsule
        return action
    }

    private static func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .label
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private static func card(_ name: String, fields: [UIView]) -> UIStackView {
        let heading = label(name, style: .headline)
        heading.accessibilityTraits.insert(.header)
        let panel = UIStackView()
        styleCard(panel, views: [heading] + fields)
        return panel
    }

    private static func styleCard(_ card: UIStackView, views: [UIView]) {
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        for view in views { card.addArrangedSubview(view) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visibleForDiscovery = true
        startDiscovery()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visibleForDiscovery = false
        stopDiscovery()
    }

    @objc private func startDiscovery() {
        guard visibleForDiscovery, UIApplication.shared.applicationState == .active,
              deviceBrowser == nil, storage.isUnlocked193, !storage.envelope.privateMode else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        deviceBrowser = browser
        browser.searchForServices(ofType: "_nocturne-sync._tcp.", inDomain: "local.")
        // This DNS-SD record only signals presence. No application socket listens at the discard port.
        let presence = NetService(domain: "local.", type: "_nocturne-ios._tcp.", name: "Nocturne Apple", port: 9)
        presenceService = presence
        presence.publish()
    }

    @objc private func stopDiscovery() {
        deviceBrowser?.stop()
        deviceBrowser?.delegate = nil
        deviceBrowser = nil
        presenceService?.stop()
        presenceService = nil
        for service in resolvingDevices.values { service.stop(); service.delegate = nil }
        resolvingDevices.removeAll()
        nearbyAddresses.removeAll()
        refreshNearbyDevices()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === deviceBrowser, service.name.hasPrefix("Nocturne Android"),
              resolvingDevices[service.name] == nil, resolvingDevices.count < 16 else { return }
        resolvingDevices[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === deviceBrowser else { return }
        let removed = resolvingDevices.removeValue(forKey: service.name)
        removed?.delegate = nil
        removed?.stop()
        nearbyAddresses.removeValue(forKey: service.name)
        refreshNearbyDevices()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard resolvingDevices[sender.name] === sender, sender.port == 48773,
              let ip = sender.addresses?.compactMap(Self.localIPv4).first else { return }
        nearbyAddresses[sender.name] = ip
        refreshNearbyDevices()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard resolvingDevices[sender.name] === sender else { return }
        resolvingDevices.removeValue(forKey: sender.name)
    }

    private static func localIPv4(_ data: Data) -> String? {
        guard data.count == MemoryLayout<sockaddr_in>.size else { return nil }
        var address = sockaddr_in()
        _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0) }
        guard address.sin_family == sa_family_t(AF_INET) else { return nil }
        let value = UInt32(bigEndian: address.sin_addr.s_addr)
        let first = value >> 24, second = value >> 16 & 255
        guard first == 10 || (first == 172 && (16...31).contains(second)) ||
              (first == 192 && second == 168) else { return nil }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address.sin_addr, &host, socklen_t(host.count)) != nil else { return nil }
        return String(cString: host)
    }

    private func refreshNearbyDevices() {
        for view in nearbyDevices.arrangedSubviews { nearbyDevices.removeArrangedSubview(view); view.removeFromSuperview() }
        if nearbyAddresses.isEmpty {
            nearbyDevices.addArrangedSubview(Self.label("附近的 Android 设备会显示在这里，也可以手动输入地址。", style: .footnote))
        }
        for (label, ip) in nearbyAddresses.sorted(by: { $0.key < $1.key }) {
            let button = UIButton(type: .system)
            button.configuration = Self.action(title: "\(label) · \(ip)", symbol: "iphone")
            button.addAction(UIAction { [weak self] _ in
                guard let self = self, self.job == nil else { return }
                self.address.text = ip
                self.scopeChanged()
                self.pair()
            }, for: .touchUpInside)
            nearbyDevices.addArrangedSubview(button)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func close() {
        cancelActive()
        dismiss(animated: true)
    }

    @objc private func cancelActive() {
        job?.cancel()
        if let pending = codeReply { codeReply = nil; pending.resume(returning: false) }
    }

    private func setBusy(_ running: Bool) {
        nearbyDevices.isUserInteractionEnabled = !running
        let controls: [UIControl] = [address, androidAlbum, direction, pairing, album, manage, useCloud, start]
        controls.forEach { $0.isEnabled = !running }
        navigationController?.isModalInPresentation = running
        navigationItem.leftBarButtonItem = running
            ? UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelActive))
            : UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        if !running {
            statusEpoch += 1
            clearTransferMetrics()
        }
    }

    @objc private func choose() {
        guard job == nil else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard PhotoSyncLibrary.allowsReadWrite(allowed) else { self.status.text = "请在系统设置允许访问需要同步的相册。"; return }
                do {
                    let library = PhotoSyncLibrary(storage: self.storage)
                    let lease = try self.storage.resourceLease193()
                    let albums = try library.albums(lease: lease)
                    let picker = UIAlertController(title: "选择 iOS 相册", message: allowed == .limited ? "照片同步限于系统已授权范围。若要选择完整图库或更多已有相册，请在系统设置调整照片访问权限。" : nil,
                                                   preferredStyle: .actionSheet)
                    for value in [PhotoSyncLibrary.Album.all, .recent] + albums {
                        picker.addAction(UIAlertAction(title: value.title, style: .default) { _ in
                            self.selectAlbum(value)
                        })
                    }
                    if allowed == .limited {
                        picker.addAction(UIAlertAction(title: "打开照片访问设置", style: .default) { _ in
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        })
                        picker.addAction(UIAlertAction(title: "管理已授权的照片", style: .default) { [weak self] _ in
                            guard let self = self else { return }
                            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { _ in
                                DispatchQueue.main.async { self.status.text = "照片授权范围已更新，请重新选择同步相册。" }
                            }
                        })
                    }
                    picker.addAction(UIAlertAction(title: "新建相册", style: .default) { _ in self.createAlbum(library, lease: lease) })
                    picker.addAction(UIAlertAction(title: "取消", style: .cancel))
                    picker.popoverPresentationController?.sourceView = self.album
                    picker.popoverPresentationController?.sourceRect = self.album.bounds
                    self.present(picker, animated: true)
                } catch { self.show(error) }
            }
        }
    }

    private func createAlbum(_ library: PhotoSyncLibrary, lease: Int) {
        let prompt = UIAlertController(title: "新建相册", message: nil, preferredStyle: .alert)
        prompt.addTextField { $0.placeholder = "相册名称" }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "创建", style: .default) { [weak self, weak prompt] _ in
            let name = prompt?.textFields?.first?.text ?? ""
            self?.task {
                guard let self = self else { return }
                let created = try await library.createAlbum(name, lease: lease)
                self.selectAlbum(created)
            }
        })
        present(prompt, animated: true)
    }

    @objc private func scopeChanged() { start.configuration?.title = "开始同步" }

    private func selectAlbum(_ value: PhotoSyncLibrary.Album) {
        scopeChanged()
        chosen = value
        album.configuration?.title = value.title
        manage.isHidden = value.isLibraryScope
        let recentOnly = value.identifier == PhotoSyncLibrary.Album.recent.identifier
        if recentOnly { direction.selectedSegmentIndex = 0 }
        direction.isEnabled = !recentOnly
    }

    @objc private func manageAlbum() {
        guard let chosen = chosen, !chosen.isLibraryScope, job == nil else { return }
        do {
            let lease = try storage.resourceLease193()
            let library = PhotoSyncLibrary(storage: storage)
            let controller = AppleAlbumContentsController(library: library, storage: storage, album: chosen, lease: lease)
            navigationController?.pushViewController(controller, animated: true)
        } catch { show(error) }
    }

    @objc private func pair() {
        view.endEditing(true)
        let ip = address.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        task {
            let session = AppleAlbumSession(storage: self.storage, lease: try self.storage.resourceLease193())
            var settings = try session.settings()
            self.status.text = "正在核对 Android 设备身份…"
            let remote = try await AppleSyncTransport.probe(address: ip)
            let local = try session.local(settings)
            let peer = try await AppleSyncTransport.pair(address: ip, remote: remote, local: local, confirm: { name, code in
                await self.enterCode(name: name, expected: code)
            }, store: { peer, trusted in
                settings.peer = AppleAlbumSession.StoredPeer(peer, trusted: trusted)
                try session.save(settings)
            })
            self.status.text = "已配对 \(peer.identity.name)"
        }
    }

    private func enterCode(name: String, expected: String) async -> Bool {
        await withCheckedContinuation { reply in
            codeReply = reply
            let dialog = UIAlertController(title: "输入同步连接码", message: "请输入 \(name) 上显示的六位数字。",
                                           preferredStyle: .alert)
            status.text = "等待确认配对码。"
            dialog.addTextField {
                $0.keyboardType = .numberPad
                $0.textContentType = .oneTimeCode
                $0.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium)
                $0.textAlignment = .center
                $0.placeholder = "000000"
                $0.accessibilityLabel = "六位配对码"
            }
            dialog.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.replyToCode(false) })
            let connect = UIAlertAction(title: "连接", style: .default) { [weak self, weak dialog] _ in
                let actual = dialog?.textFields?.first?.text ?? ""
                self?.replyToCode(actual == expected)
            }
            connect.isEnabled = false
            if let field = dialog.textFields?.first {
                field.addAction(UIAction { [weak field, weak connect] _ in
                    let bytes = (field?.text ?? "").utf8
                    connect?.isEnabled = bytes.count == 6 && bytes.allSatisfy { (48...57).contains($0) }
                }, for: .editingChanged)
            }
            dialog.addAction(connect)
            dialog.preferredAction = connect
            present(dialog, animated: true)
        }
    }

    private func replyToCode(_ accepted: Bool) {
        if let reply = codeReply { codeReply = nil; reply.resume(returning: accepted) }
    }

    @objc private func run() {
        view.endEditing(true)
        let ip = address.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = androidAlbum.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let selected = chosen, !target.isEmpty, target.utf16.count <= 72, !target.contains("/"),
              !target.contains("\\"), target != ".", target != "..",
              target.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            status.text = "请选择 iOS 相册并填写 Android 相册名称。"
            return
        }
        let selectedDirection = selected.identifier == PhotoSyncLibrary.Album.recent.identifier ? 0 : direction.selectedSegmentIndex, cloud = useCloud.isOn
        scopeChanged()
        task(keepsScreenAwake: true) {
            let session = AppleAlbumSession(storage: self.storage, lease: try self.storage.resourceLease193())
            let settings = try session.settings()
            guard let paired = settings.peer, paired.trusted else { throw AppleSyncTransport.Failure.authentication }
            let peer = try paired.connect(address: ip)
            let statusEpoch = self.statusEpoch
            self.status.text = try await session.transfer(peer: peer, local: session.local(settings), album: selected,
                sendTo: selectedDirection == 1 ? nil : target, receiveFrom: selectedDirection == 0 ? nil : target,
                allowICloud: cloud) { [weak self] update in
                    DispatchQueue.main.async {
                        guard let self = self, self.statusEpoch == statusEpoch else { return }
                        self.showTransfer(update)
                    }
                }
        }
    }

    private func task(keepsScreenAwake: Bool = false, _ action: @escaping () async throws -> Void) {
        guard job == nil else { return }
        setBusy(true)
        if keepsScreenAwake {
            if Self.wakeLeases == 0 { Self.previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            Self.wakeLeases += 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
        job = Task {
            defer {
                if keepsScreenAwake {
                    Self.wakeLeases -= 1
                    if Self.wakeLeases == 0 { UIApplication.shared.isIdleTimerDisabled = Self.previousIdleTimer }
                }
                self.job = nil
                self.setBusy(false)
            }
            do { try await action() }
            catch { self.show(error) }
        }
    }

    private func show(_ error: Error) {
        switch error {
        case AppleSyncTransport.Failure.address: status.text = "请输入同一局域网内 Android 的 IP 地址。"
        case AppleSyncTransport.Failure.certificate, AppleSyncTransport.Failure.changedPeer: status.text = "Android 设备的身份无法核对，请检查地址或重新配对。"
        case AppleSyncTransport.Failure.authentication: status.text = "请先配对 Android。"
        case AppleSyncTransport.Failure.rejected("album-version"): status.text = "Android 端需要支持手机相册同步的版本。"
        case AppleSyncTransport.Failure.declined, MediaError193.cancelled, is CancellationError:
            status.text = "已取消。再次同步时会先核对已接收原片。"
        case let failure where AppleAlbumSession.canReconnect(failure):
            start.configuration?.title = "继续同步"
            status.text = "连接中断。重新连接同一局域网后，可继续核对并传输剩余原片。"
        case AppleSyncTransport.Failure.rejected("busy"): status.text = "Android 正在处理其他同步，请稍后重试。"
        case AppleSyncTransport.Failure.rejected("mode173"), AppleSyncTransport.Failure.rejected("consent173"):
            status.text = "请在 Android 的「同步设备」中允许同步普通图库。"
        case let error as PhotoSyncLibrary.CreatedButUnverified:
            status.text = "系统相册已接收一项，验证未通过。再次同步会先核对原记录。\(error.underlying.localizedDescription)"
        default: status.text = "同步未完成。\(error.localizedDescription)"
        }
    }
}

/// Destructive actions are always scoped to the albums and originals selected on this device.
private final class AppleAlbumContentsController: UITableViewController, UITableViewDataSourcePrefetching {
    private let library: PhotoSyncLibrary
    private let storage: SecureStorage
    private let album: PhotoSyncLibrary.Album
    private let lease: Int
    private let images = PHCachingImageManager()
    private var prefetched: [IndexPath: PHAsset] = [:]
    private var assets: [PHAsset] = []
    private var working = false
    private var reviewJob: Task<Void, Never>?
    private var review: [(title: String, assets: [PHAsset])]?
    private let empty = UILabel()
    private let editButton = UIBarButtonItem(title: "管理所选项", style: .plain, target: nil, action: nil)
    private let reviewButton = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), style: .plain, target: nil, action: nil)

    init(library: PhotoSyncLibrary, storage: SecureStorage, album: PhotoSyncLibrary.Album, lease: Int) {
        self.library = library
        self.storage = storage
        self.album = album
        self.lease = lease
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = album.title
        tableView.allowsMultipleSelection = true
        tableView.register(AppleAlbumAssetCell.self, forCellReuseIdentifier: "album-item")
        tableView.prefetchDataSource = self
        tableView.rowHeight = 66
        empty.numberOfLines = 0
        empty.textColor = .secondaryLabel
        empty.font = .preferredFont(forTextStyle: .body)
        empty.adjustsFontForContentSizeCategory = true
        empty.textAlignment = .center
        editButton.target = self; editButton.action = #selector(actions)
        reviewButton.target = self; reviewButton.action = #selector(reviewDuplicates)
        reviewButton.accessibilityLabel = "检查重复与相似项目"
        navigationItem.rightBarButtonItems = [editButton, reviewButton]
        refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopThumbnailPrefetch()
    }

    private func stopThumbnailPrefetch() {
        guard !prefetched.isEmpty else { return }
        images.stopCachingImagesForAllAssets()
        prefetched.removeAll(keepingCapacity: true)
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        var cached = Set(prefetched.values.map(\.localIdentifier))
        var newAssets: [PHAsset] = []
        for path in indexPaths {
            guard prefetched.count < 48 else { break }
            guard prefetched[path] == nil, let item = asset(at: path) else { continue }
            prefetched[path] = item
            if cached.insert(item.localIdentifier).inserted { newAssets.append(item) }
        }
        guard !newAssets.isEmpty else { return }
        images.startCachingImages(for: newAssets, targetSize: AppleAlbumAssetCell.thumbnailSize,
                                  contentMode: .aspectFill, options: AppleAlbumAssetCell.thumbnailOptions)
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        let removed = indexPaths.compactMap { prefetched.removeValue(forKey: $0) }
        var stillCached = Set(prefetched.values.map(\.localIdentifier))
        let noLongerNeeded = removed.filter { stillCached.insert($0.localIdentifier).inserted }
        guard !noLongerNeeded.isEmpty else { return }
        images.stopCachingImages(for: noLongerNeeded, targetSize: AppleAlbumAssetCell.thumbnailSize,
                                 contentMode: .aspectFill, options: AppleAlbumAssetCell.thumbnailOptions)
    }

    private func refresh() {
        stopThumbnailPrefetch()
        review = nil
        navigationItem.prompt = nil
        title = album.title
        reviewButton.image = UIImage(systemName: "square.on.square")
        reviewButton.accessibilityLabel = "检查重复与相似项目"
        do {
            let result = try library.albumContents(album.identifier, lease: lease)
            assets = result.visible
            empty.text = result.limited ? "当前相册没有已授权的项目。" : "当前相册没有项目。"
        } catch {
            assets = []
            empty.text = "无法读取相册。请检查照片访问权限。"
        }
        tableView.backgroundView = assets.isEmpty ? empty : nil
        tableView.reloadData()
        updateActions()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { review?.count ?? 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let review = review, review.indices.contains(section) { return review[section].assets.count }
        return assets.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let review = review, review.indices.contains(section) else { return nil }
        return review[section].title
    }

    private func asset(at path: IndexPath) -> PHAsset? {
        if let review = review {
            guard review.indices.contains(path.section), review[path.section].assets.indices.contains(path.row) else { return nil }
            return review[path.section].assets[path.row]
        }
        return assets.indices.contains(path.row) ? assets[path.row] : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "album-item", for: indexPath) as! AppleAlbumAssetCell
        if let item = asset(at: indexPath) { cell.show(item, manager: images) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        self.tableView(tableView, cancelPrefetchingForRowsAt: [indexPath])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { updateActions() }
    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) { updateActions() }
    private func updateActions() {
        tableView.allowsSelection = !working
        navigationItem.hidesBackButton = working
        editButton.isEnabled = !working && !(tableView.indexPathsForSelectedRows ?? []).isEmpty
        reviewButton.isEnabled = !working || reviewJob != nil
    }

    @objc private func reviewDuplicates() {
        if let current = reviewJob { current.cancel(); return }
        guard !working else { return }
        if review != nil { refresh(); return }
        working = true
        title = "正在核验原片"
        reviewButton.image = UIImage(systemName: "xmark")
        reviewButton.accessibilityLabel = "取消检查"
        reviewJob = Task {
            defer { reviewJob = nil; working = false; updateActions() }
            do {
                let scanned = try await PhotoAlbumDuplicates.scan(storage: storage, albumID: album.identifier, lease: lease) { [weak self] phase, done, total in
                    DispatchQueue.main.async {
                        guard let self = self, self.reviewJob != nil else { return }
                        self.title = "\(phase) \(done)/\(total)"
                    }
                }
                try Task.checkCancellation()
                title = "重复与相似项目"
                stopThumbnailPrefetch()
                review = scanned.result.groups.map { group in
                    let label = group.exact ? "完全重复" : group.video ? "视频封面与时长相似" : "相似候选"
                    return (label + " · \(group.members.count) 项", group.members.map { scanned.assets[$0] })
                }
                var details: [String] = []
                if scanned.result.unavailable > 0 { details.append("\(scanned.result.unavailable) 项原片暂不可读取") }
                if scanned.result.approximateIncomplete { details.append("部分项目无法完成相似检查") }
                empty.text = (["没有找到重复或相似项目。"] + details).joined(separator: "\n")
                tableView.backgroundView = review?.isEmpty == true ? empty : nil
                if !details.isEmpty && review?.isEmpty == false {
                    navigationItem.prompt = details.joined(separator: " · ")
                }
                reviewButton.image = UIImage(systemName: "list.bullet")
                reviewButton.accessibilityLabel = "返回相册项目"
                tableView.reloadData()
            } catch is CancellationError {
                refresh()
            } catch {
                refresh()
                let alert = UIAlertController(title: "未能完成检查", message: mediaFailure193(error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
        updateActions()
    }

    @objc private func actions() {
        guard !working else { return }
        let selected = (tableView.indexPathsForSelectedRows ?? []).compactMap { asset(at: $0) }
        guard !selected.isEmpty else { return }
        let menu = UIAlertController(title: "管理 \(selected.count) 个项目", message: nil, preferredStyle: .actionSheet)
        menu.popoverPresentationController?.barButtonItem = editButton
        menu.addAction(UIAlertAction(title: "从该相册移除", style: .default) { [weak self] _ in
            self?.modify(selected, delete: false)
        })
        menu.addAction(UIAlertAction(title: "删除系统原片", style: .destructive) { [weak self] _ in
            self?.confirmDeletion(selected)
        })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(menu, animated: true)
    }

    private func confirmDeletion(_ selected: [PHAsset]) {
        let alert = UIAlertController(title: "删除 \(selected.count) 个系统原片？",
            message: "照片和视频将从 iOS 照片图库移入「最近删除」。还需通过系统确认。局域网另一台设备的相册不会随此操作删除。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in self?.modify(selected, delete: true) })
        present(alert, animated: true)
    }

    private func modify(_ selected: [PHAsset], delete: Bool) {
        guard !working else { return }
        working = true
        updateActions()
        Task {
            defer { working = false; refresh() }
            do {
                if delete { _ = try await library.deleteSystemOriginals(selected, lease: lease) }
                else { try await library.removeAlbumMembership(selected, albumID: album.identifier, lease: lease) }
            } catch {
                let alert = UIAlertController(title: "相册操作未完成", message: mediaFailure193(error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

private final class AppleAlbumAssetCell: UITableViewCell {
    static let thumbnailSize = CGSize(width: 132, height: 132)
    static let thumbnailOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }()

    private var request: PHImageRequestID?
    private weak var manager: PHImageManager?
    private var identifier: String?

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
    }

    private func cancelThumbnail() {
        if let request = request { manager?.cancelImageRequest(request) }
        manager = nil
        request = nil
        identifier = nil
    }

    func show(_ asset: PHAsset, manager: PHImageManager) {
        cancelThumbnail()
        identifier = asset.localIdentifier
        self.manager = manager
        var config = defaultContentConfiguration()
        config.text = asset.mediaType == .video ? "视频" : asset.mediaSubtypes.contains(.photoLive) ? "实况照片" : "照片"
        config.secondaryText = asset.creationDate?.formatted(date: .abbreviated, time: .shortened)
        config.image = UIImage(systemName: asset.mediaType == .video ? "video" : "photo")
        config.imageProperties.maximumSize = CGSize(width: 46, height: 46)
        config.imageProperties.cornerRadius = 8
        config.imageProperties.reservedLayoutSize = CGSize(width: 46, height: 46)
        contentConfiguration = config
        let key = asset.localIdentifier
        request = manager.requestImage(for: asset, targetSize: Self.thumbnailSize,
                                       contentMode: .aspectFill, options: Self.thumbnailOptions) { [weak self] image, _ in
            guard let image = image else { return }
            DispatchQueue.main.async {
                guard let self = self, self.identifier == key, var config = self.contentConfiguration as? UIListContentConfiguration else { return }
                config.image = image
                self.contentConfiguration = config
            }
        }
    }
}
