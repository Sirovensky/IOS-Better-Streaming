import BetterStreamingDomain
import BetterStreamingSources
import Testing

private func draft(
    _ kind: SourceProtocolKind,
    host: String = "nas.local",
    port: Int? = nil,
    share: String? = nil
) -> SourceDraft {
    SourceDraft(
        protocolKind: kind,
        displayName: "My NAS",
        endpoint: SourceEndpoint(hostDisplayName: host, port: port, shareName: share)
    )
}

@Test func validatorAcceptsWebDAVFTPSFTPWithHostAndValidPort() {
    for kind in [SourceProtocolKind.webDAV, .ftp, .sftp] {
        let result = SourceValidator().validate(draft(kind, port: 5005))
        #expect(result.isValid, "expected \(kind) to validate")
    }
}

@Test func validatorNoLongerRejectsWebDAVFTPSFTPAsUnsupported() {
    for kind in [SourceProtocolKind.webDAV, .ftp, .sftp] {
        let result = SourceValidator().validate(draft(kind))
        #expect(!result.issues.contains(.unsupportedProtocol(kind)))
    }
}

@Test func validatorFlagsOutOfRangePortPerProtocol() {
    for kind in [SourceProtocolKind.webDAV, .ftp, .sftp, .smb] {
        let share = kind == .smb ? "music" : nil
        let result = SourceValidator().validate(draft(kind, port: 99_999, share: share))
        #expect(result.issues.contains(.invalidPort), "expected \(kind) to flag invalid port")
    }
}

@Test func validatorFlagsMissingHostForNetworkProtocols() {
    for kind in [SourceProtocolKind.webDAV, .ftp, .sftp] {
        let result = SourceValidator().validate(draft(kind, host: "   "))
        #expect(result.issues.contains(.missingHost))
    }
}

@Test func validatorStillRejectsNFSAndDLNA() {
    for kind in [SourceProtocolKind.nfs, .dlna] {
        let result = SourceValidator().validate(draft(kind))
        #expect(result.issues.contains(.unsupportedProtocol(kind)))
    }
}

@Test func validatorDoesNotRequireShareForWebDAVFTPSFTP() {
    for kind in [SourceProtocolKind.webDAV, .ftp, .sftp] {
        let result = SourceValidator().validate(draft(kind))
        #expect(!result.issues.contains(.missingShare))
    }
}

@Test func validatorStillRequiresShareForSMB() {
    let result = SourceValidator().validate(draft(.smb))
    #expect(result.issues.contains(.missingShare))
}
