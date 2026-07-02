import Foundation
import Testing
import EvensongDomain
import RemoteFileSystem
@testable import WebDAVRemote

@Test func webDAVCapabilitiesMatchProtocolExpectations() {
    let client = WebDAVRemoteClient(
        baseURL: URL(string: "https://nas.local/dav/")!,
        username: "user",
        password: "secret"
    )

    #expect(client.capabilities.supportsByteRangeRead)
    #expect(client.capabilities.supportsDirectoryModifiedTime)
    #expect(client.capabilities.supportsBackgroundURLSession)
    #expect(!client.capabilities.supportsServerSideSearch)
    #expect(!client.capabilities.supportsStableFileID)
}

@Test func webDAVParsesMultiStatusIntoChildrenSkippingSelf() {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/music/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:getlastmodified>Mon, 12 Jan 2026 10:00:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/music/song%20one.mp3</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype/>
            <D:getcontentlength>123456</D:getcontentlength>
            <D:getcontenttype>audio/mpeg</D:getcontenttype>
            <D:getlastmodified>Tue, 13 Jan 2026 11:30:00 GMT</D:getlastmodified>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/music/Albums/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    let directory = RemotePath(displayPath: "/dav/music")
    let entries = WebDAVRemoteClient.makeEntries(
        fromMultiStatus: Data(xml.utf8),
        directory: directory,
        selfNormalizedPath: directory.normalizedPath
    )

    #expect(entries.count == 2)

    let file = entries.first { $0.kind == .file }
    #expect(file?.name == "song one.mp3")
    #expect(file?.size == 123_456)
    #expect(file?.contentType == "audio/mpeg")
    #expect(file?.modifiedAt != nil)

    let folder = entries.first { $0.kind == .directory }
    #expect(folder?.name == "Albums")
    #expect(folder?.size == nil)
}
