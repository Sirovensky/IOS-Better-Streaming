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
            return Self.makeEntries(
                fromMultiStatus: data,
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

            let (data, response) = try await session.data(for: request)
            let http = try Self.httpResponse(response)

            guard http.statusCode == 206 || http.statusCode == 200 else {
                throw Self.statusError(http.statusCode, path: path)
            }
            if http.statusCode == 206 {
                return data
            }

            // Server ignored the Range header and returned the whole body; slice
            // out the exact bytes that were requested.
            let sliceLower = Int(min(range.lowerBound, Int64(data.count)))
            let sliceUpper = Int(min(range.upperBound, Int64(data.count)))
            guard sliceLower < sliceUpper else {
                return Data()
            }
            return data.subdata(in: sliceLower..<sliceUpper)
        } catch {
            throw Self.mapError(error, path: path)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        do {
            let request = makeRequest(for: path, method: "GET")
            let (byteStream, response) = try await session.bytes(for: request)
            let http = try Self.httpResponse(response)
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw Self.statusError(http.statusCode, path: path)
            }
            let totalBytes: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil

            let fileManager = FileManager.default
            let directoryURL = localURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let tempURL = directoryURL.appendingPathComponent("\(UUID().uuidString).download")
            fileManager.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
                throw RemoteFileSystemError.invalidResponse
            }

            var completed: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(Self.downloadChunkSize)

            do {
                for try await byte in byteStream {
                    buffer.append(byte)
                    if buffer.count >= Self.downloadChunkSize {
                        try handle.write(contentsOf: buffer)
                        completed += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        await progress?(TransferProgress(completedBytes: completed, totalBytes: totalBytes))
                        try Task.checkCancellation()
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                    completed += Int64(buffer.count)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fileManager.removeItem(at: tempURL)
                throw error
            }

            // Atomic move into place.
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.moveItem(at: tempURL, to: localURL)

            await progress?(TransferProgress(completedBytes: completed, totalBytes: totalBytes ?? completed))
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
        let modifiedAt = http.value(forHTTPHeaderField: "Last-Modified").flatMap(WebDAVDateFormat.parse)
        return RemoteMetadata(
            path: path,
            kind: .file,
            size: size,
            modifiedAt: modifiedAt,
            contentType: contentType,
            supportsRangeRead: true
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
        let nodes = parseMultiStatus(data)
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
    private static func decodedPath(fromHref href: String) -> String {
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

    private static func statusError(_ status: Int, path: RemotePath) -> RemoteFileSystemError {
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

/// Parses the HTTP date formats permitted for `getlastmodified` / `Last-Modified`.
enum WebDAVDateFormat {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 1123
        "EEEE, dd-MMM-yy HH:mm:ss zzz",    // RFC 850
        "EEE MMM d HH:mm:ss yyyy"          // asctime
    ]

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
