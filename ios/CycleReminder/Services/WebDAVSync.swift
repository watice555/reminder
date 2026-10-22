import Foundation
import Security
import CryptoKit

struct WebDAVSettings: Codable, Equatable {
    var server = "https://dav.jianguoyun.com/dav/"
    var username = ""
    var password = ""
    var automatic = false

    func baseURL() throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !username.isEmpty, !username.contains(":"), !password.isEmpty
        else { throw WebDAVError.message("请填写 HTTPS WebDAV 地址、账号和应用密码。") }
        return url.appendingPathComponent("CycleReminder", isDirectory: true)
    }

    var identity: String {
        let value = ((try? baseURL().absoluteString) ?? server) + "\n" + username
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum WebDAVError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum WebDAVKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.wuth.cyclereminder.webdav",
         kSecAttrAccount as String: "configuration"]
    }
    static func load() throws -> WebDAVSettings? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WebDAVError.message("无法读取钥匙串（\(status)），请解锁设备后重试。")
        }
        return try JSONDecoder().decode(WebDAVSettings.self, from: data)
    }
    static func save(_ settings: WebDAVSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WebDAVError.message("保存钥匙串失败（\(status)）。") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebDAVError.message("移除钥匙串配置失败（\(status)）。")
        }
    }
}

struct SyncSnapshot: Codable, Equatable {
    var tasks: [ReminderTask]
    var gracePercentage: Double

    init(tasks: [ReminderTask], gracePercentage: Double) {
        self.tasks = tasks.sorted { $0.id < $1.id }
        self.gracePercentage = gracePercentage
    }

    // Sync must reject damaged/future files rather than silently drop records as backup import does.
    static func decode(_ data: Data) throws -> SyncSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int, version == 4,
              let rows = object["tasks"] as? [[String: Any]],
              let grace = object["gracePercentage"] as? Double,
              StatisticsCalculator.validGrace(grace) == grace else {
            throw WebDAVError.message("云端文件格式不兼容或已损坏，已停止同步。")
        }
        let tasks = try BackupCodec.decode(data)
        guard tasks.count == rows.count, Set(tasks.map(\.id)).count == rows.count else {
            throw WebDAVError.message("云端任务包含损坏或重复记录，已停止同步。")
        }
        for (row, task) in zip(rows, tasks) {
            guard row["id"] as? String == task.id,
                  row["lastCompletedAt"] as? String == task.lastCompletedAt,
                  row["nextDueAt"] as? String == task.nextDueAt,
                  row["createdAt"] as? String == task.createdAt,
                  let completions = row["completions"] as? [[String: Any]], completions.count == task.completions.count,
                  let reminders = row["reminders"] as? [[String: Any]], reminders.count == task.reminders.count
            else { throw WebDAVError.message("云端记录缺失或不合法，已停止同步。") }
            let completionIDs = Set(task.completions.map(\.id))
            let reminderIDs = Set(task.reminders.map(\.id))
            guard completions.allSatisfy({ item in
                guard let id = item["id"] as? String, !id.isEmpty,
                      let completed = item["completedAt"] as? String, ISODate.parse(completed) != nil,
                      let due = item["scheduledDueAt"] as? String, ISODate.parse(due) != nil else { return false }
                return completionIDs.contains(id)
            }), reminders.allSatisfy({ item in
                guard let id = item["id"] as? String, !id.isEmpty else { return false }
                return reminderIDs.contains(id)
            }) else { throw WebDAVError.message("云端历史或提醒记录不合法，已停止同步。") }
        }
        return SyncSnapshot(tasks: tasks, gracePercentage: grace)
    }
    func encoded() throws -> Data { try BackupCodec.encode(tasks, gracePercentage: gracePercentage) }

    static func merge(base: SyncSnapshot?, local: SyncSnapshot, remote: SyncSnapshot) throws -> SyncSnapshot {
        let b = Dictionary(uniqueKeysWithValues: (base?.tasks ?? []).map { ($0.id, $0) })
        let l = Dictionary(uniqueKeysWithValues: local.tasks.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: remote.tasks.map { ($0.id, $0) })
        var merged: [ReminderTask] = []
        for id in Set(b.keys).union(l.keys).union(r.keys).sorted() {
            let value: ReminderTask?
            if l[id] == r[id] { value = l[id] }
            else if l[id] == b[id] { value = r[id] }
            else if r[id] == b[id] { value = l[id] }
            else { throw WebDAVError.message("任务“\(l[id]?.name ?? r[id]?.name ?? id)”在两端有不同修改。请选择保留哪一端。") }
            if let value { merged.append(value) }
        }
        let grace: Double
        if local.gracePercentage == remote.gracePercentage { grace = local.gracePercentage }
        else if local.gracePercentage == base?.gracePercentage { grace = remote.gracePercentage }
        else if remote.gracePercentage == base?.gracePercentage { grace = local.gracePercentage }
        else { throw WebDAVError.message("两端全局宽限设置不同。请选择保留哪一端。") }
        return SyncSnapshot(tasks: merged, gracePercentage: grace)
    }
}

struct SyncBaseline: Codable {
    var identity: String
    var snapshot: SyncSnapshot
    var syncedAt: Date
}

struct WebDAVRemote {
    var snapshot: SyncSnapshot?
    var etag: String?
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class WebDAVClient {
    private let settings: WebDAVSettings
    private let session: URLSession
    private let delegate = NoRedirect()
    init(settings: WebDAVSettings, session: URLSession? = nil) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func request(_ method: String, url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Basic " + Data("\(settings.username):\(settings.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WebDAVError.message("服务器响应无效。") }
        guard data.count <= 20 * 1024 * 1024 else { throw WebDAVError.message("同步文件超过 20 MB，已停止。") }
        return (data, response)
    }
    private func check(_ response: HTTPURLResponse, allowed: Set<Int>) throws {
        guard allowed.contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401, 403: message = "认证或权限不足，请检查账号及应用密码。"
            case 409, 412: message = "云端已变化或目录不存在，请重新同步。"
            case 429: message = "请求过于频繁，请稍后重试。"
            case 300...399: message = "服务器发生重定向，请填写最终 HTTPS WebDAV 地址。"
            default: message = "WebDAV 请求失败（HTTP \(response.statusCode)）。"
            }
            throw WebDAVError.message(message)
        }
    }
    func prepareDirectory() async throws {
        let (_, response) = try await request("MKCOL", url: settings.baseURL())
        try check(response, allowed: [201, 405])
    }
    func read() async throws -> WebDAVRemote {
        let (data, response) = try await request("GET", url: settings.baseURL().appendingPathComponent("sync-v1.json"))
        if response.statusCode == 404 { return WebDAVRemote(snapshot: nil, etag: nil) }
        try check(response, allowed: [200])
        return WebDAVRemote(snapshot: try SyncSnapshot.decode(data), etag: response.value(forHTTPHeaderField: "ETag"))
    }
    func write(_ snapshot: SyncSnapshot, replacing remote: WebDAVRemote) async throws {
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        if remote.snapshot != nil {
            guard let tag = remote.etag, tag.hasPrefix("\""), tag.hasSuffix("\"") else {
                throw WebDAVError.message("服务器未提供强 ETag，无法安全覆盖云端文件。")
            }
            headers["If-Match"] = tag
        } else { headers["If-None-Match"] = "*" }
        let (_, response) = try await request("PUT", url: settings.baseURL().appendingPathComponent("sync-v1.json"), body: snapshot.encoded(), headers: headers)
        try check(response, allowed: [200, 201, 204])
    }
    // Validate conditional writes using a disposable file, never the user's sync file.
    func testWriteSafety() async throws {
        try await prepareDirectory()
        let url = try settings.baseURL().appendingPathComponent("probe-\(UUID().uuidString).txt")
        let body = Data("CycleReminder connection test".utf8)
        let (_, created) = try await request("PUT", url: url, body: body, headers: ["If-None-Match": "*"])
        try check(created, allowed: [200, 201, 204])
        do {
            let (_, duplicate) = try await request("PUT", url: url, body: body, headers: ["If-None-Match": "*"])
            let (_, mismatch) = try await request("PUT", url: url, body: body, headers: ["If-Match": "\"nonexistent-\(UUID().uuidString)\""])
            guard duplicate.statusCode == 412, mismatch.statusCode == 412 else {
                throw WebDAVError.message("服务器不支持安全的条件写入，已停止同步以避免覆盖。")
            }
            let (_, removed) = try await request("DELETE", url: url)
            try check(removed, allowed: [200, 204, 404])
        } catch {
            _ = try? await request("DELETE", url: url)
            throw error
        }
    }
}
