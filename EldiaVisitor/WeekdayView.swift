import SwiftUI
import Charts

/// 曜日別。iPad は2店舗を左右に並べて比較、iPhone は店舗で絞り込み。
struct WeekdayView: View {
    @Environment(LogStore.self) private var logs
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var period: Period = .month
    @State private var storeFilter: StoreID?
    @State private var stats: Stats?
    @State private var loading = false
    @State private var error: String?

    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("期間", selection: $period) {
                    ForEach([Period.month, .quarter, .year]) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: wide ? 380 : .infinity)

                if !wide { StoreFilterBar(selection: $storeFilter) }
                if let error { ErrorBanner(text: error) }

                if let stats {
                    WeekdaySections(columns: makeColumns(stats, wide: wide, filter: storeFilter))
                } else if loading {
                    ProgressView().padding(40)
                }

                CSVButton(period: period, store: wide ? nil : storeFilter)
                    .controlSize(.large)
            }
            .padding(.horizontal, wide ? 20 : 16)
            .padding(.bottom, 28)
        }
        .background(Palette.ground)
        .navigationTitle(wide ? "曜日別 店舗比較" : "曜日別")
        .task(id: period) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let r = period.range()
        do {
            async let rows = logs.api.stats(from: r.from, to: r.to)
            async let days = logs.api.dayCounts(from: r.from, to: r.to)
            stats = Stats(rows: try await rows, from: r.from, to: r.to, dayCounts: try await days)
            error = nil
        } catch {
            self.error = "集計を取得できませんでした：\(error.localizedDescription)"
        }
    }
}

private let blockLabels = ["0時", "3時", "6時", "9時", "12時", "15時", "18時", "21時"]

struct WeekdaySections: View {
    let columns: [StatColumn]

    var body: some View {
        // 月〜日は常に表示。祝前日・祝日はこの期間にある場合だけ表示
        let types = dayTypes.filter { t in t <= 7 || columns.contains { $0.stats.days(t) > 0 } }
        // 時間帯の濃さは店舗間で同じ目盛りにそろえる
        let blockValues: [[[Double]]] = columns.map { col in
            types.map { d in
                (0..<8).map { b in Double(col.stats.filter { $0.dtype == d && $0.hour / 3 == b }.groups) }
            }
        }
        let blockMax = blockValues.flatMap { $0.flatMap { $0 } }.max() ?? 1

        VStack(spacing: 14) {
            Card(title: "曜日別 組数") {
                Chart {
                    ForEach(columns) { col in
                        ForEach(types, id: \.self) { d in
                            BarMark(x: .value("曜日", dayTypeLabel(d)),
                                    y: .value("組数", col.stats.filter { $0.dtype == d }.groups))
                                .foregroundStyle(by: .value("店舗", col.title))
                                .position(by: .value("店舗", col.title))
                        }
                    }
                }
                .chartForegroundStyleScale(domain: columns.map(\.title), range: columns.map(\.color))
                .chartLegend(columns.count > 1 ? .visible : .hidden)
                .frame(height: 200)
                Note(text: "朝5時で日付を区切って集計（深夜0〜5時は前日扱い）。祝前日＝翌日が祝日の日（連休前の日曜も含む）、祝日＝翌日が平日の祝日。")
                InsightBox(text: Insights.weekdayCount(columns))
            }

            Card(title: "曜日 × 時間帯", subtitle: "組数（3時間ごと）") {
                Columns(columns: columns) { col in
                    let i = columns.firstIndex { $0.id == col.id } ?? 0
                    HeatmapView(rowLabels: types.map(dayTypeLabel),
                                rowColors: types.map(weekdayColor),
                                colLabels: blockLabels,
                                values: blockValues[i],
                                maxValue: max(blockMax, 1),
                                text: { String(Int($0)) },
                                labelWidth: 46)
                }
                InsightBox(text: Insights.weekdayHour(columns))
            }

            Card(title: "曜日 × 客層", subtitle: "組数の構成比") {
                Columns(columns: columns) { col in WeekdaySegmentChart(stats: col.stats, types: types) }
                SegmentLegend()
                InsightBox(text: Insights.weekdaySegment(columns))
            }

            Card(title: "曜日 × 年齢層", subtitle: "人数の構成比（%）") {
                Columns(columns: columns) { col in
                    let values: [[Double]] = types.map { d in
                        let s = col.stats.filter { $0.dtype == d }
                        return AgeBand.allCases.map { a in s.people > 0 ? Double(s.people(a)) / Double(s.people) * 100 : 0 }
                    }
                    HeatmapView(rowLabels: types.map(dayTypeLabel),
                                rowColors: types.map(weekdayColor),
                                colLabels: AgeBand.allCases.map(\.tiny),
                                values: values,
                                maxValue: 40,
                                text: { String(format: "%.0f%%", $0) },
                                labelWidth: 46)
                }
                InsightBox(text: Insights.weekdayAge(columns))
            }

            Card(title: "詳細") {
                Columns(columns: columns) { col in WeekdayTable(stats: col.stats, showTop: columns.count == 1, types: types) }
                Note(text: "1日平均＝組数÷その期間（今日まで）の日数／平均＝1組あたりの人数")
            }
        }
    }
}

struct WeekdaySegmentChart: View {
    let stats: Stats
    let types: [Int]
    var body: some View {
        Chart {
            ForEach(types, id: \.self) { d in
                let ds = stats.filter { $0.dtype == d }
                let total = ds.groups
                ForEach(Segment.allCases) { seg in
                    BarMark(x: .value("割合", total > 0 ? Double(ds.groups(seg)) / Double(total) * 100 : 0),
                            y: .value("曜日", dayTypeLabel(d)))
                        .foregroundStyle(by: .value("客層", seg.label))
                }
            }
        }
        .chartForegroundStyleScale(domain: Segment.allCases.map(\.label), range: Segment.allCases.map(\.color))
        .chartXScale(domain: 0.0...100.0)
        .chartXAxis {
            AxisMarks(values: [0.0, 50.0, 100.0]) { v in
                AxisGridLine()
                AxisValueLabel { if let p = v.as(Double.self) { Text("\(Int(p))%") } }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 230)
    }
}

struct SegmentLegend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Segment.allCases) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 10, height: 10)
                    Text(s.label).font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
    }
}

struct WeekdayTable: View {
    let stats: Stats
    let showTop: Bool
    let types: [Int]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 9) {
            GridRow {
                Text("曜日").gridColumnAlignment(.leading)
                Text("組数"); Text("人数"); Text("1日平均"); Text("平均")
                if showTop { Text("一般以外で最多").gridColumnAlignment(.leading) }
            }
            .font(.caption2.weight(.bold)).foregroundStyle(Palette.sub)
            Divider()
            ForEach(types, id: \.self) { d in
                let s = stats.filter { $0.dtype == d }
                let days = stats.days(d)
                GridRow {
                    Text(dayTypeLabel(d)).font(.footnote.weight(.heavy)).foregroundStyle(weekdayColor(d))
                    Text("\(s.groups)")
                    Text("\(s.people)")
                    Text(days > 0 ? String(format: "%.1f", Double(s.groups) / Double(days)) : "—")
                    Text(s.groups > 0 ? String(format: "%.2f", s.avgParty) : "—")
                    if showTop {
                        Text(s.topNonGeneral).font(.caption).foregroundStyle(Palette.ink2)
                    }
                }
                .font(.footnote).monospacedDigit()
            }
        }
    }
}
