import SwiftUI
import UIKit
import Observation

/// フロントマニュアルの読み込み・端末内保存・編集。
/// 読むのは共通ログインのスタッフ全員、書けるのは manual_admins に登録された人だけ（サーバー側で制限）。
/// フロントの iPad がスタッフ用アカウントでログインしていても、編集のときだけ管理者としてログインできる。
@MainActor
@Observable
final class ManualStore {
    let auth: AuthManager

    /// すべてのカード。変わるたびに、カテゴリ別一覧・ID 引き・検索用の索引を作り直す
    private(set) var cards: [ManualCard] = [] {
        didSet { rebuildIndexes() }
    }
    private(set) var loading = false
    private(set) var lastError: String?
    private(set) var lastLoaded: Date?

    /// いまの共通ログインが管理者か
    private(set) var sessionIsAdmin = false
    /// 編集のためだけの管理者ログイン（端末には保存しない）
    private(set) var adminSession: AuthSession?
    /// 編集モード
    var editing = false

    /// 画面の位置（閉じて開き直しても続きから）
    var path: [ManualRoute] = []
    var run: ManualRun?

    // 画面から何度も呼ばれるので、カードが変わったときだけ作り直す
    private var cardsByCategory: [ManualCategory: [ManualCard]] = [:]
    private var cardsByID: [UUID: ManualCard] = [:]
    private var searchIndex: [ManualSearch.Entry] = []

    /// 表示用に読み込んだ写真（メモリが足りなくなると iOS が自動で捨てる）
    @ObservationIgnored private let imageMemory = NSCache<NSString, UIImage>()

    init(auth: AuthManager) {
        self.auth = auth
        cards = ManualCache.loadCards()
        rebuildIndexes() // init の中では didSet が呼ばれないため
    }

    var canEdit: Bool { sessionIsAdmin || adminSession != nil }

    func cards(in category: ManualCategory) -> [ManualCard] { cardsByCategory[category] ?? [] }

    func card(_ id: UUID) -> ManualCard? { cardsByID[id] }

    /// あいまい検索（単語に分けて、どれか1つでも当たれば候補に出す）
    func search(_ text: String) -> ManualSearch.Result {
        ManualSearch.run(text, in: searchIndex)
    }

    private func rebuildIndexes() {
        cardsByCategory = Dictionary(grouping: cards, by: \.category)
            .mapValues { $0.sorted { ($0.sort_order, $0.title) < ($1.sort_order, $1.title) } }
        cardsByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchIndex = ManualSearch.index(cards)
    }

    // MARK: 読み込み

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let token = try await auth.accessToken()
            let data = try await request("rest/v1/manual_cards", query: [
                URLQueryItem(name: "select", value: "id,category,title,steps,sort_order,updated_at"),
                URLQueryItem(name: "order", value: "category.asc,sort_order.asc,title.asc")
            ], token: token)
            cards = try ISODate.decoder.decode([ManualCard].self, from: data)
            ManualCache.saveCards(cards)
            lastLoaded = Date()
            lastError = nil
            sessionIsAdmin = (try? await isAdmin(token: token)) ?? sessionIsAdmin
            await prefetchImages(token: token)
        } catch {
            lastError = cards.isEmpty
                ? "マニュアルを読み込めません（\(error.localizedDescription)）"
                : "最新に更新できません。端末に保存した内容を表示しています"
        }
    }

    private func isAdmin(token: String) async throws -> Bool {
        let data = try await request("rest/v1/rpc/is_manual_admin", method: "POST", body: Data("{}".utf8), token: token)
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    // MARK: 編集のログイン

    func adminSignIn(email: String, password: String) async throws {
        let session = try await AuthManager.passwordSession(email: email, password: password)
        guard try await isAdmin(token: session.accessToken) else { throw ManualError.notAdmin }
        adminSession = session
        editing = true
    }

    /// 編集を終える（管理者ログインも破棄する）
    func endEditing() {
        editing = false
        adminSession = nil
    }

    /// 書き込みに使うトークン（管理者ログイン中ならそれ、共通ログインが管理者ならそれ）
    private func editToken() async throws -> String {
        if let s = adminSession {
            guard s.expiresAt.timeIntervalSinceNow > 30 else {
                adminSession = nil
                editing = false
                throw ManualError.adminExpired
            }
            return s.accessToken
        }
        guard sessionIsAdmin else { throw ManualError.notAdmin }
        return try await auth.accessToken()
    }

    // MARK: 保存・削除・並べ替え

    func save(_ card: ManualCard) async throws {
        let token = try await editToken()
        var c = card
        c.title = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 新しいカード、またはカテゴリを移したカードは、そのカテゴリの最後に並べる
        if self.card(c.id)?.category != c.category {
            c.sort_order = nextSortOrder(in: c.category)
        }
        let data = try await request("rest/v1/manual_cards", method: "POST",
                                     query: [URLQueryItem(name: "on_conflict", value: "id")],
                                     body: try JSONEncoder().encode(CardPayload(c)),
                                     headers: ["Prefer": "resolution=merge-duplicates,return=representation"],
                                     token: token)
        if let saved = try? ISODate.decoder.decode([ManualCard].self, from: data).first { c = saved }
        if let i = cards.firstIndex(where: { $0.id == c.id }) { cards[i] = c } else { cards.append(c) }
        ManualCache.saveCards(cards)
    }

    private func nextSortOrder(in category: ManualCategory) -> Int {
        (cards(in: category).map(\.sort_order).max() ?? -1) + 1
    }

    func delete(_ card: ManualCard) async throws {
        let token = try await editToken()
        _ = try await request("rest/v1/manual_cards", method: "DELETE",
                              query: [SupabaseRequest.eq("id", card.id)],
                              headers: ["Prefer": "return=minimal"], token: token)
        cards.removeAll { $0.id == card.id }
        if run?.cardID == card.id { run = nil }
        ManualCache.saveCards(cards)
    }

    /// カードの並び順を1つ上下に動かす
    func move(_ card: ManualCard, by offset: Int) async throws {
        var list = cards(in: card.category)
        guard let i = list.firstIndex(where: { $0.id == card.id }) else { return }
        let j = i + offset
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        let token = try await editToken()
        for (order, c) in list.enumerated() where c.sort_order != order {
            _ = try await request("rest/v1/manual_cards", method: "PATCH",
                                  query: [SupabaseRequest.eq("id", c.id)],
                                  body: try JSONSerialization.data(withJSONObject: ["sort_order": order]),
                                  headers: ["Prefer": "return=minimal"], token: token)
            if let k = cards.firstIndex(where: { $0.id == c.id }) { cards[k].sort_order = order }
        }
        ManualCache.saveCards(cards)
    }

    // MARK: 変更前の版

    func versions(of cardID: UUID) async throws -> [ManualVersion] {
        try await fetchVersions([SupabaseRequest.eq("card_id", cardID)], limit: 30)
    }

    /// 削除したカード（今は無いもの）の最後の内容
    func deletedCards(in category: ManualCategory) async throws -> [ManualVersion] {
        let all = try await fetchVersions([SupabaseRequest.eq("action", "delete"),
                                           SupabaseRequest.eq("category", category.rawValue)], limit: 50)
        var seen = Set<UUID>()
        return all.filter { cardsByID[$0.card_id] == nil && seen.insert($0.card_id).inserted }
    }

    private func fetchVersions(_ filters: [URLQueryItem], limit: Int) async throws -> [ManualVersion] {
        let token = try await editToken()
        let data = try await request("rest/v1/manual_card_versions", query:
            [URLQueryItem(name: "select", value: "*")] + filters + [
                URLQueryItem(name: "order", value: "saved_at.desc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ], token: token)
        return try ISODate.decoder.decode([ManualVersion].self, from: data)
    }

    func restoreDeleted(_ v: ManualVersion) async throws {
        var c = ManualCard(category: v.category)
        c.id = v.card_id
        c.title = v.title
        c.steps = v.steps
        try await save(c)
    }

    // MARK: 写真

    /// 写真を縮小してアップロードし、ファイル名を返す
    func upload(_ image: UIImage) async throws -> String {
        let token = try await editToken()
        guard let jpeg = ManualImages.shrink(image).jpegData(compressionQuality: 0.78) else { throw ManualError.badImage }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await request("storage/v1/object/manual-images/\(name)", method: "POST", body: jpeg,
                              contentType: "image/jpeg", token: token)
        try? jpeg.write(to: ManualCache.imageFile(name), options: .atomic)
        if let img = UIImage(data: jpeg) { imageMemory.setObject(img, forKey: name as NSString) }
        return name
    }

    /// 端末内にあればそれを、無ければダウンロードして返す（読み込みと画像の展開は裏で行い、画面を止めない）
    func image(_ name: String) async -> UIImage? {
        if let img = imageMemory.object(forKey: name as NSString) { return img }
        let file = ManualCache.imageFile(name)
        var img = await ManualImages.decodeFile(file)
        if img == nil, let data = await downloadImage(name) {
            try? data.write(to: file, options: .atomic)
            img = await ManualImages.decode(data)
        }
        if let img { imageMemory.setObject(img, forKey: name as NSString) }
        return img
    }

    /// 写真をダウンロードする（token を渡さなければ、その場でログインのトークンを取る）
    private func downloadImage(_ name: String, token: String? = nil) async -> Data? {
        let usable: String
        if let token {
            usable = token
        } else if let fresh = try? await auth.accessToken() {
            usable = fresh
        } else {
            return nil
        }
        return try? await request("storage/v1/object/authenticated/manual-images/\(name)", token: usable)
    }

    /// 回線が切れても見られるように、まだ端末に無い写真を先に保存しておく
    /// （保存するだけで画像は展開しない。4枚ずつ同時にダウンロードする）
    private func prefetchImages(token: String) async {
        let missing = Set(cards.flatMap { $0.steps.compactMap(\.image) })
            .filter { !FileManager.default.fileExists(atPath: ManualCache.imageFile($0).path) }
        for batch in Array(missing).chunked(4) {
            await withTaskGroup(of: Void.self) { group in
                for name in batch {
                    group.addTask { @MainActor in
                        if let data = await self.downloadImage(name, token: token) {
                            try? data.write(to: ManualCache.imageFile(name), options: .atomic)
                        }
                    }
                }
            }
        }
    }

    // MARK: 通信

    private func request(_ path: String,
                         method: String = "GET",
                         query: [URLQueryItem] = [],
                         body: Data? = nil,
                         contentType: String = "application/json",
                         headers: [String: String] = [:],
                         token: String) async throws -> Data {
        var req = SupabaseRequest.make(path: path, method: method, query: query, body: body, bearer: token,
                                       headers: headers.merging(["Content-Type": contentType]) { $1 })
        req.timeoutInterval = 30
        let (data, resp) = try await SupabaseTrust.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 || code == 403, adminSession != nil || sessionIsAdmin, method != "GET" {
                throw ManualError.notAdmin
            }
            throw APIError.http(code, SupabaseRequest.bodyText(data))
        }
        return data
    }

    /// サーバーへ送るカードの形
    private struct CardPayload: Encodable {
        let id: UUID
        let category: String
        let title: String
        let steps: [ManualStep]
        let sort_order: Int

        init(_ c: ManualCard) {
            id = c.id
            category = c.category.rawValue
            title = c.title
            steps = c.steps
            sort_order = c.sort_order
        }
    }
}

// MARK: - 端末内保存（カードの JSON と写真ファイル）

enum ManualCache {
    private static let baseDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let cardsFile = baseDir.appendingPathComponent("manual-cards.json")

    private static let imageDir: URL = {
        let dir = baseDir.appendingPathComponent("manual-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func imageFile(_ name: String) -> URL { imageDir.appendingPathComponent(name) }

    static func loadCards() -> [ManualCard] {
        guard let data = try? Data(contentsOf: cardsFile) else { return [] }
        return (try? ISODate.decoder.decode([ManualCard].self, from: data)) ?? []
    }

    static func saveCards(_ cards: [ManualCard]) {
        if let data = try? ISODate.encoder.encode(cards) {
            try? data.write(to: cardsFile, options: .atomic)
        }
    }
}

// MARK: - 写真の加工

enum ManualImages {
    /// 長い辺を maxSide 以下に縮小する
    static func shrink(_ image: UIImage, maxSide: CGFloat = 1600) -> UIImage {
        let s = image.size
        let scale = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// ファイルを読み込んで、表示できる状態まで展開する（メインスレッドの外で）
    static func decodeFile(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return await prepared(data)
        }.value
    }

    /// データを表示できる状態まで展開する（メインスレッドの外で）
    static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { await prepared(data) }.value
    }

    private static func prepared(_ data: Data) async -> UIImage? {
        guard let img = UIImage(data: data) else { return nil }
        return await img.byPreparingForDisplay() ?? img
    }
}

enum ManualError: LocalizedError {
    case notAdmin, adminExpired, badImage

    var errorDescription: String? {
        switch self {
        case .notAdmin: return "このアカウントには編集の権限がありません"
        case .adminExpired: return "編集用のログインが切れました。もう一度ログインしてください"
        case .badImage: return "写真を読み込めませんでした"
        }
    }
}

extension Array {
    /// size 個ずつに分ける
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
