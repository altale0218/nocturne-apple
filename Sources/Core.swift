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
    var sortGallery199: Int?
    var biometricAsked193: Bool?
    var sourceScope193: String?
    var squareTiles: Bool { squareTiles193 ?? true }
    var roundedSquare: Bool { roundedSquare193 ?? true }
    var sizePreset: Int { max(0, min(3, gallerySize122 ?? 1)) }
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
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.18"
    static var notes: String { "Nocturne \(version) · Apple 开发预览\n\n同一局域网的连接暂时中断时，在已确认的相册范围内重新连接原配对设备。同步期间继续显示相册总容量和核对进度，传输速度会随实际数据调整。\n\n继续逐一核验原片和动态照片资源。相册访问、iCloud 下载与删除仍各自需要用户授权。" }
}
enum Strings {
    static var language: String { get { "zh-Hans" } set {} }
    static func text(_ chinese: String, _ english: String, _ japanese: String, _ traditional: String) -> String {
        return chinese
    }
    static var all: String { text("全部影像", "All media", "すべて", "全部影像") }
    static var photos: String { text("图片", "Photos", "写真", "圖片") }
    static var videos: String { text("视频", "Videos", "動画", "影片") }
    static var settings: String { text("设置", "Settings", "設定", "設定") }
    static var cancel: String { text("取消", "Cancel", "キャンセル", "取消") }
}

// Pure rules shared by layout, ranking and tests; no screen-size assumptions.
enum GalleryRules122 {
    static func columns(width: Double, preset: Int) -> Int {
        let balanced = max(1, Int((max(1, width) / 180).rounded()))
        let value = preset == 3 ? 1 : balanced + (preset == 0 ? 1 : preset == 2 ? -1 : 0)
        return max(1, min(8, value))
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
