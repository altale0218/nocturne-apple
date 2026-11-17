import UIKit
import Photos
import AVFoundation

final class GalleryLayout: UICollectionViewLayout {
    var mode = GalleryMode.tiles { didSet { invalidateLayout() } }
    var tileSize: CGFloat = 180 { didSet { invalidateLayout() } }
    var ratios: [CGFloat] = [] { didSet { invalidateLayout() } }
    var square = true { didSet { if oldValue != square { invalidateLayout() } } }
    var names = true { didSet { invalidateLayout() } }
    static let dayHeader = "capture-day"
    var dayStarts: [Int: String] = [:] { didSet { if oldValue != dayStarts { invalidateLayout() } } }
    private var headers: [Int: UICollectionViewLayoutAttributes] = [:]
    private var cached: [UICollectionViewLayoutAttributes] = []
    private var prefixBottom: [CGFloat] = []
    private var rowTop: [CGFloat] = []
    private var width: CGFloat = -1
    private var key = ""
    private var contentHeight: CGFloat = 0
    var sizePreset = 1 { didSet { if oldValue != sizePreset { invalidateLayout() } } }
    override func prepare() {
        guard let collection = collectionView else { return }
        let available = max(1, collection.bounds.width - collection.adjustedContentInset.left - collection.adjustedContentInset.right)
        let fingerprint = "\(mode.rawValue)/\(sizePreset)/\(square)/\(names)/\(ratios.hashValue)/\(dayStarts.hashValue)"
        guard width != available || key != fingerprint else { return }
        width = available; key = fingerprint; cached.removeAll(keepingCapacity: true); prefixBottom.removeAll(keepingCapacity: true); rowTop.removeAll(keepingCapacity: true); headers.removeAll(keepingCapacity: true)
        let gap: CGFloat = 10, padding: CGFloat = 12, footer: CGFloat = names ? 28 : 0
        let inner = max(1, available - padding * 2)
        let columns = GalleryRules122.columns(width: Double(inner), preset: sizePreset)
        func ratio(_ i: Int) -> CGFloat { square ? 1 : max(0.1, min(10, ratios[i])) }
        let boundaries = dayStarts.keys.sorted() + [ratios.count]
        var boundary = dayStarts[0] == nil ? 0 : 1
        func beginDay(_ item: Int, _ y: CGFloat) -> CGFloat {
            guard dayStarts[item] != nil else { return y }
            let attr = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.dayHeader, with: IndexPath(item: item, section: 0))
            attr.frame = CGRect(x: padding, y: y, width: inner, height: 30)
            headers[item] = attr
            return y + 34
        }
        if mode == .tiles {
            var y: CGFloat = padding, index = 0
            while index < ratios.count {
                y = beginDay(index, y)
                while boundaries[boundary] <= index { boundary += 1 }
                let remaining = boundaries[boundary] - index
                let count = min(columns, remaining)
                let end = index + count, sum = (index..<end).reduce(CGFloat(0)) { $0 + ratio($1) }
                let gridHeight = max(1, (inner - CGFloat(columns - 1) * gap) / CGFloat(columns))
                let fitting = max(1, (inner - CGFloat(count - 1) * gap) / sum)
                let height = square ? gridHeight : count < columns ? min(gridHeight, fitting) : fitting
                var x = padding
                for item in index..<end {
                    let w = square ? height : (count == columns && item == end - 1 ? padding + inner - x : height * ratio(item))
                    append(item, CGRect(x: x, y: y, width: w, height: height + footer), row: y)
                    x += w + gap
                }
                index = end; y += height + footer + gap
            }
            contentHeight = y + padding
        } else {
            // Stable shortest-column masonry fills portrait/landscape gaps, preserving aspect.
            let columnWidth = max(1, (inner - CGFloat(columns - 1) * gap) / CGFloat(columns))
            var bottoms = Array(repeating: padding, count: columns)
            for item in ratios.indices {
                if dayStarts[item] != nil { let y = beginDay(item, bottoms.max() ?? padding); bottoms = Array(repeating: y, count: columns) }
                let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
                let y = bottoms[column], height = columnWidth / ratio(item) + footer
                append(item, CGRect(x: padding + CGFloat(column) * (columnWidth + gap), y: y, width: columnWidth, height: height), row: y)
                bottoms[column] += height + gap
            }
            contentHeight = (bottoms.max() ?? padding) + padding
        }
    }
    private func append(_ item: Int, _ frame: CGRect, row: CGFloat) {
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0)); a.frame = frame; cached.append(a); prefixBottom.append(max(prefixBottom.last ?? 0, frame.maxY)); rowTop.append(row)
    }
    override var collectionViewContentSize: CGSize { CGSize(width: max(0, width), height: contentHeight) }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // Binary search by row-end prefix, avoiding O(library size) work for each scroll.
        var lo = 0, hi = cached.count
        while lo < hi { let middle = (lo + hi) / 2; if prefixBottom[middle] < rect.minY - 350 { lo = middle + 1 } else { hi = middle } }
        var result: [UICollectionViewLayoutAttributes] = []
        for item in lo..<cached.count { let a = cached[item]; if rowTop[item] > rect.maxY + 350 { break }; if let header = headers[item], header.frame.intersects(rect.insetBy(dx: 0, dy: -350)) { result.append(header) }; if a.frame.intersects(rect.insetBy(dx: -20, dy: -350)) { result.append(a) } }
        return result
    }
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? { headers[indexPath.item] }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? { indexPath.item < cached.count ? cached[indexPath.item] : nil }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { collectionView?.bounds.width != newBounds.width }
}
final class CaptureDayHeader199: UICollectionReusableView {
    let title = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        title.frame = bounds; title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        title.font = .preferredFont(forTextStyle: .headline)
        title.accessibilityTraits = .header
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class MediaCell: UICollectionViewCell {
    static let reuse = "media"
    let image = UIImageView(), name = UILabel(), facts = UILabel(), videoIcon = UILabel()
    let videoLayer = AVPlayerLayer()
    let protectedBadge193 = UIImageView(), selectionBadge193 = UILabel()
    var rankText: String?
    var represented = ""
    var showName = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 16; contentView.layer.masksToBounds = true
        contentView.backgroundColor = UIColor(white: 1, alpha: 0.06)
        image.contentMode = .scaleAspectFit; image.clipsToBounds = true
        contentView.addSubview(image); contentView.layer.addSublayer(videoLayer)
        videoLayer.videoGravity = .resizeAspect
        name.font = .systemFont(ofSize: 11, weight: .medium); name.lineBreakMode = .byTruncatingTail
        facts.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); facts.textColor = .white
        facts.textAlignment = .right; facts.backgroundColor = UIColor(white: 0, alpha: 0.28); facts.layer.cornerRadius = 7; facts.clipsToBounds = true
        videoIcon.text = "▷"; videoIcon.font = .systemFont(ofSize: 16); videoIcon.textColor = .white
        videoIcon.backgroundColor = UIColor(white: 0, alpha: 0.25); videoIcon.layer.cornerRadius = 8; videoIcon.clipsToBounds = true; videoIcon.textAlignment = .center
        contentView.addSubview(name); contentView.addSubview(facts); contentView.addSubview(videoIcon)
        if #available(iOS 13, *) { protectedBadge193.image = UIImage(systemName: "shield") }; protectedBadge193.tintColor = Theme.blue; protectedBadge193.contentMode = .scaleAspectFit; contentView.addSubview(protectedBadge193)
        selectionBadge193.textColor = .white; selectionBadge193.textAlignment = .center; selectionBadge193.font = .systemFont(ofSize: 16, weight: .semibold); selectionBadge193.layer.cornerRadius = 12; selectionBadge193.clipsToBounds = true; selectionBadge193.isHidden = true; contentView.addSubview(selectionBadge193)
        protectedBadge193.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func selection193(active: Bool, selected: Bool) {
        selectionBadge193.isHidden = !active; selectionBadge193.text = selected ? "✓" : ""
        selectionBadge193.backgroundColor = selected ? Theme.blue : UIColor(white: 0.1, alpha: 0.42)
        selectionBadge193.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor; selectionBadge193.layer.borderWidth = 1.5
        contentView.layer.borderWidth = active && selected ? 2 : 0; contentView.layer.borderColor = Theme.blue.cgColor
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let footer: CGFloat = showName ? 28 : 0
        image.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - footer))
        videoLayer.frame = image.frame
        name.frame = CGRect(x: 8, y: image.frame.maxY, width: max(1, bounds.width - 16), height: footer)
        facts.sizeToFit(); facts.frame = CGRect(x: max(4, bounds.width - facts.bounds.width - 14), y: max(4, image.frame.maxY - 26), width: facts.bounds.width + 10, height: 20)
        videoIcon.frame = CGRect(x: 8, y: 8, width: 25, height: 25)
        selectionBadge193.frame = CGRect(x: max(4, bounds.width - 32), y: max(4, image.frame.maxY - 32), width: 24, height: 24)
        protectedBadge193.frame = CGRect(x: max(4, bounds.width - 24), y: 8, width: 16, height: 18)
    }
    override func prepareForReuse() {
        super.prepareForReuse(); selection193(active: false, selected: false); represented = ""; protectedBadge193.isHidden = true; image.image = nil; videoLayer.player = nil; videoLayer.opacity = 0; facts.text = ""; rankText = nil; transform = .identity; layer.transform = CATransform3DIdentity; layer.zPosition = 0
    }
}
