import UIKit

final class AppCoordinator {
    let window: UIWindow
    private let rootSink193: ((UIViewController) -> Void)?
    private var storage: SecureStorage?
    private var ordinary193: SecureStorage?
    private var private193: SecureStorage?
    private var repository: PhotoRepository?
    private let clock = SessionClock()
    private let work = DispatchQueue(label: "com.nocturne.unlock", qos: .userInitiated)
    private var privacyCover: UIView?
    private var authEpoch193 = 0
    private var transientRepository199: PhotoRepository?
    private var active193 = true
    init(window: UIWindow, rootSink193: ((UIViewController) -> Void)? = nil) { self.window = window; self.rootSink193 = rootSink193 }
    private func showRoot193(_ controller: UIViewController) { if let sink = rootSink193 { sink(controller) } else { window.rootViewController = controller } }
    func start() {
        do {
            let original = try SecureStorage()
            let parent = original.root.deletingLastPathComponent()
            if original.envelope.privateMode {
                private193 = original
                ordinary193 = try SecureStorage(root: parent.appendingPathComponent("NocturneOrdinary193", isDirectory: true))
            } else {
                ordinary193 = original
                private193 = try SecureStorage(root: parent.appendingPathComponent("NocturnePrivate193", isDirectory: true))
            }
            if let ordinary = ordinary193 {
                try ordinary.unlock()
                enter(ordinary)
            }
        }
        catch { let controller = UIViewController(); controller.view.backgroundColor = .white; let label = UILabel(); label.text = "Nocturne: storage unavailable"; label.textAlignment = .center; label.frame = CGRect(x: 20, y: 100, width: 300, height: 80); controller.view.addSubview(label); showRoot193(controller) }
        if rootSink193 == nil { window.makeKeyAndVisible() }
    }
    private func landing(from source: UIViewController? = nil, importing asset: MediaAsset193? = nil) {
        guard let storage = private193, let presenter = source ?? window.rootViewController,
              presenter.presentedViewController == nil, transientRepository199 == nil else { return }
        let didUnlock: () -> Void = { [weak self, weak presenter] in
            guard let self = self, self.active193 else { storage.lock(); return }
            if let asset = asset, let presenter = presenter {
                self.importIntoPrivate199(asset, storage: storage, presenter: presenter)
            } else if asset == nil { self.switchLibrary193(storage) }
            else { storage.lock() }
        }
        let controller = LandingController(privateMode: storage.envelope.privateMode, biometricEnabled: storage.envelope.biometric193 == true)
        controller.open = { [weak self, weak controller] password, privateCreate in
            guard let self = self else { return }
            controller?.busy(true)
            let token = self.authEpoch193
            self.work.async {
                do {
                    try storage.unlock(password: password)
                    if privateCreate { guard let password = password else { throw StorageError.locked }; try storage.enablePrivate(password: password); try storage.save() }
                    DispatchQueue.main.async {
                        guard token == self.authEpoch193, self.active193, let controller = controller else { storage.lock(); return }
                        controller.dismiss(animated: true, completion: didUnlock)
                    }
                } catch { storage.lock(); DispatchQueue.main.async { controller?.busy(false); controller?.error193(error) } }
            }
        }
        controller.biometricOpen193 = { [weak self, weak controller] in
            guard let self = self else { return }; controller?.busy(true)
            let token = self.authEpoch193
            self.work.async {
                do { try storage.unlockBiometric193(); DispatchQueue.main.async { guard token == self.authEpoch193, self.active193 else { storage.lock(); return }; guard let controller = controller else { storage.lock(); return }; controller.dismiss(animated: true, completion: didUnlock) } }
                catch { storage.lock(); DispatchQueue.main.async { controller?.busy(false); controller?.status193("生物识别未完成或授权已失效，请使用密码。") } }
            }
        }
        if #available(iOS 13, *) { controller.isModalInPresentation = true }
        presenter.present(controller, animated: true)
        if storage.exportCleanupPending193 > 0 { controller.loadViewIfNeeded(); controller.status193("上次移出的受保护临时原件尚待清理，新的移出操作已暂停。") }
    }
    private func switchLibrary193(_ target: SecureStorage) {
        guard active193, target.isUnlocked193 else { target.lock(); return }
        if let session = clock.finish() { storage?.update { $0.sessions.append(session) } }
        try? storage?.save()
        repository?.lock()
        storage?.lock()
        enter(target)
    }
    private func enter(_ storage: SecureStorage) {
        guard storage.isUnlocked193 else { return }
        self.storage = storage
        Strings.language = "zh-Hans"
        let repo = PhotoRepository(storage: storage); repository = repo
        let gallery = GalleryController(repository: repo, storage: storage, clock: clock)
        gallery.locked = { [weak self] in self?.lock() }
        gallery.openPrivate193 = { [weak self] in self?.landing() }
        gallery.importPrivate199 = { [weak self] controller, asset in self?.landing(from: controller, importing: asset) }
        showRoot193(gallery)
        if storage.envelope.privateMode {
            repo.synchronize()
            gallery.showRelease()
            return
        }
        let lease = try? storage.resourceLease193()
        repo.requestAccess { [weak gallery, weak repo] allowed in
            guard let repo = repo, let lease = lease,
                  (try? storage.validateResourceLease193(lease)) != nil else { return }
            guard let gallery = gallery else { return }
            if allowed && storage.state.settings.automaticSync { repo.synchronize() }
            gallery.showRelease()
        }
    }
    private func importIntoPrivate199(_ asset: MediaAsset193, storage: SecureStorage, presenter: UIViewController) {
        let repo = PhotoRepository(storage: storage)
        transientRepository199 = repo
        repo.moveToPrivate193(asset, removeOriginal: false) { [weak self, weak presenter, weak repo] result in
            guard let self = self, let repo = repo, self.transientRepository199 === repo else { return }
            self.transientRepository199 = nil
            repo.lock(); storage.lock()
            guard self.active193, let presenter = presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil else { return }
            let message: String
            switch result {
            case .success: message = "已加密保存到 Private，系统相册原片仍保留。"
            case .failure: message = "转入未完成，系统相册原片仍保留。"
            }
            let alert = UIAlertController(title: "Private", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            presenter.present(alert, animated: true)
        }
    }
    func willResignActive() {
        guard storage?.envelope.privateMode == true, privacyCover == nil else { return }
        let cover = UIView(frame: window.bounds); cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]; cover.backgroundColor = Theme.background(false)
        let label = UILabel(); label.text = "Nocturne Private"; label.font = .systemFont(ofSize: 24, weight: .semibold); label.textColor = Theme.blue; label.textAlignment = .center; label.frame = cover.bounds; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; cover.addSubview(label)
        window.addSubview(cover); privacyCover = cover
    }
    func becameActive() {
        active193 = true
        if storage?.isUnlocked193 != true, let ordinary = ordinary193 {
            do { try ordinary.unlock(); enter(ordinary) }
            catch { showStorageFailure193() }
        }
        storage?.cleanupAbandonedExports193()
        privacyCover?.removeFromSuperview(); privacyCover = nil
    }
    func background() {
        guard active193 else { return }
        active193 = false
        authEpoch193 += 1
        if let transient = transientRepository199 { transientRepository199 = nil; transient.lock(); private193?.lock() }
        if storage?.envelope.privateMode == true {
            willResignActive()
            lock()
            return
        }
        if let session = clock.finish() { storage?.update { $0.sessions.append(session) } }
        try? storage?.save()
    }
    private func showStorageFailure193() {
        let screen = UIViewController()
        screen.view.backgroundColor = .white
        let notice = UILabel(frame: screen.view.bounds.insetBy(dx: 24, dy: 0))
        notice.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        notice.textAlignment = .center
        notice.numberOfLines = 0
        notice.text = "普通图库暂不可用，请解锁设备后重试。"
        screen.view.addSubview(notice)
        showRoot193(screen)
    }

    private func lock() {
        authEpoch193 += 1
        repository?.lock()
        if let session = clock.finish() { storage?.update { $0.sessions.append(session) } }
        try? storage?.save()
        storage?.lock()
        window.rootViewController?.dismiss(animated: false)
        if let ordinary = ordinary193 {
            do { try ordinary.unlock(); enter(ordinary) }
            catch { showStorageFailure193() }
        }
        if let cover = privacyCover { window.bringSubviewToFront(cover) }
    }
}
final class LandingController: UIViewController {
    let privateMode: Bool
    let biometricEnabled193: Bool
    var biometricOpen193: (() -> Void)?
    private var dark193: Bool { if #available(iOS 13, *) { return traitCollection.userInterfaceStyle == .dark }; return false }
    var open: ((String?, Bool) -> Void)?
    private let stack = UIStackView(), scroll = UIScrollView(), password = UITextField(), confirm = UITextField(), status = UILabel()
    private var buttons: [UIButton] = []
    init(privateMode: Bool, biometricEnabled: Bool = false) { self.privateMode = privateMode; self.biometricEnabled193 = biometricEnabled; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Theme.background(dark193)
        scroll.alwaysBounceVertical = true; view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        let brand = UILabel(); brand.text = privateMode ? "Nocturne Private" : "Nocturne"; brand.font = .systemFont(ofSize: 32, weight: .semibold); brand.textColor = Theme.text(dark193); brand.textAlignment = .center; stack.addArrangedSubview(brand)
        let description = UILabel(); description.font = .systemFont(ofSize: 14); description.numberOfLines = 0; description.textColor = Theme.muted(dark193)
        description.text = Strings.text("离线浏览，流畅珍藏。\n普通模式免密，Private 每次开启需密码。原片保留在系统相册，缩略图缓存始终加密。", "Offline memories, fluid browsing.\nOrdinary mode opens without a password. Private requires a password each time. Originals stay in Photos; thumbnail caches remain encrypted.", "オフラインで、軽快に。\n通常はパスワード不要。Private は起動時にパスワードが必要です。元ファイルは写真アプリに保持し、サムネイルは常に暗号化します。", "離線瀏覽，流暢珍藏。\n普通模式免密，Private 每次開啟需密碼。原片保留在系統相簿，縮圖快取始終加密。")
        stack.addArrangedSubview(description)
        password.isSecureTextEntry = true; password.placeholder = privateMode ? Strings.text("密码", "Password", "パスワード", "密碼") : Strings.text("Private 新密码 · 至少 10 位", "Private password · at least 10 characters", "Private パスワード・10文字以上", "Private 新密碼・至少10位")
        confirm.isSecureTextEntry = true; confirm.placeholder = Strings.text("再次输入密码", "Confirm password", "パスワードの確認", "再次輸入密碼")
        for input in [password, confirm] { input.borderStyle = .roundedRect; input.backgroundColor = dark193 ? UIColor(white: 0.15, alpha: 1) : .white; input.heightAnchor.constraint(equalToConstant: 48).isActive = true; stack.addArrangedSubview(input) }
        confirm.isHidden = privateMode
        add(Strings.cancel, #selector(cancel193))
        add(privateMode ? Strings.text("解锁", "Unlock", "ロック解除", "解鎖") : Strings.text("启用 Private", "Enable Private", "Private を有効化", "啟用 Private"), #selector(privateOpen))
        if privateMode && biometricEnabled193 { add("Face ID / Touch ID 解锁", #selector(biometric193)) }
        status.font = .systemFont(ofSize: 12); status.numberOfLines = 0; status.textColor = .red; stack.addArrangedSubview(status)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            preferredWidth, stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 72), stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -32)
        ])
    }
    private func add(_ title: String, _ action: Selector) {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold); button.backgroundColor = Theme.blue; button.setTitleColor(.white, for: .normal); button.layer.cornerRadius = 14; button.heightAnchor.constraint(equalToConstant: 48).isActive = true; button.addTarget(self, action: action, for: .touchUpInside); stack.addArrangedSubview(button); buttons.append(button)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scroll.frame = view.bounds.inset(by: view.safeAreaInsets) }
    @objc private func biometric193() { biometricOpen193?() }
    func status193(_ text: String) { status.text = text }
    func error193(_ failure: Error) {
        if case StorageError.invalidCredentials = failure { status.text = "密码不正确，请重试。" }
        else { status.text = "资料库暂不可用或保存未完成。原有资料保留，请勿卸载或清除数据。" }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        view.backgroundColor = Theme.background(dark193)
        for item in stack.arrangedSubviews { if let label = item as? UILabel, label !== status { label.textColor = Theme.text(dark193) } }
        for input in [password, confirm] { input.backgroundColor = dark193 ? UIColor(white: 0.15, alpha: 1) : .white; input.textColor = Theme.text(dark193) }
    }
    @objc private func cancel193() { dismiss(animated: true) }
    @objc private func privateOpen() {
        let secret = password.text ?? ""
        guard privateMode || (secret.count >= 10 && secret == confirm.text) else { error(); return }
        view.endEditing(true); password.text = ""; confirm.text = ""; open?(secret, !privateMode)
    }
    @objc private func language() {
        let alert = UIAlertController(title: "语言 / Language / 言語", message: nil, preferredStyle: .actionSheet)
        for (name, code) in [("简体中文", "zh-Hans"), ("English", "en"), ("繁體中文", "zh-Hant"), ("日本語", "ja")] { alert.addAction(UIAlertAction(title: name, style: .default) { _ in Strings.language = code; UserDefaults.standard.set(code, forKey: "language"); let next = LandingController(privateMode: self.privateMode); next.open = self.open; self.view.window?.rootViewController = next }) }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); alert.popoverPresentationController?.sourceView = buttons.last; alert.popoverPresentationController?.sourceRect = buttons.last?.bounds ?? .zero; present(alert, animated: true)
    }
    func busy(_ value: Bool) { buttons.forEach { $0.isEnabled = !value }; status.text = value ? Strings.text("正在验证…", "Verifying…", "確認中…", "正在驗證…") : "" }
    func error() { status.text = Strings.text("密码不正确，或新密码不足 10 位且两次不一致。", "Password incorrect, or a new password needs at least 10 matching characters.", "パスワードが違うか、新規パスワードが10文字未満または一致していません。", "密碼不正確，或新密碼不足10位且兩次不一致。") }
}
