import SwiftUI
import Charts

// MARK: - 分析・曜日別で共通の画面の枠

/// 期間の切り替え・店舗の絞り込み・読み込み・エラー表示をまとめた枠。
/// iPad は2店舗を左右に並べて比較、iPhone は店舗で絞り込む。
struct StatsScreen<Sections: View, Footer: View>: View {
    let periods: [Period]
    let pickerWidth: CGFloat
    let title: (_ wide: Bool) -> String
    /// 曜日別のように「期間内の日数」も必要なときは true
    var needsDayCounts: Bool = false
    @ViewBuilder let sections: ([StatColumn]) -> Sections
    @ViewBuilder let footer: (_ period: Period, _ store: StoreID?) -> Footer

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
                    ForEach(periods) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: wide ? pickerWidth : .infinity)

                if !wide { StoreFilterBar(selection: $storeFilter) }
                if let error { ErrorBanner(text: error) }

                if let stats {
                    sections(makeColumns(stats, wide: wide, filter: storeFilter))
                } else if loading {
                    ProgressView().padding(40)
                }

                footer(period, wide ? nil : storeFilter)
            }
            .padding(.horizontal, wide ? 20 : 16)
            .padding(.bottom, 28)
        }
        .background(Palette.ground)
        .navigationTitle(title(wide))
        .task(id: period) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let r = period.range()
        do {
            if needsDayCounts {
                async let rows = logs.api.stats(from: r.from, to: r.to)
                async let days = logs.api.dayCounts(from: r.from, to: r.to)
                stats = Stats(rows: try await rows, from: r.from, to: r.to, dayCounts: try await days)
            } else {
                let rows = try await logs.api.stats(from: r.from, to: r.to)
                stats = Stats(rows: rows, from: r.from, to: r.to)
            }
            error = nil
        } catch {
            self.error = "集計を取得できませんでした：\(error.localizedDescription)"
        }
    }
}

// MARK: - 分析画面

/// 分析。iPad は MODERN / LUXURY を左右に並べて比較、iPhone は店舗で絞り込み。
struct AnalysisView: View {
    var body: some View {
        StatsScreen(periods: [.today, .week, .month, .year],
                    pickerWidth: 440,
                    title: { $0 ? "店舗比較" : "分析" },
                    sections: { AnalysisSections(columns: $0) },
                    footer: { period, store in
                        HStack(spacing: 10) {
                            CSVButton(period: period, store: store)
                            NavigationLink {
                                WeekdayView()
                            } label: {
                                Label("曜日別を見る", systemImage: "calendar").frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .glassButton()
                        }
                        .controlSize(.large)
                    })
    }
}

struct StoreFilterBar: View {
    @Binding var selection: StoreID?
    var body: some View {
        Picker("店舗", selection: $selection) {
            Text("両店舗").tag(StoreID?.none)
            ForEach(StoreID.allCases) { s in Text(s.label).tag(StoreID?.some(s)) }
        }
        .pickerStyle(.segmented)
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.sunday)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// CSV書き出し（期間内の記録を1組1行で）
struct CSVButton: View {
    let period: Period
    let store: StoreID?
    @Environment(LogStore.self) private var logs
    @State private var busy = false
    @State private var file: ExportFile?
    @State private var error: String?

    var body: some View {
        Group {
            if let file {
                // 共有シートは ShareLink に任せる（iPad・Mac でも安全に開ける）
                ShareLink(item: file.url) {
                    Label("CSVを共有", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .prominentGlassButton()
                .tint(Palette.teal)
            } else {
                Button {
                    Task { await run() }
                } label: {
                    Group {
                        if busy { ProgressView() } else { Label("CSV書き出し", systemImage: "doc.text") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .glassButton()
                .disabled(busy)
            }
        }
        .onChange(of: period) { _, _ in file = nil }
        .onChange(of: store) { _, _ in file = nil }
        .alert("書き出せませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        let r = period.range()
        do {
            var rows = try await logs.api.logs(from: r.from, to: r.to)
            if let store { rows = rows.filter { $0.store == store } }
            file = ExportFile(url: try CSVExport.make(rows, from: r.from, to: r.to))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 分析の各セクション

struct AnalysisSections: View {
    let columns: [StatColumn]

    var body: some View {
        VStack(spacing: 14) {
            KPICard(columns: columns)

            Card(title: "年齢層 × 性別", subtitle: "人数") {
                Columns(columns: columns) { AgeGenderChart(stats: $0.stats) }
                InsightBox(text: Insights.ageGender(columns))
            }

            Card(title: "客層別 組数", subtitle: "組数に占める割合") {
                Columns(columns: columns) { SegmentBars(stats: $0.stats) }
                InsightBox(text: Insights.segment(columns))
                Note(text: "1組につき客層1つで集計。デリヘルは女性1名を1組として数えます。")
            }

            Card(title: "客層 × 年齢層", subtitle: "客層ごとの人数構成（%）") {
                Columns(columns: columns) { SegmentAgeHeatmap(stats: $0.stats) }
                InsightBox(text: Insights.segmentAge(columns))
            }

            Card(title: "客層別の詳細") {
                Columns(columns: columns) { SegmentDetailTable(stats: $0.stats) }
                Note(text: "平均＝1組あたりの人数")
            }

            Card(title: "時間帯別 来店組数") {
                Columns(columns: columns) { HourChart(stats: $0.stats, color: $0.color) }
                InsightBox(text: Insights.hours(columns))
            }

            Card(title: "組の人数") {
                Columns(columns: columns) { PartyBar(stats: $0.stats) }
                InsightBox(text: Insights.party(columns))
            }

            Card(title: "詳細（人数）") {
                Columns(columns: columns) { AgeTable(stats: $0.stats) }
            }
        }
    }
}

struct KPICard: View {
    let columns: [StatColumn]

    private struct Item: Identifiable {
        let id: String
        let values: [String]
    }

    private var items: [Item] {
        func each(_ f: (Stats) -> String) -> [String] { columns.map { f($0.stats) } }
        return [
            Item(id: "来店組数", values: each { "\($0.groups)組" }),
            Item(id: "来店人数", values: each { "\($0.people)名" }),
            Item(id: "平均人数", values: each { String(format: "%.2f名/組", $0.avgParty) }),
            Item(id: "男女比（男:女）", values: each { $0.genderRatio(separator: " : ") }),
            Item(id: "1名組の割合", values: each { pct($0.partyGroups[0], $0.groups) }),
            Item(id: "一般以外の割合", values: each { pct($0.groups - $0.groups(.general), $0.groups) }),
            Item(id: "一般以外で最多", values: each { $0.topNonGeneral }),
            Item(id: "ピーク時間帯", values: each { $0.peakHour })
        ]
    }

    var body: some View {
        Card(title: "概要") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if columns.count > 1 {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(columns) { c in
                            Text(c.title).font(.subheadline.weight(.heavy)).foregroundStyle(c.color)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    Divider()
                }
                ForEach(items) { item in
                    GridRow {
                        Text(item.id).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink2)
                        ForEach(item.values.indices, id: \.self) { i in
                            Text(item.values[i])
                                .font(.body.weight(.bold)).monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: columns.count > 1 ? .center : .trailing)
                        }
                    }
                }
            }
            InsightBox(text: Insights.overview(columns))
        }
    }
}

struct AgeGenderChart: View {
    let stats: Stats
    var body: some View {
        Chart {
            ForEach(AgeBand.allCases) { a in
                ForEach(Gender.allCases) { g in
                    let n = stats.people(g, a)
                    BarMark(x: .value("人数", n), y: .value("年齢層", a.short))
                        .foregroundStyle(by: .value("性別", g.label))
                        .position(by: .value("性別", g.label))
                        .annotation(position: .trailing, spacing: 2) {
                            Text("\(n)").font(.system(size: 10)).foregroundStyle(Palette.ink2)
                        }
                }
            }
        }
        .chartForegroundStyleScale(["男性": Gender.m.color, "女性": Gender.f.color])
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 280)
    }
}

struct SegmentBars: View {
    let stats: Stats
    var body: some View {
        let total = stats.groups
        let counts = Segment.allCases.map { stats.groups($0) }
        let maxN = max(counts.max() ?? 0, 1)
        VStack(spacing: 8) {
            ForEach(Segment.allCases.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(Segment.allCases[i].label)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 78, alignment: .leading)
                    ProportionBar(fraction: Double(counts[i]) / Double(maxN), color: Palette.teal, height: 14)
                    Text("\(counts[i])組 \(pct(counts[i], total))")
                        .font(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 82, alignment: .trailing)
                }
            }
        }
    }
}

struct SegmentAgeHeatmap: View {
    let stats: Stats
    var body: some View {
        let bySegment = stats.split(by: \.segment)
        HeatmapView(rowLabels: Segment.allCases.map(\.label),
                    colLabels: AgeBand.allCases.map(\.tiny),
                    values: Segment.allCases.map { (bySegment[$0] ?? stats.empty).ageShares },
                    maxValue: 55,
                    text: { String(format: "%.0f%%", $0) },
                    labelWidth: 74)
    }
}

struct SegmentDetailTable: View {
    let stats: Stats
    var body: some View {
        let bySegment = stats.split(by: \.segment)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 9) {
            GridRow {
                Text("客層")
                Text("組数").gridColumnAlignment(.trailing)
                Text("平均").gridColumnAlignment(.trailing)
                Text("男:女").gridColumnAlignment(.trailing)
                Text("主な層")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Palette.sub)
            Divider()
            ForEach(Segment.allCases) { seg in
                let s = bySegment[seg] ?? stats.empty
                GridRow {
                    Text(seg.label).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(s.groups)").monospacedDigit()
                    Text(s.groups > 0 ? String(format: "%.1f", s.avgParty) : "—").monospacedDigit()
                    Text(s.genderRatio(separator: ":")).monospacedDigit()
                    Text(s.mainLayer).font(.caption).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.footnote)
            }
        }
    }
}

struct HourChart: View {
    let stats: Stats
    let color: Color
    var body: some View {
        let counts = stats.hourlyGroups
        let peak = counts.indices.max { counts[$0] < counts[$1] } ?? -1
        Chart {
            ForEach(0..<24, id: \.self) { h in
                BarMark(x: .value("時", Double(h)), y: .value("組数", counts[h]), width: .fixed(8))
                    .foregroundStyle(h == peak && counts[h] > 0 ? Palette.teal : Palette.teal.opacity(0.35))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0.0, 6.0, 12.0, 18.0]) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))時") } }
            }
        }
        .frame(height: 150)
    }
}

struct PartyBar: View {
    let stats: Stats

    private static let kinds: [(label: String, color: Color)] = [
        ("1名", Color(hex: 0x4A4A50)),
        ("2名", Color(hex: 0x2E7D6B)),
        ("3名以上", Color(hex: 0x9A9AA0))
    ]

    var body: some View {
        let total = max(stats.groups, 1)
        let counts = stats.partyGroups
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Self.kinds.indices, id: \.self) { i in
                        let f = Double(counts[i]) / Double(total)
                        Text(f >= 0.18 ? "\(Self.kinds[i].label) \(pct(counts[i], total))" : "")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(width: max(geo.size.width * f - 2, 0), height: 26)
                            .background(Self.kinds[i].color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 26)
            Text(Self.kinds.indices.map { "\(Self.kinds[$0].label) \(pct(counts[$0], stats.groups))" }.joined(separator: "　"))
                .font(.caption).foregroundStyle(Palette.ink2)
        }
    }
}

struct AgeTable: View {
    let stats: Stats
    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("年齢層").gridColumnAlignment(.leading)
                Text("男性"); Text("女性"); Text("計"); Text("構成比")
            }
            .font(.caption2.weight(.bold)).foregroundStyle(Palette.sub)
            Divider()
            ForEach(AgeBand.allCases) { a in
                GridRow {
                    Text(a.label)
                    Text("\(stats.people(.m, a))")
                    Text("\(stats.people(.f, a))")
                    Text("\(stats.people(a))")
                    Text(pct(stats.people(a), stats.people, digits: 1))
                }
                .font(.footnote).monospacedDigit()
            }
            Divider()
            GridRow {
                Text("合計")
                Text("\(stats.male)")
                Text("\(stats.female)")
                Text("\(stats.people)")
                Text(stats.people > 0 ? "100%" : "—")
            }
            .font(.footnote.weight(.bold)).monospacedDigit()
        }
    }
}
