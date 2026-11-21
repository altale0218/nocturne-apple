import ActivityKit
import UIKit

@available(iOS 16.2, *)
final class NocturneTaskActivity {
    typealias State = NocturneTaskAttributes.ContentState
    private let kind: NocturneTaskAttributes.Kind
    private var activity: Activity<NocturneTaskAttributes>?
    private var lastUpdate: TimeInterval = -.infinity
    private var lastState: State?
    private var operation: Task<Void, Never>?
    private static var cleaned = false

    init(_ kind: NocturneTaskAttributes.Kind) { self.kind = kind }

    static var shipped: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true,
              let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("NocturneTaskActivity.appex").path)
    }

    private static func preference(_ kind: NocturneTaskAttributes.Kind) -> String {
        "liveActivities.nocturne." + kind.rawValue
    }

    static func wants(_ kind: NocturneTaskAttributes.Kind) -> Bool {
        UserDefaults.standard.object(forKey: preference(kind)) as? Bool ?? true
    }

    static var systemEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func setEnabled(_ enabled: Bool, for kind: NocturneTaskAttributes.Kind) {
        UserDefaults.standard.set(enabled, forKey: preference(kind))
        if !enabled {
            let running = Activity<NocturneTaskAttributes>.activities.filter { $0.attributes.kind == kind }
            Task { for item in running { await item.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    func start(_ phase: String) {
        guard activity == nil, Self.shipped, Self.wants(kind), UIApplication.shared.applicationState == .active,
              Self.systemEnabled else { return }
        if !Self.cleaned {
            Self.cleaned = true
            let leftovers = Activity<NocturneTaskAttributes>.activities
            Task { for leftover in leftovers { await leftover.end(nil, dismissalPolicy: .immediate) } }
        }
        let state = State(phase: phase)
        activity = try? Activity.request(attributes: NocturneTaskAttributes(kind: kind),
                                        content: content(state), pushType: nil)
        lastState = state
        lastUpdate = ProcessInfo.processInfo.systemUptime
    }

    func update(phase: String, percent: Int? = nil, rate: Int64? = nil, done: Int64? = nil, total: Int64? = nil,
                itemsDone: Int? = nil, itemsTotal: Int? = nil) {
        if let current = activity, current.activityState == .ended || current.activityState == .dismissed { return }
        if activity == nil { start(phase); lastUpdate = -.infinity }
        guard let activity, Self.wants(kind), Self.systemEnabled else { return }
        let state = State(phase: phase, percent: percent.map { min(100, max(0, $0)) },
                          bytesPerSecond: rate, done: done, total: total, itemsDone: itemsDone, itemsTotal: itemsTotal)
        let now = ProcessInfo.processInfo.systemUptime
        guard state != lastState, state.phase != lastState?.phase || now - lastUpdate >= 2 else { return }
        lastState = state
        lastUpdate = now
        let next = content(state)
        let prior = operation
        operation = Task { await prior?.value; await activity.update(next) }
    }

    func end(_ phase: String, complete: Bool = false) {
        guard let activity = activity else { return }
        self.activity = nil
        lastState = nil
        let final = ActivityContent(state: State(phase: phase, percent: complete ? 100 : nil), staleDate: nil)
        let prior = operation
        operation = Task { await prior?.value; await activity.end(final, dismissalPolicy: .after(Date().addingTimeInterval(20))) }
    }

    private func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(15))
    }
}
