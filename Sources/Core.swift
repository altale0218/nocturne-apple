import Foundation

enum GalleryMode: Int, Codable, CaseIterable { case tiles, galaxy, floating, timeFlow }
enum Appearance: String, Codable { case system, light, dark }
enum ChromeSource: String, Codable { case theme, gallery, flowing }
struct Preferences: Codable {
    var appearance = Appearance.system
    var language = "zh-Hans"
    var chrome = ChromeSource.gallery
    var mode = GalleryMode.tiles
    var tileSize: Double = 180
    var showNames = true
    var showViews = true
    var showDuration = true
    var automaticSync = true
    var previewVideos = true
    var maximumPreviews = 4
    var reducedMotion = false
    var blurRadius: Double = 24
    var sceneSpeed: Double = 1
    var sceneTravel: Double = 1
    var skipBackward: Double = 10
    var skipForward: Double = 10
    var seenRelease = ""
    // Optional additions keep 1.2.0 encrypted libraries decodable without data loss.
    var gallerySize122: Int?
    var openAtMarker122: Bool?
    var markerLead122: Double?
    var markerPreview122: Bool?
    var markerWindow122: Double?
    var finePixels122: Double?
    var holdSpeed122: Bool?
    var showDate122: Bool?
    var viewerBackgroundAll122: Bool?
    var squareTiles193: Bool?
    var roundedSquare193: Bool?
    var groupDates199: Bool?
    var swipeDismiss199: Bool?
    var showFilmstrip204: Bool?
    var viewerMuted204: Bool?
    var videoDoubleTap204: Bool?
    var sortGallery199: Int?
    var biometricAsked193: Bool?
    var sourceScope193: String?
    var squareTiles: Bool { squareTiles193 ?? true }
    var roundedSquare: Bool { roundedSquare193 ?? true }
    var sizePreset: Int { max(0, min(5, gallerySize122 ?? 1)) }
    var markerLead: Double { max(0, min(120, markerLead122 ?? 3)) }
    var markerWindow: Double { max(1, min(120, markerWindow122 ?? 8)) }
    var finePixels: Double { max(1, min(6, finePixels122 ?? 2)) }
}
struct MediaRecord: Codable {
    var favorite = false
    var star = false
    var folder = ""
    var views = 0
    var lastViewed: Date?
    var mark: Double?
    var favoriteRank122: Int?
    mutating func viewed(at date: Date = Date()) {
        if lastViewed.map({ date.timeIntervalSince($0) >= 3600 }) ?? true {
            views += 1
            lastViewed = date
        }
    }
    mutating func toggleMark(_ seconds: Double) {
        if mark != nil { mark = nil }
        else { mark = max(0, seconds) }
    }
}
struct WatchSession: Codable {
    var sequence: Int
    var began: Date
    var ended: Date?
    var activeSeconds: Double
}
struct BrowserEntry193: Codable {
    var url: String
    var title: String
    var visited: Date
}
struct LibraryState: Codable {
    var settings = Preferences()
    var records: [String: MediaRecord] = [:]
    var folders: [String] = []
    var sessions: [WatchSession] = []
    var cacheGenerations: [String: String] = [:]
    var cacheVersions: [String] = []
    var cacheOwners123: [String: String]?
    var internalMedia193: [String: EncryptedMedia193]?
    var restoredAssets193: [String: String]?
    var browserHistory193: [BrowserEntry193]?
    var browserFavorites193: [BrowserEntry193]?
    var confirmedAlbumDeletions: Set<String>?
}
final class SessionClock {
    private var lastTick: Date?
    private(set) var current: WatchSession?
    private(set) var running = false
    func start(sequence: Int, now: Date = Date()) {
        guard current == nil else { resume(now: now); return }
        current = WatchSession(sequence: sequence, began: now, ended: nil, activeSeconds: 0)
        lastTick = now
        running = true
    }
    func tick(now: Date = Date()) {
        if running, let last = lastTick { current?.activeSeconds += max(0, now.timeIntervalSince(last)) }
        lastTick = now
    }
    func pause(now: Date = Date()) { tick(now: now); running = false }
    func resume(now: Date = Date()) { guard current != nil else { return }; lastTick = now; running = true }
    func finish(now: Date = Date()) -> WatchSession? {
        tick(now: now)
        current?.ended = now
        let result = current
        current = nil; running = false; lastTick = nil
        return result
    }
}
enum Release {
    static let history = "Nocturne 1.5.38\n加入实况原件归档释放和 20 秒灵动岛测试。软件更新移至图库侧栏。\n\nNocturne 1.5.37\n优先加载屏上缩略图，修正换页闪屏，加入实时活动开关。\n\nNocturne 1.5.36\n双向累计同步进度、查重诊断、存储明细和重签更新校验。\n\nNocturne 1.5.35\n原件核验、查看器和图库快滚改进。\n\nNocturne 1.5.34\n双向查重报告、图库快滚和 Private 转入改进。\n\nNocturne 1.5.33\n优化查看器滑动、实况按钮和设置搜索。\n\nNocturne 1.5.32\n加入 iOS 软件更新和长按菜单。\n\nNocturne 1.5.31\n普通相册先按原件查重、测速并确认，缩小图库间距。\n\nNocturne 1.5.30\n区分配对和连接页，显示传输失败阶段，补齐更新历史。\n\nNocturne 1.5.29\n已配对设备断线后在相同范围内重连，精简设备选择。\n\nNocturne 1.5.28\n分别核验每次 Android 配对连接，区分身份不一致的阶段。\n\nNocturne 1.5.27\n为附近设备提供独立配对卡片，加入崩溃报告上传。\n\nNocturne 1.5.26\n显示 Android 拒绝配对的具体原因。\n\nNocturne 1.5.25\n图库子页面改用横向转场，并显示配对失败阶段。\n\nNocturne 1.5.24\n细化连接与配对诊断，调整图库交互。\n\nNocturne 1.5.23\n调整图库手势、导航与同步界面。\n\nNocturne 1.5.22\n与 Android 对齐部分图库设置和 Private 功能。\n\nNocturne 1.5.21\n加入同步实时活动，连接时核对普通图库范围。\n\nNocturne 1.5.20\n调整查看器，验证整库同步连接。\n\nNocturne 1.5.19\n调整查看器手势、菜单锚点和预览条拖动。\n\nNocturne 1.5.18\n支持接收 Android 普通图库，调整 Apple 图库控件。\n\nNocturne 1.5.17\n直接进入普通图库，调整图库、查看器和同步。\n\nNocturne 1.5.16\n建立 Apple 客户端源码基线。"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.39"
    static var notes: String { "Nocturne \(version) · Apple 开发预览\n\n设置新增实况原件归档释放，保留可验证的实况和查重记录。完整包支持 20 秒灵动岛测试。软件更新移至图库侧栏。" }
}
enum Strings {
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "zh-Hans" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }
    static func text(_ chinese: String, _ english: String, _ japanese: String, _ traditional: String) -> String {
        switch language { case "en": return english; case "ja": return japanese; case "zh-Hant": return traditional; default: return chinese }
    }
    static var all: String { text("全部影像", "All media", "すべて", "全部影像") }
    static var photos: String { text("图片", "Photos", "写真", "圖片") }
    static var videos: String { text("视频", "Videos", "動画", "影片") }
    static var settings: String { text("设置", "Settings", "設定", "設定") }
    static var cancel: String { text("取消", "Cancel", "キャンセル", "取消") }
}

// Pure rules shared by layout, ranking and tests; no screen-size assumptions.
enum GalleryRules122 {
    static let gallerySizes = [4, 5, 0, 1, 2, 3]
    static var gallerySizeTitles: [String] {
        [Strings.text("细密", "Dense", "高密度", "細密"), Strings.text("较小", "Small", "小さい", "較小"),
         Strings.text("紧凑", "Compact", "コンパクト", "緊湊"), Strings.text("均衡", "Balanced", "標準", "均衡"),
         Strings.text("大图", "Large", "大きい", "大圖"), Strings.text("单列", "Single column", "1列", "單列")]
    }
    static func columns(width: Double, preset: Int) -> Int {
        let offsets = [2, 1, 0, -1, -2]
        guard let index = gallerySizes.firstIndex(of: preset), index < offsets.count else { return 1 }
        let balanced = max(4, Int((max(1, width) / 120).rounded()))
        return max(2, min(12, balanced + offsets[index]))
    }
    static func rowCount(remaining: Int, columns: Int) -> Int {
        guard remaining > 0 else { return 0 }
        if columns == 2 && remaining == 3 { return 3 }
        if columns > 1 && remaining == columns + 1 { return (remaining + 1) / 2 }
        return min(remaining, max(1, columns))
    }
    static func quantize(_ seconds: Double, duration: Double, fps: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let frequency = fps.isFinite && fps > 0 ? fps : 30
        let lastFrame = max(0, ceil(duration * frequency) - 1) / frequency
        return max(0, min(lastFrame, (seconds * frequency).rounded() / frequency))
    }
    static func ranking(_ ids: [String], records: [String: MediaRecord]) -> [String] {
        let original = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return ids.filter { records[$0]?.favorite == true }.sorted {
            let left = records[$0]?.favoriteRank122 ?? Int.max, right = records[$1]?.favoriteRank122 ?? Int.max
            return left == right ? original[$0]! < original[$1]! : left < right
        }
    }
    static func move(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from), ids.indices.contains(to) else { return ids }
        var ordered = ids; let id = ordered.remove(at: from); ordered.insert(id, at: to); return ordered
    }
}
