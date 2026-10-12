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

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "ログインしてください"
        case .badLogin: return "メールアドレスまたはパスワードが違います"
        case .http(let code, let body): return "通信エラー（\(code)）\(body.prefix(120))"
        }
    }
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
        var comps = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(AppConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 || code == 403 { throw APIError.badLogin }
        guard (200..<300).contains(code) else { throw APIError.http(code, String(data: data, encoding: .utf8) ?? "") }
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

struct StatRow: Codable {
    let store: StoreID
    let segment: Segment
    let dow: Int
    let hour: Int
    let party: Int
    let groups: Int
    let m10: Int, m20: Int, m30: Int, m40: Int, m50: Int, m60: Int
    let f10: Int, f20: Int, f30: Int, f40: Int, f50: Int, f60: Int

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
    var people: Int { male + female }
}

struct TodayRow: Decodable {
    let store: StoreID
    let total: Int
    let client_id: UUID?
}

// MARK: - Supabase への読み書き

@MainActor
final class API {
    let auth: AuthManager
    init(auth: AuthManager) { self.auth = auth }

    private func send(path: String,
                      method: String = "GET",
                      query: [URLQueryItem] = [],
                      body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var retried = false
        while true {
            let token = try await auth.accessToken(forceRefresh: retried)
            var comps = URLComponents(url: AppConfig.supabaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { comps.queryItems = query }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.timeoutInterval = 20
            req.setValue(AppConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            if http.statusCode == 401 && !retried { retried = true; continue }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return (data, http)
        }
    }

    /// 記録を送信（client_id が同じものは二重に登録されない）
    func insert(_ logs: [VisitorLog]) async throws {
        guard !logs.isEmpty else { return }
        let body = try ISODate.encoder.encode(logs.map(NewVisitorLog.init))
        _ = try await send(path: "rest/v1/visitor_logs",
                           method: "POST",
                           query: [URLQueryItem(name: "on_conflict", value: "client_id")],
                           body: body,
                           headers: ["Prefer": "resolution=ignore-duplicates,return=minimal"])
    }

    func recent(store: StoreID, limit: Int = 5) async throws -> [VisitorLog] {
        let (data, _) = try await send(path: "rest/v1/visitor_logs", query: [
            URLQueryItem(name: "select", value: "id,client_id,store,visited_at,segment,m10,m20,m30,m40,m50,m60,f10,f20,f30,f40,f50,f60"),
            URLQueryItem(name: "store", value: "eq.\(store.rawValue)"),
            URLQueryItem(name: "order", value: "visited_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return try ISODate.decoder.decode([VisitorLog].self, from: data)
    }

    func todayRows(since: Date) async throws -> [TodayRow] {
        var all: [TodayRow] = []
        var offset = 0
        while true {
            let (data, _) = try await send(path: "rest/v1/visitor_logs", query: [
                URLQueryItem(name: "select", value: "store,total,client_id"),
                URLQueryItem(name: "visited_at", value: "gte.\(ISODate.string(since))"),
                URLQueryItem(name: "order", value: "visited_at.asc"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "limit", value: "1000")
            ])
            let page = try ISODate.decoder.decode([TodayRow].self, from: data)
            all += page
            if page.count < 1000 { return all }
            offset += 1000
        }
    }

    func delete(id: UUID) async throws {
        _ = try await send(path: "rest/v1/visitor_logs",
                           method: "DELETE",
                           query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                           headers: ["Prefer": "return=minimal"])
    }

    func stats(from: Date, to: Date) async throws -> [StatRow] {
        let body = try JSONSerialization.data(withJSONObject: ["p_from": ISODate.string(from), "p_to": ISODate.string(to)])
        let (data, _) = try await send(path: "rest/v1/rpc/visitor_stats", method: "POST", body: body)
        return try JSONDecoder().decode([StatRow].self, from: data)
    }

    /// CSV 用：期間内の記録をすべて取得
    func logs(from: Date, to: Date) async throws -> [VisitorLog] {
        var all: [VisitorLog] = []
        var offset = 0
        while true {
            let (data, _) = try await send(path: "rest/v1/visitor_logs", query: [
                URLQueryItem(name: "select", value: "id,client_id,store,visited_at,segment,m10,m20,m30,m40,m50,m60,f10,f20,f30,f40,f50,f60"),
                URLQueryItem(name: "visited_at", value: "gte.\(ISODate.string(from))"),
                URLQueryItem(name: "and", value: "(visited_at.lt.\(ISODate.string(to)))"),
                URLQueryItem(name: "order", value: "visited_at.asc"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "limit", value: "1000")
            ])
            let page = try ISODate.decoder.decode([VisitorLog].self, from: data)
            all += page
            if page.count < 1000 { return all }
            offset += 1000
        }
    }
}
