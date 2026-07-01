import BetterStreamingDomain
import Foundation
import Network
import RemoteFileSystem

public actor FTPRemoteClient: RemoteFileSystemClient {
    public nonisolated let capabilities = RemoteCapabilities(
        supportsByteRangeRead: true,
        supportsServerSideSearch: false,
        supportsStableFileID: false,
        supportsDirectoryModifiedTime: true,
        supportsBackgroundURLSession: false
    )

    private let host: String
    private let port: Int
    private let basePath: String
    private let username: String?
    private let password: String?

    public init(
        host: String,
        port: Int = 21,
        basePath: String = "",
        username: String? = nil,
        password: String? = nil
    ) {
        self.host = host
        self.port = port
        self.basePath = basePath
        self.username = username?.isEmpty == false ? username : nil
        self.password = password
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        try await withControlConnection(path: directory) { control in
            let path = resolvedPath(directory)
            let endpoint = try await control.enterPassiveMode()
            let data = try FTPDataConnection(host: endpoint.host, port: endpoint.port)
            defer { data.cancel() }   // NWConnection leaks its socket/FD unless cancelled
            try await data.connect()
            let reply = try await control.send("LIST \(Self.commandPath(path))")
            try Self.expectPreliminary(reply, path: directory)
            let listing = try await data.readAll()
            let final = try await control.readReply()
            try Self.expectComplete(final, path: directory)
            let text = String(data: listing, encoding: .utf8)
                ?? String(data: listing, encoding: .isoLatin1)
                ?? ""
            return FTPListParser.parse(text, directory: directory)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        try await withControlConnection(path: path) { control in
            let resolved = resolvedPath(path)
            let sizeReply = try await control.send("SIZE \(Self.commandPath(resolved))")
            if sizeReply.code == 213, let size = Int64(sizeReply.message.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                let modified = try? await modifiedDate(path: resolved, remotePath: path, control: control)
                return RemoteMetadata(
                    path: path,
                    kind: .file,
                    size: size,
                    modifiedAt: modified,
                    supportsRangeRead: true
                )
            }

            if let listed = try await listedEntry(for: path, control: control) {
                return RemoteMetadata(
                    path: path,
                    kind: listed.kind,
                    size: listed.kind == .file ? listed.size : nil,
                    modifiedAt: listed.modifiedAt,
                    contentType: listed.contentType,
                    supportsRangeRead: listed.kind == .file
                )
            }

            throw Self.error(from: sizeReply, path: path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw RemoteFileSystemError.unsupportedRange
        }
        guard range.upperBound > range.lowerBound else {
            return Data()
        }

        return try await withControlConnection(path: path) { control in
            let resolved = resolvedPath(path)
            let rest = try await control.send("REST \(range.lowerBound)")
            guard rest.code == 350 else {
                throw RemoteFileSystemError.unsupportedRange
            }

            let endpoint = try await control.enterPassiveMode()
            let data = try FTPDataConnection(host: endpoint.host, port: endpoint.port)
            defer { data.cancel() }   // also aborts the partial RETR on the throw paths
            try await data.connect()
            let reply = try await control.send("RETR \(Self.commandPath(resolved))")
            try Self.expectPreliminary(reply, path: path)
            let requested = range.upperBound - range.lowerBound
            let bytes = try await data.read(maxBytes: requested)
            return bytes
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        try await withControlConnection(path: path) { control in
            let resolved = resolvedPath(path)
            // Ask SIZE on THIS control connection before RETR. A nested stat() spun
            // up a second control connection, which per-IP-capped servers reject —
            // nil total then silently disabled the short-download corruption guard.
            let total = await Self.size(of: resolved, control: control)
            let endpoint = try await control.enterPassiveMode()
            let data = try FTPDataConnection(host: endpoint.host, port: endpoint.port)
            defer { data.cancel() }   // NWConnection leaks its socket/FD unless cancelled
            try await data.connect()
            let reply = try await control.send("RETR \(Self.commandPath(resolved))")
            try Self.expectPreliminary(reply, path: path)

            let directory = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tempURL = directory.appendingPathComponent("\(UUID().uuidString).download")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
                throw RemoteFileSystemError.invalidResponse
            }
            do {
                let completed = try await data.writeAll(to: handle, totalBytes: total, progress: progress)
                try handle.close()
                let final = try await control.readReply()
                try Self.expectComplete(final, path: path)
                // Guard against a server that closes the data socket early but
                // still returns 226: a short file would otherwise be accepted as a
                // complete download (corrupt media, no error).
                if let total, total > 0, completed < total {
                    throw RemoteFileSystemError.serverDisconnected
                }
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)
                await progress?(TransferProgress(completedBytes: completed, totalBytes: total ?? completed))
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }
    }
}

private extension FTPRemoteClient {
    func withControlConnection<T>(
        path: RemotePath,
        _ body: (FTPControlConnection) async throws -> T
    ) async throws -> T {
        let control: FTPControlConnection
        do {
            // A user-entered port outside 1...65535 used to trap in the NWEndpoint
            // initialiser (hard crash). Surface it as a typed error instead.
            control = try FTPControlConnection(host: host, port: port)
        } catch {
            throw Self.map(error, path: path)
        }
        do {
            try await control.connect()
            try await login(control)
            let result = try await body(control)
            control.cancel()
            return result
        } catch {
            control.cancel()
            throw Self.map(error, path: path)
        }
    }

    func login(_ control: FTPControlConnection) async throws {
        let greeting = try await control.readReply()
        try Self.expectComplete(greeting, path: RemotePath(displayPath: ""))

        let user = username ?? "anonymous"
        let userReply = try await control.send("USER \(Self.commandPath(user))")
        switch userReply.code {
        case 230:
            break
        case 331:
            let passReply = try await control.send("PASS \(Self.commandPath(password ?? "anonymous@"))")
            guard passReply.code == 230 || passReply.code == 202 else {
                throw RemoteFileSystemError.authenticationExpired
            }
        default:
            throw RemoteFileSystemError.authenticationExpired
        }

        let typeReply = try await control.send("TYPE I")
        try Self.expectComplete(typeReply, path: RemotePath(displayPath: ""))
    }

    func listedEntry(for path: RemotePath, control: FTPControlConnection) async throws -> RemoteEntry? {
        guard let parent = path.parentPath else { return nil }
        let name = path.lastPathComponent
        let endpoint = try await control.enterPassiveMode()
        let data = try FTPDataConnection(host: endpoint.host, port: endpoint.port)
        defer { data.cancel() }   // NWConnection leaks its socket/FD unless cancelled
        try await data.connect()
        let reply = try await control.send("LIST \(Self.commandPath(resolvedPath(parent)))")
        try Self.expectPreliminary(reply, path: parent)
        let listing = try await data.readAll()
        let final = try await control.readReply()
        try Self.expectComplete(final, path: parent)
        let text = String(data: listing, encoding: .utf8)
            ?? String(data: listing, encoding: .isoLatin1)
            ?? ""
        return FTPListParser.parse(text, directory: parent)
            .first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func modifiedDate(path: String, remotePath: RemotePath, control: FTPControlConnection) async throws -> Date? {
        let reply = try await control.send("MDTM \(Self.commandPath(path))")
        guard reply.code == 213, let value = reply.message.last else { return nil }
        return FTPDateParser.parseMDTM(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func resolvedPath(_ path: RemotePath) -> String {
        let base = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let child = path.displayPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.isEmpty && child.isEmpty { return "/" }
        if base.isEmpty { return "/" + child }
        if child.isEmpty { return "/" + base }
        return "/" + base + "/" + child
    }

    static func commandPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    /// Best-effort SIZE on an already-open control connection. `nil` when the
    /// server doesn't answer 213 (the caller then skips the short-read guard).
    static func size(of resolvedPath: String, control: FTPControlConnection) async -> Int64? {
        guard let reply = try? await control.send("SIZE \(commandPath(resolvedPath))"), reply.code == 213 else {
            return nil
        }
        return Int64(reply.message.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    static func expectPreliminary(_ reply: FTPReply, path: RemotePath) throws {
        guard (100..<200).contains(reply.code) else {
            throw error(from: reply, path: path)
        }
    }

    static func expectComplete(_ reply: FTPReply, path: RemotePath) throws {
        guard (200..<300).contains(reply.code) else {
            throw error(from: reply, path: path)
        }
    }

    static func error(from reply: FTPReply, path: RemotePath) -> Error {
        FTPReplyMapper.error(code: reply.code, path: path)
    }

    static func map(_ error: Error, path: RemotePath) -> Error {
        if let error = error as? RemoteFileSystemError { return error }
        if error is CancellationError { return RemoteFileSystemError.cancelled }
        if let error = error as? NWError {
            switch error {
            case .posix(.ETIMEDOUT): return RemoteFileSystemError.timeout
            default: return RemoteFileSystemError.serverDisconnected
            }
        }
        return RemoteFileSystemError.invalidResponse
    }
}

enum FTPPort {
    /// A validated `NWEndpoint.Port`. Rejects anything outside 1...65535 instead
    /// of trapping in `UInt16(_:)` / the force-unwrapped `NWEndpoint.Port` init.
    static func make(_ port: Int) throws -> NWEndpoint.Port {
        guard (1...65_535).contains(port),
              let raw = UInt16(exactly: port),
              let value = NWEndpoint.Port(rawValue: raw) else {
            throw RemoteFileSystemError.invalidResponse
        }
        return value
    }
}

private struct FTPPassiveEndpoint: Sendable {
    var host: String
    var port: Int
}

private struct FTPReply: Sendable {
    var code: Int
    var message: [String]
}

private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private final class FTPControlConnection: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "BetterStreaming.FTP.control")
    private let connection: NWConnection
    private var buffer = Data()

    init(host: String, port: Int) throws {
        self.host = host
        self.port = port
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: try FTPPort.make(port), using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume = OneShotResume()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resume.claim() { continuation.resume() }
                case .failed(let error):
                    if resume.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resume.claim() { continuation.resume(throwing: RemoteFileSystemError.serverDisconnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ command: String) async throws -> FTPReply {
        let line = command + "\r\n"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(line.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        return try await readReply()
    }

    func readReply() async throws -> FTPReply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw RemoteFileSystemError.invalidResponse
        }
        var lines = [String(first.dropFirst(min(4, first.count)))]
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            while true {
                let line = try await readLine()
                lines.append(String(line.dropFirst(min(4, line.count))))
                if line.hasPrefix("\(code) ") { break }
            }
        }
        return FTPReply(code: code, message: lines)
    }

    func enterPassiveMode() async throws -> FTPPassiveEndpoint {
        let epsv = try await send("EPSV")
        if epsv.code == 229, let endpoint = Self.parseEPSV(epsv, fallbackHost: host) {
            return endpoint
        }
        let pasv = try await send("PASV")
        guard pasv.code == 227, let endpoint = Self.parsePASV(pasv, fallbackHost: host) else {
            throw RemoteFileSystemError.invalidResponse
        }
        return endpoint
    }

    func cancel() {
        connection.cancel()
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1)
                    ?? ""
            }
            let data = try await receive()
            guard !data.isEmpty else {
                throw RemoteFileSystemError.serverDisconnected
            }
            buffer.append(data)
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func parseEPSV(_ reply: FTPReply, fallbackHost: String) -> FTPPassiveEndpoint? {
        guard let port = FTPPassiveParser.epsvPort(reply.message.joined(separator: " ")) else { return nil }
        return FTPPassiveEndpoint(host: fallbackHost, port: port)
    }

    private static func parsePASV(_ reply: FTPReply, fallbackHost: String) -> FTPPassiveEndpoint? {
        guard let port = FTPPassiveParser.pasvPort(reply.message.joined(separator: " ")) else { return nil }
        // Ignore the IP advertised in the 227 reply: servers behind NAT report a
        // private address that the client can't route to. Reuse the control
        // connection's host (what curl/lftp do); only take the port from PASV.
        return FTPPassiveEndpoint(host: fallbackHost, port: port)
    }
}

/// Pure parsers for the passive-mode replies, split out so they're unit-testable
/// without a live control connection.
enum FTPPassiveParser {
    /// Port from an EPSV `229` reply, e.g. `Entering Extended Passive Mode (|||6446|)`.
    static func epsvPort(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else {
            return nil
        }
        let payload = String(text[text.index(after: open)..<close])
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard let portText = parts.last(where: { !$0.isEmpty }),
              let port = Int(portText),
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    /// Port from a PASV `227` reply, e.g. `Entering Passive Mode (192,168,0,2,25,38)`.
    static func pasvPort(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else {
            return nil
        }
        let numbers = text[text.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        let port = numbers[4] * 256 + numbers[5]
        guard (1...65_535).contains(port) else { return nil }
        return port
    }
}

/// Maps FTP reply codes to typed errors. Extracted for unit testing.
enum FTPReplyMapper {
    static func error(code: Int, path: RemotePath) -> RemoteFileSystemError {
        switch code {
        case 421:
            return .serverDisconnected
        case 425, 426:
            return .serverDisconnected
        case 430, 530:
            return .authenticationExpired
        case 450, 550:
            return .notFound(path)
        case 451, 452, 500, 501, 502, 504:
            return .invalidResponse
        case 530...599:
            return .permissionDenied(path)
        default:
            return .invalidResponse
        }
    }
}

private final class FTPDataConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BetterStreaming.FTP.data")
    private let connection: NWConnection

    init(host: String, port: Int) throws {
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: try FTPPort.make(port), using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume = OneShotResume()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resume.claim() { continuation.resume() }
                case .failed(let error):
                    if resume.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resume.claim() { continuation.resume(throwing: RemoteFileSystemError.serverDisconnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func readAll() async throws -> Data {
        try await read(maxBytes: nil)
    }

    func read(maxBytes: Int64?) async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await receive()
            if !chunk.data.isEmpty {
                if let maxBytes {
                    let remaining = max(0, Int(maxBytes) - data.count)
                    if remaining > 0 {
                        data.append(chunk.data.prefix(remaining))
                    }
                    if data.count >= Int(maxBytes) { return data }
                } else {
                    data.append(chunk.data)
                }
            }
            if chunk.isComplete { return data }
        }
    }

    func writeAll(to handle: FileHandle, totalBytes: Int64?, progress: ProgressSink?) async throws -> Int64 {
        var completed: Int64 = 0
        while true {
            let chunk = try await receive()
            if !chunk.data.isEmpty {
                try handle.write(contentsOf: chunk.data)
                completed += Int64(chunk.data.count)
                await progress?(TransferProgress(completedBytes: completed, totalBytes: totalBytes))
            }
            if chunk.isComplete { return completed }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }
}

public enum FTPListParser {
    public static func parse(_ text: String, directory: RemotePath) -> [RemoteEntry] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0), directory: directory) }
            .sortedDeterministically()
    }

    static func parseLine(_ line: String, directory: RemotePath) -> RemoteEntry? {
        parseUnix(line, directory: directory) ?? parseDOS(line, directory: directory)
    }

    static func parseUnix(_ line: String, directory: RemotePath) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return nil }
        let mode = parts[0]
        let rawName = String(parts[8])
        let name = rawName.components(separatedBy: " -> ").first ?? rawName
        guard name != "." && name != ".." else { return nil }

        let kind: RemoteEntryKind
        switch mode.first {
        case "d": kind = .directory
        case "l": kind = .symbolicLink
        case "-": kind = .file
        default: kind = .unknown
        }
        let size = Int64(parts[4])
        return RemoteEntry(
            name: name,
            path: directory.appending(name),
            kind: kind,
            size: kind == .file ? size : nil,
            modifiedAt: FTPDateParser.parseListDate(month: String(parts[5]), day: String(parts[6]), timeOrYear: String(parts[7]))
        )
    }

    static func parseDOS(_ line: String, directory: RemotePath) -> RemoteEntry? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let name = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != "." && name != ".." else { return nil }
        let isDirectory = parts[2].localizedCaseInsensitiveCompare("<DIR>") == .orderedSame
        let size = isDirectory ? nil : Int64(parts[2])
        return RemoteEntry(
            name: name,
            path: directory.appending(name),
            kind: isDirectory ? .directory : .file,
            size: size,
            modifiedAt: FTPDateParser.parseDOSDate(date: String(parts[0]), time: String(parts[1]))
        )
    }
}

enum FTPDateParser {
    // DateFormatter is expensive to allocate and not thread-safe. Cache one per
    // format and serialise access with a lock, instead of allocating a fresh
    // formatter on every one of a 10k-entry listing's lines.
    private static let lock = NSLock()

    private static let mdtmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    private static let listFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d yyyy HH:mm"
        return formatter
    }()

    private static let dosFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd-yy hh:mma"
        return formatter
    }()

    private static func date(_ formatter: DateFormatter, from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }

    static func parseMDTM(_ value: String) -> Date? {
        date(mdtmFormatter, from: value)
    }

    static func parseListDate(month: String, day: String, timeOrYear: String) -> Date? {
        let year: String
        let time: String
        if timeOrYear.contains(":") {
            year = String(Calendar.current.component(.year, from: Date()))
            time = timeOrYear
        } else {
            year = timeOrYear
            time = "00:00"
        }
        guard let parsed = date(listFormatter, from: "\(month) \(day) \(year) \(time)") else { return nil }
        // `ls` omits the year for recent files. If we assumed the current year but
        // the date lands in the future (a Dec file listed in Jan), it's last year.
        if timeOrYear.contains(":"), parsed.timeIntervalSinceNow > 86_400 {
            return Calendar.current.date(byAdding: .year, value: -1, to: parsed) ?? parsed
        }
        return parsed
    }

    static func parseDOSDate(date dateString: String, time: String) -> Date? {
        date(dosFormatter, from: "\(dateString) \(time)")
    }
}
