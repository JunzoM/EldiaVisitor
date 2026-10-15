import Foundation
import SwiftUI
import Testing
@testable import EldiaVisitor

// MARK: - テスト用のデータ

/// 何度実行しても同じ並びになる乱数（テストの結果を毎回同じにする）
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func row(_ store: StoreID = .modern, _ segment: Segment = .general,
                 dtype: Int = 1, hour: Int = 21, groups: Int = 1,
                 m: [AgeBand: Int] = [:], f: [AgeBand: Int] = [:]) -> StatRow {
    let total = m.values.reduce(0, +) + f.values.reduce(0, +)
    return StatRow(store: store, segment: segment, dow: min(dtype, 7), dtype: dtype, hour: hour,
                   party: min(max(total / max(groups, 1), 1), 3), groups: groups,
                   m10: m[.a10] ?? 0, m20: m[.a20] ?? 0, m30: m[.a30] ?? 0,
                   m40: m[.a40] ?? 0, m50: m[.a50] ?? 0, m60: m[.a60] ?? 0,
                   f10: f[.a10] ?? 0, f20: f[.a20] ?? 0, f30: f[.a30] ?? 0,
                   f40: f[.a40] ?? 0, f50: f[.a50] ?? 0, f60: f[.a60] ?? 0)
}

private func randomRows(_ n: Int, seed: UInt64 = 42) -> [StatRow] {
    var g = SeededGenerator(state: seed)
    return (0..<n).map { _ in
        var m: [AgeBand: Int] = [:], f: [AgeBand: Int] = [:]
        for a in AgeBand.allCases {
            if Int.random(in: 0..<4, using: &g) == 0 { m[a] = Int.random(in: 1...2, using: &g) }
            if Int.random(in: 0..<4, using: &g) == 0 { f[a] = Int.random(in: 1...2, using: &g) }
        }
        if m.isEmpty && f.isEmpty { f[.a20] = 1 }
        return row(StoreID.allCases.randomElement(using: &g)!,
                   Segment.allCases.randomElement(using: &g)!,
                   dtype: Int.random(in: 1...9, using: &g),
                   hour: Int.random(in: 0..<24, using: &g),
                   groups: Int.random(in: 1...3, using: &g), m: m, f: f)
    }
}

private let epoch = Date(timeIntervalSince1970: 0)
private func stats(_ rows: [StatRow], days: [Int: Int] = [:]) -> Stats {
    Stats(rows: rows, from: epoch, to: epoch, dayCounts: days)
}

// MARK: - 集計（1回の走査でまとめて数えた結果が、素直に数えた結果と同じか）

@Suite("集計")
struct StatsAggregationTests {
    let rows = randomRows(500)

    @Test("合計・男女×年齢層・客層・時間帯・組の人数が、行を直接数えた結果と一致する")
    func matchesNaiveCount() {
        let s = stats(rows)
        #expect(s.groups == rows.reduce(0) { $0 + $1.groups })
        #expect(s.male == rows.reduce(0) { $0 + $1.male })
        #expect(s.female == rows.reduce(0) { $0 + $1.female })
        #expect(s.people == s.male + s.female)
        for g in Gender.allCases {
            for a in AgeBand.allCases {
                #expect(s.people(g, a) == rows.reduce(0) { $0 + $1.count(g, a) })
            }
        }
        for seg in Segment.allCases {
            #expect(s.groups(seg) == rows.filter { $0.segment == seg }.reduce(0) { $0 + $1.groups })
        }
        for h in 0..<24 {
            #expect(s.hourlyGroups[h] == rows.filter { $0.hour == h }.reduce(0) { $0 + $1.groups })
        }
        #expect(s.partyGroups.reduce(0, +) == s.groups)
    }

    @Test("split で分けた各グループの合計が全体と一致し、filter と同じ中身になる")
    func splitMatchesFilter() {
        let s = stats(rows)
        let byType = s.split(by: \.dtype)
        #expect(byType.values.reduce(0) { $0 + $1.groups } == s.groups)
        for (t, part) in byType {
            let filtered = s.filter { $0.dtype == t }
            #expect(part.groups == filtered.groups)
            #expect(part.people == filtered.people)
            #expect(part.ageShares == filtered.ageShares)
        }
    }

    @Test("曜日×3時間ごとの組数が、filter で数えた結果と一致する")
    func blockGroupsMatchFilter() {
        let s = stats(rows)
        let blocks = s.blockGroups()
        for d in dayTypes {
            for b in 0..<8 {
                let expected = s.filter { $0.dtype == d && $0.hour / 3 == b }.groups
                #expect((blocks[d]?[b] ?? 0) == expected)
            }
        }
    }

    @Test("店舗で絞り込むと、2店舗の合計が全体に戻る")
    func storesAddUp() {
        let s = stats(rows)
        #expect(s.only(.modern).groups + s.only(.luxury).groups == s.groups)
        #expect(s.only(nil).groups == s.groups)
    }

    @Test("記録がないときは割合・平均が0、指標は「—」")
    func emptyStats() {
        let s = stats([])
        #expect(s.avgParty == 0)
        #expect(s.ageShares.allSatisfy { $0 == 0 })
        #expect(s.peakHour == "—")
        #expect(s.topNonGeneral == "—")
        #expect(s.mainLayer == "—")
        #expect(s.genderRatio(separator: ":") == "—")
    }
}

// MARK: - 同数のときの表示

@Suite("同数の扱い")
struct TieTests {
    @Test func helpers() {
        #expect(tiedIndices([1, 3, 3, 0]) == [1, 2])
        #expect(tiedIndices([1, 3, 3, 0], lowest: true) == [3])
        #expect(tiedIndices([Int]()) == [])
        #expect(joinTies(["21"], suffix: "時台") == "21時台")
        #expect(joinTies(["21", "22"], suffix: "時台") == "21・22時台")
        #expect(joinTies(["3", "4", "5", "6"], suffix: "時台") == "3・4・5時台ほか")
        #expect(joinAges([.a30]) == "30代")
        #expect(joinAges([.a30, .a40]) == "30・40代")
        #expect(joinAges([.a50, .a60]) == "50・60代〜")
        #expect(joinAges([.a20, .a30, .a40]) == "20・30代ほか")
    }

    @Test("ピーク時間帯が同数なら両方を出す")
    func peakHourTie() {
        let s = stats([row(hour: 21, f: [.a20: 1]), row(hour: 22, f: [.a20: 1])])
        #expect(s.peakHour == "21・22時台")
    }

    @Test("一般以外で最多が同数なら両方を出す")
    func topSegmentTie() {
        let s = stats([row(.modern, .age_gap, m: [.a50: 1], f: [.a20: 1]),
                       row(.modern, .girls, f: [.a20: 2]),
                       row(.modern, .general, m: [.a30: 1])])
        #expect(s.topNonGeneral == "年の差・女子会")
    }

    @Test("主な層が同数なら年齢層を並べる")
    func mainLayerTie() {
        let s = stats([row(m: [.a30: 1, .a40: 1])])
        #expect(s.mainLayer == "男30・40代")
    }
}

// MARK: - 言葉による分析

@Suite("言葉による分析")
struct InsightsTests {
    private func column(_ s: Stats, title: String = "モダン") -> StatColumn {
        StatColumn(id: title, title: title, color: .black, stats: s)
    }

    @Test("概要（1店舗）の文章")
    func overviewSingle() {
        let s = stats([row(hour: 21, groups: 2, m: [.a30: 2], f: [.a20: 2]),
                       row(.modern, .deli, hour: 22, f: [.a20: 1])])
        #expect(Insights.overview([column(s)])
                == "3組・5名が来店、1組平均1.67名。ピークは21時台、一般以外で最多はデリヘル。（記録がまだ少ないため参考値）")
    }

    @Test("記録が30組以上なら参考値の注記は付かない")
    func noNoteWhenEnough() {
        let s = stats([row(hour: 21, groups: 30, f: [.a20: 30])])
        let text = Insights.overview([column(s)]) ?? ""
        #expect(!text.contains("参考値"))
    }

    @Test("時間帯：ピークが同数なら「各」を付けて並べる")
    func hoursTie() {
        let s = stats([row(hour: 21, f: [.a20: 1]), row(hour: 22, f: [.a20: 1])])
        let text = Insights.hours([column(s)]) ?? ""
        #expect(text.hasPrefix("ピークが21・22時台（各1組）"))
    }

    @Test("曜日別：最多の曜日は曜日の並び順で決まり、同数なら並べる")
    func weekdayTieIsDeterministic() {
        let s = stats([row(dtype: 5, f: [.a20: 1]), row(dtype: 6, f: [.a20: 1])],
                      days: [1: 4, 2: 4, 3: 4, 4: 4, 5: 4, 6: 4, 7: 4])
        let text = Insights.weekdayCount([column(s)]) ?? ""
        #expect(text.hasPrefix("金曜・土曜が最多"))
    }

    @Test("記録がない列だけなら文章を出さない")
    func emptyGivesNil() {
        #expect(Insights.overview([column(stats([]))]) == nil)
        #expect(Insights.hours([column(stats([]))]) == nil)
    }
}

// MARK: - 営業日（朝5時区切り）

@Suite("営業日")
struct BusinessDayTests {
    private func jst(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        JST.calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test("深夜0〜5時は前日の営業日")
    func startOfTodayBeforeFive() {
        #expect(JST.startOfToday(jst(2026, 10, 16, 3)) == jst(2026, 10, 15, 5))
        #expect(JST.startOfToday(jst(2026, 10, 16, 4, 59)) == jst(2026, 10, 15, 5))
        #expect(JST.startOfToday(jst(2026, 10, 16, 5)) == jst(2026, 10, 16, 5))
    }

    @Test("「今日」「今月」の範囲は朝5時から翌朝5時まで")
    func periodRanges() {
        let today = Period.today.range(now: jst(2026, 10, 16, 3))
        #expect(today.from == jst(2026, 10, 15, 5))
        #expect(today.to == jst(2026, 10, 16, 5))
        // 11月1日の深夜2時は、まだ10月の営業日
        let month = Period.month.range(now: jst(2026, 11, 1, 2))
        #expect(month.from == jst(2026, 10, 1, 5))
        #expect(month.to == jst(2026, 11, 1, 5))
    }
}

// MARK: - 入力中の組

@Suite("入力中の組")
struct DraftTests {
    @Test("デリヘルは女性のみ記録できる")
    func deliFemaleOnly() {
        var d = Draft()
        d.segment = .deli
        d.add(.f, .a20)
        #expect(d.canRecord)
        d.add(.m, .a40)
        #expect(d.deliHasMale)
        #expect(!d.canRecord)
        d.undo()
        #expect(d.canRecord)
    }

    @Test("一つ戻す・クリア")
    func undoAndClear() {
        var d = Draft()
        #expect(d.isPristine)
        d.add(.m, .a30); d.add(.m, .a30); d.add(.f, .a20)
        #expect(d.total == 3 && d.male == 2)
        d.undo()
        #expect(d.count(.f, .a20) == 0 && d.total == 2)
        d.minutesAgo = 10
        #expect(!d.isPristine)
        d.clear()
        #expect(d.isPristine)
    }

    @Test("よく使う組み合わせで中身を置き換え、一つ戻すで1名ずつ減らせる")
    func fillFromCombo() {
        let combo = row(m: [.a30: 1], f: [.a20: 2])
        var d = Draft()
        d.add(.m, .a60)
        d.minutesAgo = 5
        d.fill(segment: .age_gap, with: combo)
        #expect(d.count(.m, .a60) == 0)
        #expect(d.count(.m, .a30) == 1 && d.count(.f, .a20) == 2)
        #expect(d.segment == .age_gap && d.minutesAgo == 5)
        #expect(d.taps.count == 3)
        d.undo()
        #expect(d.total == 2)
    }

    @Test("来店時刻は「◯分前」の分だけ戻す")
    func visitDate() {
        var d = Draft()
        d.minutesAgo = 15
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(d.visitDate(now: now) == now.addingTimeInterval(-900))
    }
}

// MARK: - 通信の形式

@Suite("通信の形式")
struct DecodingTests {
    @Test("Postgres の日時（小数秒6桁・+09:00）を読める")
    func parsesPostgresTimestamps() {
        #expect(ISODate.parse("2026-10-16T05:48:47.179092+09:00") != nil)
        #expect(ISODate.parse("2026-10-15T20:48:47+00:00") != nil)
        #expect(ISODate.parse("2026-10-15T20:48:47.1Z") != nil)
    }

    @Test("visitor_sync：変化なしのときは版だけ")
    func decodesUnchangedSnapshot() throws {
        let json = #"{"v": "16:2026-10-16 06:48:47.182977+09", "changed": false}"#
        let s = try ISODate.decoder.decode(SyncSnapshot.self, from: Data(json.utf8))
        #expect(!s.changed && s.recent == nil && s.today == nil)
    }

    @Test("visitor_sync：変化ありのときは直前の記録と今日の件数")
    func decodesChangedSnapshot() throws {
        let json = #"""
        {"v": "2:x", "changed": true,
         "today": [{"store": "modern", "total": 2, "client_id": "784b81cd-bf63-44a7-9e15-b091e0a24f48"}],
         "recent": [{"id": "d9e74a7a-3c90-45b8-a27a-6b411c811141", "client_id": "e43e438c-a496-45ae-9493-93a49c8903fe",
                     "store": "luxury", "segment": "general", "visited_at": "2026-10-16T05:48:47.179092+09:00",
                     "m10": 0, "m20": 0, "m30": 1, "m40": 0, "m50": 0, "m60": 0,
                     "f10": 0, "f20": 1, "f30": 0, "f40": 0, "f50": 0, "f60": 0}]}
        """#
        let s = try ISODate.decoder.decode(SyncSnapshot.self, from: Data(json.utf8))
        #expect(s.changed)
        #expect(s.today?.first?.total == 2)
        #expect(s.recent?.first?.store == .luxury)
        #expect(s.recent?.first?.summary == "男30代・女20代")
    }

    @Test("よく使う組み合わせ：一般は客層を省いて表示")
    func frequentLabel() throws {
        let json = #"""
        [{"store": "modern", "segment": "general", "n": 6, "rk": 1, "total": 2,
          "m10": 0, "m20": 0, "m30": 1, "m40": 0, "m50": 0, "m60": 0,
          "f10": 0, "f20": 1, "f30": 0, "f40": 0, "f50": 0, "f60": 0},
         {"store": "modern", "segment": "deli", "n": 4, "rk": 2, "total": 1,
          "m10": 0, "m20": 0, "m30": 0, "m40": 0, "m50": 0, "m60": 0,
          "f10": 0, "f20": 1, "f30": 0, "f40": 0, "f50": 0, "f60": 0}]
        """#
        let rows = try JSONDecoder().decode([FrequentCombo].self, from: Data(json.utf8))
        #expect(rows.map(\.label) == ["男30代・女20代", "女20代 デリヘル"])
    }

    @Test("サーバー関数がないとき（PGRST202）を見分けられる")
    func missingFunction() {
        #expect(APIError.http(404, #"{"code":"PGRST202","message":"Could not find the function"}"#).isMissingFunction)
        #expect(!APIError.http(404, "not found").isMissingFunction)
        #expect(!APIError.http(500, "PGRST202").isMissingFunction)
    }
}
