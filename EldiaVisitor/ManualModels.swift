import SwiftUI

// MARK: - フロント業務マニュアル：データの形
// 共通 Supabase の manual_cards（1行＝1カード、手順は steps に JSON で入る）

enum ManualCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case pay, reserve, members, coupon, food, slip, sirius
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pay: return "精算"
        case .reserve: return "ご予約"
        case .members: return "メンバーズ"
        case .coupon: return "クーポン"
        case .food: return "食事"
        case .slip: return "伝票"
        case .sirius: return "その他操作"
        }
    }

    var symbol: String {
        switch self {
        case .pay: return "yensign.circle"
        case .reserve: return "calendar"
        case .members: return "person.text.rectangle"
        case .coupon: return "ticket"
        case .food: return "fork.knife"
        case .slip: return "doc.text"
        case .sirius: return "square.grid.2x2"
        }
    }
}

enum StepKind: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 人がやること
    case step
    /// ALMEX-SIRIUS i での操作
    case sirius
    /// はい／いいえで分かれる質問
    case question
    var id: String { rawValue }

    var label: String {
        switch self {
        case .step: return "手順"
        case .sirius: return "SIRIUS i 操作"
        case .question: return "はい／いいえ"
        }
    }
}

/// 1ステップ。分岐先は番号ではなく ID で持つ（並べ替えても分岐が崩れない）
struct ManualStep: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var kind: StepKind = .step
    var text: String = ""
    /// manual-images バケット内のファイル名
    var image: String?
    /// 質問で「はい」のときの行き先（未指定なら次のステップ）
    var yes: String?
    /// 質問で「いいえ」のときの行き先（未指定なら次のステップ）
    var no: String?
    /// ここで対応完了（途中で終わる枝のため）
    var end: Bool = false

    init(kind: StepKind = .step) { self.kind = kind }

    private enum CodingKeys: String, CodingKey { case id, kind, text, image, yes, no, end }

    // 項目が欠けていても読めるようにする（後から項目を増やしても古い端末が壊れない）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decode(StepKind.self, forKey: .kind)) ?? .step
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        yes = try? c.decodeIfPresent(String.self, forKey: .yes)
        no = try? c.decodeIfPresent(String.self, forKey: .no)
        end = (try? c.decodeIfPresent(Bool.self, forKey: .end)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(image, forKey: .image)
        if kind == .question {
            try c.encodeIfPresent(yes, forKey: .yes)
            try c.encodeIfPresent(no, forKey: .no)
        } else if end {
            try c.encode(true, forKey: .end)
        }
    }
}

struct ManualCard: Codable, Identifiable, Hashable {
    var id: UUID
    var category: ManualCategory
    var title: String
    var steps: [ManualStep]
    var sort_order: Int
    var updated_at: Date?

    init(category: ManualCategory) {
        id = UUID()
        self.category = category
        title = ""
        steps = [ManualStep()]
        sort_order = 0
        updated_at = nil
    }

    func index(of stepID: String?) -> Int? {
        guard let stepID else { return nil }
        return steps.firstIndex { $0.id == stepID }
    }
}

/// 保存の前の内容（manual_card_versions の1行）
struct ManualVersion: Decodable, Identifiable, Hashable {
    let id: Int
    let card_id: UUID
    let action: String
    let category: ManualCategory
    let title: String
    let steps: [ManualStep]
    let sort_order: Int
    let saved_at: Date
}

/// 閲覧中の位置（マニュアルを閉じて来店記録に戻っても、開き直すと続きから見られる）
struct ManualRun: Hashable {
    let cardID: UUID
    var stepID: String
    var history: [String] = []
    var finished = false

    /// 次のステップへ進む。target が指定されていればそこへ（質問の はい／いいえ）、無ければ次の番号へ。
    /// 最後のステップを越えたら完了にする
    mutating func advance(in card: ManualCard, from step: ManualStep, to target: String?) {
        guard let current = card.index(of: step.id) else { return }
        let next = card.index(of: target) ?? (current + 1)
        guard card.steps.indices.contains(next) else {
            finished = true
            return
        }
        history.append(step.id)
        stepID = card.steps[next].id
    }

    /// 1つ前のステップに戻る（戻れなければ何もしない）
    mutating func stepBack() {
        guard let previous = history.popLast() else { return }
        stepID = previous
        finished = false
    }

    var canStepBack: Bool { !history.isEmpty }
}

enum ManualRoute: Hashable {
    case category(ManualCategory)
    case card(UUID)
}

extension ManualCategory {
    /// カテゴリの色（落ち着いた色で、文字は白でも読める濃さ）
    var tint: Color {
        switch self {
        case .pay: return Color(hex: 0x2E6B5E)
        case .reserve: return Color(hex: 0x2B4A8A)
        case .members: return Color(hex: 0x7B4FA0)
        case .coupon: return Color(hex: 0xB0592A)
        case .food: return Color(hex: 0x8A6408)
        case .slip: return Color(hex: 0x4F5B66)
        case .sirius: return Color(hex: 0x01579B)
        }
    }
    var soft: Color {
        switch self {
        case .pay: return Color(hex: 0xE3F0EC)
        case .reserve: return Color(hex: 0xE6ECF7)
        case .members: return Color(hex: 0xEFE8F5)
        case .coupon: return Color(hex: 0xF8ECE4)
        case .food: return Color(hex: 0xF5ECD6)
        case .slip: return Color(hex: 0xEBEDF0)
        case .sirius: return Color(hex: 0xE1F0FA)
        }
    }
}

extension StepKind {
    /// 編集画面の追加ボタンや、写真が無いときの表示に使うアイコン
    var symbol: String {
        switch self {
        case .step: return "hand.point.up.left"
        case .sirius: return "desktopcomputer"
        case .question: return "questionmark.circle"
        }
    }

    var badgeFill: Color { self == .sirius ? Palette.noticeFill : Color(hex: 0xEDEDF2) }
    var badgeText: Color { self == .sirius ? Palette.noticeText : Palette.ink2 }
}

// MARK: - マニュアル画面で繰り返し使う色

extension Palette {
    /// 灰色のボタンの背景
    static let chip = Color(hex: 0xE9E9EE)
    /// 注意の帯（黄土色）の背景と文字
    static let noticeFill = Color(hex: 0xF5E9C8)
    static let noticeText = Color(hex: 0x6B4E06)
    /// 「探した言葉」の背景
    static let tealSoft = Color(hex: 0xE3F0EC)
    /// 写真が無いときのアイコン・進み具合の未到達部分
    static let placeholder = Color(hex: 0xC7C7CC)
    static let track = Color(hex: 0xDADADF)
}
