import Foundation
import WorkbenchCore

/// Loopback-only HTTP client for the Trajectory companion
/// (`Companion/server.py`). URLSession + Codable, no dependencies.
/// The simulator reaches the Mac host over loopback; provider and GitHub
/// credentials never leave the companion — this client carries none.
struct LiveCompanionClient: Sendable {
    var baseURL: URL

    init(host: String = "127.0.0.1", port: Int = Int(ProcessInfo.processInfo.environment["TRAJECTORY_COMPANION_PORT"] ?? "") ?? 8124) {
        baseURL = URL(string: "http://\(host):\(port)")!
    }

    // MARK: - Job records

    struct Job: Sendable, Hashable, Codable {
        var jobID: String
        var op: String
        var status: String
        var progress: Double
        var note: String?
        var result: JobResult?
        var error: String?
        var construction: LiveConstruction? = nil

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case op, status, progress, note, result, error, construction
        }

        var isTerminal: Bool {
            status == "succeeded" || status == "failed" || status == "cancelled"
        }
    }

    struct JobResult: Sendable, Hashable, Codable {
        var candidate: String?
        var commit: String?
        var tree: String?
        var passed: Bool?
        var failingStep: String?
        var scenarioStatus: String?
        var conclusion: String?
        var runID: Int64?
        var pushed: Bool?
        var deduplicated: Bool?

        enum CodingKeys: String, CodingKey {
            case candidate, commit, tree, passed
            case failingStep = "failing_step"
            case scenarioStatus = "scenario_status"
            case conclusion
            case runID = "run_id"
            case pushed, deduplicated
        }
    }

    struct Diff: Sendable, Hashable, Codable {
        var candidate: String
        var diff: String
        var changedFiles: Int

        enum CodingKeys: String, CodingKey {
            case candidate, diff
            case changedFiles = "changed_files"
        }
    }

    struct SourceFile: Sendable, Hashable, Codable {
        var candidate: String
        var path: String
        var text: String
    }

    enum ClientError: Error, LocalizedError {
        case transport(Error)
        case http(Int, String)
        case undecodable(String)

        var errorDescription: String? {
            switch self {
            case .transport(let e): "Companion unreachable: \(e.localizedDescription)"
            case .http(let code, let body): "Companion refused (\(code)): \(body)"
            case .undecodable(let what): "Companion reply unreadable: \(what)"
            }
        }
    }

    // MARK: - Transport

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return try await send(request)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await getURL(baseURL.appendingPathComponent(path))
    }

    /// GET with real query items. Paths carrying '?' must never go
    /// through appendingPathComponent: it percent-encodes the '?' into
    /// a path character and the backend receives the wrong route.
    private func getURL<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return try await send(request)
    }

    private func queryURL(_ path: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)
        guard components != nil else {
            throw ClientError.undecodable("bad companion path \(path)")
        }
        components!.queryItems = items
        guard let url = components!.url else {
            throw ClientError.undecodable("bad companion query \(path)")
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.undecodable("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(http.statusCode, String(body.prefix(300)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.undecodable("\(error)")
        }
    }

    // MARK: - Operations (one per companion endpoint)

    func createSession() async throws -> LiveSessionSnapshot {
        try await post("sessions", body: [:])
    }

    func session(_ sid: String) async throws -> LiveSessionSnapshot {
        try await get("sessions/\(sid)")
    }

    func importRepo(_ sid: String, repo: String, ref: String) async throws -> Job {
        try await post("sessions/\(sid)/import", body: ["repo": repo, "ref": ref])
    }

    struct AcceptReply: Sendable, Hashable, Codable {
        var changed: Bool
        var answer: LiveAnswer
        var intentRevision: Int

        enum CodingKeys: String, CodingKey {
            case changed, answer
            case intentRevision = "intent_revision"
        }
    }

    func accept(_ sid: String, answer: LiveAnswer) async throws -> AcceptReply {
        try await post("sessions/\(sid)/accept", body: ["answer": answer.rawValue])
    }

    func generate(_ sid: String, candidate: String) async throws -> Job {
        try await post("sessions/\(sid)/generate", body: ["candidate": candidate])
    }

    /// Explicit compound user action: accepts this rule and constructs one
    /// fresh candidate. It never checks, commits, pushes, or starts CI.
    func construct(_ sid: String, candidate: String, answer: LiveAnswer,
                   parentCandidate: String?, parentTree: String?) async throws -> Job {
        var body: [String: Any] = ["candidate": candidate, "answer": answer.rawValue]
        if let parentCandidate { body["parent_candidate"] = parentCandidate }
        if let parentTree { body["parent_tree"] = parentTree }
        return try await post("sessions/\(sid)/construct", body: body)
    }

    func check(_ sid: String, candidate: String) async throws -> Job {
        try await post("sessions/\(sid)/check", body: ["candidate": candidate])
    }

    func commit(_ sid: String, candidate: String, message: String) async throws -> Job {
        try await post("sessions/\(sid)/commit",
                       body: ["candidate": candidate, "message": message])
    }

    func push(_ sid: String, candidate: String) async throws -> Job {
        try await post("sessions/\(sid)/push", body: ["candidate": candidate])
    }

    func observe(_ sid: String, commit: String, timeout: Int = 600) async throws -> Job {
        try await post("sessions/\(sid)/observe",
                       body: ["commit": commit, "timeout_s": timeout])
    }

    func job(_ sid: String, _ jid: String) async throws -> Job {
        try await get("sessions/\(sid)/jobs/\(jid)")
    }

    func cancel(_ sid: String, _ jid: String) async throws -> Job {
        try await post("sessions/\(sid)/jobs/\(jid)/cancel", body: [:])
    }

    func diff(_ sid: String, candidate: String) async throws -> Diff {
        try await getURL(queryURL("sessions/\(sid)/diff", items: [
            URLQueryItem(name: "candidate", value: candidate),
        ]))
    }

    func source(_ sid: String, candidate: String, path: String) async throws -> SourceFile {
        try await getURL(queryURL("sessions/\(sid)/source", items: [
            URLQueryItem(name: "candidate", value: candidate),
            URLQueryItem(name: "path", value: path),
        ]))
    }

    /// Poll a job until it reaches a terminal state. Throws on task
    /// cancellation (callers cancel the companion job separately).
    func wait(_ sid: String, _ jid: String) async throws -> Job {
        while true {
            try Task.checkCancellation()
            let current = try await job(sid, jid)
            if current.isTerminal { return current }
            try await Task.sleep(for: .seconds(3))
        }
    }
}
