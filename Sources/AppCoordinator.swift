import UIKit
import Photos

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
    private var privateTransition: UIView?
    private var authEpoch193 = 0
    private var transientRepository199: PhotoRepository?
    private var active193 = true
    init(window: UIWindow, rootSink193: ((UIViewController) -> Void)? = nil) { self.window = window; self.rootSink193 = rootSink193 }
    private func showRoot193(_ controller: UIViewController) { if let sink = rootSink193 { sink(controller) } else { window.rootViewController = controller } }
    func start() {
        let initial = UIViewController()
        initial.view.backgroundColor = Theme.background(false)
        showRoot193(initial)
        if rootSink193 == nil { window.makeKeyAndVisible() }
        work.async { [weak self] in
            guard let self = self else { return }
            do {
                let original = try SecureStorage()
                let parent = original.root.deletingLastPathComponent()
                let ordinary: SecureStorage
                let vault: SecureStorage
                if original.envelope.privateMode {
                    vault = original
                    ordinary = try SecureStorage(root: parent.appendingPathComponent("NocturneOrdinary193", isDirectory: true))
                } else {
                    ordinary = original
                    vault = try SecureStorage(root: parent.appendingPathComponent("NocturnePrivate193", isDirectory: true))
                }
                do { try ordinary.unlock() }
                catch {
                    DispatchQueue.main.async {
                        self.ordinary193 = ordinary; self.private193 = vault
                        self.showStorageFailure193()
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.ordinary193 = ordinary; self.private193 = vault
                    if self.active193 { self.enter(ordinary) } else { ordinary.lock() }
                }
            } catch { DispatchQueue.main.async { self.showStorageFailure193() } }
        }
    }
    private func landing(from source: UIViewController? = nil, importing assets: [MediaAsset193] = []) {
        guard let storage = private193, let presenter = source ?? window.rootViewController,
              presenter.presentedViewController == nil, transientRepository199 == nil else { return }
        let didUnlock: () -> Void = { [weak self, weak presenter] in
            guard let self = self, self.active193 else { storage.lock(); return }
            if !assets.isEmpty, let presenter = presenter {
                self.importIntoPrivate199(assets, storage: storage, presenter: presenter)
            } else if assets.isEmpty { self.switchLibrary193(storage) }
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
                        guard token == self.authEpoch193, self.active193, let controller = controller else { storage.lock(); controller?.busy(false); return }
                        controller.dismiss(animated: true, completion: didUnlock)
                    }
                } catch { storage.lock(); DispatchQueue.main.async { controller?.busy(false); controller?.error193(error) } }
            }
        }
        controller.biometricOpen193 = { [weak self, weak controller] in
            guard let self = self else { return }; controller?.busy(true)
            let token = self.authEpoch193
            self.work.async {
                do { try storage.unlockBiometric193(); DispatchQueue.main.async { guard token == self.authEpoch193, self.active193 else { storage.lock(); controller?.busy(false); return }; guard let controller = controller else { storage.lock(); return }; controller.dismiss(animated: true, completion: didUnlock) } }
                catch { storage.lock(); DispatchQueue.main.async { controller?.busy(false); controller?.status193("生物识别未完成或授权已失效，请使用密码。") } }
            }
        }
        controller.configureSlide()
        if !assets.isEmpty { controller.loadViewIfNeeded(); controller.status193("原片通过加密核验后，系统会询问是否删除。使用 iCloud 照片时，删除会同步到其他设备。") }
        presenter.present(controller, animated: true)
        if storage.exportCleanupPending193 > 0 { controller.loadViewIfNeeded(); controller.status193("上次移出的受保护临时原件尚待清理，新的移出操作已暂停。") }
    }
    private func switchLibrary193(_ target: SecureStorage) {
        guard active193, target.isUnlocked193 else { target.lock(); return }
        if let session = clock.finish() { storage?.update { $0.sessions.append(session) } }
        do { try storage?.save() }
        catch {
            target.lock()
            let warning = UIAlertController(title: "未能保存图库", message: "请检查可用存储空间后再切换。", preferredStyle: .alert)
            warning.addAction(UIAlertAction(title: "好", style: .default))
            window.rootViewController?.present(warning, animated: true)
            return
        }
        repository?.lock()
        storage?.lock()
        enter(target)
        if target.envelope.privateMode { animatePrivate204(opening: true) }
    }
    private func enter(_ storage: SecureStorage) {
        guard storage.isUnlocked193 else { return }
        self.storage = storage
        Strings.language = UserDefaults.standard.string(forKey: "language") ?? storage.state.settings.language
        let repo = PhotoRepository(storage: storage); repository = repo
        let gallery = GalleryController(repository: repo, storage: storage, clock: clock)
        gallery.locked = { [weak self] in self?.exitPrivate204() }
        gallery.openPrivate193 = { [weak self] in self?.landing() }
        gallery.importPrivate199 = { [weak self] controller, asset in self?.landing(from: controller, importing: asset) }
        showRoot193(gallery)
        if storage.envelope.privateMode {
            repo.synchronize()
            return
        }
        let lease = try? storage.resourceLease193()
        repo.requestAccess { [weak repo] allowed in
            guard let repo = repo, let lease = lease,
                  (try? storage.validateResourceLease193(lease)) != nil else { return }
            if allowed { repo.synchronize() }
            gallery.showRelease()
        }
    }
    private func importIntoPrivate199(_ assets: [MediaAsset193], storage: SecureStorage, presenter: UIViewController) {
        let repo = PhotoRepository(storage: storage)
        transientRepository199 = repo
        var verified: [MediaAsset193] = []
        let progress = UIAlertController(title: "转入 Private", message: "准备加密原件…", preferredStyle: .alert)
        let finish: (Set<String>) -> Void = { [weak self, weak presenter, weak repo, weak progress] removed in
            guard let self, let repo, self.transientRepository199 === repo else { return }
            self.transientRepository199 = nil
            repo.lock(); storage.lock()
            let showResult = {
                guard self.active193, let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { return }
                let remaining = assets.count - removed.count
                let message = "已加密核验 \(verified.count)/\(assets.count) 项。\n已从系统图库删除 \(removed.count) 项。" +
                    (remaining > 0 ? "\n\(remaining) 项未完成转入，可重新尝试。" : "") +
                    (removed.isEmpty ? "" : "\n若要立即清除原片，请在系统照片的「最近删除」中永久删除。")
                let result = UIAlertController(title: "Private", message: message, preferredStyle: .alert)
                result.addAction(UIAlertAction(title: "好", style: .default))
                presenter.present(result, animated: true)
            }
            if let progress, progress.presentingViewController != nil { progress.dismiss(animated: true, completion: showResult) }
            else { showResult() }
        }
        func process(_ index: Int) {
            guard active193, transientRepository199 === repo, storage.isUnlocked193 else { return }
            guard index < assets.count else {
                guard !verified.isEmpty, let lease = try? storage.resourceLease193() else { finish([]); return }
                progress.message = "等待系统相册确认删除 \(verified.count) 项原片…"
                NativeAssetRevision.delete(verified.compactMap(\.native), check: {
                    try storage.validateResourceLease193(lease)
                }, completion: { result in finish((try? result.get()) ?? []) })
                return
            }
            progress.message = "正在加密并核验 \(index + 1)/\(assets.count)"
            repo.moveToPrivate193(assets[index], removeOriginal: false) { result in
                if case .success = result { verified.append(assets[index]) }
                process(index + 1)
            }
        }
        presenter.present(progress, animated: true) { process(0) }
    }
    func willResignActive() {
        guard storage?.envelope.privateMode == true, privacyCover == nil else { return }
        privateTransition?.removeFromSuperview()
        privateTransition = nil
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

    private func exitPrivate204() {
        guard let storage = storage, storage.envelope.privateMode else { return }
        if let session = clock.finish() { storage.update { $0.sessions.append(session) } }
        do { try storage.save() }
        catch {
            let warning = UIAlertController(title: "未能保存 Private", message: "请检查可用存储空间后再退出。", preferredStyle: .alert)
            warning.addAction(UIAlertAction(title: "好", style: .default))
            window.rootViewController?.present(warning, animated: true)
            return
        }
        let reduced = storage.state.settings.reducedMotion
        lock()
        if !reduced { animatePrivate204(opening: false) }
    }

    private func animatePrivate204(opening: Bool) {
        guard active193, privacyCover == nil, storage?.state.settings.reducedMotion != true,
              !UIAccessibility.isReduceMotionEnabled, !window.bounds.isEmpty else { return }
        privateTransition?.removeFromSuperview()
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isAccessibilityElement = false
        let gold = UIView(frame: overlay.bounds)
        gold.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gold.backgroundColor = UIColor(red: 1, green: 0.847, blue: 0.302, alpha: 1)
        let shape = UIView(frame: overlay.bounds)
        shape.backgroundColor = UIColor(red: 1, green: 0.988, blue: 0.949, alpha: 1)
        shape.clipsToBounds = true
        if #available(iOS 13, *) { shape.layer.cornerCurve = .continuous }
        overlay.isUserInteractionEnabled = false
        overlay.addSubview(gold)
        overlay.addSubview(shape)
        window.addSubview(overlay)
        privateTransition = overlay
        let compact = CGRect(x: overlay.bounds.midX - 36, y: overlay.bounds.midY - 36, width: 72, height: 72)
        if opening { shape.frame = compact; shape.layer.cornerRadius = 36 }
        UIView.animate(withDuration: 0.47, delay: 0, options: [.curveEaseInOut]) {
            shape.frame = opening ? overlay.bounds : compact
            shape.layer.cornerRadius = opening ? 0 : 36
        } completion: { [weak self, weak overlay] _ in
            guard let overlay = overlay, self?.privateTransition === overlay else { return }
            UIView.animate(withDuration: 0.29, delay: 0, options: [.curveEaseOut]) {
                overlay.alpha = 0
            } completion: { [weak self] _ in
                overlay.removeFromSuperview()
                if self?.privateTransition === overlay { self?.privateTransition = nil }
            }
        }
    }
}
final class LandingController: UIViewController {
    private let slide = GalleryPageSlide()
    private var verifying = false

    func configureSlide() {
        slide.configure(self)
        slide.installEdge(on: self) { [weak self] in self?.verifying == false }
    }

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
        for (name, code) in [("简体中文", "zh-Hans"), ("English", "en"), ("繁體中文", "zh-Hant"), ("日本語", "ja")] {
            alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                Strings.language = code
                self?.dismiss(animated: true)
            })
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); alert.popoverPresentationController?.sourceView = buttons.last; alert.popoverPresentationController?.sourceRect = buttons.last?.bounds ?? .zero; present(alert, animated: true)
    }
    func busy(_ value: Bool) { verifying = value; buttons.forEach { $0.isEnabled = !value }; status.text = value ? Strings.text("正在验证…", "Verifying…", "確認中…", "正在驗證…") : "" }
    func error() { status.text = Strings.text("密码不正确，或新密码不足 10 位且两次不一致。", "Password incorrect, or a new password needs at least 10 matching characters.", "パスワードが違うか、新規パスワードが10文字未満または一致していません。", "密碼不正確，或新密碼不足10位且兩次不一致。") }
}
