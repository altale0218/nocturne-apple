import Foundation
import CoreFoundation
import CryptoKit

/// Version 1 transfers each manifest item as one transaction, with a digest for every native resource.
enum MobileAlbumTransfer {
    struct Unavailable: Error {}
    private static let maximumOriginalBytes: Int64 = 1 << 50
    protocol Source {
        var count: Int { get }
        var unavailable: Int { get }
        var originalBytes: Int64? { get }
        func nextPage() async throws -> MobileAlbumManifest.Page?
        func open(_ asset: MobileAlbumManifest, part: Int) async throws -> FileHandle
        func acknowledged(_ page: MobileAlbumManifest.Page, items: [String]) async throws
    }

    protocol Target {
        func start(count: Int, unavailable: Int) async throws
        func plan(_ page: MobileAlbumManifest.Page) async throws -> [String]
        func stage(_ asset: MobileAlbumManifest, part: Int) async throws -> FileHandle
        func commit(_ asset: MobileAlbumManifest) async throws
        func finish(_ page: MobileAlbumManifest.Page) async throws -> [String]
        func abort() async
    }

    typealias Channel = AppleSyncTransport.Channel
    private static let maximumCount = 100_000

    static func send(_ source: Source, channel: Channel, batchReceipts: Bool = true, resourceReady: Bool = false,
                     approval: PreviewTotals? = nil, onInventory: ((Int64?) -> Void)? = nil,
                     onPayload: ((Int64, Int64, Double) -> Void)? = nil,
                     progress: (Int, Int) -> Void = { _, _ in }) async throws {
        let count = source.count
        guard (0...maximumCount).contains(count), (0...(maximumCount - count)).contains(source.unavailable)
              else { throw MediaError193.tooLarge }
        var open: [String: Any] = ["op": "album-open1", "count": count, "unavailable": source.unavailable, "partialCommit": true]
        let capacity = validOriginalBytes(source.originalBytes)
        if let capacity = capacity { open["originalBytes"] = capacity }
        onInventory?(capacity)
        if batchReceipts { open["batchReceipts"] = true }
        try await channel.sendObject(1, open)
        let ready = try await expect(channel, kind: 2, operation: "album-ready1")
        guard ready["count"] as? Int == count else { throw MediaError193.changed }
        let batched = batchReceipts && enabled(ready["batchReceipts"])
        var seen = Set<String>(), pages = Set<String>(), bytes: Int64 = 0
        let payload = PayloadProgress(approvedBytes: approval?.bytes, report: onPayload)
        while let page = try await source.nextPage() {
            try verify(page, count: count, seen: &seen, pages: &pages)
            let packet = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
            try await channel.sendObject(1, packetFor("album-page1", page: page.id, fields: ["manifest": packet]))
            let request = try await expect(channel, kind: 2, operation: "album-want1", page: page.id)
            let items = Dictionary(uniqueKeysWithValues: page.assets.map { ($0.id, $0) })
            let wanted = try requested(request["assets"], items: items)
            if let approval, !wanted.allSatisfy({ items[$0].map(approval.allows) == true }) {
                throw AppleSyncTransport.Failure.rejected("album-plan-changed")
            }
            var committed = Set<String>(), declined = Set<String>()
            payload.beginPage(wanted: wanted, items: items)
            var window = PageWindow()
            for (position, id) in wanted.enumerated() {
                guard let asset = items[id] else { throw MediaError193.changed }
                try account(asset, bytes: &bytes)
                try await channel.sendObject(3, packetFor("album-asset1", page: page.id, item: id))
                for (part, resource) in asset.resources.enumerated() {
                    if resourceReady {
                        let grant = try await expect(channel, kind: 6, operation: "album-resource-ready1", page: page.id, item: id)
                        guard grant["part"] as? Int == part else { throw MediaError193.changed }
                    }
                    let input = try await withWaiting(channel) { try await source.open(asset, part: part) }
                    try await transmit(input, resource: resource, channel: channel, payload: payload)
                    try await channel.sendObject(5, packetFor("album-resource-end1", page: page.id, item: id,
                                                             fields: ["part": part]))
                }
                if !batched {
                    let outcome = try await channel.receiveObject(6)
                    guard outcome["batch"] as? String == page.id, outcome["gid"] as? String == id
                          else { throw MediaError193.changed }
                    switch outcome["op"] as? String {
                    case "album-asset-ok1": committed.insert(id)
                    case "album-asset-skip1": declined.insert(id)
                    default: throw MediaError193.malformed
                    }
                } else if window.checkpoint(asset.byteCount, next: nextBytes(wanted, items: items, position: position)) {
                    let checkpoint = try await expect(channel, kind: 6, operation: "album-page-progress1", page: page.id)
                    guard checkpoint["count"] as? Int == position + 1 else { throw MediaError193.changed }
                }
            }
            try await channel.sendObject(7, packetFor("album-page-end1", page: page.id))
            let receipt = try await expect(channel, kind: 6, operation: "album-page-ok1", page: page.id)
            let confirmed = try requested(receipt["assets"], items: items)
            guard committed.isSubset(of: Set(confirmed)), declined.isDisjoint(with: confirmed)
                  else { throw MediaError193.verification }
            try await source.acknowledged(page, items: confirmed)
            progress(seen.count, count)
        }
        guard seen.count == count else { throw MediaError193.changed }
        try await channel.sendObject(1, ["op": "album-end1", "count": count])
        let final = try await expect(channel, kind: 6, operation: "album-end-ok1")
        guard final["count"] as? Int == count else { throw MediaError193.changed }
    }

    static func receive(_ target: Target, channel: Channel, approval: PreviewTotals? = nil,
                        onInventory: ((Int64?) -> Void)? = nil,
                        onPayload: ((Int64, Int64, Double) -> Void)? = nil, progress: (Int, Int) -> Void = { _, _ in }) async throws {
        do {
            let open = try await expect(channel, kind: 1, operation: "album-open1")
            guard let count = open["count"] as? Int, (0...maximumCount).contains(count)
                  else { throw MediaError193.malformed }
            let capacity = open["originalBytes"] as? NSNumber
            if let capacity = capacity, CFGetTypeID(capacity) != CFBooleanGetTypeID() {
                onInventory?(validOriginalBytes(capacity as? Int64))
            } else {
                onInventory?(nil)
            }
            let partial = enabled(open["partialCommit"])
            let batched = partial && enabled(open["batchReceipts"])
            let unavailable = open["unavailable"] ?? 0
            guard let skipped = unavailable as? Int, (0...(maximumCount - count)).contains(skipped)
                  else { throw MediaError193.malformed }
            try await withWaiting(channel) { try await target.start(count: count, unavailable: skipped) }
            var ready: [String: Any] = ["op": "album-ready1", "count": count]
            if batched { ready["batchReceipts"] = true }
            try await channel.sendObject(2, ready)
            var seen = Set<String>(), pages = Set<String>(), bytes: Int64 = 0
            let payload = PayloadProgress(approvedBytes: approval?.bytes, report: onPayload)
            while true {
                let packet = try await channel.receiveObject(1)
                if packet["op"] as? String == "album-end1" {
                    guard packet["count"] as? Int == count, seen.count == count else { throw MediaError193.changed }
                    try await channel.sendObject(6, ["op": "album-end-ok1", "count": count])
                    return
                }
                guard packet["op"] as? String == "album-page1", let contents = packet["manifest"],
                      JSONSerialization.isValidJSONObject(contents) else { throw MediaError193.malformed }
                let manifest = try JSONSerialization.data(withJSONObject: contents)
                let page = try JSONDecoder().decode(MobileAlbumManifest.Page.self, from: manifest)
                guard packet["batch"] as? String == page.id else { throw MediaError193.changed }
                try verify(page, count: count, seen: &seen, pages: &pages)
                let items = Dictionary(uniqueKeysWithValues: page.assets.map { ($0.id, $0) })
                let plan = try await withWaiting(channel) { try await target.plan(page) }
                let wanted = try requested(plan, items: items)
                if let approval, !wanted.allSatisfy({ items[$0].map(approval.allows) == true }) {
                    throw AppleSyncTransport.Failure.rejected("album-plan-changed")
                }
                var committed = Set<String>(), declined = Set<String>()
                try await channel.sendObject(2, packetFor("album-want1", page: page.id, fields: ["assets": wanted]))
                payload.beginPage(wanted: wanted, items: items)
                var window = PageWindow()
                for (position, id) in wanted.enumerated() {
                    guard let asset = items[id] else { throw MediaError193.changed }
                    try account(asset, bytes: &bytes)
                    _ = try await expect(channel, kind: 3, operation: "album-asset1", page: page.id, item: id)
                    for (part, resource) in asset.resources.enumerated() {
                        let file = try await target.stage(asset, part: part)
                        try await read(file, resource: resource, channel: channel, payload: payload)
                        let end = try await expect(channel, kind: 5, operation: "album-resource-end1", page: page.id, item: id)
                        guard end["part"] as? Int == part else { throw MediaError193.changed }
                    }
                    do {
                        try await withWaiting(channel) { try await target.commit(asset) }
                        committed.insert(id)
                    } catch let unavailable as Unavailable {
                        guard partial else { throw unavailable }
                        declined.insert(id)
                    }
                    // The page receipt is sent only after the target finishes publishing.
                    if !batched {
                        let outcome = declined.contains(id) ? "album-asset-skip1" : "album-asset-ok1"
                        try await channel.sendObject(6, packetFor(outcome, page: page.id, item: id))
                    } else if window.checkpoint(asset.byteCount, next: nextBytes(wanted, items: items, position: position)) {
                        try await channel.sendObject(6, packetFor("album-page-progress1", page: page.id,
                                                                  fields: ["count": position + 1]))
                    }
                }
                _ = try await expect(channel, kind: 7, operation: "album-page-end1", page: page.id)
                let receipt = try await withWaiting(channel) { try await target.finish(page) }
                let confirmed = try requested(receipt, items: items)
                guard committed.isSubset(of: Set(confirmed)), declined.isDisjoint(with: confirmed)
                      else { throw MediaError193.verification }
                try await channel.sendObject(6, packetFor("album-page-ok1", page: page.id, fields: ["assets": confirmed]))
                progress(seen.count, count)
            }
        } catch {
            await target.abort()
            throw error
        }
    }

    struct PreviewSelection {
        let pending: [String]
        let duplicates: Int
        let deferred: Int
    }

    struct PreviewTotals {
        var pending = 0
        var duplicates = 0
        var deferred = 0
        var bytes: Int64 = 0
        private var approved: [String: String] = [:]
        private var originals = Set<String>()

        mutating func record(_ choice: PreviewSelection, page: MobileAlbumManifest.Page,
                             items: [String: MobileAlbumManifest]) throws {
            guard choice.duplicates >= 0, choice.deferred >= 0,
                  choice.pending.count <= page.assets.count,
                  choice.duplicates <= page.assets.count, choice.deferred <= page.assets.count,
                  choice.pending.count + choice.duplicates + choice.deferred == page.assets.count else { throw MediaError193.changed }
            let wanted = try MobileAlbumTransfer.requested(choice.pending, items: items)
            duplicates += choice.duplicates
            deferred += choice.deferred
            for id in wanted {
                guard let item = items[id] else { throw MediaError193.changed }
                if !originals.insert(item.transferKey).inserted { duplicates += 1; continue }
                guard item.byteCount <= maximumOriginalBytes - bytes else { throw MediaError193.tooLarge }
                bytes += item.byteCount; pending += 1; approved[id] = item.transferKey
            }
        }

        func allows(_ item: MobileAlbumManifest) -> Bool { approved[item.id] == item.transferKey }
    }

    static func previewSend(_ source: Source, channel: Channel, progress: (Int, Int, Int) -> Void = { _, _, _ in }) async throws -> PreviewTotals {
        let count = source.count
        guard (0...maximumCount).contains(count), (0...(maximumCount - count)).contains(source.unavailable)
              else { throw MediaError193.tooLarge }
        try await channel.sendObject(1, ["op": "album-preview-open1", "count": count, "unavailable": source.unavailable])
        _ = try await expect(channel, kind: 2, operation: "album-preview-ready1")
        var totals = PreviewTotals(), seen = Set<String>(), pages = Set<String>()
        totals.deferred = source.unavailable
        while let page = try await source.nextPage() {
            try verify(page, count: count, seen: &seen, pages: &pages)
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
            try await channel.sendObject(1, packetFor("album-preview-page1", page: page.id, fields: ["manifest": body]))
            progress(seen.count - page.assets.count, page.assets.count, count)
            let response = try await expect(channel, kind: 2, operation: "album-preview-result1", page: page.id)
            guard let pending = response["assets"] as? [String], let duplicate = response["duplicates"] as? Int,
                  let deferred = response["deferred"] as? Int else { throw MediaError193.malformed }
            let items = Dictionary(uniqueKeysWithValues: page.assets.map { ($0.id, $0) })
            try totals.record(.init(pending: pending, duplicates: duplicate, deferred: deferred), page: page, items: items)
            progress(seen.count, 0, count)
        }
        guard seen.count == count else { throw MediaError193.changed }
        try await channel.sendObject(1, ["op": "album-preview-end1"])
        _ = try await expect(channel, kind: 2, operation: "album-preview-ok1")
        return totals
    }

    static func previewReceive(_ target: PhotoAlbumTarget, channel: Channel, progress: (Int, Int, Int) -> Void = { _, _, _ in }) async throws -> PreviewTotals {
        try await previewReceive(channel: channel, start: { count, unavailable in
            try await target.start(count: count, unavailable: unavailable)
        }, choose: target.preview, progress: progress)
    }

    static func previewReceive(channel: Channel, start: (Int, Int) async throws -> Void,
                               choose: (MobileAlbumManifest.Page) throws -> PreviewSelection,
                               progress: (Int, Int, Int) -> Void) async throws -> PreviewTotals {
        let open = try await expect(channel, kind: 1, operation: "album-preview-open1")
        guard let count = open["count"] as? Int, (0...maximumCount).contains(count),
              let unavailable = open["unavailable"] as? Int, (0...(maximumCount - count)).contains(unavailable)
              else { throw MediaError193.malformed }
        try await withWaiting(channel) { try await start(count, unavailable) }
        try await channel.sendObject(2, ["op": "album-preview-ready1"])
        var totals = PreviewTotals(), seen = Set<String>(), pages = Set<String>()
        totals.deferred = unavailable
        while true {
            let packet = try await channel.receiveObject(1)
            if packet["op"] as? String == "album-preview-end1" {
                guard seen.count == count else { throw MediaError193.changed }
                try await channel.sendObject(2, ["op": "album-preview-ok1"])
                return totals
            }
            guard packet["op"] as? String == "album-preview-page1", let body = packet["manifest"],
                  JSONSerialization.isValidJSONObject(body) else { throw MediaError193.malformed }
            let page = try JSONDecoder().decode(MobileAlbumManifest.Page.self, from: JSONSerialization.data(withJSONObject: body))
            guard packet["batch"] as? String == page.id else { throw MediaError193.changed }
            try verify(page, count: count, seen: &seen, pages: &pages)
            progress(seen.count - page.assets.count, page.assets.count, count)
            let items = Dictionary(uniqueKeysWithValues: page.assets.map { ($0.id, $0) })
            let choice = try choose(page)
            try totals.record(choice, page: page, items: items)
            progress(seen.count, 0, count)
            try await channel.sendObject(2, packetFor("album-preview-result1", page: page.id, fields: [
                "assets": choice.pending, "duplicates": choice.duplicates, "deferred": choice.deferred]))
        }
    }

    private static func validOriginalBytes(_ bytes: Int64?) -> Int64? {
        guard let bytes = bytes, (0...maximumOriginalBytes).contains(bytes) else { return nil }
        return bytes
    }

    private static func nextBytes(_ wanted: [String], items: [String: MobileAlbumManifest], position: Int) -> Int64 {
        guard position + 1 < wanted.count else { return 0 }
        return items[wanted[position + 1]]?.byteCount ?? 0
    }

    private final class PayloadProgress {
        private let report: ((Int64, Int64, Double) -> Void)?
        private let approvedBytes: Int64?
        private var total: Int64 = 0
        private var completed: Int64 = 0
        private var tick: UInt64 = 0
        private var lastPayload: UInt64 = 0
        private var sent: Int64 = 0
        private var sampleBytes: Int64 = 0
        private var rate: Double = 0

        init(approvedBytes: Int64?, report: ((Int64, Int64, Double) -> Void)?) {
            self.approvedBytes = approvedBytes
            self.report = report
        }

        func beginPage(wanted: [String], items: [String: MobileAlbumManifest]) {
            guard let report else { return }
            completed += sent
            total = wanted.reduce(0) { $0 + (items[$1]?.byteCount ?? 0) }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastPayload > 1_500_000_000 { rate = 0 }
            tick = now
            sent = 0
            sampleBytes = 0
            if total > 0 { report(completed, approvedBytes ?? completed + total, rate) }
        }

        func record(_ count: Int) {
            guard let report else { return }
            sent += Int64(count)
            let now = DispatchTime.now().uptimeNanoseconds
            lastPayload = now
            let duration = now - tick
            guard duration >= 350_000_000 || sent == total else { return }
            if duration >= 100_000_000 {
                let sample = Double(sent - sampleBytes) * 1_000_000_000 / Double(duration)
                rate = rate == 0 ? sample : rate * 0.72 + sample * 0.28
            }
            tick = now
            sampleBytes = sent
            report(completed + sent, approvedBytes ?? completed + total, rate)
        }
    }

    struct PageWindow {
        private static let byteLimit: Int64 = 64 * 1024 * 1024
        private static let itemLimit = 32
        private var items = 0
        private var bytes: Int64 = 0

        mutating func checkpoint(_ completed: Int64, next: Int64) -> Bool {
            bytes += completed
            items += 1
            guard next > 0, items >= Self.itemLimit || bytes > Self.byteLimit - next else { return false }
            items = 0
            bytes = 0
            return true
        }
    }

    private static func enabled(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func transmit(_ input: FileHandle, resource: PhotoSyncLibrary.Resource,
                                 channel: Channel, payload: PayloadProgress) async throws {
        defer { try? input.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while bytes < resource.bytes {
            try Task.checkCancellation()
            let expected = Int(min(Int64(AppleSyncTransport.frameLimit), resource.bytes - bytes))
            guard let next = try input.read(upToCount: expected), !next.isEmpty, next.count <= expected
                  else { throw MediaError193.changed }
            hash.update(data: next)
            try await channel.send(4, next)
            bytes += Int64(next.count)
            payload.record(next.count)
        }
        let remainder = try input.read(upToCount: 1)
        guard remainder?.isEmpty ?? true, AppleSyncTransport.hex(Data(hash.finalize())) == resource.sha256
              else { throw MediaError193.changed }
    }

    private static func read(_ output: FileHandle, resource: PhotoSyncLibrary.Resource,
                                 channel: Channel, payload: PayloadProgress) async throws {
        defer { try? output.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while bytes < resource.bytes {
            let frame = try await channel.receiveFrame()
            guard frame.kind == 4, !frame.data.isEmpty, Int64(frame.data.count) <= resource.bytes - bytes
                  else { throw MediaError193.malformed }
            try output.write(contentsOf: frame.data)
            hash.update(data: frame.data)
            bytes += Int64(frame.data.count)
            payload.record(frame.data.count)
        }
        guard AppleSyncTransport.hex(Data(hash.finalize())) == resource.sha256 else {
            throw MediaError193.verification
        }
        try output.synchronize()
    }

    static func withWaiting<T>(_ channel: Channel, operation: () async throws -> T) async throws -> T {
        let timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                do { try await channel.sendWaiting() }
                catch { return }
            }
        }
        do {
            let result = try await operation()
            timer.cancel()
            await timer.value
            return result
        } catch {
            timer.cancel()
            await timer.value
            throw error
        }
    }

    private static func expect(_ channel: Channel, kind: UInt8, operation: String, page: String? = nil,
                               item: String? = nil) async throws -> [String: Any] {
        let packet = try await channel.receiveObject(kind)
        guard packet["op"] as? String == operation,
              page == nil || packet["batch"] as? String == page,
              item == nil || packet["gid"] as? String == item else { throw MediaError193.changed }
        return packet
    }

    private static func packetFor(_ operation: String, page: String, item: String? = nil,
                                  fields: [String: Any] = [:]) -> [String: Any] {
        var packet = fields
        packet["op"] = operation
        packet["batch"] = page
        if let item = item { packet["gid"] = item }
        return packet
    }

    private static func verify(_ page: MobileAlbumManifest.Page, count: Int, seen: inout Set<String>,
                               pages: inout Set<String>) throws {
        try page.validate()
        guard !page.assets.isEmpty, pages.insert(page.id).inserted, page.assets.count <= count - seen.count
              else { throw MediaError193.malformed }
        for item in page.assets where !seen.insert(item.id).inserted { throw MediaError193.changed }
    }

    private static func account(_ asset: MobileAlbumManifest, bytes: inout Int64) throws {
        for resource in asset.resources {
            guard resource.bytes <= PhotoSyncLibrary.maximumAssetBytes - bytes else { throw MediaError193.tooLarge }
            bytes += resource.bytes
        }
    }

    private static func requested(_ untyped: Any?, items: [String: MobileAlbumManifest]) throws -> [String] {
        guard let ids = untyped as? [String], ids.count <= items.count,
              Set(ids).count == ids.count, ids.allSatisfy({ items[$0] != nil })
              else { throw MediaError193.malformed }
        return ids
    }
}

extension MobileAlbumTransfer.Source {
    var originalBytes: Int64? { nil }
}
