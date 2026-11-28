import CryptoKit
import Foundation

/// AWS credentials, read once from an `aws` CLI profile.
public struct AWSCredentials: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }

    /// `aws configure export-credentials --profile <name>`: works for static keys, SSO
    /// and assumed roles alike, so LectureJockey never parses ~/.aws itself.
    public static func fromProfile(_ profile: String) throws -> AWSCredentials {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["aws", "configure", "export-credentials", "--profile", profile, "--format", "process"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["AccessKeyId"] as? String, let secret = obj["SecretAccessKey"] as? String
        else { throw BedrockError.noCredentials(profile) }
        return AWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: obj["SessionToken"] as? String)
    }
}

/// AWS Signature Version 4 for one request.
public struct SigV4: Sendable {
    public let credentials: AWSCredentials
    public let region: String
    public let service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// Headers to add to the request: x-amz-date, (x-amz-security-token) and Authorization.
    /// `path` is the request path as sent (already percent-encoded); `query` is the raw query string.
    public func sign(method: String, host: String, path: String, query: String = "",
                     headers: [String: String], body: Data, date: Date = Date()) -> [String: String] {
        let amzDate = Self.format(date, "yyyyMMdd'T'HHmmss'Z'")
        let day = String(amzDate.prefix(8))
        var all = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespaces) }
        all["host"] = host
        all["x-amz-date"] = amzDate
        if let token = credentials.sessionToken { all["x-amz-security-token"] = token }

        let names = all.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(all[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalQuery = query.split(separator: "&").map(String.init).sorted().joined(separator: "&")
        // Every service but S3 encodes each path segment a second time for the canonical request.
        let canonicalPath = service == "s3" ? path : path.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }.joined(separator: "/")
        let canonical = [method, canonicalPath.isEmpty ? "/" : canonicalPath, canonicalQuery, canonicalHeaders,
                         signedHeaders, Self.hex(SHA256.hash(data: body))].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))

        var out = ["x-amz-date": amzDate,
                   "Authorization": "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"]
        if let token = credentials.sessionToken { out["x-amz-security-token"] = token }
        return out
    }

    /// RFC 3986 unreserved characters stay, everything else becomes %XX (uppercase).
    public static func uriEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// Claude on Amazon Bedrock through the Converse API, signed with SigV4.
public struct BedrockClient: Sendable {
    public let region: String
    public let signer: SigV4
    public var timeout: TimeInterval = 15

    public init(credentials: AWSCredentials, region: String) {
        self.region = region
        self.signer = SigV4(credentials: credentials, region: region, service: "bedrock")
    }

    public struct Usage: Sendable, Equatable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
    }

    /// Decoded once from the response and never mutated.
    public struct ToolUse: @unchecked Sendable {
        public let name: String
        public let input: [String: Any]
        public init(name: String, input: [String: Any]) { self.name = name; self.input = input }
    }

    public struct Reply: @unchecked Sendable {
        public let toolUses: [ToolUse]
        public let text: String
        public let stopReason: String
        public let usage: Usage
        public let latencyMs: Int
    }

    /// One Converse call. `body` is the Converse request JSON (system, messages, toolConfig, ...).
    public func converse(model: String, body: [String: Any]) throws -> Reply {
        let host = "bedrock-runtime.\(region).amazonaws.com"
        let path = "/model/\(SigV4.uriEncode(model))/converse"
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        let headers = ["content-type": "application/json"]
        for (k, v) in headers.merging(signer.sign(method: "POST", host: host, path: path, headers: headers, body: data), uniquingKeysWith: { $1 }) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (respData, status) = try HTTP.send(request)
        guard status == 200 else {
            throw BedrockError.http(status, String(decoding: respData.prefix(400), as: UTF8.self))
        }
        return try Self.parse(respData)
    }

    static func parse(_ data: Data) throws -> Reply {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [String: Any], let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { throw BedrockError.badResponse }
        var tools: [ToolUse] = []
        var text = ""
        for block in content {
            if let t = block["text"] as? String { text += t }
            if let tu = block["toolUse"] as? [String: Any], let name = tu["name"] as? String {
                tools.append(ToolUse(name: name, input: tu["input"] as? [String: Any] ?? [:]))
            }
        }
        let u = obj["usage"] as? [String: Any] ?? [:]
        let usage = Usage(inputTokens: u["inputTokens"] as? Int ?? 0, outputTokens: u["outputTokens"] as? Int ?? 0,
                          cacheReadTokens: u["cacheReadInputTokens"] as? Int ?? 0, cacheWriteTokens: u["cacheWriteInputTokens"] as? Int ?? 0)
        let latency = (obj["metrics"] as? [String: Any])?["latencyMs"] as? Int ?? 0
        return Reply(toolUses: tools, text: text, stopReason: obj["stopReason"] as? String ?? "", usage: usage, latencyMs: latency)
    }
}

public enum BedrockError: Error, CustomStringConvertible {
    case noCredentials(String)
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .noCredentials(let p): return "no AWS credentials for profile \(p) (aws configure export-credentials failed)"
        case .http(let code, let body): return "Bedrock HTTP \(code): \(body)"
        case .badResponse: return "Bedrock returned an unexpected response"
        }
    }
}

/// Synchronous HTTP for the watcher's serial queue.
enum HTTP {
    static func send(_ request: URLRequest) throws -> (Data, Int) {
        final class Box: @unchecked Sendable { var result: Result<(Data, Int), Error> = .failure(BedrockError.badResponse) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { box.result = .failure(error) }
            else { box.result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}
