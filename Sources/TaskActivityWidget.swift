import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NocturneTaskWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NocturneTaskAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(title(context), systemImage: icon(context))
                    .font(.headline)
                Text(summary(context)).font(.subheadline).monospacedDigit()
                progress(context.state)
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(title(context), systemImage: icon(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary(context)).monospacedDigit()
                        progress(context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context))
            } compactTrailing: {
                if let interval = context.state.testInterval {
                    Text(timerInterval: interval, countsDown: true)
                        .monospacedDigit().lineLimit(1).frame(width: 42)
                } else {
                    Text(context.isStale ? "等待" : context.state.percent.map { "\($0)%" } ?? context.state.phase)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
            } minimal: {
                Image(systemName: icon(context))
            }
        }
    }

    @ViewBuilder private func progress(_ state: NocturneTaskAttributes.ContentState) -> some View {
        if let interval = state.testInterval {
            ProgressView(timerInterval: interval, countsDown: false)
        } else if let percent = state.percent {
            ProgressView(value: Double(percent), total: 100)
        }
    }

    private func icon(_ context: ActivityViewContext<NocturneTaskAttributes>) -> String {
        if context.attributes.kind == .test { return "timer" }
        return context.attributes.kind == .sync ? "arrow.left.arrow.right" : "photo.on.rectangle"
    }

    private func title(_ context: ActivityViewContext<NocturneTaskAttributes>) -> String {
        if context.attributes.kind == .test { return "灵动岛测试" }
        return context.attributes.kind == .sync ? "图库同步" : "缩略图准备"
    }

    private func summary(_ context: ActivityViewContext<NocturneTaskAttributes>) -> String {
        if context.attributes.kind == .test { return "20 秒测试" }
        if context.isStale { return "等待任务更新" }
        var values = [context.state.phase]
        if let done = context.state.done, let total = context.state.total { values.append("\(bytes(done))/\(bytes(total))") }
        if let done = context.state.itemsDone, let total = context.state.itemsTotal { values.append("\(done)/\(total) 项") }
        if let rate = context.state.bytesPerSecond { values.append(bytes(rate) + "/s") }
        return values.joined(separator: " · ")
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
