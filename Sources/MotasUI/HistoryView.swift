import Charts
import MotasCore
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
                        .foregroundStyle(by: .value("Provider", sample.provider.displayName))
                        .interpolationMethod(.stepEnd)
                        .symbol(.circle)
                        .symbolSize(model.history.count < 50 ? 20 : 0)
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartXScale(domain: Date.now.addingTimeInterval(-7 * 86_400)...Date.now)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 320)
        .environment(\.locale, Format.locale)
    }
}
