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

    private(set) var cards: [ManualCard] = []
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

    @ObservationIgnored private var imageMemory: [String: UIImage] = [:]

    init(auth: AuthManager) {
        self.auth = auth
        cards = Self.loadCache()
    }

    var canEdit: Bool { sessionIsAdmin || adminSession != nil }

    func cards(in category: ManualCategory) -> [ManualCard] {
        cards.filter { $0.category == category }
            .sorted { ($0.sort_order, $0.title) < ($1.sort_order, $1.title) }
    }

    func card(_ id: UUID) -> ManualCard? { cards.first { $0.id == id } }

    func search(_ text: String) -> [ManualCard] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        guard !words.isEmpty else { return [] }
        return cards.filter { c in words.allSatisfy { c.searchText.localizedCaseInsensitiveContains($0) } }
            .sorted { $0.title < $1.title }
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
            let list = try ISODate.decoder.decode([ManualCard].self, from: data)
            cards = list
            saveCache()
            lastLoaded = Date()
            lastError = nil
            sessionIsAdmin = (try? await isAdmin(token: token)) ?? sessionIsAdmin
            await prefetchImages()
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
        var comps = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(AppConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, resp) = try await SupabaseTrust.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 || code == 403 { throw APIError.badLogin }
        guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
        struct T: Decodable { let access_token: String; let refresh_token: String; let expires_in: Double }
        let t = try JSONDecoder().decode(T.self, from: data)
        let s = AuthSession(accessToken: t.access_token, refreshToken: t.refresh_token,
                            expiresAt: Date().addingTimeInterval(t.expires_in), email: email)
        guard try await isAdmin(token: s.accessToken) else { throw ManualError.notAdmin }
        adminSession = s
        editing = true
    }

    /// 編集を終える（管理者ログインも破棄する）
    func endEditing() {
        editing = false
        adminSession = nil
    }

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
        let isNew = self.card(c.id) == nil
        if isNew {
            c.sort_order = (cards(in: c.category).map(\.sort_order).max() ?? -1) + 1
        } else if let old = self.card(c.id), old.category != c.category {
            c.sort_order = (cards(in: c.category).map(\.sort_order).max() ?? -1) + 1
        }
        let body = try JSONEncoder().encode(Payload(c, includeID: true))
        let data = try await request("rest/v1/manual_cards", method: "POST",
                                     query: [URLQueryItem(name: "on_conflict", value: "id")],
                                     body: body,
                                     headers: ["Prefer": "resolution=merge-duplicates,return=representation"],
                                     token: token)
        if let saved = try? ISODate.decoder.decode([ManualCard].self, from: data).first { c = saved }
        if let i = cards.firstIndex(where: { $0.id == c.id }) { cards[i] = c } else { cards.append(c) }
        saveCache()
    }

    func delete(_ card: ManualCard) async throws {
        let token = try await editToken()
        _ = try await request("rest/v1/manual_cards", method: "DELETE",
                              query: [URLQueryItem(name: "id", value: "eq.\(card.id.uuidString.lowercased())")],
                              headers: ["Prefer": "return=minimal"], token: token)
        cards.removeAll { $0.id == card.id }
        if run?.cardID == card.id { run = nil }
        saveCache()
    }

    /// カードの並び順を1つ上下に動かす
    func move(_ card: ManualCard, by offset: Int) async throws {
        var list = cards(in: card.category)
        guard let i = list.firstIndex(where: { $0.id == card.id }) else { return }
        let j = i + offset
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        let token = try await editToken()
        for (n, c) in list.enumerated() where c.sort_order != n {
            _ = try await request("rest/v1/manual_cards", method: "PATCH",
                                  query: [URLQueryItem(name: "id", value: "eq.\(c.id.uuidString.lowercased())")],
                                  body: try JSONSerialization.data(withJSONObject: ["sort_order": n]),
                                  headers: ["Prefer": "return=minimal"], token: token)
            if let k = cards.firstIndex(where: { $0.id == c.id }) { cards[k].sort_order = n }
        }
        saveCache()
    }

    // MARK: 変更前の版

    func versions(of cardID: UUID) async throws -> [ManualVersion] {
        let token = try await editToken()
        let data = try await request("rest/v1/manual_card_versions", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "card_id", value: "eq.\(cardID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "saved_at.desc"),
            URLQueryItem(name: "limit", value: "30")
        ], token: token)
        return try ISODate.decoder.decode([ManualVersion].self, from: data)
    }

    /// 削除したカード（今は無いもの）の最後の内容
    func deletedCards(in category: ManualCategory) async throws -> [ManualVersion] {
        let token = try await editToken()
        let data = try await request("rest/v1/manual_card_versions", query: [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "action", value: "eq.delete"),
            URLQueryItem(name: "category", value: "eq.\(category.rawValue)"),
            URLQueryItem(name: "order", value: "saved_at.desc"),
            URLQueryItem(name: "limit", value: "50")
        ], token: token)
        let all = try ISODate.decoder.decode([ManualVersion].self, from: data)
        let alive = Set(cards.map(\.id))
        var seen = Set<UUID>()
        return all.filter { !alive.contains($0.card_id) && seen.insert($0.card_id).inserted }
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
        guard let jpeg = Self.shrink(image).jpegData(compressionQuality: 0.78) else { throw ManualError.badImage }
        let name = "\(UUID().uuidString.lowercased()).jpg"
        _ = try await request("storage/v1/object/manual-images/\(name)", method: "POST", body: jpeg,
                              contentType: "image/jpeg", token: token)
        try? jpeg.write(to: Self.imageFile(name), options: .atomic)
        imageMemory[name] = UIImage(data: jpeg)
        return name
    }

    /// 端末内にあればそれを、無ければダウンロードして返す
    func image(_ name: String) async -> UIImage? {
        if let img = imageMemory[name] { return img }
        let file = Self.imageFile(name)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            imageMemory[name] = img
            return img
        }
        guard let token = try? await auth.accessToken(),
              let data = try? await request("storage/v1/object/authenticated/manual-images/\(name)", token: token),
              let img = UIImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        imageMemory[name] = img
        return img
    }

    /// 回線が切れても見られるように、すべての写真を先に保存しておく
    private func prefetchImages() async {
        let names = Set(cards.flatMap { $0.steps.compactMap(\.image) })
        for n in names where !FileManager.default.fileExists(atPath: Self.imageFile(n).path) {
            _ = await image(n)
        }
    }

    private static func shrink(_ image: UIImage, maxSide: CGFloat = 1600) -> UIImage {
        let s = image.size
        let scale = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
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
        var comps = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(AppConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await SupabaseTrust.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 || code == 403, adminSession != nil || sessionIsAdmin, method != "GET" {
                throw ManualError.notAdmin
            }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private struct Payload: Encodable {
        let id: UUID
        let category: String
        let title: String
        let steps: [ManualStep]
        let sort_order: Int
        init(_ c: ManualCard, includeID: Bool) {
            id = c.id
            category = c.category.rawValue
            title = c.title
            steps = c.steps
            sort_order = c.sort_order
        }
    }

    // MARK: 端末内保存

    private static var baseDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var cacheURL: URL { baseDir.appendingPathComponent("manual-cards.json") }

    private static func imageFile(_ name: String) -> URL {
        let dir = baseDir.appendingPathComponent("manual-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func loadCache() -> [ManualCard] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? ISODate.decoder.decode([ManualCard].self, from: data)) ?? []
    }

    private func saveCache() {
        if let data = try? ISODate.encoder.encode(cards) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
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
