import EvensongDomain
import Foundation
import RemoteFileSystem
import Testing
@testable import FTPRemote

@Test func ftpPortRejectsOutOfRangeInsteadOfTrapping() {
    #expect((try? FTPPort.make(0)) == nil)
    #expect((try? FTPPort.make(-1)) == nil)
    #expect((try? FTPPort.make(65_536)) == nil)
    #expect((try? FTPPort.make(99_999)) == nil)
    #expect((try? FTPPort.make(21)) != nil)
    #expect((try? FTPPort.make(1)) != nil)
    #expect((try? FTPPort.make(65_535)) != nil)
}

@Test func ftpClientWithInvalidPortThrowsRatherThanCrashing() async {
    let client = FTPRemoteClient(host: "example.com", port: 99_999)
    await #expect(throws: RemoteFileSystemError.self) {
        _ = try await client.list(RemotePath(displayPath: "/"))
    }
}

@Test func ftpEPSVReplyPortIsParsed() {
    #expect(FTPPassiveParser.epsvPort("229 Entering Extended Passive Mode (|||6446|)") == 6446)
    #expect(FTPPassiveParser.epsvPort("229 Entering Extended Passive Mode (|||70000|)") == nil)
    #expect(FTPPassiveParser.epsvPort("229 no parens here") == nil)
}

@Test func ftpPASVReplyPortIsParsed() {
    #expect(FTPPassiveParser.pasvPort("227 Entering Passive Mode (192,168,0,2,25,38)") == 25 * 256 + 38)
    #expect(FTPPassiveParser.pasvPort("227 Entering Passive Mode (192,168,0,2,25)") == nil)  // too few octets
    #expect(FTPPassiveParser.pasvPort("227 Entering Passive Mode (0,0,0,0,0,0)") == nil)      // port 0
}

@Test func ftpReplyCodesMapToTypedErrors() {
    let path = RemotePath(displayPath: "/x")
    #expect(FTPReplyMapper.error(code: 421, path: path) == .serverDisconnected)
    #expect(FTPReplyMapper.error(code: 530, path: path) == .authenticationExpired)
    #expect(FTPReplyMapper.error(code: 550, path: path) == .notFound(path))
    #expect(FTPReplyMapper.error(code: 501, path: path) == .invalidResponse)
    #expect(FTPReplyMapper.error(code: 552, path: path) == .permissionDenied(path))
    #expect(FTPReplyMapper.error(code: 999, path: path) == .invalidResponse)
}

@Test func ftpListDateNeverResolvesIntoTheFuture() {
    // A "recent" listing (time, no year) must resolve into the past. The
    // rollover guard turns a Dec file listed in Jan into last December.
    let date = FTPDateParser.parseListDate(month: "Dec", day: "31", timeOrYear: "23:59")
    #expect(date != nil)
    if let date { #expect(date.timeIntervalSinceNow <= 86_400) }
}

@Test func ftpListDateParsesExplicitYear() {
    let date = FTPDateParser.parseListDate(month: "Jun", day: "15", timeOrYear: "2020")
    #expect(date != nil)
    if let date {
        #expect(Calendar.current.component(.year, from: date) == 2020)
    }
}

@Test func ftpMDTMDateParsing() {
    #expect(FTPDateParser.parseMDTM("20200615123045") != nil)
    #expect(FTPDateParser.parseMDTM("not-a-date") == nil)
}
