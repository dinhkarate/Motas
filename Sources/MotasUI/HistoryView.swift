import Charts
import MotasCore
import MotasDesign
import SwiftUI

public struct HistoryView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pool reserve — last 7 days").font(.headline)
            if model.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Motas records pool reserve on every refresh."))
            } else {
                Chart(model.history, id: \.self) { sample in
                    LineMark(x: .value("Time", sample.at), y: .value("Reserve", sample.reserve))
                        .foregroundStyle(by: .value("Pool", title(sample.pool)))
                        .interpolationMethod(.stepEnd)
                        .symbol(.circle)
                        .symbolSize(model.history.count < 50 ? 20 : 0)
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Design.percent(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartXScale(domain: Date.now.addingTimeInterval(-7 * 86_400)...Date.now)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 320)
        .environment(\.locale, Design.locale)
    }

    /// The pool's title, else its id (a pool that no longer exists).
    private func title(_ pool: String) -> String { model.pools.first { $0.id == pool }?.title ?? pool }
}
