import XCTest
@testable import EldiaVisitor

/// フロントマニュアルのあいまい検索のテスト
final class ManualSearchTests: XCTestCase {

    // MARK: 準備

    private func card(_ title: String, _ category: ManualCategory = .pay, steps: [String] = ["手順"]) -> ManualCard {
        var c = ManualCard(category: category)
        c.title = title
        c.steps = steps.map { text in
            var s = ManualStep()
            s.text = text
            return s
        }
        return c
    }

    private func search(_ query: String, in cards: [ManualCard]) -> ManualSearch.Result {
        ManualSearch.run(query, in: ManualSearch.index(cards))
    }

    // MARK: 単語に分ける

    func testKeywordsDropParticlesAndPhrases() {
        let keys = ManualSearch.keywords("電話でオーダー入力したい")
        XCTAssertTrue(keys.contains("電話"), "\(keys)")
        XCTAssertTrue(keys.contains("オーダー"), "\(keys)")
        XCTAssertTrue(keys.contains("入力"), "\(keys)")
        XCTAssertFalse(keys.contains("で"), "\(keys)")
        XCTAssertFalse(keys.contains("したい"), "\(keys)")
    }

    func testKeywordsHaveNoDuplicates() {
        let keys = ManualSearch.keywords("電話 電話")
        XCTAssertEqual(keys.filter { $0 == "電話" }.count, 1)
    }

    func testOnlyStopWordsFallsBackToWholeQuery() {
        XCTAssertEqual(ManualSearch.keywords("したい"), ["したい"])
    }

    func testEmptyQueryFindsNothing() {
        let r = search("   ", in: [card("電話でオーダー入力")])
        XCTAssertTrue(r.keywords.isEmpty)
        XCTAssertTrue(r.hits.isEmpty)
    }

    // MARK: 表記ゆれ

    func testNormalizeIgnoresKanaWidthAndCase() {
        XCTAssertEqual(ManualSearch.normalize("おーだー"), ManualSearch.normalize("オーダー"))
        XCTAssertEqual(ManualSearch.normalize("ｵｰﾀﾞｰ"), ManualSearch.normalize("オーダー"))
        XCTAssertEqual(ManualSearch.normalize("ＴＥＬ"), "tel")
    }

    func testHiraganaQueryFindsKatakanaTitle() {
        let r = search("くーぽん", in: [card("クーポンの使い方", .coupon)])
        XCTAssertEqual(r.hits.map(\.card.title), ["クーポンの使い方"])
    }

    // MARK: 一部一致・並び順

    func testTwoWordsFindTarget() {
        let target = card("電話でオーダー入力", .food)
        let other = card("精算機でお釣りが出ない")
        let r = search("電話 オーダー", in: [other, target])
        XCTAssertEqual(r.full.map(\.card.title), ["電話でオーダー入力"])
        XCTAssertTrue(r.partial.isEmpty)
    }

    func testPartialMatchesAreListedSeparately() {
        let a = card("電話でオーダー入力", .food)
        let b = card("精算機でお釣りが出ない")
        let r = search("電話 精算", in: [a, b])
        XCTAssertTrue(r.full.isEmpty)
        XCTAssertEqual(Set(r.partial.map(\.card.title)), ["電話でオーダー入力", "精算機でお釣りが出ない"])
    }

    func testTitleMatchRanksAboveBodyMatch() {
        let inBody = card("会員の確認", .members, steps: ["電話で確認する"])
        let inTitle = card("電話の取り方", .reserve)
        let r = search("電話", in: [inBody, inTitle])
        XCTAssertEqual(r.hits.map(\.card.title), ["電話の取り方", "会員の確認"])
    }

    func testMoreMatchedWordsRankFirst() {
        let one = card("電話の取り方", .reserve)
        let two = card("電話でオーダー入力", .food)
        let r = search("電話 オーダー", in: [one, two])
        XCTAssertEqual(r.hits.first?.card.title, "電話でオーダー入力")
    }

    // MARK: 言い換え・近い書き方

    func testSynonymFindsCard() {
        let r = search("注文", in: [card("オーダー入力", .food)])
        XCTAssertEqual(r.hits.count, 1)
    }

    func testSynonymWorksBothWays() {
        let r = search("会計", in: [card("精算機でお釣りが出ない")])
        XCTAssertEqual(r.hits.count, 1)
    }

    func testSimilarSpellingIsFound() {
        // 「チェックイン」を「チェックインン」と言い間違えても近ければ当たる
        let r = search("チェックインン", in: [card("チェックインの手順", .reserve)])
        XCTAssertEqual(r.hits.count, 1)
    }

    func testUnrelatedWordFindsNothing() {
        let r = search("駐車場", in: [card("電話でオーダー入力", .food)])
        XCTAssertTrue(r.hits.isEmpty)
    }
}

/// 1画面1ステップの「進む・戻る・完了」のテスト
final class ManualRunTests: XCTestCase {

    /// 1:質問（はい→3、いいえ→2） 2:手順（ここで完了） 3:手順 4:手順
    private func branchingCard() -> ManualCard {
        var c = ManualCard(category: .pay)
        var q = ManualStep(kind: .question); q.text = "Q"
        var a = ManualStep(); a.text = "A"; a.end = true
        var b = ManualStep(); b.text = "B"
        var d = ManualStep(); d.text = "D"
        q.yes = b.id
        q.no = a.id
        c.steps = [q, a, b, d]
        return c
    }

    func testYesGoesToTarget() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[0].id)
        run.advance(in: c, from: c.steps[0], to: c.steps[0].yes)
        XCTAssertEqual(run.stepID, c.steps[2].id)
        XCTAssertEqual(run.history, [c.steps[0].id])
    }

    func testNoTargetGoesToNextStep() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[2].id)
        run.advance(in: c, from: c.steps[2], to: nil)
        XCTAssertEqual(run.stepID, c.steps[3].id)
        XCTAssertFalse(run.finished)
    }

    func testAdvancingPastLastStepFinishes() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[3].id)
        run.advance(in: c, from: c.steps[3], to: nil)
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.stepID, c.steps[3].id)
        XCTAssertTrue(run.history.isEmpty)
    }

    func testUnknownTargetFallsBackToNextStep() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[0].id)
        run.advance(in: c, from: c.steps[0], to: "削除されたステップ")
        XCTAssertEqual(run.stepID, c.steps[1].id)
    }

    func testStepBackReturnsAndClearsFinished() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[0].id)
        run.advance(in: c, from: c.steps[0], to: c.steps[0].yes)
        run.finished = true
        run.stepBack()
        XCTAssertEqual(run.stepID, c.steps[0].id)
        XCTAssertFalse(run.finished)
        XCTAssertFalse(run.canStepBack)
    }

    func testStepBackWithoutHistoryDoesNothing() {
        let c = branchingCard()
        var run = ManualRun(cardID: c.id, stepID: c.steps[2].id)
        run.stepBack()
        XCTAssertEqual(run.stepID, c.steps[2].id)
    }

    func testStepEncodingKeepsOnlyRelevantFields() throws {
        var s = ManualStep(); s.text = "x"; s.yes = "a"; s.end = false
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(s), encoding: .utf8))
        XCTAssertFalse(json.contains("\"yes\""), "手順には分岐先を保存しない")
        XCTAssertFalse(json.contains("\"end\""))
        let decoded = try JSONDecoder().decode(ManualStep.self, from: Data(#"{"text":"t"}"#.utf8))
        XCTAssertEqual(decoded.kind, .step)
        XCTAssertEqual(decoded.text, "t")
    }
}
