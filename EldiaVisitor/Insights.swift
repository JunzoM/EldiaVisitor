import SwiftUI

/// 各カードの「言葉による分析」。記録の数字から自動で文章を作る（通信や AI は使わない）。
/// iPad（2店舗）は比較の文章、iPhone（1列）はその店舗・両店舗合計の文章になる。
enum Insights {

    // MARK: 共通

    private static func p(_ v: Double) -> String { String(format: "%.0f%%", v) }
    private static func ratio(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func active(_ cols: [StatColumn]) -> [StatColumn] { cols.filter { $0.stats.groups > 0 } }

    /// 2列（店舗比較）のときは「◯◯は」を前に付ける
    private static func subject(_ c: StatColumn, in cols: [StatColumn]) -> String {
        cols.count > 1 ? "\(c.title)は" : ""
    }

    /// 文をつないで句点で終え、記録が少ないときは参考値である旨を添える
    private static func sentences(_ parts: [String], _ cols: [StatColumn]) -> String? {
        guard !parts.isEmpty else { return nil }
        return finish(parts.joined(separator: "。") + "。", cols)
    }

    /// 記録が少ないときは参考値である旨を添える
    private static func finish(_ text: String, _ cols: [StatColumn]) -> String {
        let total = cols.reduce(0) { $0 + $1.stats.groups }
        return total < 30 ? text + "（記録がまだ少ないため参考値）" : text
    }

    // MARK: 概要

    static func overview(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        if cols.count == 2, cs.count == 2 {
            let a = cs[0], b = cs[1]
            let (hi, lo) = a.stats.groups >= b.stats.groups ? (a, b) : (b, a)
            let diff = hi.stats.groups - lo.stats.groups
            var t = diff == 0
                ? "組数は両店舗とも\(hi.stats.groups)組。"
                : "\(hi.title)が\(lo.title)より\(diff)組多い（＋\(p(percentValue(diff, lo.stats.groups)))）。"
            t += "1組平均は\(a.title) \(String(format: "%.2f", a.stats.avgParty))名・\(b.title) \(String(format: "%.2f", b.stats.avgParty))名。"
            if a.stats.peakHour == b.stats.peakHour { t += "ピークは両店舗とも\(a.stats.peakHour)。" }
            return finish(t, cols)
        }
        let s = cs[0].stats
        return finish("\(s.groups)組・\(s.people)名が来店、1組平均\(String(format: "%.2f", s.avgParty))名。ピークは\(s.peakHour)、一般以外で最多は\(s.topNonGeneral)。", cols)
    }

    // MARK: 年齢層 × 性別

    private static func ageGenderOne(_ s: Stats) -> String {
        var best: (Gender, AgeBand, Int) = (.f, .a20, -1)
        for g in Gender.allCases { for a in AgeBand.allCases where s.people(g, a) > best.2 { best = (g, a, s.people(g, a)) } }
        let young = s.people(.a20) + s.people(.a30)
        return "\(best.0.label)\(best.1.short)が最多、20〜30代で全体の\(p(percentValue(young, s.people)))"
    }

    static func ageGender(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        if cols.count == 1 { return finish(ageGenderOne(cs[0].stats) + "。", cols) }
        var parts = cs.map { "\($0.title)は" + ageGenderOne($0.stats) }
        if cs.count == 2 {
            let older = cs.map { percentValue($0.stats.people(.a40) + $0.stats.people(.a50) + $0.stats.people(.a60), $0.stats.people) }
            let hi = older[0] >= older[1] ? 0 : 1
            if abs(older[0] - older[1]) >= 3 {
                parts.append("40代以上の比率は\(cs[hi].title)が高め（\(p(older[hi]))・\(cs[1 - hi].title) \(p(older[1 - hi]))）")
            }
        }
        return sentences(parts, cols)
    }

    // MARK: 客層

    static func segment(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        if cols.count == 2, cs.count == 2 {
            let a = cs[0], b = cs[1]
            var aHigh: [String] = [], bHigh: [String] = []
            for seg in Segment.nonGeneral {
                let pa = percentValue(a.stats.groups(seg), a.stats.groups), pb = percentValue(b.stats.groups(seg), b.stats.groups)
                if pa - pb >= 1.5 { aHigh.append(seg.label) } else if pb - pa >= 1.5 { bHigh.append(seg.label) }
            }
            var parts: [String] = []
            if !aHigh.isEmpty { parts.append("\(a.title)は\(aHigh.joined(separator: "・"))の比率が高め") }
            if !bHigh.isEmpty { parts.append("\(b.title)は\(bHigh.joined(separator: "・"))が多め") }
            return finish(parts.isEmpty ? "客層の構成は両店舗でほぼ同じ。" : parts.joined(separator: "、") + "。", cols)
        }
        let s = cs[0].stats
        let nonGeneral = s.groups - s.groups(.general)
        let top = Segment.nonGeneral.max { s.groups($0) < s.groups($1) }
        var t = "一般以外の組は全体の\(p(percentValue(nonGeneral, s.groups)))。"
        if let top, s.groups(top) > 0 { t += "一般以外で最多は\(top.label)（\(p(percentValue(s.groups(top), s.groups)))）。" }
        return finish(t, cols)
    }

    // MARK: 客層 × 年齢層

    private static func segmentAgeOne(_ s: Stats) -> String? {
        let segs = Segment.nonGeneral
            .filter { s.groups($0) >= 3 }
            .sorted { s.groups($0) > s.groups($1) }
            .prefix(3)
        guard !segs.isEmpty else { return nil }
        let bySegment = s.split(by: \.segment)
        return segs.map { seg in "\(seg.label)は\((bySegment[seg] ?? s.empty).mainLayer)" }.joined(separator: "、")
    }

    static func segmentAge(_ cols: [StatColumn]) -> String? {
        let parts = cols.compactMap { c in segmentAgeOne(c.stats).map { cols.count > 1 ? "\(c.title)：\($0)" : $0 } }
        guard !parts.isEmpty else { return nil }
        return finish(parts.joined(separator: "／") + "が中心。", cols)
    }

    // MARK: 時間帯

    static func hours(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let info = cs.map { c -> (title: String, peak: Int, peakCount: Int, low: Int) in
            let counts = c.stats.hourlyGroups
            let peak = counts.indices.max { counts[$0] < counts[$1] } ?? 0
            let low = counts.indices.min { counts[$0] < counts[$1] } ?? 0
            return (c.title, peak, counts[peak], low)
        }
        if info.count == 2, info[0].peak == info[1].peak {
            return finish("両店舗とも\(info[0].peak)時台がピーク（\(info[0].title) \(info[0].peakCount)組・\(info[1].title) \(info[1].peakCount)組）。", cols)
        }
        let parts = info.map { i in (cols.count > 1 ? "\(i.title)は" : "") + "ピークが\(i.peak)時台（\(i.peakCount)組）、最も少ないのは\(i.low)時台" }
        return sentences(parts, cols)
    }

    // MARK: 組の人数

    static func party(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let parts = cs.map { c -> String in
            let s = c.stats
            let shares = s.partyGroups.map { percentValue($0, s.groups) }
            return subject(c, in: cols) + "1名組\(p(shares[0]))・2名組\(p(shares[1]))・3名以上\(p(shares[2]))"
        }
        return sentences(parts, cols)
    }

    // MARK: 曜日別

    private static func dayName(_ d: Int) -> String { d <= 7 ? weekdayLabels[d - 1] + "曜" : dayTypeLabel(d) }

    static func weekdayCount(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let info = cs.map { c -> (title: String, best: Int, ratio: Double) in
            let byType = c.stats.split(by: \.dtype)
            // 1日あたりの組数（その期間に日がない種類は除く）
            var per: [Int: Double] = [:]
            for t in dayTypes where c.stats.days(t) > 0 {
                per[t] = Double(byType[t]?.groups ?? 0) / Double(c.stats.days(t))
            }
            let best = per.max { $0.value < $1.value }?.key ?? 6
            let weekdays = (1...5).compactMap { per[$0] }
            let weekdayAvg = weekdays.isEmpty ? 0 : weekdays.reduce(0, +) / Double(weekdays.count)
            return (c.title, best, weekdayAvg > 0 ? (per[best] ?? 0) / weekdayAvg : 0)
        }
        if info.count == 2, info[0].best == info[1].best {
            return finish("両店舗とも\(dayName(info[0].best))が最多（1日あたり平日平均の\(info[0].title) \(ratio(info[0].ratio))倍・\(info[1].title) \(ratio(info[1].ratio))倍）。", cols)
        }
        let parts = info.map { i in (cols.count > 1 ? "\(i.title)は" : "") + "\(dayName(i.best))が最多（1日あたり平日平均の\(ratio(i.ratio))倍）" }
        return sentences(parts, cols)
    }

    static func weekdayHour(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let parts = cs.map { c -> String in
            let blocks = c.stats.blockGroups()
            var best = (1, 0, -1)
            for d in dayTypes { for b in 0..<8 {
                let v = blocks[d]?[b] ?? 0
                if v > best.2 { best = (d, b, v) }
            } }
            return subject(c, in: cols) + "\(dayName(best.0))の\(best.1 * 3)〜\(best.1 * 3 + 3)時が最も混雑（\(best.2)組）"
        }
        return sentences(parts, cols)
    }

    static func weekdaySegment(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let parts = cs.compactMap { c -> String? in
            let halves = c.stats.split { $0.dtype >= 6 }
            let wkEnd = halves[true] ?? c.stats.empty, wkDay = halves[false] ?? c.stats.empty
            guard wkEnd.groups > 0, wkDay.groups > 0 else { return nil }
            var up: [String] = [], down: [String] = []
            for seg in Segment.nonGeneral {
                let e = percentValue(wkEnd.groups(seg), wkEnd.groups), d = percentValue(wkDay.groups(seg), wkDay.groups)
                if e - d >= 2 { up.append(seg.label) } else if d - e >= 2 { down.append(seg.label) }
            }
            var t: [String] = []
            if !up.isEmpty { t.append("土日・祝日は\(up.joined(separator: "・"))が増え") }
            if !down.isEmpty { t.append("平日は\(down.joined(separator: "・"))の比率が高い") }
            let body = t.isEmpty ? "平日と土日で客層の差は小さい" : t.joined(separator: "、")
            return subject(c, in: cols) + body
        }
        return sentences(parts, cols)
    }

    static func weekdayAge(_ cols: [StatColumn]) -> String? {
        let cs = active(cols)
        guard !cs.isEmpty else { return nil }
        let parts = cs.compactMap { c -> String? in
            let late = c.stats.filter { [5, 6, 8].contains($0.dtype) }, early = c.stats.filter { $0.dtype <= 4 }
            guard late.people > 0, early.people > 0 else { return nil }
            let l20 = percentValue(late.people(.a20), late.people), e20 = percentValue(early.people(.a20), early.people)
            let e3040 = percentValue(early.people(.a30) + early.people(.a40), early.people)
            return subject(c, in: cols) + "金・土・祝前日は20代が\(p(l20))（月〜木は\(p(e20))）、月〜木は30〜40代が\(p(e3040))"
        }
        return sentences(parts, cols)
    }
}

/// カードの下に出す、言葉による分析の枠
struct InsightBox: View {
    let text: String?
    var body: some View {
        if let text {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.teal)
                    .padding(.top, 2)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
