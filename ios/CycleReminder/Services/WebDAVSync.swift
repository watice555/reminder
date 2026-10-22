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
    private var useMoveForCreation = false
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
        if remote.snapshot == nil, useMoveForCreation {
            let staged = try settings.baseURL().appendingPathComponent("upload-\(UUID().uuidString).json")
            do {
                let (_, uploaded) = try await request("PUT", url: staged, body: snapshot.encoded(),
                                                     headers: ["Content-Type": "application/json; charset=utf-8"])
                try check(uploaded, allowed: [201])
                let destination = try settings.baseURL().appendingPathComponent("sync-v1.json")
                let (_, moved) = try await request("MOVE", url: staged,
                    headers: ["Destination": destination.absoluteString, "Overwrite": "F"])
                try check(moved, allowed: [201])
            } catch {
                // Only clean our random staging path, never the shared destination.
                _ = try? await request("DELETE", url: staged)
                throw error
            }
            return
        }
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
    // Use different bytes for each PUT: a repeated identical write can hide an ignored condition.
    @discardableResult
    func testWriteSafety() async throws -> String {
        let url = try settings.baseURL().appendingPathComponent("probe-\(UUID().uuidString).txt")
        useMoveForCreation = false
        var fallbackPassed = false
        var trace: [String] = []
        var cleanupURLs: [URL] = []
        var failure: String?
        var lastResponseBody = Data()

        func send(_ label: String, _ method: String, to target: URL, body: Data? = nil,
                  headers: [String: String] = [:]) async throws -> HTTPURLResponse {
            do {
                let (data, response) = try await request(method, url: target, body: body, headers: headers)
                lastResponseBody = data
                var line = "\(label)：HTTP \(response.statusCode)"
                // Only include numeric retry delays, never arbitrary server headers or response bodies.
                if let value = response.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Int(value), seconds >= 0 {
                    line += "（建议 \(seconds) 秒后重试）"
                }
                trace.append(line)
                return response
            } catch {
                let detail: String
                if let error = error as? URLError {
                    switch error.code {
                    case .timedOut: detail = "网络超时"
                    case .notConnectedToInternet: detail = "设备离线"
                    case .cancelled: detail = "请求取消"
                    default: detail = "网络错误（\(error.code.rawValue)）"
                    }
                } else { detail = "请求未取得有效响应" }
                trace.append("\(label)：\(detail)")
                throw WebDAVError.message("\(label)失败：\(detail)。尚不能判断服务器是否支持条件写入。")
            }
        }
        func checkProbe(_ response: HTTPURLResponse, allowed: Set<Int>, step: String) throws {
            guard !allowed.contains(response.statusCode) else { return }
            let reason: String
            switch response.statusCode {
            case 401, 403: reason = "认证或权限不足，请检查应用密码和目录权限"
            case 429: reason = "服务器限流，请等待后重试"
            case 500...599: reason = "服务器暂时异常，请稍后重试"
            case 300...399: reason = "服务器要求重定向，请检查最终 HTTPS 地址"
            case 404, 409: reason = "测试文件或目录不可用，请稍后重试"
            default: reason = "服务器返回非预期响应"
            }
            throw WebDAVError.message("\(step)：\(reason)（HTTP \(response.statusCode)）。尚不能确认条件写入能力。")
        }
        func readProbe(_ label: String, at target: URL) async throws -> Data {
            let response = try await send(label, "GET", to: target)
            try checkProbe(response, allowed: [200], step: label)
            return lastResponseBody
        }
        do {
            let directory = try await send("准备目录", "MKCOL", to: settings.baseURL())
            try checkProbe(directory, allowed: [201, 405], step: "准备目录")
            let initial = try await send("创建测试文件", "PUT", to: url, body: Data("initial".utf8),
                                         headers: ["If-None-Match": "*", "Content-Type": "text/plain"])
            try checkProbe(initial, allowed: [200, 201, 204], step: "创建测试文件")
            cleanupURLs.append(url)
            let duplicate = try await send("防止重复创建（If-None-Match）", "PUT", to: url,
                                           body: Data("must-not-replace-initial".utf8), headers: ["If-None-Match": "*"])
            try checkProbe(duplicate, allowed: Set(200...299).union([412]), step: "防止重复创建检查")
            let mismatch = try await send("拒绝错误版本（If-Match）", "PUT", to: url,
                                          body: Data("must-not-replace-with-wrong-version".utf8),
                                          headers: ["If-Match": "\"nonexistent-\(UUID().uuidString)\""])
            try checkProbe(mismatch, allowed: Set(200...299).union([412]), step: "错误版本检查")
            guard mismatch.statusCode == 412 else {
                let ignored = [("If-None-Match", duplicate.statusCode), ("If-Match", mismatch.statusCode)]
                    .filter { $0.1 != 412 }.map { "\($0.0) 返回 HTTP \($0.1)" }.joined(separator: "；")
                throw WebDAVError.message("服务器接受了应被拒绝的测试写入（\(ignored)，预期 412）。当前服务未通过防覆盖检查，已停止同步。正式任务文件未写入。")
            }
            if duplicate.statusCode != 412 {
                trace.append("首次创建改用 MOVE + Overwrite: F，继续验证防覆盖能力")
                let source = try settings.baseURL().appendingPathComponent("probe-move-\(UUID().uuidString).txt")
                let target = try settings.baseURL().appendingPathComponent("probe-target-\(UUID().uuidString).txt")
                cleanupURLs.append(source)
                let staged = try await send("创建移动测试源", "PUT", to: source, body: Data("move-probe".utf8))
                try checkProbe(staged, allowed: [201], step: "创建移动测试源")
                let destinationBefore = try await readProbe("读取移动前目标内容", at: url)
                let refused = try await send("禁止移动覆盖已有文件", "MOVE", to: source,
                    headers: ["Destination": url.absoluteString, "Overwrite": "F"])
                guard [409, 412].contains(refused.statusCode) else {
                    try checkProbe(refused, allowed: Set(200...299), step: "移动防覆盖检查")
                    throw WebDAVError.message("服务器忽略 MOVE 的禁止覆盖条件（HTTP \(refused.statusCode)，预期 412），不能安全创建同步文件。正式任务文件未写入。")
                }
                let destinationAfter = try await readProbe("核验已有目标未被覆盖", at: url)
                let sourceAfter = try await readProbe("核验移动源仍然存在", at: source)
                guard destinationBefore == destinationAfter, sourceAfter == Data("move-probe".utf8) else {
                    throw WebDAVError.message("服务器报告移动冲突，但测试文件内容发生变化，防覆盖验证失败。正式任务文件未写入。")
                }
                trace.append("冲突后内容核验通过：目标未变，源文件保留")
                cleanupURLs.append(target)
                let moved = try await send("移动到不存在的目标", "MOVE", to: source,
                    headers: ["Destination": target.absoluteString, "Overwrite": "F"])
                try checkProbe(moved, allowed: [201], step: "移动创建检查")
                let movedBody = try await readProbe("核验新目标内容", at: target)
                let oldSource = try await send("核验移动源已移除", "GET", to: source)
                guard movedBody == Data("move-probe".utf8), oldSource.statusCode == 404 else {
                    throw WebDAVError.message("移动成功响应与实际文件状态不一致，已停止同步。")
                }
                fallbackPassed = true
            }
        } catch { failure = error.localizedDescription }

        for cleanupURL in cleanupURLs {
            do {
                let removed = try await send("清理测试文件", "DELETE", to: cleanupURL)
                try checkProbe(removed, allowed: [200, 204, 404], step: "清理测试文件")
            } catch {
                let cleanup = "临时文件清理未完成：\(cleanupURL.lastPathComponent)。可稍后在坚果云 CycleReminder 目录删除此测试文件。"
                failure = [failure, cleanup].compactMap { $0 }.joined(separator: "\n")
            }
        }
        let report = "检查记录：\n" + trace.joined(separator: "\n")
        if let failure { throw WebDAVError.message(failure + "\n\n" + report) }
        useMoveForCreation = fallbackPassed
        return report
    }
}
