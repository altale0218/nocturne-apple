import UIKit

final class SettingsController: UITableViewController, UIAdaptivePresentationControllerDelegate, UISearchResultsUpdating {
    let storage: SecureStorage
    var changed: (() -> Void)?, modeChanged: (() -> Void)?
    private var sections: [[String]] = []
    private var titles: [String] = []
    private var pendingGalleryRefresh = false
    private var query = ""
    private var changingPassword = false
    private var selectedSetting: IndexPath?
    init(storage: SecureStorage) { self.storage = storage; if #available(iOS 13, *) { super.init(style: .insetGrouped) } else { super.init(style: .grouped) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = Strings.settings
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 56
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = Strings.text("搜索设置", "Search settings", "設定を検索", "搜尋設定")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        refreshTitles()
        refreshSections()
        applyAppearance()
    }
    private func refreshSections() {
        let p = storage.state.settings
        sections = [["appearance", "chrome", "language", "motion"],
                    ["size", "square", "names", "views", "duration"],
                    ["filmstrip", "swipeDismiss", "blur", "viewerAll", "date", "fine"],
                    ["videoDoubleTap", "viewerMuted", "hold", "openMark"],
                    ["preview"], ["mode", "boundary", "privacy"], ["release"]]
        if p.squareTiles { sections[1].insert("squareCorners", at: 2) }
        if storage.envelope.privateMode { sections[5].insert(contentsOf: ["password", "biometric"], at: 1) }
        if p.previewVideos { sections[4].append("limit"); sections[4].append("markLoop"); if p.markerPreview122 == true { sections[4].append("markWindow") } }
        if p.mode == .galaxy && !p.reducedMotion { sections[1].append("speed") }
        if p.videoDoubleTap204 ?? true { sections[3].insert(contentsOf: ["back", "forward"], at: 1) }
        if (p.openAtMarker122 ?? true) || p.markerPreview122 == true { sections[3].append("lead") }
        if !query.isEmpty {
            for section in sections.indices {
                if !titles[section].localizedCaseInsensitiveContains(query) {
                    sections[section] = sections[section].filter { label($0).localizedCaseInsensitiveContains(query) }
                }
            }
        }
    }
    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        refreshSections()
        tableView.reloadData()
    }
    private func refreshTitles() {
        titles = [Strings.text("外观", "Appearance", "外観", "外觀"), Strings.text("主页", "Gallery", "ギャラリー", "主頁"),
                  Strings.text("查看器", "Viewer", "ビューアー", "檢視器"), Strings.text("播放", "Playback", "再生", "播放"),
                  Strings.text("性能", "Performance", "性能", "效能"), "Private · " + Strings.text("隐私", "Privacy", "プライバシー", "隱私"),
                  Strings.text("软件更新", "Software updates", "ソフトウェア更新", "軟體更新")]

    }
    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].isEmpty ? nil : titles[section] }
    private func label(_ id: String) -> String {
        switch id {
        case "filmstrip": return Strings.text("显示底部预览条", "Show the filmstrip", "プレビュー列を表示", "顯示底部預覽條")
        case "swipeDismiss": return Strings.text("下滑退出查看器", "Swipe down to close viewer", "下にスワイプして閉じる", "下滑退出檢視器")
        case "viewerMuted": return Strings.text("查看器默认静音", "Mute viewer by default", "既定でミュート", "檢視器預設靜音")
        case "videoDoubleTap": return Strings.text("双击视频左右快退／快进", "Double-tap video to skip", "動画をダブルタップして移動", "雙擊影片左右快退／快進")
        case "privacy": return Strings.text("隐私政策", "Privacy policy", "プライバシーポリシー", "隱私權政策")
        case "password": return Strings.text("更改密码", "Change password", "パスワードを変更", "更改密碼")
        case "size": return Strings.text("片源大小", "Media size", "表示サイズ", "片源大小")
        case "viewerAll": return Strings.text("模糊延伸至查看器控制区", "Blur behind viewer controls", "操作エリアまでぼかす", "模糊延伸至檢視器控制區")
        case "date": return Strings.text("显示拍摄日期", "Show captured date", "撮影日を表示", "顯示拍攝日期")
        case "fine": return Strings.text("精细拖动 · 每帧点数", "Fine scrub · points per frame", "精密移動・1フレームのポイント数", "精細拖動・每幀點數")
        case "hold": return Strings.text("长按 2×，拖到底部锁定", "Hold 2×, drag down to lock", "長押し2倍速・下端で固定", "長按 2×，拖到底部鎖定")
        case "openMark": return Strings.text("预览未就绪时从标点前打开", "Open near marker if preview not ready", "プレビュー未準備時はマーク前から開く", "預覽未就緒時從標點前開啟")
        case "lead": return Strings.text("标点前秒数", "Seconds before marker", "マーク前の秒数", "標點前秒數")
        case "markLoop": return Strings.text("从标点循环预览", "Preview around marker", "マークから繰り返す", "從標點循環預覽")
        case "markWindow": return Strings.text("标点预览循环时长", "Marker preview loop duration", "マークプレビューの長さ", "標點預覽循環時長")
        case "appearance": return Strings.text("深浅色", "Appearance", "外観", "深淺色")
        case "square": return "1:1方形缩略图"
        case "squareCorners": return "1:1卡片保留圆角"
        case "biometric": return "生物识别解锁"
        case "language": return "语言 / Language / 言語"
        case "chrome": return Strings.text("主题取色", "Theme colors", "テーマの色", "主題取色")
        case "motion": return Strings.text("减少动态效果", "Reduce motion", "視差効果を減らす", "減少動態效果")
        case "names": return Strings.text("按拍摄日期分组", "Group by capture date", "撮影日ごとにまとめる", "按拍攝日期分組")
        case "views": return Strings.text("显示观看次数", "Show view counts", "閲覧回数を表示", "顯示觀看次數")
        case "duration": return Strings.text("显示视频时长", "Show video duration", "動画の長さを表示", "顯示影片時長")
        case "sync": return Strings.text("开启自动同步", "Sync on open", "起動時に同期", "開啟自動同步")
        case "preview": return Strings.text("同时预览视频", "Video previews", "動画プレビュー", "同時預覽影片")
        case "limit": return Strings.text("并行视频上限", "Preview limit", "同時動画の上限", "並行影片上限")
        case "speed": return Strings.text("镜头移动速度", "Camera speed", "カメラの速度", "鏡頭移動速度")
        case "back": return Strings.text("双击左侧回退", "Double-tap left rewind", "左をダブルタップで戻る", "雙擊左側後退")
        case "forward": return Strings.text("双击右侧前进", "Double-tap right forward", "右をダブルタップで進む", "雙擊右側前進")
        case "blur": return Strings.text("静态模糊强度", "Static blur strength", "静的ぼかしの強さ", "靜態模糊強度")
        case "mode": return storage.envelope.privateMode ? Strings.text("返回普通图库", "Switch to ordinary", "通常モードに変更", "切換普通模式") : Strings.text("打开 Private", "Enable Private", "Private を有効化", "啟用 Private")
        case "boundary": return Strings.text("保护范围与性能影响", "Protection and performance", "保護範囲と性能への影響", "保護範圍與效能影響")
        default: return "Nocturne · " + Release.version
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "setting")
        let id = sections[indexPath.section][indexPath.row], p = storage.state.settings
        cell.detailTextLabel?.text = nil
        cell.textLabel?.text = label(id); cell.textLabel?.font = .systemFont(ofSize: 14); cell.textLabel?.numberOfLines = 2
        let switches = ["square": p.squareTiles, "squareCorners": p.roundedSquare, "motion": p.reducedMotion, "names": p.groupDates199 ?? true, "views": p.showViews, "duration": p.showDuration, "preview": p.previewVideos, "date": p.showDate122 ?? true, "hold": p.holdSpeed122 ?? true, "openMark": p.openAtMarker122 ?? true, "markLoop": p.markerPreview122 ?? false, "filmstrip": p.showFilmstrip204 ?? true, "swipeDismiss": p.swipeDismiss199 ?? true, "viewerMuted": p.viewerMuted204 ?? false, "videoDoubleTap": p.videoDoubleTap204 ?? true, "viewerAll": p.viewerBackgroundAll122 ?? true]
        if let value = switches[id] {
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.removeTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            toggle.accessibilityIdentifier = id
            toggle.accessibilityLabel = cell.textLabel?.text
            toggle.setOn(value, animated: false)
            toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            cell.accessoryType = .none
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else {
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        if id == "size", let index = GalleryRules122.gallerySizes.firstIndex(of: p.sizePreset) { cell.detailTextLabel?.text = GalleryRules122.gallerySizeTitles[index] }
        if id == "lead" { cell.detailTextLabel?.text = "\(Int(p.markerLead)) s" }
        if id == "markWindow" { cell.detailTextLabel?.text = "\(Int(p.markerWindow)) s" }
        if id == "fine" { cell.detailTextLabel?.text = "\(p.finePixels) pt" }
        if id == "language" { cell.detailTextLabel?.text = Strings.language }
        if id == "biometric" { cell.detailTextLabel?.text = storage.envelope.biometric193 == true ? "已启用" : "未启用" }
        if id == "appearance" { cell.detailTextLabel?.text = p.appearance.rawValue }
        if id == "limit" { cell.detailTextLabel?.text = String(p.maximumPreviews) }
        if id == "back" { cell.detailTextLabel?.text = "\(Int(p.skipBackward)) s" }
        if id == "forward" { cell.detailTextLabel?.text = "\(Int(p.skipForward)) s" }
        if id == "speed" { cell.detailTextLabel?.text = String(format: "%.1f×", p.sceneSpeed) }
        return cell
    }
    @objc private func toggled(_ sender: UISwitch) {
        storage.update { state in
            switch sender.accessibilityIdentifier {
            case "filmstrip": state.settings.showFilmstrip204 = sender.isOn
            case "swipeDismiss": state.settings.swipeDismiss199 = sender.isOn
            case "viewerMuted": state.settings.viewerMuted204 = sender.isOn
            case "videoDoubleTap": state.settings.videoDoubleTap204 = sender.isOn
            case "names":
                if sender.isOn && (state.settings.sortGallery199 ?? 0) >= 2 { state.settings.sortGallery199 = 0 }
            default: break
            }
            switch sender.accessibilityIdentifier { case "square": state.settings.squareTiles193 = sender.isOn; case "squareCorners": state.settings.roundedSquare193 = sender.isOn; case "motion": state.settings.reducedMotion = sender.isOn; case "names": state.settings.groupDates199 = sender.isOn; case "views": state.settings.showViews = sender.isOn; case "duration": state.settings.showDuration = sender.isOn; case "sync": state.settings.automaticSync = sender.isOn; case "preview": state.settings.previewVideos = sender.isOn; case "viewerAll": state.settings.viewerBackgroundAll122 = sender.isOn; case "date": state.settings.showDate122 = sender.isOn; case "hold": state.settings.holdSpeed122 = sender.isOn; case "openMark": state.settings.openAtMarker122 = sender.isOn; case "markLoop": state.settings.markerPreview122 = sender.isOn; default: break }
        }
        try? storage.save()
        pendingGalleryRefresh = true
        let previous = sections
        refreshSections()

        var removed: [IndexPath] = []
        var inserted: [IndexPath] = []
        for section in sections.indices {
            let before = Set(previous[section]), after = Set(sections[section])
            for (row, id) in previous[section].enumerated() where !after.contains(id) {
                removed.append(IndexPath(row: row, section: section))
            }
            for (row, id) in sections[section].enumerated() where !before.contains(id) {
                inserted.append(IndexPath(row: row, section: section))
            }
        }
        if !removed.isEmpty || !inserted.isEmpty {
            tableView.performBatchUpdates {
                tableView.deleteRows(at: removed, with: .automatic)
                tableView.insertRows(at: inserted, with: .automatic)
            }
        }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedSetting = indexPath
        tableView.deselectRow(at: indexPath, animated: true)
        let id = sections[indexPath.section][indexPath.row]
        switch id {
        case "privacy": showPrivacyChoices()
        case "password": showPasswordChange()
        case "size":
            let values = GalleryRules122.gallerySizes.map { String($0) }
            choices(id, names: GalleryRules122.gallerySizeTitles, values: values) { $0.settings.gallerySize122 = Int($1) }
        case "lead": number(id, current: storage.state.settings.markerLead, range: 0...120) { $0.settings.markerLead122 = $1 }
        case "markWindow": number(id, current: storage.state.settings.markerWindow, range: 1...120) { $0.settings.markerWindow122 = $1 }
        case "fine": number(id, current: storage.state.settings.finePixels, range: 1...6) { $0.settings.finePixels122 = $1 }
        case "biometric": configureBiometric193()
        case "language": choices(id, names: ["简体中文", "English", "繁體中文", "日本語"], values: ["zh-Hans", "en", "zh-Hant", "ja"]) { state, value in state.settings.language = value; Strings.language = value }
        case "appearance": choices(id, names: [Strings.text("跟随系统", "System", "システム", "跟隨系統"), Strings.text("浅色", "Light", "ライト", "淺色"), Strings.text("深色", "Dark", "ダーク", "深色")], values: ["system", "light", "dark"]) { $0.settings.appearance = Appearance(rawValue: $1)! }
        case "chrome": choices(id, names: [Strings.text("主题色", "Theme", "テーマ", "主題色"), Strings.text("图库融合", "Gallery blend", "写真と調和", "圖庫融合"), Strings.text("流光渐变", "Flowing gradient", "流れるグラデーション", "流光漸層")], values: ["theme", "gallery", "flowing"]) { $0.settings.chrome = ChromeSource(rawValue: $1)! }
        case "limit": number(id, current: Double(storage.state.settings.maximumPreviews), range: 1...16) { $0.settings.maximumPreviews = Int($1) }
        case "speed": number(id, current: storage.state.settings.sceneSpeed, range: 0.1...3) { $0.settings.sceneSpeed = $1 }
        case "back": number(id, current: storage.state.settings.skipBackward, range: 1...120) { $0.settings.skipBackward = $1 }
        case "forward": number(id, current: storage.state.settings.skipForward, range: 1...120) { $0.settings.skipForward = $1 }
        case "blur": number(id, current: storage.state.settings.blurRadius, range: 0...48) { $0.settings.blurRadius = $1 }
        case "mode": changeMode()
        case "boundary": message(label(id), Strings.text("缓存始终经过认证加密。Private 增加每次开启的密码验证，影响解锁耗时；不会逐帧验证密码或降低原片分辨率。系统相册中的原片仍由系统管理，不会因为开启 Private 自动隐藏或加密复制。本工程未经过安全审计。", "Caches always use authenticated encryption. Private adds startup password verification, affecting unlock time, not per-frame playback or original resolution. Originals in Photos remain managed by the system and are not hidden or copied by enabling Private. This engineering preview has not had a security audit.", "キャッシュは常に認証付き暗号化。Private は起動時のパスワード検証を追加し、解除時間に影響します。フレーム処理や元画像の解像度は変えません。システム写真の元ファイルは自動的に非表示や複製になりません。セキュリティ監査は未実施です。", "快取始終使用驗證加密。Private 增加啟動密碼驗證，影響解鎖時間，不影響逐幀播放與原片解析度。系統相簿原片不會自動隱藏或加密複製。本工程未經安全審計。"))
        case "release": message(label(id), Release.notes)
        default: break
        }
    }
    private func choices(_ id: String, names: [String], values: [String], apply: @escaping (inout LibraryState, String) -> Void) {
        let alert = UIAlertController(title: label(id), message: nil, preferredStyle: .actionSheet)
        for (n, name) in names.enumerated() {
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in
                self.storage.update { apply(&$0, values[n]) }
                try? self.storage.save()
                self.title = Strings.settings
                self.applyAppearance()
                self.refreshTitles()
                self.refreshSections()
                self.tableView.reloadData()
                self.applyGallerySettings()
            })
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView
        if let selectedSetting = selectedSetting, let cell = tableView.cellForRow(at: selectedSetting) {
            alert.popoverPresentationController?.sourceRect = cell.frame
        } else {
            alert.popoverPresentationController?.sourceRect = CGRect(x: tableView.bounds.midX, y: tableView.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }
    private func number(_ id: String, current: Double, range: ClosedRange<Double>, apply: @escaping (inout LibraryState, Double) -> Void) {
        let alert = UIAlertController(title: label(id), message: "\(range.lowerBound)–\(range.upperBound)", preferredStyle: .alert)
        alert.addTextField { $0.text = String(current); $0.keyboardType = .decimalPad }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            guard let text = alert.textFields?.first?.text, let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, range.contains(value) else { self.message(label: self.label(id), body: "Invalid value"); return }
            self.storage.update { apply(&$0, value) }; try? self.storage.save(); self.tableView.reloadData(); self.applyGallerySettings()
        }); present(alert, animated: true)
    }
    private func configureBiometric193() {
        guard storage.envelope.privateMode else { return }
        let enabled = storage.envelope.biometric193 == true
        let alert = UIAlertController(title: enabled ? "关闭生物识别解锁？" : "启用生物识别解锁？", message: "由系统Face ID或Touch ID验证；密码入口保留。新增生物特征或关闭系统密码后可能需要重新启用。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: enabled ? "关闭" : "启用", style: .default) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do { if enabled { try self.storage.disableBiometric193() } else { try self.storage.enableBiometric193() }
                    DispatchQueue.main.async { self.tableView.reloadData() }
                } catch { DispatchQueue.main.async { self.message("生物识别", "未完成设置；资料库密码和原有资料保持不变。") } }
            }
        }); present(alert, animated: true)
    }
    private func changeMode() {
        let change = modeChanged
        navigationItem.searchController?.isActive = false
        dismiss(animated: true) { change?() }
    }
    private func showPrivacyChoices() {
        let picker = UIAlertController(title: label("privacy"), message: nil, preferredStyle: .alert)
        picker.addAction(UIAlertAction(title: "简明版", style: .default) { [weak self] _ in
            self?.message("隐私政策 · 简明版", "照片权限用于浏览原件、生成缩略图和按你的指令同步。局域网权限用于搜索和连接已配对设备。Private 的生物识别由系统验证，缓存使用认证加密。")
        })
        picker.addAction(UIAlertAction(title: "完整版", style: .default) { [weak self] _ in
            self?.message("隐私政策 · 完整版", "照片：访问你授权的图库，显示照片和视频、读取拍摄信息、准备预览。整库同步需要完整权限，可能通过 Apple 照片从 iCloud 取得原片。\n\n局域网：发现设备；核对配对码后保存设备凭证。只有启动同步并获对方同意后才传输媒体。\n\nPrivate：加密原件保存在应用内。进入 Private 不会自动移动或隐藏系统相册里的照片。生物识别由系统处理，应用不读取生物特征数据。切到后台会锁定 Private。\n\n系统界面：实时活动仅显示普通图库任务的进度、容量、速度，不显示照片或文件名。内置浏览器会连接你主动访问的网站。可在系统设置管理权限。")
        })
        picker.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        present(picker, animated: true)
    }
    private func showPasswordChange() {
        guard !changingPassword, storage.envelope.privateMode else { return }
        let form = UIAlertController(title: label("password"), message: "新密码至少 10 位。", preferredStyle: .alert)
        for prompt in ["当前密码", "新密码", "确认新密码"] {
            form.addTextField { field in
                field.placeholder = prompt
                field.isSecureTextEntry = true
                if #available(iOS 12, *) { field.textContentType = prompt == "当前密码" ? .password : .newPassword }
            }
        }
        form.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        form.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak form] _ in
            guard let self = self, let fields = form?.textFields, fields.count == 3 else { return }
            let current = fields[0].text ?? "", replacement = fields[1].text ?? ""
            guard !current.isEmpty, replacement.count >= 10, replacement == fields[2].text else {
                self.message(self.label("password"), "请填写当前密码，并确认两次输入的新密码一致。")
                return
            }
            self.changingPassword = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.storage.changePrivatePassword(current: current, replacement: replacement) }
                DispatchQueue.main.async {
                    self.changingPassword = false
                    guard self.viewIfLoaded?.window != nil else { return }
                    switch result {
                    case .success:
                        self.tableView.reloadData()
                        self.message(self.label("password"), "密码已更新。如需使用 Face ID 或 Touch ID，请重新启用生物识别解锁。")
                    case .failure(StorageError.invalidCredentials): self.message(self.label("password"), "当前密码不正确。")
                    case .failure: self.message(self.label("password"), "未能保存新密码。请检查存储空间后重试。")
                    }
                }
            }
        })
        present(form, animated: true)
    }
    private func message(_ label: String, _ body: String) { let alert = UIAlertController(title: label, message: body, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
    private func message(label: String, body: String) { message(label, body) }
    private func applyGallerySettings() {
        pendingGalleryRefresh = false
        changed?()
    }
    private func applyAppearance() {
        if #available(iOS 13, *) {
            let appearance = storage.state.settings.appearance
            let style: UIUserInterfaceStyle = appearance == .system ? .unspecified : appearance == .dark ? .dark : .light
            navigationController?.overrideUserInterfaceStyle = style
            overrideUserInterfaceStyle = style
        }
    }
    private func refreshGalleryIfNeeded() {
        if pendingGalleryRefresh { applyGallerySettings() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        refreshGalleryIfNeeded()
    }
    @objc private func done() {
        dismiss(animated: true) { self.refreshGalleryIfNeeded() }
    }
}
