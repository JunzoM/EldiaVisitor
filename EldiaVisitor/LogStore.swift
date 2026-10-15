import Foundation
import Observation

struct DisplayLog: Identifiable, Hashable {
    let log: VisitorLog
    let isPending: Bool
    var id: UUID { log.dedupeKey }
}

struct DayCount {
    var groups = 0
    var people = 0
}

/// サーバーにある「今日（営業日）」の記録の、店舗ごとの集計
struct ServerTodaySummary {
    var count = DayCount()
    /// 二重に数えないための記録の識別子
    var keys = Set<UUID>()
}

/// 記録の保存・送信・直近履歴の管理。
/// 記録はまず端末内に保存し、通信できたら送信する（電波が悪くても記録が消えない）。
@MainActor
@Observable
final class LogStore {
    let api: API

    private(set) var pending: [VisitorLog] = []
    private(set) var serverRecent: [StoreID: [VisitorLog]] = [:]
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    /// サーバーから取った今日の記録（店舗ごとに集計済み。画面を描くたびに数え直さない）
    private var serverToday: [StoreID: ServerTodaySummary] = [:]
    @ObservationIgnored private var serverTodayRows: [TodayRow] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var todayStart = JST.startOfToday()

    /// 同期の間隔（未送信の再送＋最新の取得）
    private static let syncInterval: UInt64 = 10_000_000_000

    init(api: API) {
        self.api = api
        pending = Self.loadPending()
    }

    // MARK: 同期ループ（10秒ごと：未送信の再送＋最新の取得）

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(nanoseconds: Self.syncInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        serverRecent = [:]
        serverToday = [:]
        serverTodayRows = []
    }

    func syncNow() async {
        await flush()
        await refresh()
    }

    // MARK: 記録・削除

    func record(store: StoreID, draft: Draft) {
        guard draft.canRecord else { return }
        let log = VisitorLog(store: store, segment: draft.segment, counts: draft.counts, at: draft.visitDate())
        pending.append(log)
        savePending()
        Task { await self.syncNow() }
    }

    func delete(_ item: DisplayLog) async {
        if let i = pending.firstIndex(where: { $0.dedupeKey == item.id }) {
            pending.remove(at: i)
            savePending()
        }
        if !item.isPending {
            do {
                try await api.delete(id: item.log.id)
                lastError = nil
            } catch {
                lastError = "削除できませんでした：\(error.localizedDescription)"
            }
        }
        await refresh()
    }

    // MARK: 画面用

    func recent(for store: StoreID, limit: Int = 5) -> [DisplayLog] {
        let server = serverRecent[store] ?? []
        let serverKeys = Set(server.map(\.dedupeKey))
        let local = pending.filter { $0.store == store && !serverKeys.contains($0.dedupeKey) }
            .map { DisplayLog(log: $0, isPending: true) }
        let merged = local + server.map { DisplayLog(log: $0, isPending: false) }
        return Array(merged.sorted { $0.log.visited_at > $1.log.visited_at }.prefix(limit))
    }

    /// 今日（営業日）の組数・人数。サーバーの記録＋まだ送っていない記録（重複は除く）
    func today(for store: StoreID) -> DayCount {
        let start = JST.startOfToday()
        // 日付が変わったのにまだ最新を取れていないときは、サーバー分を数えない
        let server = start == todayStart ? (serverToday[store] ?? ServerTodaySummary()) : ServerTodaySummary()
        var c = server.count
        for p in pending where p.store == store && p.visited_at >= start && !server.keys.contains(p.dedupeKey) {
            c.groups += 1
            c.people += p.total
        }
        return c
    }

    // MARK: 送受信

    private func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batch = pending
        do {
            try await api.insert(batch)
            let sent = Set(batch.map(\.dedupeKey))
            pending.removeAll { sent.contains($0.dedupeKey) }
            savePending()
            lastError = nil
        } catch {
            lastError = "未送信 \(pending.count)件（通信できたら自動で送ります）"
        }
    }

    func refresh() async {
        do {
            let start = JST.startOfToday()
            async let m = api.recent(store: .modern)
            async let l = api.recent(store: .luxury)
            async let t = api.todayRows(since: start)
            let (mr, lr, tr) = try await (m, l, t)
            // 内容が変わったときだけ更新する（10秒ごとの同期で画面を無駄に描き直さない）
            let recent: [StoreID: [VisitorLog]] = [.modern: mr, .luxury: lr]
            if recent != serverRecent { serverRecent = recent }
            if tr != serverTodayRows || start != todayStart {
                serverTodayRows = tr
                serverToday = Self.summarize(tr)
            }
            todayStart = start
            lastSync = Date()
            if pending.isEmpty, lastError != nil { lastError = nil }
        } catch APIError.notLoggedIn {
            stop()
        } catch {
            lastError = "最新の記録を取得できません（\(error.localizedDescription)）"
        }
    }

    private static func summarize(_ rows: [TodayRow]) -> [StoreID: ServerTodaySummary] {
        var out: [StoreID: ServerTodaySummary] = [:]
        for r in rows {
            var s = out[r.store] ?? ServerTodaySummary()
            s.count.groups += 1
            s.count.people += r.total
            if let k = r.client_id { s.keys.insert(k) }
            out[r.store] = s
        }
        return out
    }

    // MARK: 端末内保存

    private static let pendingURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-visitor-logs.json")
    }()

    private static func loadPending() -> [VisitorLog] {
        guard let data = try? Data(contentsOf: pendingURL) else { return [] }
        return (try? ISODate.decoder.decode([VisitorLog].self, from: data)) ?? []
    }

    private func savePending() {
        if let data = try? ISODate.encoder.encode(pending) {
            try? data.write(to: Self.pendingURL, options: .atomic)
        }
    }
}
