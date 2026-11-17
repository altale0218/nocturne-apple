import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var coordinator: AppCoordinator?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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
