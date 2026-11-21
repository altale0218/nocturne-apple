import UIKit
import CryptoKit
import Security

final class SettingsController: UITableViewController, UIAdaptivePresentationControllerDelegate, UISearchResultsUpdating, UISearchControllerDelegate {
    let storage: SecureStorage
    var changed: (() -> Void)?, modeChanged: (() -> Void)?
    private var sections: [[String]] = []
    private var titles: [String] = []
    private var pendingGalleryRefresh = false
    private var query = ""
    private var searchRefresh: DispatchWorkItem?
    private var changingPassword = false
    private var selectedSetting: IndexPath?
    init(storage: SecureStorage) { self.storage = storage; if #available(iOS 13, *) { super.init(style: .insetGrouped) } else { super.init(style: .grouped) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = Strings.settings
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(done))
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 56
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.delegate = self
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
        sections[6].append("storageAudit")
        if #available(iOS 15, *) { sections[6].append("crashReport") }
        if p.squareTiles { sections[1].insert("squareCorners", at: 2) }
        if storage.envelope.privateMode { sections[5].insert(contentsOf: ["password", "biometric"], at: 1) }
        #if !NOCTURNE_LEGACY
        if #available(iOS 16.2, *), !storage.envelope.privateMode {
            if NocturneTaskActivity.shipped { sections[4].append(contentsOf: ["activityCache", "activitySync"]) }
            else { sections[4].append("activityUnavailable") }
        }
        #endif
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
        searchRefresh?.cancel()
        let next = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.query != next else { return }
            self.query = next
            let previous = self.sections
            self.refreshSections()
            if previous != self.sections { UIView.performWithoutAnimation { self.tableView.reloadData() } }
        }
        searchRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }
    func willPresentSearchController(_ searchController: UISearchController) {
        if tableView.isDecelerating { tableView.setContentOffset(tableView.contentOffset, animated: false) }
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
        if id == "crashReport" { return "上传崩溃报告" }
        if id == "storageAudit" { return "本机存储明细" }
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
        case "activityCache": return "实时活动 · 缩略图准备"
        case "activitySync": return "实时活动 · 图库同步"
        case "activityUnavailable": return "实时活动 · 当前安装包未包含扩展"
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
        var switchValue = switches[id]
        #if !NOCTURNE_LEGACY
        if #available(iOS 16.2, *) {
            if id == "activityCache" { switchValue = NocturneTaskActivity.wants(.cache) }
            if id == "activitySync" { switchValue = NocturneTaskActivity.wants(.sync) }
        }
        #endif
        if let value = switchValue {
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
        #if !NOCTURNE_LEGACY
        if #available(iOS 16.2, *), (id == "activityCache" || id == "activitySync"), !NocturneTaskActivity.systemEnabled {
            cell.detailTextLabel?.text = "系统已关闭"
        }
        #endif
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
        #if !NOCTURNE_LEGACY
        if #available(iOS 16.2, *) {
            switch sender.accessibilityIdentifier {
            case "activityCache": NocturneTaskActivity.setEnabled(sender.isOn, for: .cache); return
            case "activitySync": NocturneTaskActivity.setEnabled(sender.isOn, for: .sync); return
            default: break
            }
        }
        #endif
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
        case "activityUnavailable": message("实时活动", "此安装包省略了实时活动扩展。请安装保留扩展的完整 IPA，并在 iOS 的 Nocturne 设置中允许实时活动。")
        case "storageAudit": showStorageAudit()
        case "crashReport": if #available(iOS 15, *) { CrashReports209.shared.present(from: self) }
        case "release": if !storage.envelope.privateMode { navigationController?.pushViewController(AppleUpdateController(), animated: true) } else { showReleaseNotes() }
        default: break
        }
    }
    private func showStorageAudit() {
        let root = storage.root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = FileManager.default
            let parent = root.deletingLastPathComponent()
            let categories = [("缩略图与预览缓存", "Cache"), ("同步实况原件归档", "AlbumOriginals"),
                ("同步临时文件", "AlbumStaging"), ("同步回执", "AlbumSync"),
                ("Private 媒体", "Media193"), ("临时导出文件", "ProtectedExport193")]
            let roots = ["Nocturne", "NocturneOrdinary193", "NocturnePrivate193"].map {
                parent.appendingPathComponent($0, isDirectory: true)
            }
            var lines: [String] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
            for (title, name) in categories {
                var bytes: Int64 = 0
                for library in roots {
                    guard let entries = files.enumerator(at: library.appendingPathComponent(name), includingPropertiesForKeys: keys)
                        else { continue }
                    for case let url as URL in entries {
                        autoreleasepool {
                            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                                  values.isSymbolicLink != true else { return }
                            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                        }
                    }
                }
                lines.append(title + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            let summary = lines.joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
                self.message("本机存储明细", summary)
            }
        }
    }
    private func choices(_ id: String, names: [String], values: [String], apply: @escaping (inout LibraryState, String) -> Void) {
        let alert = UIAlertController(title: label(id), message: nil, preferredStyle: .alert)
        for (name, value) in zip(names, values) {
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in
                self.storage.update { apply(&$0, value) }
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
    private func showReleaseNotes() {
        let picker = UIAlertController(title: "更新日志", message: nil, preferredStyle: .alert)
        picker.addAction(UIAlertAction(title: "当前版本", style: .default) { [weak self] _ in
            self?.message("Nocturne · " + Release.version, Release.notes)
        })
        picker.addAction(UIAlertAction(title: "历史版本", style: .default) { [weak self] _ in
            self?.message("Apple 版本历史", Release.history)
        })
        picker.addAction(UIAlertAction(title: Strings.cancel, style: .cancel))
        present(picker, animated: true)
    }

    private func showPrivacyChoices() {
        let picker = UIAlertController(title: label("privacy"), message: nil, preferredStyle: .alert)
        picker.addAction(UIAlertAction(title: "简明版", style: .default) { [weak self] _ in
            self?.message("隐私政策 · 简明版", "照片、视频和文件夹访问用于浏览、导入和刷新本机图库。Android 可请求通知、安装更新和系统生物识别权限；Windows Private 使用指定且已解锁的 BitLocker 文件夹。应用不采集指纹或面部模板。\n\n联网用于浏览器、云更新、已配对设备同步和设备统计。照片、文件路径、Private 内容和密钥不会发送给更新或统计服务。\n\n设备统计默认开启，收集随机安装 ID、版本、已知安装时间、设备型号与系统版本；Windows 还收集 CPU、GPU 和内存配置。")
        })
        picker.addAction(UIAlertAction(title: "完整版", style: .default) { [weak self] _ in
            self?.message("隐私政策 · 完整版", "Nocturne 隐私政策\n生效日期：2026年11月2日 · 版本227\n\n一、照片与 Private\n普通图库在本机读取所选照片/视频。Private 文件、缩略图和索引保存在应用加密空间；Windows Private 仅使用你指定且已解锁的 BitLocker 存储位置。照片、文件路径、Private 内容、密码、解密密钥、配对凭据、浏览记录和本地缓存不会上传至设备统计或软件更新服务器。图库不会自动上传云相册。\n\n二、设备与版本统计\n新版默认开启设备统计，不额外弹出首次统计告知。本版不提供应用内统计开关或自行删除云端记录的按钮；既有撤回选择升级后保留。统计与图库、Private、更新及设备同步完全分离。\n发送随机安装ID、当前版本和Build、可取得的首次安装/当前版本安装时间、已记录版本履历及前后关系、最后上报时间。Android还发送品牌、型号及系统版本；Windows还发送设备品牌型号、系统版本、CPU/GPU型号和物理内存容量。不读取IMEI、MAC、硬件序列号、TPM或系统设备唯一ID。缺失的旧版安装时间保持未知。随机ID仍可关联同一安装实例，设备参数也可能具有识别性，统计并非完全匿名。\n首次启用、版本或设备参数变化时发送；无变化时正常最多每七天一次，失败退避。统计由独立HTTPS服务传送至Cloudflare Workers/D1，可能存储在境外，由受身份验证的管理后台访问；不是端到端加密。Cloudflare作为网络服务商会接触来源IP等网络元数据，应用统计数据库不记录IP，不启用请求正文日志。统计记录在服务运行期间保留；服务端清理或终止服务时删除对应记录。此前已撤回的安装实例仍停止上报，未完成的删除请求联网后继续执行。为防止旧请求复活，删除后保留随机凭据的不可逆摘要约30天，随后自动清理。平台备份的物理清理时间不由本应用保证。\n\n三、权限用途\n照片/视频读取和用户所选媒体权限：展示、导入及刷新本机内容；文件夹授权仅访问用户选择的来源。照片位置权限用于读取原始拍摄位置，不申请GPS实时定位。旧版Android存储写入权限用于用户确认的保存。通知、前台媒体处理/数据同步及唤醒权限用于后台处理任务和必要进度，不用于统计保活。网络/网络状态权限用于浏览器、云更新、已配对的局域网同步和设备统计；多播权限用于局域网设备发现。安装未知应用权限仅用于用户确认的软件更新，系统负责安装确认。生物识别权限调用系统认证，不读取或保存指纹/面部模板；Private密码与本地加密密钥不进入统计。拒绝可选权限不影响无关功能，可能使对应功能不可用。没有申请通讯录、麦克风或实时位置。\n\n四、浏览器、更新与同步\n浏览器网站和搜索引擎按正常网络请求获取网址、IP及用户主动提交内容；浏览器历史依用户选择在本机保存，网站Cookie用于对应网站。HTTPS保护传输；用户选择HTTP时，中间网络可能读取或修改内容。云更新从用户选择的Cloudflare、Gitee 或 GitHub获取公开版本和签名安装包，服务方可接触请求IP，不上传图库。设备相册同步须独立配对、验证目标及用户授权，通过加密链路传输；普通内容可按同步规则保存至系统相册，Private内容加密保存，不自动转发给非目标设备。\n\n五、删除与管理\n可在系统设置撤回媒体/通知等系统权限。本页仅提供政策说明，不提供统计配置或删除按钮。移入/移出Private、媒体删除仍遵循身份验证、原件完整性和系统授权规则；不能清除第三方既有副本、系统回收站或云备份。卸载可能删除本地密钥与应用私有内容，请先安全移出或备份。政策变更通过版本日志及本页说明，新增数据用途需重新告知。问题可通过应用诊断导出后由用户自行审核提交，不会自动上传照片或原始日志。")
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




private enum AppleUpdateSource: String, CaseIterable, Sendable {
    case cloudflare, gitee, github
    var label: String {
        switch self { case .cloudflare: return "Cloudflare"; case .gitee: return "Gitee"; case .github: return "GitHub" }
    }
    var icon: String {
        switch self { case .cloudflare: return "cloud.fill"; case .gitee: return "chevron.left.forwardslash.chevron.right"; case .github: return "point.3.connected.trianglepath.dotted" }
    }
    private static let giteeAPI = "https://gitee.com/api/v5/repos/altalatic/nocturne-releases/releases"
    func permits(_ url: URL, redirect: Bool) -> Bool {
        guard url.scheme == "https", let host = url.host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        switch self {
        case .cloudflare:
            return host == "nocturne-updates.pages.dev" && url.query == nil
                && (url.path == "/releases/apple.json" || url.path.range(of: #"^/packages/apple/[1-9][0-9]*-[0-9a-f]{64}\.ipa$"#, options: .regularExpression) != nil)
        case .github:
            if redirect && ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) { return true }
            return host == "github.com" && url.query == nil
                && url.path.hasPrefix("/altale0218/nocturne-releases/releases/download/")
        case .gitee:
            if redirect && host == "foruda.gitee.com" { return true }
            return host == "gitee.com" && url.query == nil
                && url.path.hasPrefix("/api/v5/repos/altalatic/nocturne-releases/releases/")
        }
    }

    func catalogURL() async throws -> URL {
        switch self {
        case .cloudflare:
            return URL(string: "https://nocturne-updates.pages.dev/releases/apple.json")!
        case .github:
            return URL(string: "https://github.com/altale0218/nocturne-releases/releases/download/ota-catalog/apple.json")!
        case .gitee:
            let tag = URL(string: Self.giteeAPI + "/tags/apple-ota-catalog")!
            let body = try await AppleUpdateNetwork.read(tag, source: self)
            let release = try JSONDecoder().decode(GiteeRelease.self, from: body)
            guard release.id > 0 else { throw AppleUpdateNetwork.Invalid.catalog }
            let list = URL(string: Self.giteeAPI + "/\(release.id)/attach_files")!
            let result = try await AppleUpdateNetwork.read(list, source: self)
            let assets = try JSONDecoder().decode([GiteeAsset].self, from: result).filter { $0.name == "apple.json" }
            guard assets.count == 1, let asset = assets.first, asset.id > 0 else { throw AppleUpdateNetwork.Invalid.catalog }
            return URL(string: Self.giteeAPI + "/\(release.id)/attach_files/\(asset.id)/download")!
        }
    }
    private struct GiteeRelease: Decodable { let id: Int64 }
    private struct GiteeAsset: Decodable { let id: Int64; let name: String }
}

private enum AppleUpdateNetwork {
    enum Invalid: Error { case catalog, endpoint, package }
    private static let publisher = "ae3b0557e3f11a0927212bb49c2d2e7a70db33e842dfce04dec616f2276a57e2"
    private static let catalogLimit = 128 * 1024
    private static let packageLimit: Int64 = 512 * 1024 * 1024
    private struct Catalog: Decodable { let schema: Int; let ready: Bool; let releases: [Proof] }
    private struct Proof: Decodable { let payload: String; let signature: String; let certificate: String }

    struct Offer: Decodable, Sendable {
        let schema: Int, kind: String, bundle: String, version: String, channel: String
        let build: Int, size: Int64, sha256: String, notes: String
        let downloads: [String: URL]
        var fileName: String { "Nocturne-iOS-\(version)-\(build)\(channel == "beta" ? "-beta" : "").ipa" }
    }

    private final class Redirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let source: AppleUpdateSource
        init(_ source: AppleUpdateSource) { self.source = source }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map { source.permits($0, redirect: true) } == true ? request : nil)
        }
    }

    private static func connection(_ source: AppleUpdateSource) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 14
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: Redirect(source), delegateQueue: nil)
    }

    static func read(_ url: URL, source: AppleUpdateSource) async throws -> Data {
        guard source.permits(url, redirect: false) else { throw Invalid.endpoint }
        let session = connection(source)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json, application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, source.permits(final, redirect: true),
              http.expectedContentLength <= Int64(catalogLimit) else { throw Invalid.endpoint }
        var content = Data()
        for try await byte in bytes {
            guard content.count < catalogLimit else { throw Invalid.catalog }
            content.append(byte)
        }
        return content
    }

    static func check(_ source: AppleUpdateSource, installed: Int, beta: Bool) async throws -> Offer? {
        let url = try await source.catalogURL()
        let data = try await read(url, source: source)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schema == 1, catalog.ready, catalog.releases.count <= 8, !catalog.releases.isEmpty else { throw Invalid.catalog }
        let offers = catalog.releases.compactMap { try? validate($0) }
        guard !offers.isEmpty else { throw Invalid.catalog }
        return offers.filter { $0.build > installed && ($0.channel == "stable" || beta) && $0.downloads[source.rawValue] != nil }
            .max { $0.build < $1.build }
    }

    private static func validate(_ proof: Proof) throws -> Offer {
        guard let cert = Data(base64Encoded: proof.certificate),
              AppleSyncTransport.hex(Data(SHA256.hash(data: cert))) == publisher,
              let certificate = SecCertificateCreateWithData(nil, cert as CFData),
              let key = SecCertificateCopyKey(certificate),
              let payload = Data(base64Encoded: proof.payload), payload.count <= 18_000,
              let signature = Data(base64Encoded: proof.signature),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, signature as CFData, nil)
              else { throw Invalid.catalog }
        let offer = try JSONDecoder().decode(Offer.self, from: payload)
        guard offer.schema == 1, offer.kind == "apple", offer.bundle == "com.nocturne.gallery",
              [ "stable", "beta" ].contains(offer.channel), (1...1_000_000).contains(offer.build),
              offer.version.range(of: #"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"#, options: .regularExpression) != nil,
              offer.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              (1...packageLimit).contains(offer.size), offer.notes.utf8.count <= 8_000, !offer.downloads.isEmpty
              else { throw Invalid.catalog }
        for (name, url) in offer.downloads {
            guard let source = AppleUpdateSource(rawValue: name), source.permits(url, redirect: false) else { throw Invalid.endpoint }
            if source == .cloudflare, url.path != "/packages/apple/\(offer.build)-\(offer.sha256).ipa" { throw Invalid.endpoint }
        }
        return offer
    }

    static func save(_ offer: Offer, source: AppleUpdateSource) async throws -> URL {
        guard let url = offer.downloads[source.rawValue], source.permits(url, redirect: false) else { throw Invalid.endpoint }
        let session = connection(source)
        defer { session.finishTasksAndInvalidate() }
        let (temp, response) = try await session.download(from: url)
        let files = FileManager.default
        defer { try? files.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, source.permits(final, redirect: true),
              let size = try files.attributesOfItem(atPath: temp.path)[.size] as? NSNumber,
              size.int64Value == offer.size else { throw Invalid.package }
        let handle = try FileHandle(forReadingFrom: temp)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard AppleSyncTransport.hex(Data(hash.finalize())) == offer.sha256 else { throw Invalid.package }
        try Task.checkCancellation()
        let folder = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VerifiedUpdates/\(offer.sha256)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(offer.fileName)
        if files.fileExists(atPath: local.path) { try files.replaceItem(at: local, withItemAt: temp, backupItemName: nil, options: [], resultingItemURL: nil) }
        else { try files.moveItem(at: temp, to: local) }
        return local
    }
}

@MainActor private final class AppleUpdateController: UITableViewController {
    private var channel = UserDefaults.standard.bool(forKey: "update.beta")
    private var source = UserDefaults.standard.string(forKey: "update.source") ?? "auto"
    private var active: Task<Void, Never>?
    private var generation = 0
    private var offer: (AppleUpdateNetwork.Offer, AppleUpdateSource)?
    private var local: URL?
    private var status = "检查云端软件更新"
    private var spinning = false
    private var downloading = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "软件更新"
        check()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { active?.cancel(); generation += 1 }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [3, 3, 2][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["当前版本","云端更新","更新日志"][section] }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        var title = "", symbol = "", subtitle: String?
        var interactive = true
        switch (indexPath.section, indexPath.row) {
        case (0,0): title = "Nocturne · \(Release.version)"; subtitle = "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")"; symbol = "app.badge.checkmark"; interactive = false
        case (0,1):
            title = "接收测试版更新"; symbol = "testtube.2"; interactive = false
            let control = UISwitch(); control.isOn = channel; control.isEnabled = !downloading
            control.addTarget(self, action: #selector(changeChannel(_:)), for: .valueChanged); cell.accessoryView = control
        case (0,2):
            let selected = AppleUpdateSource(rawValue: source)
            title = "更新源"; subtitle = selected?.label ?? "自动选择 · Cloudflare / Gitee / GitHub"; symbol = selected?.icon ?? "arrow.triangle.branch"; interactive = !downloading
        case (1,0):
            title = status; interactive = false
            if spinning { let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating(); cell.accessoryView = spinner }
        case (1,1): title = "检查更新"; symbol = "arrow.clockwise"; interactive = !downloading
        case (1,2):
            title = local == nil ? "下载更新" : "另存到文件"
            subtitle = offer.map { ($0.0.channel == "beta" ? "测试版" : "正式版") + " · " + $0.0.version + " · " + $0.1.label }
            symbol = local == nil ? "arrow.down.circle" : "folder"; interactive = offer != nil && !downloading
        case (2,0): title = "当前版本日志"; symbol = "doc.text"
        default: title = "历史版本日志"; symbol = "clock.arrow.circlepath"
        }
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = subtitle
        cell.imageView?.image = UIImage(systemName: symbol)
        if interactive { cell.accessoryType = .disclosureIndicator } else { cell.selectionStyle = .none }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        switch (path.section, path.row) {
        case (0,2): if !downloading { selectSource() }
        case (1,1): if !downloading { check() }
        case (1,2): if !downloading { confirmDownload() }
        case (2,0): message("当前版本", Release.notes)
        case (2,1): message("历史版本", Release.history)
        default: break
        }
    }
    @objc private func changeChannel(_ control: UISwitch) {
        channel = control.isOn; UserDefaults.standard.set(channel, forKey: "update.beta"); check()
    }
    private func selectSource() {
        let dialog = UIAlertController(title: "更新源", message: nil, preferredStyle: .alert)
        for (key, label) in [("auto", "自动选择")] + AppleUpdateSource.allCases.map({ ($0.rawValue, $0.label) }) {
            dialog.addAction(UIAlertAction(title: (source == key ? "✓  " : "") + label, style: .default) { [weak self] _ in
                guard let self else { return }
                self.source = key; UserDefaults.standard.set(key, forKey: "update.source"); self.check()
            })
        }
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(dialog, animated: true)
    }
    private struct Result: Sendable {
        let source: AppleUpdateSource, offer: AppleUpdateNetwork.Offer?, failure: String?
    }
    private func check() {
        active?.cancel(); generation += 1
        let attempt = generation, beta = channel
        let installed = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let targets = AppleUpdateSource(rawValue: source).map { [$0] } ?? AppleUpdateSource.allCases
        local = nil; offer = nil; spinning = true
        status = targets.count > 1 ? "正在检查 Cloudflare、Gitee 和 GitHub…" : "正在通过 \(targets[0].label) 检查更新…"
        tableView.reloadData()
        active = Task { [weak self] in
            await withTaskGroup(of: Result.self) { group in
                for target in targets {
                    group.addTask {
                        do { return Result(source: target, offer: try await AppleUpdateNetwork.check(target, installed: installed, beta: beta), failure: nil) }
                        catch {
                            let reason: String
                            switch error {
                            case AppleUpdateNetwork.Invalid.catalog, is DecodingError: reason = "目录格式或签名校验失败"
                            case AppleUpdateNetwork.Invalid.endpoint: reason = "服务器响应或重定向无效"
                            case let network as URLError: reason = "网络连接失败（\(network.errorCode)）"
                            default: reason = "无法读取更新目录"
                            }
                            return Result(source: target, offer: nil, failure: reason)
                        }
                    }
                }
                var tested = 0, succeeded = 0
                var failures: [String] = []
                for await result in group {
                    guard let self, !Task.isCancelled, self.generation == attempt else { group.cancelAll(); return }
                    tested += 1
                    if let failure = result.failure { failures.append("\(result.source.label) · \(failure)") }
                    else { succeeded += 1 }
                    if let candidate = result.offer, candidate.build > (self.offer?.0.build ?? installed) { self.offer = (candidate, result.source) }
                    self.spinning = tested < targets.count
                    if let current = self.offer { self.status = "发现\(current.0.channel == "beta" ? "测试版" : "正式版") · \(current.0.version)" }
                    else if succeeded > 0 { self.status = "已是最新版本" }
                    else if !self.spinning { self.status = failures.joined(separator: "\n") }
                    self.tableView.reloadData()
                }
            }
        }
    }
    private func confirmDownload() {
        if let local { export(local); return }
        guard let offer else { return }
        let kind = offer.0.channel == "beta" ? "测试版" : "正式版"
        let size = ByteCountFormatter.string(fromByteCount: offer.0.size, countStyle: .file)
        let dialog = UIAlertController(title: "下载 \(kind) \(offer.0.version)",
            message: "\(offer.1.label) · \(size)\n\n\(offer.0.notes)\n\n下载后可存入「文件」，再用 AltStore 等已配置的工具签名安装。", preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
        dialog.addAction(UIAlertAction(title: "下载更新", style: .default) { [weak self] _ in self?.download(offer) })
        present(dialog, animated: true)
    }
    private func download(_ chosen: (AppleUpdateNetwork.Offer, AppleUpdateSource)) {
        active?.cancel(); generation += 1
        let attempt = generation
        downloading = true; spinning = true; status = "正在下载并校验安装包…"; tableView.reloadData()
        active = Task { [weak self] in
            do {
                let url = try await AppleUpdateNetwork.save(chosen.0, source: chosen.1)
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                self.local = url
                self.status = "安装包已校验，可存入「文件」"
            } catch {
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                self.status = "下载或校验失败，请重新检查更新"
            }
            guard let self, self.generation == attempt, !Task.isCancelled else { return }
            self.downloading = false; self.spinning = false; self.tableView.reloadData()
            if let local = self.local, self.viewIfLoaded?.window != nil { self.export(local) }
        }
    }
    private func export(_ url: URL) {
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
    }
    private func message(_ title: String, _ text: String) {
        let dialog = UIAlertController(title: title, message: text, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "好", style: .cancel)); present(dialog, animated: true)
    }
}
