import UIKit
import MetricKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var coordinator: AppCoordinator?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if #available(iOS 15, *) { MXMetricManager.shared.add(CrashReports209.shared) }
        Strings.language = UserDefaults.standard.string(forKey: "language") ?? "zh-Hans"
        #if NOCTURNE_LEGACY
        let window = UIWindow(frame: UIScreen.main.bounds); self.window = window
        let coordinator = AppCoordinator(window: window); self.coordinator = coordinator; coordinator.start()
        #endif
        return true
    }
    @available(iOS 13, *)
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role); configuration.delegateClass = SceneDelegate.self; return configuration
    }
    func applicationWillResignActive(_ application: UIApplication) { coordinator?.willResignActive() }
    func applicationDidBecomeActive(_ application: UIApplication) { coordinator?.becameActive() }
    func applicationDidEnterBackground(_ application: UIApplication) { coordinator?.background() }
    func applicationWillTerminate(_ application: UIApplication) { coordinator?.background() }
}
@available(iOS 13, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var coordinator: AppCoordinator?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); self.window = window
        // Stage Manager chooses the initial size; no fixed screen-size assumptions or maximum restriction.
        scene.sizeRestrictions?.minimumSize = CGSize(width: 320, height: 320)
        let coordinator = AppCoordinator(window: window); self.coordinator = coordinator; coordinator.start()
    }
    func sceneWillResignActive(_ scene: UIScene) { coordinator?.willResignActive() }
    func sceneDidBecomeActive(_ scene: UIScene) { coordinator?.becameActive() }
    func sceneDidEnterBackground(_ scene: UIScene) { coordinator?.background() }
    func sceneDidDisconnect(_ scene: UIScene) { coordinator?.background() }
}

@available(iOS 15, *)
final class CrashReports209: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports209()
    private let storageKey = "nocturne.crash-summary"
    private let queue = DispatchQueue(label: "nocturne.crash-summary")

    struct Summary: Codable {
        let platform: String
        let version: String
        let kind: String
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let report = payloads.flatMap({ $0.crashDiagnostics ?? [] }).last else { return }
        let kind = "signal:\(report.signal?.intValue ?? 0);exception:\(report.exceptionType?.intValue ?? 0)"
        let version = report.metaData.applicationVersion
        let summary = Summary(platform: "ios", version: version, kind: kind)
        queue.async {
            if let data = try? JSONEncoder().encode(summary) {
                UserDefaults.standard.set(data, forKey: self.storageKey)
            }
        }
    }

    func present(from controller: UIViewController) {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            let alert = UIAlertController(title: "崩溃报告", message: "系统尚未提供崩溃记录。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .cancel))
            controller.present(alert, animated: true)
            return
        }
        let alert = UIAlertController(title: "上传崩溃报告",
            message: "发送版本 \(summary.version) 和崩溃代码 \(summary.kind)。报告在云端保留 30 天。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "上传", style: .default) { [weak controller] _ in
            var request = URLRequest(url: URL(string: "https://nocturne-crash-reports.altale0218.workers.dev/v1/crashes")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            URLSession.shared.dataTask(with: request) { body, response, _ in
                let id = (response as? HTTPURLResponse)?.statusCode == 201
                    ? body.flatMap { try? JSONDecoder().decode(Receipt.self, from: $0).id } : nil
                DispatchQueue.main.async {
                    guard let controller = controller, controller.viewIfLoaded?.window != nil else { return }
                    let result = UIAlertController(title: "崩溃报告", message: id.map { "已上传。报告编号 \($0)" } ?? "上传失败，记录仍保存在本机。", preferredStyle: .alert)
                    result.addAction(UIAlertAction(title: "好", style: .cancel))
                    controller.present(result, animated: true)
                }
            }.resume()
        })
        controller.present(alert, animated: true)
    }

    private struct Receipt: Decodable { let id: String }
}
