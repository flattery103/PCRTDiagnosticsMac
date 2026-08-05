import Foundation
import Darwin
import PCRTCore

struct ServerAPIError: LocalizedError {
    let statusCode: Int?
    let message: String
    var errorDescription: String? { message }
}

struct UploadAcknowledgement {
    let uploadedNames: Set<String>
    let acknowledged: Bool
}

final class ServerAPIClient {
    private let baseURL = PCRTProduct.serverURL
    private let session: URLSession
    private(set) var claimToken: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchConfiguration(code: String) async throws -> SessionConfig {
        let normalized = try SessionCode.validate(code)
        let url = baseURL.appendingPathComponent("api/v1/sessions/\(normalized)")
        let data = try await requestData(URLRequest(url: url), timeout: 30)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerAPIError(statusCode: nil, message: "The PCRT server returned an invalid session configuration.")
        }
        let config = root["config"] as? [String: Any] ?? [:]
        let scanType = firstString(root["scan_type"], config["scan_type"], "quick").lowercased()
        let displayName = firstString(config["display_name"], root["scan_type"], "macOS Diagnostic Scan")
        let claimPath = firstString(root["claim_endpoint"], "/api/v1/sessions/\(normalized)/claim")
        let uploadPath = firstString(root["upload_endpoint"], "/api/v1/sessions/\(normalized)/reports")
        let limits = config["limits"] as? [String: Any] ?? [:]
        let overrides = config["overrides"] as? [String: Any] ?? [:]
        return SessionConfig(
            code: normalized,
            scanType: scanType,
            displayName: displayName,
            customerName: firstString(root["customer_name"]),
            technicianName: firstString(root["technician_name"]),
            uploadReports: (config["upload_reports"] as? Bool) ?? true,
            claimEndpoint: absoluteEndpoint(claimPath).absoluteString,
            uploadEndpoint: absoluteEndpoint(uploadPath).absoluteString,
            statusEndpoint: absoluteEndpoint("/api/v1/sessions/\(normalized)/status").absoluteString,
            cpuStressMinutes: firstPositiveInt(overrides, limits, key: "cpu_stress_minutes"),
            memoryPressurePercent: firstPositiveInt(overrides, limits, key: "memory_pressure_percent"),
            diskTestMB: firstPositiveInt(overrides, limits, key: "disk_test_mb"),
            gpuStressMinutes: firstPositiveInt(overrides, limits, key: "gpu_stress_minutes"),
            rawConfig: config.mapValues(JSONValue.from(any:))
        )
    }

    func claim(config: SessionConfig, computerName: String, clientID: String) async throws {
        let payload: [String: Any] = [
            "client_id": clientID,
            "computer_name": computerName,
            "client_version": clientVersion
        ]
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let data = try await jsonRequest(urlString: config.claimEndpoint, payload: payload, claimToken: nil, timeout: 30)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = root["claim_token"] as? String, !token.isEmpty else {
                    throw ServerAPIError(statusCode: nil, message: "The server claimed the session but did not return a claim token.")
                }
                claimToken = token
                return
            } catch {
                lastError = error
                if attempt == 1 { try? await Task.sleep(nanoseconds: 750_000_000) }
            }
        }
        throw lastError ?? ServerAPIError(statusCode: nil, message: "The session could not be claimed.")
    }

    func updateStatus(config: SessionConfig, status: String, progress: Int, stage: String, detail: String, computerName: String) async throws {
        guard let token = claimToken else { throw ServerAPIError(statusCode: nil, message: "The claim token is not available.") }
        _ = try await jsonRequest(urlString: config.statusEndpoint, payload: [
            "status": status,
            "computer_name": computerName,
            "client_version": clientVersion,
            "progress_percent": min(max(progress, 0), 100),
            "progress_stage": stage,
            "progress_detail": detail
        ], claimToken: token, timeout: 30)
    }

    func upload(config: SessionConfig, paths: ReportPaths, computerName: String) async throws -> UploadAcknowledgement {
        guard let token = claimToken else { throw ServerAPIError(statusCode: nil, message: "The claim token is not available.") }
        guard let url = URL(string: config.uploadEndpoint) else { throw ServerAPIError(statusCode: nil, message: "The upload endpoint is invalid.") }
        let boundary = "PCRTBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let multipartURL = FileManager.default.temporaryDirectory.appendingPathComponent("pcrt-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: multipartURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ServerAPIError(statusCode: nil, message: "The temporary multipart upload file could not be created.")
        }
        let output = try FileHandle(forWritingTo: multipartURL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: multipartURL)
        }

        func write(_ value: String) throws {
            try output.write(contentsOf: Data(value.utf8))
        }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }

        try field("computer_name", computerName)
        try field("client_version", clientVersion)
        try field("report_kind", "macos_diagnostic_report")
        for file in paths.requiredFiles {
            let fileURL = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ServerAPIError(statusCode: nil, message: "The required report file \(file.name) is missing at \(file.path).")
            }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(file.name)\"\r\nContent-Type: \(contentType(file.name))\r\n\r\n")
            do {
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
        try output.synchronize()
        try output.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-PCRT-Claim-Token")
        let data = try await uploadData(request, fromFile: multipartURL, timeout: 300)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerAPIError(statusCode: nil, message: "The server returned an invalid upload acknowledgement.")
        }
        let uploaded = (root["uploaded"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
        return UploadAcknowledgement(uploadedNames: Set(uploaded), acknowledged: (root["acknowledged"] as? Bool) ?? false)
    }

    private var clientVersion: String {
        "macOS \(PCRTProduct.version) (\(SystemArchitecture.current))"
    }

    private func jsonRequest(urlString: String, payload: [String: Any], claimToken: String?, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ServerAPIError(statusCode: nil, message: "The server endpoint is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let claimToken = claimToken { request.setValue(claimToken, forHTTPHeaderField: "X-PCRT-Claim-Token") }
        return try await requestData(request, timeout: timeout)
    }

    private func requestData(_ request: URLRequest, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var request = request
            request.timeoutInterval = timeout
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ServerAPIError(statusCode: nil, message: "The PCRT server did not return an HTTP response.")); return
                }
                let body = data ?? Data()
                guard (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: Self.apiError(status: http.statusCode, body: body)); return
                }
                continuation.resume(returning: body)
            }
            task.resume()
        }
    }

    private func uploadData(_ request: URLRequest, fromFile fileURL: URL, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var request = request
            request.timeoutInterval = timeout
            let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ServerAPIError(statusCode: nil, message: "The PCRT server did not return an HTTP response.")); return
                }
                let body = data ?? Data()
                guard (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: Self.apiError(status: http.statusCode, body: body)); return
                }
                continuation.resume(returning: body)
            }
            task.resume()
        }
    }

    private static func apiError(status: Int, body: Data) -> ServerAPIError {
        var message = HTTPURLResponse.localizedString(forStatusCode: status)
        if let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            message = (root["message"] as? String) ?? (root["error"] as? String) ?? message
        } else if let text = String(data: body, encoding: .utf8), !text.isEmpty {
            message = String(text.prefix(500))
        }
        return ServerAPIError(statusCode: status, message: message)
    }

    private func absoluteEndpoint(_ endpoint: String) -> URL {
        if let url = URL(string: endpoint), url.scheme != nil { return url }
        return URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: baseURL)!.absoluteURL
    }

    private func firstString(_ values: Any?...) -> String {
        for value in values {
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return ""
    }

    private func firstPositiveInt(_ first: [String: Any], _ second: [String: Any], key: String) -> Int {
        for source in [first, second] {
            if let value = source[key] as? Int, value > 0 { return value }
            if let value = source[key] as? NSNumber, value.intValue > 0 { return value.intValue }
        }
        return 0
    }

    private func contentType(_ name: String) -> String {
        name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".json") ? "application/json" : "text/plain"
    }
}

enum SystemArchitecture {
    static var current: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
    }
}
