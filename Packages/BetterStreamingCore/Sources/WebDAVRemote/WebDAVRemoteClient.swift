import Foundation
import BetterStreamingDomain
import RemoteFileSystem

/// A real WebDAV implementation of ``RemoteFileSystemClient``.
///
/// The client speaks HTTP/WebDAV directly via `URLSession`:
/// - `list` issues a `PROPFIND` with `Depth: 1` and parses the `multistatus` XML body.
/// - `stat` issues a `PROPFIND` with `Depth: 0` (falling back to `HEAD`).
/// - `read` issues a ranged `GET` (`Range: bytes=lower-upper`).
/// - `download` streams the body to a temporary file and atomically moves it into place.
///
/// Mutable state (the `URLSession`) is isolated by the actor, and credentials are
/// only ever materialised into an `Authorization` header — they are never logged.
public actor WebDAVRemoteClient: RemoteFileSystemClient {
    public nonisolated let capabilities = RemoteCapabilities(
        supportsByteRangeRead: true,
        supportsServerSideSearch: false,
        supportsStableFileID: false,
        supportsDirectoryModifiedTime: true,
        supportsBackgroundURLSession: true
    )

    /// The root URL every request is resolved against.
    public nonisolated let baseURL: URL

    private let session: URLSession
    private let authorizationHeader: String?

    private static let downloadChunkSize = 262_144

    /// Creates a WebDAV client.
    ///
    /// - Parameters:
    ///   - baseURL: The collection root, e.g. `https://nas.local/dav/`.
    ///   - username: Optional Basic-auth username. Pass `nil` for anonymous access.
    ///   - password: Optional Basic-auth password.
    public init(baseURL: URL, username: String?, password: String?) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpShouldUsePipelining = true
        // Without this, `waitsForConnectivity` inherits the 7-day default resource
        // timeout, so an operation started in airplane mode hangs "forever".
        configuration.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: configuration)

        if let username, !username.isEmpty {
            let credentials = "\(username):\(password ?? "")"
            let encoded = Data(credentials.utf8).base64EncodedString()
            self.authorizationHeader = "Basic \(encoded)"
        } else {
            self.authorizationHeader = nil
        }
    }

    // MARK: - RemoteFileSystemClient

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        do {
            var request = makeRequest(for: directory, method: "PROPFIND", isDirectory: true)
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.propfindBody

            let (data, response) = try await session.data(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 207 || http.statusCode == 200 else {
                throw Self.statusError(http.statusCode, path: directory)
            }

            let requestURL = absoluteURL(for: directory, isDirectory: true)
            let selfNormalizedPath = RemotePath(displayPath: requestURL.path(percentEncoded: false)).normalizedPath
            let nodes = Self.parseMultiStatus(data)
            // A wrong URL against a plain web server answers 200 with non-WebDAV
            // HTML, which parses to zero nodes — that must NOT look like a valid
            // empty directory. Require a real multistatus: a 207, or a 200 body
            // that includes this collection's own node.
            if http.statusCode == 200, !Self.containsSelfNode(nodes, selfNormalizedPath: selfNormalizedPath) {
                throw RemoteFileSystemError.invalidResponse
            }
            return Self.makeEntries(
                fromNodes: nodes,
                directory: directory,
                selfNormalizedPath: selfNormalizedPath
            )
        } catch {
            throw Self.mapError(error, path: directory)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        do {
            return try await statViaPropfind(path)
        } catch let error as RemoteFileSystemError where error == .invalidResponse {
            // Some servers reject PROPFIND on plain files; fall back to HEAD.
            do {
                return try await statViaHead(path)
            } catch {
                throw Self.mapError(error, path: path)
            }
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw RemoteFileSystemError.unsupportedRange
        }
        guard range.upperBound > range.lowerBound else {
            return Data()
        }

        do {
            var request = makeRequest(for: path, method: "GET")
            let lower = range.lowerBound
            let upper = range.upperBound - 1
            request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")

            // Stream the body instead of `session.data`. A server that ignores the
            // Range header returns 200 with the WHOLE file; buffering it (a 1 GB
            // FLAC during a 256 KB metadata probe) triggers jetsam. Stream, skip to
            // the window on a 200, take the window, then break to cancel the task.
            let (byteStream, response) = try await session.bytes(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 206 || http.statusCode == 200 else {
                throw Self.statusError(http.statusCode, path: path)
            }

            let windowLength = Int(range.upperBound - range.lowerBound)
            let bytesToSkip = http.statusCode == 200 ? Int(range.lowerBound) : 0
            // A Range-ignoring server forces a byte-walk to the window. Near-EOF
            // reads (MP4 tail probes) would walk the whole file — refuse instead
            // of pegging a core for minutes.
            guard bytesToSkip <= 4 * 1_024 * 1_024 else {
                throw RemoteFileSystemError.unsupportedRange
            }
            var result = Data(capacity: min(windowLength, Self.downloadChunkSize))
            var skipped = 0
            for try await byte in byteStream {
                if skipped < bytesToSkip {
                    skipped += 1
                    continue
                }
                result.append(byte)
                if result.count >= windowLength {
                    break   // got the window; leaving the loop cancels the transfer
                }
            }
            return result
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        do {
            let request = makeRequest(for: path, method: "GET")
            // Use URLSession's download task (chunked, off-thread IO) instead of a
            // per-byte AsyncBytes loop, which pegged a core for minutes on a large
            // FLAC. Progress arrives via a task-specific delegate.
            let delegate = WebDAVDownloadProgressDelegate(progress: progress)
            let (downloadedURL, response) = try await session.download(for: request, delegate: delegate)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 200 || http.statusCode == 206 else {
                try? FileManager.default.removeItem(at: downloadedURL)
                throw Self.statusError(http.statusCode, path: path)
            }

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.moveItem(at: downloadedURL, to: localURL)

            let total: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            let onDisk = (try? fileManager.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
            let completed = onDisk ?? total ?? 0
            await progress?(TransferProgress(completedBytes: completed, totalBytes: total ?? completed))
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    // MARK: - stat helpers

    private func statViaPropfind(_ path: RemotePath) async throws -> RemoteMetadata {
        var request = makeRequest(for: path, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let (data, response) = try await session.data(for: request)
        let http = try Self.httpResponse(response)
        guard http.statusCode == 207 || http.statusCode == 200 else {
            throw Self.statusError(http.statusCode, path: path)
        }

        let nodes = Self.parseMultiStatus(data)
        guard let node = nodes.first else {
            throw RemoteFileSystemError.invalidResponse
        }
        let kind: RemoteEntryKind = node.isCollection ? .directory : .file
        return RemoteMetadata(
            path: path,
            kind: kind,
            size: kind == .file ? node.contentLength : nil,
            modifiedAt: node.lastModified,
            contentType: node.contentType,
            supportsRangeRead: true
        )
    }

    private func statViaHead(_ path: RemotePath) async throws -> RemoteMetadata {
        let request = makeRequest(for: path, method: "HEAD")
        let (_, response) = try await session.data(for: request)
        let http = try Self.httpResponse(response)
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw Self.statusError(http.statusCode, path: path)
        }
        let size: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        // HEAD can't reliably distinguish a collection, but hardcoding `.file` mis-
        // classified directories. Infer from the content type; fall back to
        // `.unknown` rather than asserting a file.
        let kind: RemoteEntryKind
        if let contentType, contentType.lowercased().contains("directory") {
            kind = .directory
        } else if size != nil {
            kind = .file
        } else {
            kind = .unknown
        }
        let modifiedAt = http.value(forHTTPHeaderField: "Last-Modified").flatMap(WebDAVDateFormat.parse)
        return RemoteMetadata(
            path: path,
            kind: kind,
            size: kind == .file ? size : nil,
            modifiedAt: modifiedAt,
            contentType: contentType,
            supportsRangeRead: kind == .file
        )
    }

    // MARK: - Request building

    private func makeRequest(for path: RemotePath, method: String, isDirectory: Bool = false) -> URLRequest {
        var request = URLRequest(url: absoluteURL(for: path, isDirectory: isDirectory))
        request.httpMethod = method
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func absoluteURL(for path: RemotePath, isDirectory: Bool) -> URL {
        var url = baseURL
        for component in path.remotePathComponents {
            url.appendPathComponent(component)
        }
        if isDirectory {
            let absolute = url.absoluteString
            if !absolute.hasSuffix("/") {
                url = URL(string: absolute + "/") ?? url
            }
        }
        return url
    }

    // MARK: - Multistatus parsing

    /// Builds the child entries of `directory` from a `multistatus` body, skipping
    /// the directory's own (self) entry.
    static func makeEntries(
        fromMultiStatus data: Data,
        directory: RemotePath,
        selfNormalizedPath: String
    ) -> [RemoteEntry] {
        makeEntries(
            fromNodes: parseMultiStatus(data),
            directory: directory,
            selfNormalizedPath: selfNormalizedPath
        )
    }

    /// True when `nodes` contains the collection's own (self) entry — the marker
    /// that this really was a WebDAV multistatus body for the requested path.
    static func containsSelfNode(_ nodes: [WebDAVResponseNode], selfNormalizedPath: String) -> Bool {
        nodes.contains { RemotePath(displayPath: decodedPath(fromHref: $0.href)).normalizedPath == selfNormalizedPath }
    }

    static func makeEntries(
        fromNodes nodes: [WebDAVResponseNode],
        directory: RemotePath,
        selfNormalizedPath: String
    ) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        entries.reserveCapacity(nodes.count)

        for node in nodes {
            let hrefPath = decodedPath(fromHref: node.href)
            let hrefRemotePath = RemotePath(displayPath: hrefPath)

            // Skip the collection's own entry.
            if hrefRemotePath.normalizedPath == selfNormalizedPath {
                continue
            }

            let name = hrefRemotePath.lastPathComponent
            guard !name.isEmpty else {
                continue
            }

            let kind: RemoteEntryKind = node.isCollection ? .directory : .file
            entries.append(
                RemoteEntry(
                    name: name,
                    path: directory.appending(name),
                    kind: kind,
                    size: kind == .file ? node.contentLength : nil,
                    modifiedAt: node.lastModified,
                    contentType: node.contentType
                )
            )
        }

        return entries
    }

    static func parseMultiStatus(_ data: Data) -> [WebDAVResponseNode] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = MultiStatusParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            return []
        }
        return delegate.responses
    }

    /// Extracts the percent-decoded path portion from an `href`, which may be a full
    /// URL (`https://host/dav/x`) or an absolute/relative path (`/dav/x`).
    static func decodedPath(fromHref href: String) -> String {
        if let components = URLComponents(string: href), !components.path.isEmpty {
            return components.path
        }
        return href.removingPercentEncoding ?? href
    }

    // MARK: - Error mapping

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.invalidResponse
        }
        return http
    }

    static func statusError(_ status: Int, path: RemotePath) -> RemoteFileSystemError {
        switch status {
        case 401:
            return .authenticationExpired
        case 403:
            return .permissionDenied(path)
        case 404, 410:
            return .notFound(path)
        case 408, 504:
            return .timeout
        case 416:
            return .unsupportedRange
        case 502, 503:
            return .serverDisconnected
        default:
            return .invalidResponse
        }
    }

    private static func mapError(_ error: Error, path: RemotePath) -> Error {
        if let error = error as? RemoteFileSystemError {
            return error
        }
        if error is CancellationError {
            return RemoteFileSystemError.cancelled
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return RemoteFileSystemError.cancelled
            case .userAuthenticationRequired:
                return RemoteFileSystemError.authenticationExpired
            case .timedOut:
                return RemoteFileSystemError.timeout
            case .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .secureConnectionFailed:
                return RemoteFileSystemError.serverDisconnected
            case .fileDoesNotExist:
                return RemoteFileSystemError.notFound(path)
            default:
                return RemoteFileSystemError.invalidResponse
            }
        }
        return RemoteFileSystemError.invalidResponse
    }

    // MARK: - PROPFIND body

    private static let propfindBody: Data = {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:getcontenttype/>
          </D:prop>
        </D:propfind>
        """
        return Data(xml.utf8)
    }()
}

/// One `<response>` node parsed from a WebDAV `multistatus` body.
struct WebDAVResponseNode {
    var href: String = ""
    var isCollection: Bool = false
    var contentLength: Int64?
    var lastModified: Date?
    var contentType: String?
}

/// Synchronous, single-threaded `XMLParser` delegate used to decode `multistatus`
/// bodies. Created and consumed within a single call, so it never crosses a
/// concurrency boundary.
private final class MultiStatusParserDelegate: NSObject, XMLParserDelegate {
    private(set) var responses: [WebDAVResponseNode] = []
    private var current: WebDAVResponseNode?
    private var buffer = ""
    private var inResourceType = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        switch elementName.lowercased() {
        case "response":
            current = WebDAVResponseNode()
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType {
                current?.isCollection = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href":
            current?.href = text
        case "getcontentlength":
            current?.contentLength = Int64(text)
        case "getlastmodified":
            current?.lastModified = WebDAVDateFormat.parse(text)
        case "getcontenttype":
            current?.contentType = text.isEmpty ? nil : text
        case "resourcetype":
            inResourceType = false
        case "response":
            if let current {
                responses.append(current)
            }
            current = nil
        default:
            break
        }
        buffer = ""
    }
}

/// Per-task download delegate that reports byte progress. A task-specific
/// delegate keeps the actor's shared `URLSession` delegate-free.
private final class WebDAVDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: ProgressSink?

    init(progress: ProgressSink?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progress else { return }
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { await progress(TransferProgress(completedBytes: totalBytesWritten, totalBytes: total)) }
    }

    // Required by the protocol. The async `download(for:delegate:)` returns the
    // file URL itself, so nothing is needed here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// Parses the HTTP date formats permitted for `getlastmodified` / `Last-Modified`.
enum WebDAVDateFormat {
    // DateFormatter is costly and not thread-safe; cache one per format behind a
    // lock instead of allocating three per date node on every listing.
    private static let lock = NSLock()

    private static let formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 1123
         "EEEE, dd-MMM-yy HH:mm:ss zzz",    // RFC 850
         "EEE MMM d HH:mm:ss yyyy"]         // asctime
            .map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "GMT")
                formatter.dateFormat = format
                return formatter
            }
    }()

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
