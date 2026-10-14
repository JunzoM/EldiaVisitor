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

/// 記録の保存・送信・直近履歴の管理。
/// 記録はまず端末内に保存し、通信できたら送信する（電波が悪くても記録が消えない）。
@MainActor
@Observable
final class LogStore {
    let api: API

    private(set) var pending: [VisitorLog] = []
    private(set) var serverRecent: [StoreID: [VisitorLog]] = [:]
    private(set) var serverToday: [TodayRow] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var todayStart = JST.startOfToday()

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
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        serverRecent = [:]
        serverToday = []
    }

    func syncNow() async {
        await flush()
        await refresh()
    }

    // MARK: 記録・削除

    func record(store: StoreID, draft: Draft) {
        guard draft.canRecord else { return }
        let log = VisitorLog(store: store, segment: draft.segment, counts: draft.counts,
                             at: Date().addingTimeInterval(-Double(draft.minutesAgo) * 60))
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

    func today(for store: StoreID) -> DayCount {
        var c = DayCount()
        let start = JST.startOfToday()
        var keys = Set<UUID>()
        if start == todayStart {
            for r in serverToday where r.store == store {
                c.groups += 1
                c.people += r.total
                if let k = r.client_id { keys.insert(k) }
            }
        }
        for p in pending where p.store == store && p.visited_at >= start && !keys.contains(p.dedupeKey) {
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
            serverRecent = [.modern: mr, .luxury: lr]
            serverToday = tr
            todayStart = start
            lastSync = Date()
            if pending.isEmpty { lastError = nil }
        } catch APIError.notLoggedIn {
            stop()
        } catch {
            lastError = "最新の記録を取得できません（\(error.localizedDescription)）"
        }
    }

    // MARK: 端末内保存

    private static var pendingURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-visitor-logs.json")
    }

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
