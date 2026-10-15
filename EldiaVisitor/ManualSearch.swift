import Foundation
import NaturalLanguage

/// マニュアルのあいまい検索。
/// ・話した文や入力した文を単語に分け（「電話でオーダー入力したい」→ 電話・オーダー・入力）、助詞や「したい」などは除く
/// ・ひらがな／カタカナ、全角／半角、大文字／小文字の違いは同じとみなす
/// ・言い換え（オーダー＝注文 など）も同じ言葉として探す
/// ・どれか1つでも当たれば候補に出し、当たった数が多い順・タイトルで当たったもの優先で並べる
///
/// カードの文章の正規化（重い処理）はカードが変わったときに1回だけ行い（`Entry`）、
/// 1文字入力するごとの検索では、正規化済みの文章を調べるだけにしている。
enum ManualSearch {

    // MARK: 索引（カードごとに正規化済みの文章）

    struct Entry {
        let card: ManualCard
        let title: String
        let body: String
        /// 近い書き方を探すときに使う、タイトル＋本文
        let all: String

        init(_ card: ManualCard) {
            self.card = card
            title = ManualSearch.normalize(card.title)
            body = ManualSearch.normalize(card.steps.map(\.text).joined(separator: " "))
            all = title + " " + body
        }
    }

    static func index(_ cards: [ManualCard]) -> [Entry] { cards.map(Entry.init) }

    // MARK: 結果

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
        let full: [Hit]
        /// 一部の言葉だけ当たったもの
        let partial: [Hit]

        init(keywords: [String], hits: [Hit]) {
            self.keywords = keywords
            self.hits = hits
            full = hits.filter { $0.matched == keywords.count }
            partial = hits.filter { $0.matched < keywords.count }
        }

        static let empty = Result(keywords: [], hits: [])
    }

    // MARK: 検索

    /// 1つの言葉について、探す形を先にまとめておく（カードごとに計算し直さない）
    private struct Term {
        /// 言い換えを含めた正規化済みの言葉
        let variants: [String]
        /// 近い書き方の判定に使う2文字ずつの組（3文字未満なら空）
        let pairs: [String]

        init(_ word: String) {
            let normalized = ManualSearch.normalize(word)
            variants = ManualSearch.expand(normalized)
            pairs = ManualSearch.bigrams(normalized)
        }
    }

    static func run(_ query: String, in entries: [Entry]) -> Result {
        let keys = keywords(query)
        guard !keys.isEmpty else { return .empty }
        let terms = keys.map(Term.init)

        var hits: [Hit] = []
        for entry in entries {
            var matched = 0
            var score = 0.0
            for term in terms {
                if let points = points(for: term, in: entry) {
                    matched += 1
                    score += points
                }
            }
            if matched > 0 { hits.append(Hit(card: entry.card, matched: matched, score: score)) }
        }
        hits.sort(by: ranksBefore)
        return Result(keywords: keys, hits: hits)
    }

    /// 1つの言葉がカードに当たったときの点数（タイトル 3点・本文 1点・近い書き方 0.5点）。当たらなければ nil
    private static func points(for term: Term, in entry: Entry) -> Double? {
        if term.variants.contains(where: { entry.title.contains($0) }) { return 3 }
        if term.variants.contains(where: { entry.body.contains($0) }) { return 1 }
        if isSimilar(term.pairs, in: entry.all) { return 0.5 }
        return nil
    }

    /// 当たった言葉の数 → 点数 → タイトルの順に並べる
    private static func ranksBefore(_ a: Hit, _ b: Hit) -> Bool {
        if a.matched != b.matched { return a.matched > b.matched }
        if a.score != b.score { return a.score > b.score }
        return a.card.title < b.card.title
    }

    // MARK: 単語に分ける

    static func keywords(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = q
        var words: [String] = []
        var seen = Set<String>()
        tokenizer.enumerateTokens(in: q.startIndex..<q.endIndex) { range, _ in
            let w = String(q[range]).trimmingCharacters(in: tokenTrim)
            if isMeaningful(w), seen.insert(w).inserted { words.append(w) }
            return true
        }
        // 単語に分けられなかったとき（すべて助詞など）は元の文で探す
        return words.isEmpty ? [q] : words
    }

    private static let tokenTrim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)

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

    private static func isMeaningful(_ w: String) -> Bool {
        guard !w.isEmpty, !stopWords.contains(w) else { return false }
        // かな1文字は助詞などなので除く（漢字1文字は残す）
        if w.count == 1, w.unicodeScalars.allSatisfy { isKana($0) } { return false }
        return true
    }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
    }

    // MARK: 表記ゆれ

    /// ひらがな→カタカナ、全角英数→半角、半角カナ→全角、小文字にそろえる
    static func normalize(_ s: String) -> String {
        let nfkc = s.precomposedStringWithCompatibilityMapping
        let katakana = nfkc.applyingTransform(.hiraganaToKatakana, reverse: false) ?? nfkc
        return katakana.lowercased()
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
    ]

    /// 正規化した言葉 → 同じ意味の言葉すべて（言葉ごとにグループを探し回らないよう、最初に1回だけ作る）
    private static let synonymIndex: [String: [String]] = {
        var index: [String: [String]] = [:]
        for group in synonymGroups.map({ $0.map(normalize) }) {
            for word in group {
                var list = index[word, default: []]
                for v in group where !list.contains(v) { list.append(v) }
                index[word] = list
            }
        }
        return index
    }()

    /// 正規化済みの言葉と、その言い換え
    private static func expand(_ normalized: String) -> [String] {
        [normalized] + (synonymIndex[normalized] ?? []).filter { $0 != normalized }
    }

    // MARK: 近い書き方

    /// 2文字ずつの組（3文字未満の言葉は対象外なので空）
    private static func bigrams(_ word: String) -> [String] {
        let chars = Array(word)
        guard chars.count >= 3 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
    }

    /// 2文字ずつの組の6割以上が含まれていれば、近い書き方とみなす
    private static func isSimilar(_ pairs: [String], in text: String) -> Bool {
        guard !pairs.isEmpty else { return false }
        let found = pairs.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
        return Double(found) / Double(pairs.count) >= 0.6
    }
}
