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
            if samples.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Motas records pool reserve on every refresh."))
            } else {
                Chart {
                    ForEach(series) { line in
                        ForEach(line.samples, id: \.self) { sample in
                            LineMark(x: .value("Time", sample.at), y: .value("Reserve", sample.reserve))
                                .foregroundStyle(by: .value("Pool", line.title))
                                .interpolationMethod(.stepEnd)
                        }
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Design.percent(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartXScale(domain: start...end)
                .chartForegroundStyleScale(domain: series.map(\.title),
                                           range: series.map { $0.provider.map(Design.accent) ?? .secondary })
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 320)
        .environment(\.locale, Design.locale)
    }

    private var end: Date { model.now }
    private var start: Date { end.addingTimeInterval(-7 * 86_400) }

    private var samples: [PoolSample] {
        model.history.filter { $0.at >= start }
    }

    private struct Series: Identifiable {
        var id: String
        var title: String
        var provider: Provider?
        var samples: [PoolSample]
    }

    /// One line per pool id; the saved snapshot's title, else the id.
    private var series: [Series] {
        Dictionary(grouping: samples, by: \.pool)
            .map { id, samples in
                return Series(id: id, title: model.savedPoolTitles[id] ?? id, provider: Design.family(for: id),
                              samples: samples.sorted { $0.at < $1.at })
            }
            .sorted { $0.title < $1.title }
    }
}
