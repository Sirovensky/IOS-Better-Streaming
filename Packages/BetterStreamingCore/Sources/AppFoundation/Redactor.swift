import Foundation

public struct Redactor: Sendable {
    public static let redactedPlaceholder = "<redacted>"
    public static let credentialsPlaceholder = "<credentials>"
    public static let usernamePlaceholder = "<username>"
    public static let passwordPlaceholder = "<password>"
    public static let tokenPlaceholder = "<token>"
    public static let hostPlaceholder = "<host>"
    public static let pathPlaceholder = "<path>"

    public init() {}

    public func redact(_ value: String) -> String {
        guard !value.isEmpty else {
            return value
        }

        var redacted = value
        redacted = redactURLs(in: redacted)
        redacted = redactAuthorization(in: redacted)
        redacted = redactAssignments(in: redacted, using: Self.secretAssignmentRegexes, placeholder: Self.redactedPlaceholder)
        redacted = redactAssignments(in: redacted, using: Self.usernameAssignmentRegexes, placeholder: Self.usernamePlaceholder)
        redacted = redactAssignments(in: redacted, using: Self.hostAssignmentRegexes, placeholder: Self.hostPlaceholder)
        redacted = redactAssignments(in: redacted, using: Self.pathAssignmentRegexes, placeholder: Self.pathPlaceholder)
        redacted = redactUNCPaths(in: redacted)
        redacted = redactKnownTokenShapes(in: redacted)
        redacted = redactEmailAddresses(in: redacted)
        redacted = redactHostLiterals(in: redacted)
        return redacted
    }

    public func redactURL(_ url: URL) -> String {
        redactURLString(url.absoluteString)
    }

    public func redactURLString(_ value: String) -> String {
        sanitizedURLString(value)
    }

    public func redactHost(_ host: String) -> String {
        host.isEmpty ? host : Self.hostPlaceholder
    }

    public func redactUsername(_ username: String) -> String {
        username.isEmpty ? username : Self.usernamePlaceholder
    }

    public func redactPassword(_ password: String) -> String {
        password.isEmpty ? password : Self.passwordPlaceholder
    }

    public func redactToken(_ token: String) -> String {
        token.isEmpty ? token : Self.tokenPlaceholder
    }

    public func redactPath(_ path: String) -> String {
        path.isEmpty ? path : Self.pathPlaceholder
    }

    public func redactValue(_ value: String, named name: String) -> String {
        guard !value.isEmpty else {
            return value
        }

        switch Self.valueKind(forKey: name) {
        case .secret:
            return Self.redactedPlaceholder
        case .username:
            return Self.usernamePlaceholder
        case .host:
            return Self.hostPlaceholder
        case .path:
            return Self.pathPlaceholder
        case .publicValue:
            return redact(value)
        }
    }

    private func redactURLs(in value: String) -> String {
        replacingMatches(in: value, using: Self.urlRegex) { match in
            sanitizedURLString(match)
        }
    }

    private func sanitizedURLString(_ value: String) -> String {
        let split = splitTrailingPunctuation(from: value)
        let body = split.body

        guard
            let components = URLComponents(string: body),
            let scheme = components.scheme
        else {
            return fallbackSanitizedURLString(body) + split.suffix
        }

        var result = "\(scheme)://"
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            result += "\(Self.credentialsPlaceholder)@"
        }

        if scheme.lowercased() != "file" {
            result += Self.hostPlaceholder
        }

        if let port = components.port {
            result += ":\(port)"
        }

        if !components.percentEncodedPath.isEmpty {
            result += components.percentEncodedPath == "/" ? "/" : "/\(Self.pathPlaceholder)"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(sanitizedQueryString(query))"
        }

        if components.percentEncodedFragment != nil {
            result += "#\(Self.redactedPlaceholder)"
        }

        return result + split.suffix
    }

    private func fallbackSanitizedURLString(_ value: String) -> String {
        guard let schemeRange = value.range(of: "://") else {
            return Self.redactedPlaceholder
        }

        return "\(value[..<schemeRange.upperBound])\(Self.redactedPlaceholder)"
    }

    private func sanitizedQueryString(_ query: String) -> String {
        query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { item -> String in
                let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first, !key.isEmpty else {
                    return Self.redactedPlaceholder
                }

                return "\(key)=\(Self.redactedPlaceholder)"
            }
            .joined(separator: "&")
    }

    private func splitTrailingPunctuation(from value: String) -> (body: String, suffix: String) {
        var body = value
        var suffix = ""

        while let last = body.last, [".", ",", ";", ")"].contains(last) {
            body.removeLast()
            suffix.insert(last, at: suffix.startIndex)
        }

        return (body, suffix)
    }

    private func redactAuthorization(in value: String) -> String {
        var redacted = value
        redacted = replacingAll(
            in: redacted,
            using: Self.authorizationAssignmentRegex,
            template: "$1\(Self.redactedPlaceholder)"
        )
        redacted = replacingAll(
            in: redacted,
            using: Self.bearerBasicTokenRegex,
            template: "$1 \(Self.tokenPlaceholder)"
        )
        return redacted
    }

    private func redactAssignments(in value: String, using regexes: AssignmentRegexes, placeholder: String) -> String {
        replacingMatches(in: value, using: regexes.full) { match in
            let nsMatch = match as NSString
            guard
                let prefixMatch = regexes.prefix.firstMatch(
                    in: match,
                    range: NSRange(location: 0, length: nsMatch.length)
                )
            else {
                return placeholder
            }

            let key = nsMatch.substring(with: prefixMatch.range(at: 1))
            let separator = nsMatch.substring(with: prefixMatch.range(at: 2))
            return "\(key)\(separator)\(placeholder)"
        }
    }

    private func redactUNCPaths(in value: String) -> String {
        replacingAll(in: value, using: Self.uncPathRegex, template: Self.pathPlaceholder)
    }

    private func redactKnownTokenShapes(in value: String) -> String {
        replacingAll(in: value, using: Self.knownTokenShapeRegex, template: Self.tokenPlaceholder)
    }

    private func redactEmailAddresses(in value: String) -> String {
        replacingAll(
            in: value,
            using: Self.emailRegex,
            template: "\(Self.usernamePlaceholder)@\(Self.hostPlaceholder)"
        )
    }

    private func redactHostLiterals(in value: String) -> String {
        var redacted = value
        redacted = replacingAll(in: redacted, using: Self.ipv4Regex, template: Self.hostPlaceholder)
        redacted = replacingAll(in: redacted, using: Self.ipv6Regex, template: Self.hostPlaceholder)
        redacted = replacingAll(in: redacted, using: Self.hostNameRegex, template: Self.hostPlaceholder)
        return redacted
    }

    /// Applies a template-based replacement to every match of a precompiled regex.
    /// Equivalent to `replacingOccurrences(of:with:options:.regularExpression)`.
    private func replacingAll(in value: String, using regex: NSRegularExpression, template: String) -> String {
        regex.stringByReplacingMatches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length),
            withTemplate: template
        )
    }

    private func replacingMatches(in value: String, using regex: NSRegularExpression, transform: (String) -> String) -> String {
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        var result = value

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else {
                continue
            }

            let original = nsValue.substring(with: match.range)
            result.replaceSubrange(range, with: transform(original))
        }

        return result
    }

    private static func valueKind(forKey key: String) -> ValueKind {
        let normalized = key
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        if secretMetadataKeys.contains(normalized) {
            return .secret
        }

        if usernameMetadataKeys.contains(normalized) {
            return .username
        }

        if hostMetadataKeys.contains(normalized) {
            return .host
        }

        if pathMetadataKeys.contains(normalized) {
            return .path
        }

        return .publicValue
    }

    private enum ValueKind {
        case secret
        case username
        case host
        case path
        case publicValue
    }

    private static let secretAssignmentKeys = #"password|passwd|pwd|pass|token|access[-_]?token|refresh[-_]?token|id[-_]?token|api[-_]?key|apikey|secret|session(?:id|[-_]?id)?|auth(?:orization)?|credential(?:s)?|signature|sig|key|code"#
    private static let usernameAssignmentKeys = #"username|user|login|account|domain|workgroup"#
    private static let hostAssignmentKeys = #"host|hostname|server|endpoint|address|ip"#
    private static let pathAssignmentKeys = #"path|folder|file|share|root"#

    // MARK: - Cached compiled regular expressions
    //
    // `redact` runs on a logging hot path. `NSRegularExpression` is immutable and
    // documented as thread-safe, so we compile each pattern exactly once and reuse
    // it. `nonisolated(unsafe)` opts these out of Swift 6's Sendable check (the type
    // is not marked `Sendable` on every SDK) without changing the immutable, thread-safe
    // semantics relied upon here.

    private struct AssignmentRegexes {
        let full: NSRegularExpression
        let prefix: NSRegularExpression

        init(keys: String) {
            full = try! NSRegularExpression(
                pattern: #"(?i)(["']?\b(?:\#(keys))\b["']?)(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^&\s,;}]+)"#,
                options: []
            )
            prefix = try! NSRegularExpression(
                pattern: #"(?i)(["']?\b(?:\#(keys))\b["']?)(\s*[:=]\s*)"#,
                options: []
            )
        }
    }

    nonisolated(unsafe) private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#,
        options: []
    )
    nonisolated(unsafe) private static let authorizationAssignmentRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(authorization\s*[:=]\s*)(?:bearer|basic|digest)?\s*[^,\s;}]+"#,
        options: []
    )
    nonisolated(unsafe) private static let bearerBasicTokenRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer|basic)\s+[a-z0-9._~+/\-=]{4,}"#,
        options: []
    )
    nonisolated(unsafe) private static let uncPathRegex = try! NSRegularExpression(
        pattern: #"\\\\[^\\\s]+(?:\\[^\s\\]+)*"#,
        options: []
    )
    nonisolated(unsafe) private static let knownTokenShapeRegex = try! NSRegularExpression(
        pattern: #"\b(?:sk|pk|gh[pousr]?|xox[baprs])[-_][a-zA-Z0-9._-]{12,}\b"#,
        options: []
    )
    nonisolated(unsafe) private static let emailRegex = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b"#,
        options: []
    )
    nonisolated(unsafe) private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"(?<![\w])(?:\d{1,3}\.){3}\d{1,3}(?![\w])"#,
        options: []
    )
    nonisolated(unsafe) private static let ipv6Regex = try! NSRegularExpression(
        pattern: #"\[[0-9a-fA-F:]{2,}\]"#,
        options: []
    )
    nonisolated(unsafe) private static let hostNameRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![@\w-])(?:[a-z0-9-]{1,63}\.)+(?:local|lan|home|internal|home\.arpa|example|invalid|test|com|net|org|io|dev|app)(?![\w-])"#,
        options: []
    )

    nonisolated(unsafe) private static let secretAssignmentRegexes = AssignmentRegexes(keys: secretAssignmentKeys)
    nonisolated(unsafe) private static let usernameAssignmentRegexes = AssignmentRegexes(keys: usernameAssignmentKeys)
    nonisolated(unsafe) private static let hostAssignmentRegexes = AssignmentRegexes(keys: hostAssignmentKeys)
    nonisolated(unsafe) private static let pathAssignmentRegexes = AssignmentRegexes(keys: pathAssignmentKeys)

    private static let secretMetadataKeys: Set<String> = [
        "password",
        "passwd",
        "pwd",
        "pass",
        "token",
        "accesstoken",
        "refreshtoken",
        "idtoken",
        "apikey",
        "secret",
        "session",
        "sessionid",
        "auth",
        "authorization",
        "credential",
        "credentials",
        "signature",
        "sig",
        "key",
        "code"
    ]

    private static let usernameMetadataKeys: Set<String> = [
        "username",
        "user",
        "login",
        "account",
        "domain",
        "workgroup"
    ]

    private static let hostMetadataKeys: Set<String> = [
        "host",
        "hostname",
        "server",
        "endpoint",
        "address",
        "ip"
    ]

    private static let pathMetadataKeys: Set<String> = [
        "path",
        "folder",
        "file",
        "share",
        "root"
    ]
}
