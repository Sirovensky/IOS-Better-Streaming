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
        redacted = redactAssignments(in: redacted, keys: Self.secretAssignmentKeys, placeholder: Self.redactedPlaceholder)
        redacted = redactAssignments(in: redacted, keys: Self.usernameAssignmentKeys, placeholder: Self.usernamePlaceholder)
        redacted = redactAssignments(in: redacted, keys: Self.hostAssignmentKeys, placeholder: Self.hostPlaceholder)
        redacted = redactAssignments(in: redacted, keys: Self.pathAssignmentKeys, placeholder: Self.pathPlaceholder)
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
        replacingMatches(
            in: value,
            pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#
        ) { match in
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
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b(authorization\s*[:=]\s*)(?:bearer|basic|digest)?\s*[^,\s;}]+"#,
            with: "$1\(Self.redactedPlaceholder)",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b(bearer|basic)\s+[a-z0-9._~+/\-=]{4,}"#,
            with: "$1 \(Self.tokenPlaceholder)",
            options: .regularExpression
        )
        return redacted
    }

    private func redactAssignments(in value: String, keys: String, placeholder: String) -> String {
        replacingMatches(
            in: value,
            pattern: #"(?i)(["']?\b(?:\#(keys))\b["']?)(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^&\s,;}]+)"#
        ) { match in
            let nsMatch = match as NSString
            guard
                let regex = try? NSRegularExpression(
                    pattern: #"(?i)(["']?\b(?:\#(keys))\b["']?)(\s*[:=]\s*)"#,
                    options: []
                ),
                let prefixMatch = regex.firstMatch(in: match, range: NSRange(location: 0, length: nsMatch.length))
            else {
                return placeholder
            }

            let key = nsMatch.substring(with: prefixMatch.range(at: 1))
            let separator = nsMatch.substring(with: prefixMatch.range(at: 2))
            return "\(key)\(separator)\(placeholder)"
        }
    }

    private func redactUNCPaths(in value: String) -> String {
        value.replacingOccurrences(
            of: #"\\\\[^\\\s]+(?:\\[^\s\\]+)*"#,
            with: Self.pathPlaceholder,
            options: .regularExpression
        )
    }

    private func redactKnownTokenShapes(in value: String) -> String {
        value.replacingOccurrences(
            of: #"\b(?:sk|pk|gh[pousr]?|xox[baprs])[-_][a-zA-Z0-9._-]{12,}\b"#,
            with: Self.tokenPlaceholder,
            options: .regularExpression
        )
    }

    private func redactEmailAddresses(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b"#,
            with: "\(Self.usernamePlaceholder)@\(Self.hostPlaceholder)",
            options: .regularExpression
        )
    }

    private func redactHostLiterals(in value: String) -> String {
        var redacted = value
        redacted = redacted.replacingOccurrences(
            of: #"(?<![\w])(?:\d{1,3}\.){3}\d{1,3}(?![\w])"#,
            with: Self.hostPlaceholder,
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"\[[0-9a-fA-F:]{2,}\]"#,
            with: Self.hostPlaceholder,
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)(?<![@\w-])(?:[a-z0-9-]{1,63}\.)+(?:local|lan|home|internal|home\.arpa|example|invalid|test|com|net|org|io|dev|app)(?![\w-])"#,
            with: Self.hostPlaceholder,
            options: .regularExpression
        )
        return redacted
    }

    private func replacingMatches(in value: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }

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
