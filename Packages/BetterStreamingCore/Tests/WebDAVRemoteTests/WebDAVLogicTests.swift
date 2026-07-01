import BetterStreamingDomain
import Foundation
import RemoteFileSystem
import Testing
@testable import WebDAVRemote

@Test func webDAVStatusCodesMapToTypedErrors() {
    let path = RemotePath(displayPath: "/x")
    #expect(WebDAVRemoteClient.statusError(401, path: path) == .authenticationExpired)
    #expect(WebDAVRemoteClient.statusError(403, path: path) == .permissionDenied(path))
    #expect(WebDAVRemoteClient.statusError(404, path: path) == .notFound(path))
    #expect(WebDAVRemoteClient.statusError(416, path: path) == .unsupportedRange)
    #expect(WebDAVRemoteClient.statusError(503, path: path) == .serverDisconnected)
    #expect(WebDAVRemoteClient.statusError(418, path: path) == .invalidResponse)
}

@Test func webDAVDecodesHrefPaths() {
    #expect(WebDAVRemoteClient.decodedPath(fromHref: "https://nas.local/dav/song%20one.mp3") == "/dav/song one.mp3")
    #expect(WebDAVRemoteClient.decodedPath(fromHref: "/dav/Albums/") == "/dav/Albums/")
}

@Test func webDAVParsesEachPermittedDateFormat() {
    #expect(WebDAVDateFormat.parse("Mon, 12 Jan 2026 10:00:00 GMT") != nil)          // RFC 1123
    #expect(WebDAVDateFormat.parse("Sunday, 06-Nov-94 08:49:37 GMT") != nil)          // RFC 850
    #expect(WebDAVDateFormat.parse("Sun Nov  6 08:49:37 1994") != nil)                // asctime
    #expect(WebDAVDateFormat.parse("garbage") == nil)
    #expect(WebDAVDateFormat.parse("   ") == nil)
}

@Test func webDAVDetectsSelfNodePresence() {
    let selfPath = RemotePath(displayPath: "/dav/music").normalizedPath
    let withSelf = [
        WebDAVResponseNode(href: "/dav/music/"),
        WebDAVResponseNode(href: "/dav/music/song.mp3")
    ]
    let withoutSelf = [WebDAVResponseNode(href: "/dav/music/song.mp3")]

    #expect(WebDAVRemoteClient.containsSelfNode(withSelf, selfNormalizedPath: selfPath))
    #expect(!WebDAVRemoteClient.containsSelfNode(withoutSelf, selfNormalizedPath: selfPath))
    #expect(!WebDAVRemoteClient.containsSelfNode([], selfNormalizedPath: selfPath))
}

@Test func webDAVMakeEntriesFromNodesSkipsSelf() {
    let directory = RemotePath(displayPath: "/dav/music")
    let nodes = [
        WebDAVResponseNode(href: "/dav/music/", isCollection: true),
        WebDAVResponseNode(href: "/dav/music/track.flac", isCollection: false, contentLength: 100)
    ]
    let entries = WebDAVRemoteClient.makeEntries(
        fromNodes: nodes,
        directory: directory,
        selfNormalizedPath: directory.normalizedPath
    )
    #expect(entries.map(\.name) == ["track.flac"])
    #expect(entries.first?.size == 100)
}
