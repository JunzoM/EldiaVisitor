import SwiftUI

// MARK: - 期間

enum Period: String, CaseIterable, Identifiable {
    case today, week, month, quarter, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "今週"
        case .month: return "今月"
        case .quarter: return "過去3か月"
        case .year: return "年間"
        }
    }

    func range(now: Date = Date()) -> (from: Date, to: Date) {
        let cal = JST.calendar
        switch self {
        case .today:
            let s = cal.startOfDay(for: now)
            return (s, cal.date(byAdding: .day, value: 1, to: s)!)
        case .week:
            let i = cal.dateInterval(of: .weekOfYear, for: now)!
            return (i.start, i.end)
        case .month:
            let i = cal.dateInterval(of: .month, for: now)!
            return (i.start, i.end)
        case .quarter:
            let i = cal.dateInterval(of: .month, for: now)!
            return (cal.date(byAdding: .month, value: -2, to: i.start)!, i.end)
        case .year:
            let i = cal.dateInterval(of: .year, for: now)!
            return (i.start, i.end)
        }
    }
}

// MARK: - 集計

struct Stats {
    let rows: [StatRow]
    let from: Date
    let to: Date

    func filter(_ keep: (StatRow) -> Bool) -> Stats { Stats(rows: rows.filter(keep), from: from, to: to) }
    func only(_ store: StoreID?) -> Stats { store.map { s in filter { $0.store == s } } ?? self }

    var groups: Int { rows.reduce(0) { $0 + $1.groups } }
    var people: Int { rows.reduce(0) { $0 + $1.people } }
    var male: Int { rows.reduce(0) { $0 + $1.male } }
    var female: Int { rows.reduce(0) { $0 + $1.female } }
    func people(_ g: Gender, _ a: AgeBand) -> Int { rows.reduce(0) { $0 + $1.count(g, a) } }
    func people(_ a: AgeBand) -> Int { people(.m, a) + people(.f, a) }

    var avgParty: Double { groups == 0 ? 0 : Double(people) / Double(groups) }

    /// 各曜日（1=月〜7=日）がこの期間（今日まで）に何日あるか
    func dayCount(dow: Int, now: Date = Date()) -> Int {
        let cal = JST.calendar
        var d = cal.startOfDay(for: from)
        let end = min(to, now)
        var n = 0
        while d < end {
            let wd = cal.component(.weekday, from: d) // 1=日
            if (wd + 5) % 7 + 1 == dow { n += 1 }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return n
    }

    // 文字列にした指標
    var peakHour: String {
        guard groups > 0 else { return "—" }
        let counts = (0..<24).map { h in filter { $0.hour == h }.groups }
        let h = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        return "\(h)時台"
    }

    func groups(_ segment: Segment) -> Int { filter { $0.segment == segment }.groups }

    var topNonGeneral: String {
        let segs = Segment.allCases.filter { $0 != .general }
        let counts = segs.map { groups($0) }
        guard let i = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[i] > 0 else { return "—" }
        return segs[i].label
    }

    /// 主な層：例「男50代×女20代」「女20代」「男女30代」
    var mainLayer: String {
        guard people > 0 else { return "—" }
        func best(_ g: Gender) -> (AgeBand, Int) {
            AgeBand.allCases.map { ($0, people(g, $0)) }.max { $0.1 < $1.1 } ?? (.a20, 0)
        }
        let (ma, mc) = best(.m), (fa, fc) = best(.f)
        let mShare = Double(male) / Double(people), fShare = Double(female) / Double(people)
        if mShare >= 0.2 && fShare >= 0.2 && mc > 0 && fc > 0 {
            return ma == fa ? "男女\(ma.short)" : "男\(ma.short)×女\(fa.short)"
        }
        return male >= female ? "男\(ma.short)" : "女\(fa.short)"
    }
}

func pct(_ part: Int, _ whole: Int, digits: Int = 0) -> String {
    guard whole > 0 else { return "—" }
    return String(format: "%.\(digits)f%%", Double(part) / Double(whole) * 100)
}

// MARK: - 表示の列（iPhone は1列、iPad は店舗ごとの2列）

struct StatColumn: Identifiable {
    let id: String
    let title: String
    let color: Color
    let stats: Stats
}

func makeColumns(_ stats: Stats, wide: Bool, filter: StoreID?) -> [StatColumn] {
    if wide {
        return StoreID.allCases.map { StatColumn(id: $0.rawValue, title: $0.label, color: $0.deep, stats: stats.only($0)) }
    }
    if let f = filter {
        return [StatColumn(id: f.rawValue, title: f.label, color: f.deep, stats: stats.only(f))]
    }
    return [StatColumn(id: "both", title: "両店舗", color: Palette.teal, stats: stats)]
}

// MARK: - 部品

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.ink2) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct Columns<Content: View>: View {
    let columns: [StatColumn]
    @ViewBuilder var content: (StatColumn) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(columns) { col in
                VStack(alignment: .leading, spacing: 6) {
                    if columns.count > 1 {
                        Text(col.title).font(.subheadline.weight(.heavy)).foregroundStyle(col.color)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    content(col)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct Note: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Palette.sub)
    }
}

struct ProportionBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(fraction.isFinite ? geo.size.width * min(fraction, 1) : 0, fraction > 0 ? 2 : 0))
        }
        .frame(height: height)
    }
}

/// 濃さで量を表す表
struct HeatmapView: View {
    let rowLabels: [String]
    var rowColors: [Color]? = nil
    let colLabels: [String]
    let values: [[Double]]
    let maxValue: Double
    let text: (Double) -> String
    var labelWidth: CGFloat = 30

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Color.clear.frame(width: labelWidth, height: 1)
                ForEach(colLabels.indices, id: \.self) { c in
                    Text(colLabels[c])
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.sub)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(rowLabels.indices, id: \.self) { r in
                GridRow {
                    Text(rowLabels[r])
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(rowColors?[r] ?? Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: labelWidth, alignment: .leading)
                    ForEach(colLabels.indices, id: \.self) { c in
                        let v = values[r][c]
                        let a = maxValue > 0 ? min(v / maxValue, 1) : 0
                        Text(v > 0 ? text(v) : "–")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(a > 0.45 ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(Palette.teal.opacity(0.06 + a * 0.94), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }
}

// MARK: - CSV

enum CSVExport {
    static func make(_ logs: [VisitorLog], from: Date, to: Date) throws -> URL {
        var lines: [String] = []
        var head = ["日時", "店舗", "客層"]
        for g in Gender.allCases { for a in AgeBand.allCases { head.append(g.short + a.label) } }
        head += ["男性計", "女性計", "合計"]
        lines.append(head.joined(separator: ","))
        for l in logs {
            var row = [JST.csv.string(from: l.visited_at), l.store.label, l.segment.label]
            for g in Gender.allCases { for a in AgeBand.allCases { row.append("\(l.count(g, a))") } }
            row += ["\(l.male)", "\(l.female)", "\(l.total)"]
            lines.append(row.joined(separator: ","))
        }
        let last = JST.calendar.date(byAdding: .second, value: -1, to: to) ?? to
        let name = "来店記録_\(JST.fileDate.string(from: from))-\(JST.fileDate.string(from: last)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // Excel で文字化けしないよう BOM 付き UTF-8
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
