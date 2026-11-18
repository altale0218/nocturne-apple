import UIKit

enum Theme {
    static let blue = UIColor(red: 0.16, green: 0.41, blue: 0.86, alpha: 1)
    static func background(_ dark: Bool) -> UIColor { dark ? UIColor(white: 0.065, alpha: 1) : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1) }
    static func text(_ dark: Bool) -> UIColor { dark ? UIColor(white: 0.94, alpha: 1) : UIColor(red: 0.10, green: 0.15, blue: 0.20, alpha: 1) }
    static func muted(_ dark: Bool) -> UIColor { dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.42, alpha: 1) }
    static func button(_ symbol: String, target: Any?, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        if #available(iOS 13, *), let icon = UIImage(systemName: symbol) { button.setImage(icon, for: .normal) }
        else { button.setTitle(["chevron.left": "‹", "ellipsis": "•••", "play.fill": "▶", "pause.fill": "Ⅱ", "gearshape": "⚙", "line.3.horizontal": "☰", "arrow.clockwise": "↻"][symbol] ?? "◇", for: .normal) }
        button.tintColor = Theme.blue
        button.addTarget(target, action: action, for: .touchUpInside)
        button.layer.cornerRadius = 14
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            var style = UIButton.Configuration.glass(); style.image = button.image(for: .normal); style.baseForegroundColor = Theme.blue
            button.configuration = style; button.backgroundColor = .clear
        }
        #endif
        button.accessibilityLabel = symbol
        return button
    }
    static func animate(reduced: Bool, _ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        UIView.animate(withDuration: reduced ? 0 : 0.38, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.25, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: completion)
    }
}
final class FlowBackground: UIView {
    let gradient = CAGradientLayer()
    private let photo = UIImageView(), veil = UIView()
    private var photoEpoch = 0
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false
        photo.contentMode = .scaleAspectFill; photo.clipsToBounds = true; photo.transform = CGAffineTransform(scaleX: -1, y: 1); photo.alpha = 0.24; addSubview(photo); veil.backgroundColor = UIColor(white: 1, alpha: 0.52); addSubview(veil)
        gradient.colors = [UIColor(red: 0.25, green: 0.51, blue: 0.85, alpha: 0.12).cgColor,
                           UIColor(red: 0.64, green: 0.44, blue: 0.87, alpha: 0.10).cgColor,
                           UIColor(red: 0.34, green: 0.75, blue: 0.71, alpha: 0.08).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds; photo.frame = bounds; veil.frame = bounds }
    func image(_ source: UIImage?, radius: Double, dark: Bool) {
        photoEpoch += 1; let token = photoEpoch
        veil.backgroundColor = dark ? UIColor(white: 0.05, alpha: 0.65) : UIColor(white: 1, alpha: 0.52)
        guard let source = source else { photo.image = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = PhotoBlur120.render(source, radius: radius)
            DispatchQueue.main.async { guard let self = self, token == self.photoEpoch else { return }; self.photo.image = result }
        }
    }
    func run(_ enabled: Bool) {
        gradient.removeAllAnimations()
        guard enabled else { return }
        let animation = CABasicAnimation(keyPath: "startPoint")
        animation.fromValue = NSValue(cgPoint: CGPoint(x: -0.3, y: 0.1)); animation.toValue = NSValue(cgPoint: CGPoint(x: 1, y: 0.8))
        animation.duration = 12; animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(animation, forKey: "flow")
    }
}
final class PreparationPanel: UIView {
    let title = UILabel(), progress = UIProgressView(progressViewStyle: .default)
    private var normalized = CGPoint(x: 1, y: 0.2)
    private var origin = CGPoint.zero
    private var fade: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.98, alpha: 0.92); layer.cornerRadius = 18
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.10; layer.shadowRadius = 12
        title.font = .systemFont(ofSize: 12, weight: .medium); title.textColor = UIColor(white: 0.2, alpha: 1)
        addSubview(title); addSubview(progress)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(activate)); addGestureRecognizer(tap)
        if let point = UserDefaults.standard.array(forKey: "preparationPosition") as? [Double], point.count == 2 { normalized = CGPoint(x: point[0], y: point[1]) }
        accessibilityLabel = Strings.text("缩略图准备进度", "Thumbnail preparation progress", "サムネイル準備の進捗", "縮圖準備進度")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); title.frame = CGRect(x: 14, y: 10, width: bounds.width - 28, height: 20); progress.frame = CGRect(x: 14, y: 38, width: bounds.width - 28, height: 4) }
    func restore(in parent: UIView) {
        let area = parent.bounds.inset(by: parent.safeAreaInsets).insetBy(dx: 10, dy: 10)
        let width = max(0, min(260, area.width))
        let x = min(1, max(0, normalized.x)), y = min(1, max(0, normalized.y))
        frame = CGRect(x: area.minX + x * max(0, area.width - width),
                       y: area.minY + y * max(0, area.height - 56), width: width, height: 56)
    }
    @objc private func activate() {
        fade?.cancel(); alpha = 1
        let work = DispatchWorkItem { [weak self] in UIView.animate(withDuration: 0.3) { self?.alpha = 0.35 } }
        fade = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        if gesture.state == .began { origin = frame.origin; activate() }
        let delta = gesture.translation(in: parent), area = parent.bounds.inset(by: parent.safeAreaInsets).insetBy(dx: 10, dy: 10)
        frame.origin = CGPoint(x: max(area.minX, min(area.maxX - frame.width, origin.x + delta.x)), y: max(area.minY, min(area.maxY - frame.height, origin.y + delta.y)))
        if gesture.state == .ended || gesture.state == .cancelled {
            normalized = CGPoint(x: (frame.minX - area.minX) / max(1, area.width - frame.width), y: (frame.minY - area.minY) / max(1, area.height - frame.height))
            UserDefaults.standard.set([Double(normalized.x), Double(normalized.y)], forKey: "preparationPosition")
            activate()
        }
    }
    func update(_ value: Double, message: String) {
        hideWork?.cancel(); title.text = message; title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.75
        progress.setProgress(Float(max(0, min(1, value))), animated: true)
        isHidden = message.isEmpty
        if !isHidden && fade == nil { activate() }
        if value >= 1 && !message.isEmpty {
            activate(); UIAccessibility.post(notification: .announcement, argument: message)
            let work = DispatchWorkItem { [weak self] in self?.isHidden = true }; hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }
    deinit { fade?.cancel(); hideWork?.cancel() }
}

/// System compositor material, never a screenshot/readback blur implementation.
final class NativeGlass193: UIVisualEffectView {
    override init(effect: UIVisualEffect? = nil) {
        super.init(effect: nil); clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh193), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        refresh193()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); refresh193() }
    @objc private func refresh193() {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { cornerConfiguration = .capsule() }
        #endif
        if UIAccessibility.isReduceTransparencyEnabled {
            effect = nil
            if #available(iOS 13, *) { backgroundColor = .secondarySystemBackground } else { backgroundColor = .white }
            return
        }
        backgroundColor = .clear
        #if compiler(>=6.2)
        if #available(iOS 26, *) { effect = UIGlassEffect(style: .regular); return }
        #endif
        if #available(iOS 13, *) { effect = UIBlurEffect(style: .systemMaterial) } else { effect = UIBlurEffect(style: .light) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return }
        #endif
        layer.cornerRadius = min(26, bounds.height / 2)
        if #available(iOS 13, *) { layer.cornerCurve = .continuous }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
