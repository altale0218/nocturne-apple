import UIKit
import WebKit

enum WebPolicy123 {
    static var searchEngine193 = "google"
    static func allowed(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), host.contains("."), !host.contains(":"), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".lan"), !host.hasSuffix(".internal"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil else { return false }
        return !url.absoluteString.contains("\\") && url.absoluteString.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func address(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096, !text.contains("\\"), text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if let url = URL(string: text), url.scheme != nil { return allowed(url) ? url : nil }
        if text.contains(".") && text.rangeOfCharacter(from: .whitespaces) == nil { return URL(string: "https://" + text).flatMap { allowed($0) ? $0 : nil } }
        guard !text.contains(":"), !text.hasPrefix("/"), !text.hasPrefix("~") else { return nil }
        let base = searchEngine193 == "bing" ? "https://www.bing.com/search" : searchEngine193 == "duckduckgo" ? "https://duckduckgo.com/" : "https://www.google.com/search"
        var query = URLComponents(string: base)!; query.queryItems = [URLQueryItem(name: "q", value: text)]; return query.url
    }
}

@available(iOS 18.4, *)
final class BrowserController: UIViewController, UITextFieldDelegate, WKNavigationDelegate, WKUIDelegate {
    private let bar = UIStackView(), tabs = UIStackView(), field = UITextField(), host = UIView(), progress = UIProgressView(), home = UIStackView(), note = UILabel()
    private let store = WKWebsiteDataStore.nonPersistent()
    private var pages: [WKWebView] = [], current: WKWebView?, observation: NSKeyValueObservation?
    private let records193: BrowserRecords193
    init(storage: SecureStorage) { records193 = BrowserRecords193(storage); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var language = Strings.language
    private func text(_ zh: String, _ en: String, _ ja: String, _ tw: String) -> String { language == "en" ? en : language == "ja" ? ja : language == "zh-Hant" ? tw : zh }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let savedEngine = UserDefaults.standard.string(forKey: "browser.search193") ?? "google"
        WebPolicy123.searchEngine193 = ["google", "bing", "duckduckgo"].contains(savedEngine) ? savedEngine : "google"
        bar.axis = .horizontal; bar.spacing = 6; bar.alignment = .center
        bar.addArrangedSubview(button("xmark", #selector(closeBrowser))); bar.addArrangedSubview(button("chevron.left", #selector(back))); bar.addArrangedSubview(button("chevron.right", #selector(forward)))
        field.placeholder = "HTTPS / " + text("搜索", "Search", "検索", "搜尋"); field.borderStyle = .roundedRect; field.keyboardType = .webSearch; field.returnKeyType = .go; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); bar.addArrangedSubview(field); bar.addArrangedSubview(button("ellipsis", #selector(menu)))
        tabs.axis = .horizontal; tabs.spacing = 6; tabs.distribution = .fillEqually
        home.axis = .vertical; home.spacing = 20
        for (content, size) in [("◎", CGFloat(64)), ("Nocturne Browser", CGFloat(28)), (text("轻量浏览，与相册分开。", "Light browsing, separate from your gallery.", "写真とは別に、軽快なブラウジング。", "輕量瀏覽，與相簿分開。"), CGFloat(16))] {
            let label = UILabel(); label.text = content; label.font = .systemFont(ofSize: size, weight: .semibold); label.textAlignment = .center; label.numberOfLines = 0; home.addArrangedSubview(label)
        }
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabel; note.numberOfLines = 0; note.textAlignment = .center
        note.text = text("网址或搜索后才联网。图库不传递照片、视频或密码。网页会收到网址、搜索词与连接信息。网页会话不持久化；你访问的页面标题、网址与收藏另外保存在应用加密资料库中，可清除历史记录。", "Network navigation starts after address or search submission. No gallery photos, videos or passwords are forwarded. Sites receive the URL, search terms and connection information. Nonpersistent web sessions use system WebKit storage, not the Private gallery cipher.", "アドレスや検索の送信後に接続します。写真・動画・パスワードは渡しません。URL・検索語・接続情報はサイトへ送信されます。非永続セッションはシステム WebKit が管理し、Private 写真の暗号化とは別です。", "輸入網址或搜尋後才連線，不傳送照片、影片或密碼。網站會收到網址、搜尋詞與連線資訊。非持久網頁工作階段由系統 WebKit 管理，並非 Private 圖庫快取加密。")
        home.addArrangedSubview(note)
        let favorites = UIButton(type: .system); favorites.setTitle("收藏夹 · 快速访问", for: .normal); favorites.addTarget(self, action: #selector(favorites193), for: .touchUpInside)
        favorites.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; home.addArrangedSubview(favorites)
        host.addSubview(home)
        for item in [bar, tabs, progress, host] { view.addSubview(item) }; refreshTabs()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); let safe = view.safeAreaInsets, width = view.bounds.width - safe.left - safe.right
        bar.frame = CGRect(x: safe.left + 10, y: safe.top + 4, width: width - 20, height: 44); tabs.frame = CGRect(x: safe.left + 10, y: bar.frame.maxY + 4, width: width - 20, height: 36)
        progress.frame = CGRect(x: safe.left, y: tabs.frame.maxY + 4, width: width, height: 2); host.frame = CGRect(x: safe.left, y: progress.frame.maxY, width: width, height: max(1, view.bounds.height - safe.bottom - progress.frame.maxY))
        current?.frame = host.bounds; home.frame = CGRect(x: 24, y: max(12, (host.bounds.height - 370) / 2), width: width - 48, height: min(370, host.bounds.height - 24))
    }
    private func button(_ symbol: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setImage(UIImage(systemName: symbol), for: .normal); button.addTarget(self, action: action, for: .touchUpInside); button.widthAnchor.constraint(equalToConstant: 36).isActive = true; button.heightAnchor.constraint(equalToConstant: 40).isActive = true; return button
    }
    private func newPage() -> WKWebView? {
        guard pages.count < 4 else { return nil }
        let config = WKWebViewConfiguration(); config.websiteDataStore = store; config.preferences.javaScriptCanOpenWindowsAutomatically = false; config.allowsAirPlayForMediaPlayback = false; config.allowsPictureInPictureMediaPlayback = false; config.mediaTypesRequiringUserActionForPlayback = .all
        let page = WKWebView(frame: host.bounds, configuration: config); page.navigationDelegate = self; page.uiDelegate = self; page.isInspectable = false; page.allowsBackForwardNavigationGestures = true
        pages.append(page); select(page); return page
    }
    private func select(_ page: WKWebView) {
        current?.pauseAllMediaPlayback(); current?.removeFromSuperview(); observation = nil; current = page; home.isHidden = true; host.addSubview(page); page.frame = host.bounds
        observation = page.observe(\.estimatedProgress, options: [.new]) { [weak self] page, _ in self?.progress.setProgress(Float(page.estimatedProgress), animated: true); self?.progress.isHidden = page.estimatedProgress >= 1 }
        field.text = page.url?.absoluteString; refreshTabs()
    }
    private func refreshTabs() {
        if bar.arrangedSubviews.count >= 3 { bar.arrangedSubviews[1].isHidden = current?.canGoBack != true; bar.arrangedSubviews[2].isHidden = current?.canGoForward != true }
        for item in tabs.arrangedSubviews { tabs.removeArrangedSubview(item); item.removeFromSuperview() }
        for (index, page) in pages.enumerated() { let b = UIButton(type: .system); b.setTitle(String(index + 1), for: .normal); b.tag = index; b.tintColor = page === current ? .systemBlue : .secondaryLabel; b.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside); tabs.addArrangedSubview(b) }
        tabs.addArrangedSubview(button("plus", #selector(addTab))); tabs.addArrangedSubview(button("house", #selector(goHome))); if current != nil { tabs.addArrangedSubview(button("xmark", #selector(closeTab))) }
    }
    @objc private func selectTab(_ button: UIButton) { if pages.indices.contains(button.tag) { select(pages[button.tag]) } }
    @objc private func addTab() { _ = newPage(); field.becomeFirstResponder() }
    @objc private func closeTab() { guard let page = current else { return }; page.stopLoading(); page.pauseAllMediaPlayback(); page.removeFromSuperview(); pages.removeAll { $0 === page }; current = nil; if let next = pages.last { select(next) } else { goHome() } }
    @objc private func goHome() { current?.pauseAllMediaPlayback(); current?.removeFromSuperview(); current = nil; observation = nil; home.isHidden = false; field.text = ""; refreshTabs() }
    @objc private func back() { current?.goBack() }
    @objc private func forward() { current?.goForward() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let url = WebPolicy123.address(field.text ?? ""), let page = current ?? newPage() else { return false }
        field.resignFirstResponder(); page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)); return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url.map(WebPolicy123.allowed) == true && action.targetFrame != nil ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        decisionHandler(response.canShowMIMEType && !attachment ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === current { field.text = webView.url?.absoluteString }
        if let url = webView.url, WebPolicy123.allowed(url) {
            let entry = BrowserEntry193(url: url.absoluteString, title: String((webView.title ?? url.host ?? "网页").prefix(200)), visited: Date())
            records193.remember(entry)
        }
        refreshTabs()
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    @objc private func backgrounded() { pages.forEach { $0.pauseAllMediaPlayback() } }
    private func searchEngine193() {
        let alert = UIAlertController(title: "搜索引擎", message: "仅在你提交搜索时发送查询词。", preferredStyle: .actionSheet)
        for (name, code) in [("Google", "google"), ("Bing", "bing"), ("DuckDuckGo", "duckduckgo")] {
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in WebPolicy123.searchEngine193 = code; UserDefaults.standard.set(code, forKey: "browser.search193") })
        }
        alert.addAction(UIAlertAction(title: Strings.cancel, style: .cancel)); alert.popoverPresentationController?.sourceView = bar; alert.popoverPresentationController?.sourceRect = bar.bounds; present(alert, animated: true)
    }
    @objc private func favorites193() { openLibrary193(favorites: true) }
    private func openLibrary193(favorites: Bool) {
        let list = BrowserLibrary193(records: records193, favorites: favorites) { [weak self] entry in
            guard let self = self, let url = URL(string: entry.url), WebPolicy123.allowed(url), let page = self.current ?? self.newPage() else { return }
            page.load(URLRequest(url: url))
        }
        let nav = UINavigationController(rootViewController: list); nav.modalPresentationStyle = .pageSheet; present(nav, animated: true)
    }
    @objc private func menu() {
        let alert = UIAlertController(title: "Nocturne Browser", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: text("刷新", "Reload", "再読み込み", "重新載入"), style: .default) { [weak self] _ in self?.current?.reload() })
        alert.addAction(UIAlertAction(title: "历史记录 · 长按添加收藏", style: .default) { [weak self] _ in self?.openLibrary193(favorites: false) })
        alert.addAction(UIAlertAction(title: "收藏夹", style: .default) { [weak self] _ in self?.openLibrary193(favorites: true) })
        alert.addAction(UIAlertAction(title: "收藏当前网页", style: .default) { [weak self] _ in
            guard let self = self, let url = self.current?.url, WebPolicy123.allowed(url) else { return }
            self.records193.favorite(BrowserEntry193(url: url.absoluteString, title: String((self.current?.title ?? url.host ?? "网页").prefix(200)), visited: Date()))
        })
        alert.addAction(UIAlertAction(title: "搜索引擎", style: .default) { [weak self] _ in self?.searchEngine193() })
        alert.addAction(UIAlertAction(title: text("关闭全部标签并清除会话", "Close all and clear session", "全タブとセッションを消去", "關閉全部分頁並清除工作階段"), style: .default) { [weak self] _ in
            guard let self = self else { return }; self.pages.forEach { $0.stopLoading(); $0.removeFromSuperview() }; self.pages.removeAll(); self.goHome()
            self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        })
        alert.addAction(UIAlertAction(title: text("取消", "Cancel", "キャンセル", "取消"), style: .cancel)); alert.popoverPresentationController?.sourceView = bar; alert.popoverPresentationController?.sourceRect = bar.bounds; present(alert, animated: true)
    }
    private func chooseLanguage() {
        let alert = UIAlertController(title: "Language / 语言 / 言語", message: nil, preferredStyle: .actionSheet)
        for (id, name) in [("zh-Hans", "简体中文"), ("en", "English"), ("zh-Hant", "繁體中文"), ("ja", "日本語")] { alert.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in self?.language = id; UserDefaults.standard.set(id, forKey: "language"); self?.field.placeholder = "HTTPS / " + name }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = bar; alert.popoverPresentationController?.sourceRect = bar.bounds; present(alert, animated: true)
    }
    @objc private func closeBrowser() {
        observation = nil
        pages.forEach { $0.stopLoading(); $0.pauseAllMediaPlayback(); $0.navigationDelegate = nil; $0.uiDelegate = nil; $0.removeFromSuperview() }
        pages.removeAll(); current = nil
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        dismiss(animated: true)
    }
    deinit { NotificationCenter.default.removeObserver(self); pages.forEach { $0.stopLoading(); $0.navigationDelegate = nil; $0.uiDelegate = nil } }
}

/// No JavaScript bridge, vault credential, arbitrary file URL or gallery media is exposed to WebKit.
final class BrowserRecords193 {
    private let storage: SecureStorage, lease: Int?
    private let queue = DispatchQueue(label: "com.nocturne.browser-records193", qos: .utility)
    init(_ storage: SecureStorage) { self.storage = storage; lease = try? storage.resourceLease193() }
    func entries(favorites: Bool) -> [BrowserEntry193] {
        guard let lease = lease else { return [] }; return (try? storage.browserEntries193(favorites: favorites, lease: lease)) ?? []
    }
    func remember(_ entry: BrowserEntry193) { write(entry, favorite: false) }
    func favorite(_ entry: BrowserEntry193, completion: ((Result<Void, Error>) -> Void)? = nil) { write(entry, favorite: true, completion: completion) }
    private func write(_ entry: BrowserEntry193, favorite: Bool, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let lease = lease else { completion?(.failure(StorageError.locked)); return }
        queue.async {
            let result: Result<Void, Error> = Result { try self.storage.saveBrowserEntry193(entry, favorite: favorite, lease: lease) }
            if let completion = completion { DispatchQueue.main.async { completion(result) } }
        }
    }
    func clear(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let lease = lease else { completion(.failure(StorageError.locked)); return }
        queue.async { let result: Result<Void, Error> = Result { try self.storage.clearBrowserHistory193(lease: lease) }; DispatchQueue.main.async { completion(result) } }
    }
}
@available(iOS 18.4, *)
private final class BrowserLibrary193: UITableViewController {
    private let records: BrowserRecords193, favorites: Bool, open: (BrowserEntry193) -> Void
    private var entries: [BrowserEntry193] = []
    init(records: BrowserRecords193, favorites: Bool, open: @escaping (BrowserEntry193) -> Void) {
        self.records = records; self.favorites = favorites; self.open = open; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = favorites ? "收藏夹" : "历史记录 · 长按收藏"; entries = records.entries(favorites: favorites)
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        if !favorites { navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清除", style: .plain, target: self, action: #selector(clear)) }
        if entries.isEmpty { let label = UILabel(); label.text = "暂无内容"; label.textAlignment = .center; label.textColor = .secondaryLabel; tableView.backgroundView = label }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil), entry = entries[indexPath.row]
        cell.textLabel?.text = entry.title; cell.detailTextLabel?.text = URL(string: entry.url)?.host; cell.imageView?.image = UIImage(systemName: favorites ? "star" : "clock"); return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = entries[indexPath.row]; dismiss(animated: true) { self.open(entry) }
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !favorites else { return nil }; let entry = entries[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: [UIAction(title: "添加收藏夹", image: UIImage(systemName: "star")) { _ in self.records.favorite(entry) { result in self.result193(result, success: "已加入收藏夹") } }]) }
    }
    private func result193(_ result: Result<Void, Error>, success: String) {
        let title: String
        switch result { case .success: title = success; case .failure: title = "记录保存失败，请确认应用仍处于解锁状态。" }
        guard !title.isEmpty, view.window != nil else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true)
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func clear() {
        let alert = UIAlertController(title: "清除浏览历史？", message: "收藏夹与网页当前会话保留。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { _ in self.records.clear { result in
            if case .success = result { self.entries = []; self.tableView.reloadData() }
            else { self.result193(result, success: "") }
        } })
        present(alert, animated: true)
    }
}
