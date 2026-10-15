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

    /// 期間（営業日＝朝5時区切りで区切る）
    func range(now: Date = Date()) -> (from: Date, to: Date) {
        let cal = JST.calendar
        let h = AppConfig.businessDayOffset
        let b = now.addingTimeInterval(-h)
        func shift(_ i: DateInterval) -> (from: Date, to: Date) { (i.start.addingTimeInterval(h), i.end.addingTimeInterval(h)) }
        switch self {
        case .today:
            let s = cal.startOfDay(for: b)
            return shift(DateInterval(start: s, end: cal.date(byAdding: .day, value: 1, to: s)!))
        case .week:
            return shift(cal.dateInterval(of: .weekOfYear, for: b)!)
        case .month:
            return shift(cal.dateInterval(of: .month, for: b)!)
        case .quarter:
            let i = cal.dateInterval(of: .month, for: b)!
            return shift(DateInterval(start: cal.date(byAdding: .month, value: -2, to: i.start)!, end: i.end))
        case .year:
            return shift(cal.dateInterval(of: .year, for: b)!)
        }
    }
}

// MARK: - 集計

extension Segment {
    /// 0〜6 の並び順（集計の配列の位置に使う）
    var index: Int {
        switch self {
        case .general: return 0
        case .deli: return 1
        case .age_gap: return 2
        case .girls: return 3
        case .family: return 4
        case .inbound: return 5
        case .business: return 6
        }
    }
}

/// 割合（%）。分母が0なら0
func percentValue(_ part: Int, _ whole: Int) -> Double {
    whole > 0 ? Double(part) / Double(whole) * 100 : 0
}

/// サーバー関数 visitor_stats の行をまとめたもの。
/// 合計・男女×年齢層・時間帯・客層・組の人数は、作るときに1回の走査でまとめて数えておく
/// （画面やコメントを作るたびに行を何度も絞り込み直さないため）。
struct Stats {
    let rows: [StatRow]
    let from: Date
    let to: Date
    var dayCounts: [Int: Int] = [:]

    /// 組数
    let groups: Int
    /// 男性 6 + 女性 6 の人数（男10代…男60代〜、女10代…女60代〜）
    private let ageGender: [Int]
    /// 時（0〜23時）ごとの組数
    let hourlyGroups: [Int]
    /// 客層ごとの組数（Segment.index の順）
    private let segmentGroups: [Int]
    /// 組の人数ごとの組数（1名・2名・3名以上）
    let partyGroups: [Int]

    init(rows: [StatRow], from: Date, to: Date, dayCounts: [Int: Int] = [:]) {
        self.rows = rows
        self.from = from
        self.to = to
        self.dayCounts = dayCounts
        var groups = 0
        var ageGender = [Int](repeating: 0, count: 12)
        var hourly = [Int](repeating: 0, count: 24)
        var segments = [Int](repeating: 0, count: Segment.allCases.count)
        var party = [0, 0, 0]
        for r in rows {
            groups += r.groups
            for a in AgeBand.allCases {
                ageGender[a.index] += r.count(.m, a)
                ageGender[6 + a.index] += r.count(.f, a)
            }
            if (0..<24).contains(r.hour) { hourly[r.hour] += r.groups }
            segments[r.segment.index] += r.groups
            switch r.party {
            case 1: party[0] += r.groups
            case 2: party[1] += r.groups
            case 3...: party[2] += r.groups
            default: break
            }
        }
        self.groups = groups
        self.ageGender = ageGender
        self.hourlyGroups = hourly
        self.segmentGroups = segments
        self.partyGroups = party
    }

    // MARK: 絞り込み

    func filter(_ keep: (StatRow) -> Bool) -> Stats { Stats(rows: rows.filter(keep), from: from, to: to, dayCounts: dayCounts) }
    func only(_ store: StoreID?) -> Stats { store.map { s in filter { $0.store == s } } ?? self }

    /// 1回の走査で、キーごとの Stats に分ける（客層別・曜日別などをまとめて作る）
    func split<Key: Hashable>(by key: (StatRow) -> Key) -> [Key: Stats] {
        var buckets: [Key: [StatRow]] = [:]
        for r in rows { buckets[key(r), default: []].append(r) }
        return buckets.mapValues { Stats(rows: $0, from: from, to: to, dayCounts: dayCounts) }
    }

    /// 行のない Stats（split で該当がなかったとき用）
    var empty: Stats { Stats(rows: [], from: from, to: to, dayCounts: dayCounts) }

    // MARK: 人数・組数

    var male: Int { ageGender[0..<6].reduce(0, +) }
    var female: Int { ageGender[6..<12].reduce(0, +) }
    var people: Int { male + female }
    func people(_ g: Gender, _ a: AgeBand) -> Int { ageGender[(g == .m ? 0 : 6) + a.index] }
    func people(_ a: AgeBand) -> Int { people(.m, a) + people(.f, a) }
    func groups(_ segment: Segment) -> Int { segmentGroups[segment.index] }

    var avgParty: Double { groups == 0 ? 0 : Double(people) / Double(groups) }

    /// 年齢層ごとの人数の割合（%）
    var ageShares: [Double] { AgeBand.allCases.map { percentValue(people($0), people) } }

    /// 営業日の種類（1〜7＝月〜日、8＝祝前日、9＝祝日）ごとの、この期間（今日まで）の日数
    func days(_ type: Int) -> Int { dayCounts[type] ?? 0 }

    /// 営業日の種類ごと × 3時間ごと（0〜8ブロック）の組数を1回の走査で数える
    func blockGroups() -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for r in rows {
            let b = r.hour / 3
            guard (0..<8).contains(b) else { continue }
            out[r.dtype, default: [Int](repeating: 0, count: 8)][b] += r.groups
        }
        return out
    }

    // MARK: 文字列にした指標

    var peakHour: String {
        guard groups > 0 else { return "—" }
        let counts = hourlyGroups
        let h = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        return "\(h)時台"
    }

    var topNonGeneral: String {
        let segs = Segment.nonGeneral
        let counts = segs.map { groups($0) }
        guard let i = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[i] > 0 else { return "—" }
        return segs[i].label
    }

    /// 男女比（例「48 : 52」）。人数が0なら「—」
    func genderRatio(separator: String) -> String {
        guard people > 0 else { return "—" }
        let m = Int(percentValue(male, people).rounded()), f = Int(percentValue(female, people).rounded())
        return "\(m)\(separator)\(f)"
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

extension Dictionary where Value == Stats {
    /// キーに該当がなければ行のない Stats を返す
    func stats(_ key: Key, orEmpty base: Stats) -> Stats { self[key] ?? base.empty }
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
        let last = to.addingTimeInterval(-AppConfig.businessDayOffset - 1)
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
