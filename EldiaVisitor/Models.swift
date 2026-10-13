import SwiftUI

// MARK: - 接続先

enum AppConfig {
    static let supabaseURL = URL(string: "https://mqapkwlxlunyvsuhiujb.supabase.co")!
    /// 公開用キー（RLS により共通ログインしたスタッフのみ読み書きできる）
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1xYXBrd2x4bHVueXZzdWhpdWpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMzNTQyMzUsImV4cCI6MjA4ODkzMDIzNX0.3BCcAtsfMHHXemd-AYYfdIhLoWyZJ1crRl5jNrsReWk"
}

// MARK: - 色

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Palette {
    static let teal = Color(hex: 0x2E6B5E)
    static let ground = Color(hex: 0xF2F2F7)
    static let card = Color.white
    static let line = Color(hex: 0xE5E5EA)
    static let sub = Color(hex: 0x6B6B70)
    static let ink2 = Color(hex: 0x3C3C43)
    static let saturday = Color(hex: 0x2B4A8A)
    static let sunday = Color(hex: 0xB3261E)
}

// MARK: - 店舗

enum StoreID: String, CaseIterable, Identifiable, Codable, Hashable {
    case modern, luxury
    var id: String { rawValue }
    var label: String { self == .modern ? "モダン" : "ラグジュアリー" }
    var accent: Color { self == .modern ? Color(hex: 0x0277BD) : Color(hex: 0x8A6408) }
    var deep: Color { self == .modern ? Color(hex: 0x01579B) : Color(hex: 0x6B4E06) }
    var soft: Color { self == .modern ? Color(hex: 0xE1F0FA) : Color(hex: 0xF5E9C8) }
}

// MARK: - 客層（1組に1つ）

enum Segment: String, CaseIterable, Identifiable, Codable, Hashable {
    case general, deli, age_gap, girls, family, inbound, business
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "一般"
        case .deli: return "デリヘル"
        case .age_gap: return "年の差"
        case .girls: return "女子会"
        case .family: return "ファミリー"
        case .inbound: return "インバウンド"
        case .business: return "ビジネス"
        }
    }
    var color: Color {
        switch self {
        case .general: return Color(hex: 0xC7CAD1)
        case .deli: return Color(hex: 0x7B4FA0)
        case .age_gap: return Color(hex: 0x2E6B5E)
        case .girls: return Color(hex: 0xD9789B)
        case .family: return Color(hex: 0xE0A23B)
        case .inbound: return Color(hex: 0x3B8FD9)
        case .business: return Color(hex: 0x3C3C43)
        }
    }
}

// MARK: - 性別・年齢層

enum Gender: String, CaseIterable, Identifiable, Hashable, Codable {
    case m, f
    var id: String { rawValue }
    var label: String { self == .m ? "男性" : "女性" }
    var short: String { self == .m ? "男" : "女" }
    var color: Color { self == .m ? Color(hex: 0x3A5BA0) : Color(hex: 0xC4501B) }
    var soft: Color { self == .m ? Color(hex: 0xEEF2FA) : Color(hex: 0xFDF1EA) }
    var border: Color { self == .m ? Color(hex: 0xC7D3EC) : Color(hex: 0xF2CDB8) }
    var symbol: String { self == .m ? "figure.stand" : "figure.stand.dress" }
}

enum AgeBand: Int, CaseIterable, Identifiable, Hashable, Codable {
    case a10 = 10, a20 = 20, a30 = 30, a40 = 40, a50 = 50, a60 = 60
    var id: Int { rawValue }
    var label: String { self == .a60 ? "60代〜" : "\(rawValue)代" }
    var short: String { self == .a60 ? "60代〜" : "\(rawValue)代" }
    var tiny: String { self == .a60 ? "60〜" : "\(rawValue)代" }
}

struct CountKey: Hashable, Codable {
    let gender: Gender
    let age: AgeBand
}

/// 「男30代・女20代×2」のような内訳の文字列
func partySummary(_ count: (Gender, AgeBand) -> Int) -> String {
    var parts: [String] = []
    for g in Gender.allCases {
        for a in AgeBand.allCases {
            let c = count(g, a)
            if c > 0 { parts.append(g.short + a.short + (c > 1 ? "×\(c)" : "")) }
        }
    }
    return parts.joined(separator: "・")
}

// MARK: - 来店記録（1行＝1組）

struct VisitorLog: Codable, Identifiable, Hashable {
    var id: UUID
    var client_id: UUID?
    var store: StoreID
    var visited_at: Date
    var segment: Segment
    var m10: Int, m20: Int, m30: Int, m40: Int, m50: Int, m60: Int
    var f10: Int, f20: Int, f30: Int, f40: Int, f50: Int, f60: Int

    init(store: StoreID, segment: Segment, counts: [CountKey: Int], at date: Date = Date()) {
        let cid = UUID()
        id = cid
        client_id = cid
        self.store = store
        self.segment = segment
        visited_at = date
        func c(_ g: Gender, _ a: AgeBand) -> Int { counts[CountKey(gender: g, age: a)] ?? 0 }
        m10 = c(.m, .a10); m20 = c(.m, .a20); m30 = c(.m, .a30); m40 = c(.m, .a40); m50 = c(.m, .a50); m60 = c(.m, .a60)
        f10 = c(.f, .a10); f20 = c(.f, .a20); f30 = c(.f, .a30); f40 = c(.f, .a40); f50 = c(.f, .a50); f60 = c(.f, .a60)
    }

    func count(_ g: Gender, _ a: AgeBand) -> Int {
        switch (g, a) {
        case (.m, .a10): return m10
        case (.m, .a20): return m20
        case (.m, .a30): return m30
        case (.m, .a40): return m40
        case (.m, .a50): return m50
        case (.m, .a60): return m60
        case (.f, .a10): return f10
        case (.f, .a20): return f20
        case (.f, .a30): return f30
        case (.f, .a40): return f40
        case (.f, .a50): return f50
        case (.f, .a60): return f60
        }
    }

    var male: Int { m10 + m20 + m30 + m40 + m50 + m60 }
    var female: Int { f10 + f20 + f30 + f40 + f50 + f60 }
    var total: Int { male + female }
    var summary: String { partySummary { count($0, $1) } }
    var dedupeKey: UUID { client_id ?? id }
}

/// サーバーへ送る形
struct NewVisitorLog: Encodable {
    let client_id: UUID
    let store: String
    let visited_at: Date
    let segment: String
    let m10: Int, m20: Int, m30: Int, m40: Int, m50: Int, m60: Int
    let f10: Int, f20: Int, f30: Int, f40: Int, f50: Int, f60: Int

    init(_ l: VisitorLog) {
        client_id = l.dedupeKey
        store = l.store.rawValue
        visited_at = l.visited_at
        segment = l.segment.rawValue
        m10 = l.m10; m20 = l.m20; m30 = l.m30; m40 = l.m40; m50 = l.m50; m60 = l.m60
        f10 = l.f10; f20 = l.f20; f30 = l.f30; f40 = l.f40; f50 = l.f50; f60 = l.f60
    }
}

// MARK: - 入力中の組

struct Draft {
    var counts: [CountKey: Int] = [:]
    var taps: [CountKey] = []
    var segment: Segment = .general

    var total: Int { counts.values.reduce(0, +) }
    var male: Int { counts.filter { $0.key.gender == .m }.values.reduce(0, +) }
    var isEmpty: Bool { total == 0 }
    /// デリヘルは女性のみ（男性は「一般」で別に記録する運用）
    var deliHasMale: Bool { segment == .deli && male > 0 }
    var canRecord: Bool { !isEmpty && !deliHasMale }
    var summary: String { partySummary { counts[CountKey(gender: $0, age: $1)] ?? 0 } }

    func count(_ g: Gender, _ a: AgeBand) -> Int { counts[CountKey(gender: g, age: a)] ?? 0 }

    mutating func add(_ g: Gender, _ a: AgeBand) {
        let k = CountKey(gender: g, age: a)
        counts[k, default: 0] += 1
        taps.append(k)
    }

    mutating func undo() {
        guard let k = taps.popLast() else { return }
        let v = (counts[k] ?? 0) - 1
        counts[k] = v > 0 ? v : nil
    }

    mutating func clear() { self = Draft() }
}

// MARK: - 日時（日本時間）

enum JST {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "ja_JP")
        c.firstWeekday = 2
        return c
    }()

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = timeZone
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    static let hm = formatter("HH:mm")
    static let hms = formatter("HH:mm:ss")
    static let dateLong = formatter("yyyy年M月d日(E)")
    static let csv = formatter("yyyy/MM/dd HH:mm")
    static let fileDate = formatter("yyyyMMdd")

    static func startOfToday(_ now: Date = Date()) -> Date { calendar.startOfDay(for: now) }
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(_ d: Date) -> String { plain.string(from: d) }

    static func parse(_ s: String) -> Date? {
        if let d = withFraction.date(from: s) { return d }
        if let d = plain.date(from: s) { return d }
        // 小数秒が6桁などの場合は3桁に詰めて再挑戦
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let frac = s[s.index(after: dot)..<end]
            let ms = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            let trimmed: String = String(s[..<dot]) + "." + ms + String(s[end...])
            if let d = withFraction.date(from: trimmed) { return d }
        }
        return nil
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISODate.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "日時を読めません: \(s)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISODate.string(date))
        }
        return e
    }()
}

let weekdayLabels = ["月", "火", "水", "木", "金", "土", "日"]

func weekdayColor(_ dow: Int) -> Color {
    dow == 6 ? Palette.saturday : (dow == 7 ? Palette.sunday : Color.primary)
}

// MARK: - ボタンの見た目（iOS 26 以上は Liquid Glass、iPadOS 17 などは通常のボタン）

extension View {
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
