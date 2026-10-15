import Foundation
import Security
import Observation

// MARK: - Keychain（ログイン情報の保存）

enum Keychain {
    private static let service = "com.bestdelight.eldiavisitor"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ data: Data) {
        delete()
        var q = baseQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> Data? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - エラー

enum APIError: LocalizedError {
    case notLoggedIn
    case badLogin
    case http(Int, String)

    /// サーバー関数がまだ用意されていない（データベースの更新前）
    var isMissingFunction: Bool {
        if case .http(let code, let body) = self { return code == 404 && body.contains("PGRST202") }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "ログインしてください"
        case .badLogin: return "メールアドレスまたはパスワードが違います"
        case .http(let code, let body): return "通信エラー（\(code)）\(body.prefix(120))"
        }
    }
}

// MARK: - Supabase へのリクエスト作成（ログインと読み書きで共通）

enum SupabaseRequest {
    /// apikey と JSON の Content-Type を付けた URLRequest。bearer があれば Authorization も付ける
    static func make(path: String,
                     method: String,
                     query: [URLQueryItem] = [],
                     body: Data? = nil,
                     bearer: String? = nil,
                     headers: [String: String] = [:]) -> URLRequest {
        var comps = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(AppConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    static func bodyText(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }
}

// MARK: - ログイン（共通ログイン = Supabase Auth）

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String
}

private struct TokenResponse: Decodable {
    struct User: Decodable { let email: String? }
    let access_token: String
    let refresh_token: String
    let expires_in: Double
    let user: User?
}

@MainActor
@Observable
final class AuthManager {
    private(set) var session: AuthSession?
    @ObservationIgnored private var refreshTask: Task<AuthSession, Error>?

    init() {
        if let data = Keychain.load(), let s = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = s
        }
    }

    var email: String { session?.email ?? "" }

    func signIn(email: String, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let s = try await token(grant: "password", body: body, fallbackEmail: email)
        store(s)
    }

    func signOut() {
        session = nil
        Keychain.delete()
    }

    /// 有効なアクセストークン（期限が近ければ更新）
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let s = session else { throw APIError.notLoggedIn }
        if !forceRefresh, s.expiresAt.timeIntervalSinceNow > 120 { return s.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> AuthSession {
        if let t = refreshTask { return try await t.value }
        guard let s = session else { throw APIError.notLoggedIn }
        let t = Task { () throws -> AuthSession in
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
            return try await self.token(grant: "refresh_token", body: body, fallbackEmail: s.email)
        }
        refreshTask = t
        defer { refreshTask = nil }
        do {
            let new = try await t.value
            store(new)
            return new
        } catch APIError.badLogin {
            signOut()
            throw APIError.notLoggedIn
        }
    }

    private func token(grant: String, body: Data, fallbackEmail: String) async throws -> AuthSession {
        let req = SupabaseRequest.make(path: "auth/v1/token",
                                       method: "POST",
                                       query: [URLQueryItem(name: "grant_type", value: grant)],
                                       body: body)
        let (data, resp) = try await SupabaseTrust.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 || code == 403 { throw APIError.badLogin }
        guard (200..<300).contains(code) else { throw APIError.http(code, SupabaseRequest.bodyText(data)) }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return AuthSession(accessToken: t.access_token,
                           refreshToken: t.refresh_token,
                           expiresAt: Date().addingTimeInterval(t.expires_in),
                           email: t.user?.email ?? fallbackEmail)
    }

    private func store(_ s: AuthSession) {
        session = s
        if let data = try? JSONEncoder().encode(s) { Keychain.save(data) }
    }
}

// MARK: - 集計（サーバー関数 visitor_stats の1行）

struct StatRow: Codable, AgeGenderCounts {
    let store: StoreID
    let segment: Segment
    let dow: Int
    /// 営業日の種類（1〜7＝月〜日、8＝祝前日、9＝祝日）
    let dtype: Int
    let hour: Int
    let party: Int
    let groups: Int
    let m10: Int, m20: Int, m30: Int, m40: Int, m50: Int, m60: Int
    let f10: Int, f20: Int, f30: Int, f40: Int, f50: Int, f60: Int

    /// この行の人数（男女合計）
    var people: Int { total }
}

struct TodayRow: Decodable, Equatable {
    let store: StoreID
    let total: Int
    let client_id: UUID?
}

/// サーバー関数 visitor_sync の結果。changed が false のときは版（v）だけが入る
struct SyncSnapshot: Decodable {
    let v: String
    let changed: Bool
    let recent: [VisitorLog]?
    let today: [TodayRow]?
}

/// よく使う組み合わせ（サーバー関数 visitor_frequent の1行）
struct FrequentCombo: Decodable, Hashable, Identifiable, AgeGenderCounts {
    let store: StoreID
    let segment: Segment
    let m10: Int, m20: Int, m30: Int, m40: Int, m50: Int, m60: Int
    let f10: Int, f20: Int, f30: Int, f40: Int, f50: Int, f60: Int
    /// 期間内に記録された回数
    let n: Int

    var id: String { "\(store.rawValue)-\(segment.rawValue)-\(summary)" }
    var summary: String { partySummary { count($0, $1) } }
    /// ボタンの文字（一般は客層を省く）
    var label: String { segment == .general ? summary : "\(summary) \(segment.label)" }
}

// MARK: - Supabase への読み書き

@MainActor
final class API {
    let auth: AuthManager
    init(auth: AuthManager) { self.auth = auth }

    /// 記録1組の取得に使う列
    private static let logColumns = "id,client_id,store,visited_at,segment,m10,m20,m30,m40,m50,m60,f10,f20,f30,f40,f50,f60"
    /// 一度に取得する最大件数（Supabase の上限に合わせる）
    private static let pageSize = 1000
    private static let table = "rest/v1/visitor_logs"

    /// ログイン中のトークンで送る。期限切れ（401）なら1回だけトークンを更新してやり直す
    private func send(path: String,
                      method: String = "GET",
                      query: [URLQueryItem] = [],
                      body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var retried = false
        while true {
            let token = try await auth.accessToken(forceRefresh: retried)
            var req = SupabaseRequest.make(path: path, method: method, query: query, body: body, bearer: token, headers: headers)
            req.timeoutInterval = 20
            let (data, resp) = try await SupabaseTrust.session.data(for: req)
            let http = resp as! HTTPURLResponse
            if http.statusCode == 401 && !retried { retried = true; continue }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode, SupabaseRequest.bodyText(data))
            }
            return (data, http)
        }
    }

    /// 1000件ずつ区切って、条件に合う行をすべて取得する
    private func fetchAllPages<T: Decodable>(_ query: [URLQueryItem]) async throws -> [T] {
        var all: [T] = []
        var offset = 0
        while true {
            let paging = [URLQueryItem(name: "offset", value: "\(offset)"),
                          URLQueryItem(name: "limit", value: "\(Self.pageSize)")]
            let (data, _) = try await send(path: Self.table, query: query + paging)
            let page = try ISODate.decoder.decode([T].self, from: data)
            all += page
            if page.count < Self.pageSize { return all }
            offset += Self.pageSize
        }
    }

    /// 期間を渡すサーバー関数（visitor_stats など）を呼ぶ
    private func callPeriodFunction(_ name: String, from: Date, to: Date) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["p_from": ISODate.string(from), "p_to": ISODate.string(to)])
        return try await send(path: "rest/v1/rpc/\(name)", method: "POST", body: body).0
    }

    /// 記録を送信（client_id が同じものは二重に登録されない）
    func insert(_ logs: [VisitorLog]) async throws {
        guard !logs.isEmpty else { return }
        let body = try ISODate.encoder.encode(logs.map(NewVisitorLog.init))
        _ = try await send(path: Self.table,
                           method: "POST",
                           query: [URLQueryItem(name: "on_conflict", value: "client_id")],
                           body: body,
                           headers: ["Prefer": "resolution=ignore-duplicates,return=minimal"])
    }

    func recent(store: StoreID, limit: Int = 5) async throws -> [VisitorLog] {
        let (data, _) = try await send(path: Self.table, query: [
            URLQueryItem(name: "select", value: Self.logColumns),
            URLQueryItem(name: "store", value: "eq.\(store.rawValue)"),
            URLQueryItem(name: "order", value: "visited_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return try ISODate.decoder.decode([VisitorLog].self, from: data)
    }

    func todayRows(since: Date) async throws -> [TodayRow] {
        try await fetchAllPages([
            URLQueryItem(name: "select", value: "store,total,client_id"),
            URLQueryItem(name: "visited_at", value: "gte.\(ISODate.string(since))"),
            URLQueryItem(name: "order", value: "visited_at.asc")
        ])
    }

    func delete(id: UUID) async throws {
        _ = try await send(path: Self.table,
                           method: "DELETE",
                           query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                           headers: ["Prefer": "return=minimal"])
    }

    /// 同期1回分（直前5組×2店舗＋今日の件数）。known に前回の版を渡すと、変化がなければ版だけが返る
    func sync(since: Date, known: String?) async throws -> SyncSnapshot {
        var params: [String: Any] = ["p_since": ISODate.string(since)]
        if let known { params["p_known"] = known }
        let body = try JSONSerialization.data(withJSONObject: params)
        let (data, _) = try await send(path: "rest/v1/rpc/visitor_sync", method: "POST", body: body)
        return try ISODate.decoder.decode(SyncSnapshot.self, from: data)
    }

    /// 店舗ごとの、よく使う組み合わせ（直近30日で3回以上・上位3つ）
    func frequent() async throws -> [FrequentCombo] {
        let body = try JSONSerialization.data(withJSONObject: ["p_days": 30, "p_limit": 3])
        let (data, _) = try await send(path: "rest/v1/rpc/visitor_frequent", method: "POST", body: body)
        return try JSONDecoder().decode([FrequentCombo].self, from: data)
    }

    func stats(from: Date, to: Date) async throws -> [StatRow] {
        try JSONDecoder().decode([StatRow].self, from: try await callPeriodFunction("visitor_stats", from: from, to: to))
    }

    /// 期間内（今日まで）の営業日の種類ごとの日数
    func dayCounts(from: Date, to: Date) async throws -> [Int: Int] {
        let raw = try JSONDecoder().decode([String: Int].self,
                                           from: try await callPeriodFunction("visitor_day_counts", from: from, to: to))
        var out: [Int: Int] = [:]
        for (k, v) in raw { if let t = Int(k) { out[t] = v } }
        return out
    }

    /// CSV 用：期間内の記録をすべて取得
    func logs(from: Date, to: Date) async throws -> [VisitorLog] {
        try await fetchAllPages([
            URLQueryItem(name: "select", value: Self.logColumns),
            URLQueryItem(name: "visited_at", value: "gte.\(ISODate.string(from))"),
            URLQueryItem(name: "and", value: "(visited_at.lt.\(ISODate.string(to)))"),
            URLQueryItem(name: "order", value: "visited_at.asc")
        ])
    }
}
