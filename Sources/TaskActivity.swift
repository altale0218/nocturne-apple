import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct NocturneTaskAttributes: ActivityAttributes {
    enum Kind: String, Codable { case cache, sync }
    struct ContentState: Codable, Hashable {
        var phase: String
        var percent: Int?
        var bytesPerSecond: Int64?
        var done: Int64?
        var total: Int64?
        var itemsDone: Int?
        var itemsTotal: Int?
    }
    let kind: Kind
}
