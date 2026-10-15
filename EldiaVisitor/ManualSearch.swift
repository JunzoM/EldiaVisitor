import Foundation
import NaturalLanguage

/// マニュアルのあいまい検索。
/// ・話した文や入力した文を単語に分け（「電話でオーダー入力したい」→ 電話・オーダー・入力）、助詞や「したい」などは除く
/// ・ひらがな／カタカナ、全角／半角、大文字／小文字の違いは同じとみなす
/// ・言い換え（オーダー＝注文 など）も同じ言葉として探す
/// ・どれか1つでも当たれば候補に出し、当たった数が多い順・タイトルで当たったもの優先で並べる
enum ManualSearch {
    struct Hit: Identifiable {
        let card: ManualCard
        /// 当たった言葉の数
        let matched: Int
        let score: Double
        var id: UUID { card.id }
    }

    struct Result {
        let keywords: [String]
        let hits: [Hit]
        /// すべての言葉に当たったもの
        var full: [Hit] { hits.filter { $0.matched == keywords.count } }
        /// 一部の言葉だけ当たったもの
        var partial: [Hit] { hits.filter { $0.matched < keywords.count } }
    }

    static func run(_ query: String, in cards: [ManualCard]) -> Result {
        let keys = keywords(query)
        guard !keys.isEmpty else { return Result(keywords: [], hits: []) }
        let variants = keys.map(expand)

        var hits: [Hit] = []
        for c in cards {
            let title = normalize(c.title)
            let body = normalize(c.steps.map(\.text).joined(separator: " "))
            var matched = 0
            var score = 0.0
            for (i, vs) in variants.enumerated() {
                if vs.contains(where: { title.contains($0) }) {
                    matched += 1; score += 3
                } else if vs.contains(where: { body.contains($0) }) {
                    matched += 1; score += 1
                } else if similar(normalize(keys[i]), in: title + " " + body) {
                    matched += 1; score += 0.5
                }
            }
            if matched > 0 { hits.append(Hit(card: c, matched: matched, score: score)) }
        }
        hits.sort {
            if $0.matched != $1.matched { return $0.matched > $1.matched }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.card.title < $1.card.title
        }
        return Result(keywords: keys, hits: hits)
    }

    // MARK: 単語に分ける

    static func keywords(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let tok = NLTokenizer(unit: .word)
        tok.setLanguage(.japanese)
        tok.string = q
        var out: [String] = []
        let trim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)
        tok.enumerateTokens(in: q.startIndex..<q.endIndex) { range, _ in
            let w = String(q[range]).trimmingCharacters(in: trim)
            if keep(w), !out.contains(w) { out.append(w) }
            return true
        }
        // 単語に分けられなかったとき（すべて助詞など）は元の文で探す
        return out.isEmpty ? [q] : out
    }

    /// 探すときに意味のない言葉
    private static let stopWords: Set<String> = [
        "の", "に", "は", "を", "が", "で", "と", "へ", "も", "や", "か", "な", "ね", "よ",
        "から", "まで", "より", "など", "って", "とか",
        "とき", "時", "ため", "こと", "もの", "よう", "方", "かた", "方法", "やり方", "仕方", "しかた",
        "したい", "たい", "する", "します", "して", "した", "しない", "できる", "できない", "ない",
        "です", "ます", "ある", "いる", "なる", "れる", "られる",
        "どう", "どうやって", "どうする", "どうすれ", "どうすれば", "ば", "教え", "教えて", "知りたい",
        "について", "場合", "お願い", "ください", "下さい", "いい", "よい"
    ]

    private static func keep(_ w: String) -> Bool {
        guard !w.isEmpty, !stopWords.contains(w) else { return false }
        // かな1文字は助詞などなので除く（漢字1文字は残す）
        if w.count == 1, w.unicodeScalars.allSatisfy({ isKana($0) }) { return false }
        return true
    }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
    }

    // MARK: 表記ゆれ

    /// ひらがな→カタカナ、全角英数→半角、半角カナ→全角、小文字にそろえる
    static func normalize(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let kata = nfkc.applyingTransform(.hiraganaToKatakana, reverse: false) ?? nfkc
        return kata.lowercased()
    }

    /// 同じ意味として探す言い換え（フロント業務でよく使うもの）
    private static let synonymGroups: [[String]] = [
        ["オーダー", "注文"],
        ["電話", "でんわ", "TEL", "コール"],
        ["精算", "会計", "支払", "支払い", "お支払い", "清算"],
        ["お釣り", "おつり", "釣銭", "釣り銭", "つり銭"],
        ["予約", "よやく", "リザーブ"],
        ["メンバーズ", "メンバー", "会員"],
        ["クーポン", "割引券"],
        ["食事", "フード", "料理", "ごはん", "ご飯"],
        ["伝票", "でんぴょう"],
        ["入力", "登録", "打ち込み"],
        ["取消", "取り消し", "キャンセル"],
        ["延長", "えんちょう"],
        ["チェックイン", "入室"],
        ["チェックアウト", "退室"],
    ].map { $0.map(normalize) }

    private static func expand(_ word: String) -> [String] {
        let n = normalize(word)
        var out = [n]
        for g in synonymGroups where g.contains(n) {
            for v in g where !out.contains(v) { out.append(v) }
        }
        return out
    }

    /// 少し違う書き方でも当てる（3文字以上の言葉で、2文字ずつの組の6割以上が含まれていれば当たり）
    private static func similar(_ word: String, in text: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 3 else { return false }
        let pairs = (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
        let found = pairs.filter { text.contains($0) }.count
        return Double(found) / Double(pairs.count) >= 0.6
    }
}
