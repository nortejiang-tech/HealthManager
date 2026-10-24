import Foundation

/// All errors are categories/status codes; server bodies and Authorization are never logged.
enum GarminAPIError: Error, Equatable, LocalizedError {
    case keyUnavailable, invalidKey, invalidToken, redirectRejected, transport, invalidResponse, operationInProgress
    case http(Int, retryAfter: TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .operationInProgress: return "正在同步，请等待完成后再更换密钥或断开连接"
        case .keyUnavailable: return "请先导入 Garmin Personal API Key"
        case .invalidKey: return "密钥文件格式不正确"
        case .invalidToken: return "认证响应格式无效"
        case .redirectRejected: return "已拒绝认证地址重定向"
        case .transport: return "Garmin 网络请求未完成，请稍后重试"
        case .invalidResponse: return "Garmin 响应格式无效"
        case .http(let status, _):
            if status == 401 { return "Garmin 认证已失效，请检查或重新导入密钥" }
            if status == 403 { return "Garmin 拒绝了此数据的访问权限" }
            if status == 429 { return "Garmin 请求受限，将等待后重试" }
            return "Garmin 服务返回 HTTP \(status)"
        }
    }
}

protocol GarminCredentialSource: Sendable {
    func read() throws -> String
}
protocol GarminHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
private final class GarminNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
final class GarminURLTransport: GarminHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: GarminNoRedirect(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GarminAPIError.invalidResponse }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as GarminAPIError { throw error }
        catch { throw GarminAPIError.transport }
    }
}

actor GarminClient {
    static let host = "personal.connectapi.garmin.cn"
    private let credentials: any GarminCredentialSource
    private let transport: any GarminHTTPTransport
    private var bearer: String?
    private var expiresAt = Date.distantPast
    init(credentials: any GarminCredentialSource, transport: any GarminHTTPTransport = GarminURLTransport()) {
        self.credentials = credentials; self.transport = transport
    }
    func invalidate() { bearer = nil; expiresAt = .distantPast }
    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 4096 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    private func token(now: Date, force: Bool = false) async throws -> String {
        if !force, let bearer, expiresAt.timeIntervalSince(now) > 3600 { return bearer }
        let key = try credentials.read()
        guard Self.validKey(key) else { throw GarminAPIError.invalidKey }
        var request = URLRequest(url: URL(string: "https://\(Self.host)/personalapitoken-service/personal-api/personal-api-key/token")!)
        request.httpMethod = "POST"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("ApiKey \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        try Self.check(response)
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let expiry = Self.expiry(value), expiry > now else { throw GarminAPIError.invalidToken }
        bearer = value; expiresAt = expiry
        return value
    }
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = GarminNormalizer.number(object["exp"]) else { return nil }
        // Only an expiry hint for a token received over TLS; not JWT signature validation.
        return Date(timeIntervalSince1970: exp)
    }
    func fetch(_ metric: GarminMetric, date: String, now: Date = Date()) async throws -> Data? {
        guard date.count == 10, date.allSatisfy({ $0.isNumber || $0 == "-" }) else { throw GarminAPIError.invalidResponse }
        let path: String
        switch metric {
        case .hrv: path = "/hrv-service/hrv/\(date)"
        case .sleep: path = "/sleep-service/sleep/dailySleep?date=\(date)"
        case .bodyBattery: path = "/wellness-service/wellness/bodyBattery/reports/daily?startDate=\(date)&endDate=\(date)&chunks=24"
        case .stress: path = "/usersummary-service/stats/stress/daily/\(date)/\(date)"
        }
        for attempt in 0...1 {
            let value = try await token(now: now, force: attempt == 1)
            var request = URLRequest(url: URL(string: "https://\(Self.host)\(path)")!)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request)
            if response.statusCode == 401, attempt == 0 { invalidate(); continue }
            try Self.check(response)
            if response.statusCode == 204 { return nil }
            return data
        }
        throw GarminAPIError.http(401, retryAfter: nil)
    }
    private static func check(_ response: HTTPURLResponse) throws {
        if (300...399).contains(response.statusCode) { throw GarminAPIError.redirectRejected }
        guard (200...299).contains(response.statusCode) else {
            var wait: TimeInterval?
            if let text = response.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Double(text), seconds.isFinite { wait = max(0, seconds) }
                else {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
                    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    wait = f.date(from: text).map { max(0, $0.timeIntervalSinceNow) }
                }
            }
            throw GarminAPIError.http(response.statusCode, retryAfter: wait)
        }
    }
}
