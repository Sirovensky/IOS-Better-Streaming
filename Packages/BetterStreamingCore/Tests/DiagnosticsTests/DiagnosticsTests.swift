import Testing
import Diagnostics

@Test func diagnosticEventRedactsPasswords() {
    let event = DiagnosticEvent(code: "test", message: "smb://user:secret@example.local/music?password=secret")
    #expect(!event.message.contains("secret"))
}

@Test func redactorRemovesUrlUserInfoHostsPathsAndQueryValues() {
    let redactor = DiagnosticRedactor()

    let redacted = redactor.redactURLString(
        "smb://fixture-user:p%40ss@fixture-nas.invalid:445/Music/Private?password=p%40ss&token=fixtureToken&folder=/library/private/Music#frag"
    )

    #expect(redacted == "smb://<credentials>@<host>:445/<path>?password=<redacted>&token=<redacted>&folder=<redacted>#<redacted>")
    assertNoLeak(redacted, secrets: [
        "fixture-user",
        "p%40ss",
        "fixture-nas.invalid",
        "Music",
        "Private",
        "fixtureToken",
        "/library/private"
    ])
}

@Test func diagnosticEventRedactsMessageAndMetadata() {
    let event = DiagnosticEvent(
        kind: .connectionFailure,
        classification: .connection,
        severity: .error,
        code: "source.authentication_failed",
        message: """
        Failed url=smb://fixture-user:p@ss@fixture-nas.invalid/Music/Private?password=p@ss&token=fixtureToken \
        Authorization: Bearer fixtureToken username=fixture-user host=203.0.113.25 path=/library/private/Music
        """,
        metadata: [
            "url": "smb://fixture-user:p@ss@fixture-nas.invalid/Music/Private?password=p@ss&token=fixtureToken",
            "username": "fixture-user",
            "password": "p@ss",
            "token": "fixtureToken",
            "host": "fixture-nas.invalid",
            "path": "/library/private/Music"
        ]
    )

    #expect(event.kind == .connectionFailure)
    #expect(event.classification == .connection)
    #expect(event.severity == .error)
    #expect(event.metadata["username"] == "<username>")
    #expect(event.metadata["password"] == "<redacted>")
    #expect(event.metadata["token"] == "<redacted>")
    #expect(event.metadata["host"] == "<host>")
    #expect(event.metadata["path"] == "<path>")

    assertNoLeak(event.message, secrets: [
        "fixture-user",
        "p@ss",
        "fixture-nas.invalid",
        "203.0.113.25",
        "fixtureToken",
        "/library/private",
        "Music",
        "Private"
    ])

    assertNoLeak(event.metadata.values.joined(separator: " "), secrets: [
        "fixture-user",
        "p@ss",
        "fixture-nas.invalid",
        "fixtureToken",
        "Music",
        "Private"
    ])
}

@Test func userFacingSummariesDoNotEchoGenericSecretBearingErrors() {
    let error = LeakyError(
        description: "failed smb://fixture-user-b:fixture-password-b@fixture-garage.invalid/Audio/Secret?token=fixtureTokenB Authorization: Bearer fixtureTokenB host=198.51.100.42"
    )

    let summary = DiagnosticErrorSummaries.connection(error)
    #expect(summary.title == "Connection Failed")
    #expect(summary.classification == .connection)
    #expect(summary.diagnosticsCode == "connection.failed")

    assertNoLeak(summary.title, secrets: ["fixture-user-b", "fixture-password-b", "fixture-garage.invalid", "fixtureTokenB", "198.51.100.42", "Secret"])
    assertNoLeak(summary.message, secrets: ["fixture-user-b", "fixture-password-b", "fixture-garage.invalid", "fixtureTokenB", "198.51.100.42", "Secret"])
    assertNoLeak(summary.redactedDebugDescription, secrets: ["fixture-user-b", "fixture-password-b", "fixture-garage.invalid", "fixtureTokenB", "198.51.100.42", "Secret"])

    let event = summary.diagnosticEvent(metadata: [
        "password": "fixture-password-b",
        "url": "smb://fixture-user-b:fixture-password-b@fixture-garage.invalid/Audio/Secret?token=fixtureTokenB"
    ])

    assertNoLeak(event.message, secrets: ["fixture-user-b", "fixture-password-b", "fixture-garage.invalid", "fixtureTokenB", "Secret"])
    assertNoLeak(event.metadata.values.joined(separator: " "), secrets: ["fixture-user-b", "fixture-password-b", "fixture-garage.invalid", "fixtureTokenB", "Secret"])
}

@Test func scanAndPlaybackFallbackSummariesAreUserSafe() {
    let scanSummary = DiagnosticErrorSummaries.scan(
        LeakyError(description: "scan failed path=/fixture/volume/Private token=fixtureScanToken server=fixture-nas.invalid")
    )
    let playbackSummary = DiagnosticErrorSummaries.playback(
        LeakyError(description: "playback failed url=http://fixture-user:pw@fixture-nas.invalid:8080/stream/song.flac?access_token=fixturePlayToken")
    )

    #expect(scanSummary.title == "Scan Failed")
    #expect(scanSummary.classification == .scan)
    #expect(playbackSummary.title == "Playback Failed")
    #expect(playbackSummary.classification == .playback)

    assertNoLeak(scanSummary.redactedDebugDescription, secrets: ["Private", "fixtureScanToken", "fixture-nas.invalid", "/fixture/volume"])
    assertNoLeak(playbackSummary.redactedDebugDescription, secrets: ["fixture-user", "pw", "fixture-nas.invalid", "song.flac", "fixturePlayToken"])
}

private struct LeakyError: Error, CustomStringConvertible {
    var description: String
}

private func assertNoLeak(_ value: String, secrets: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for secret in secrets {
        #expect(
            value.range(of: secret, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
            "Leaked secret: \(secret) in \(value)",
            sourceLocation: sourceLocation
        )
    }
}
