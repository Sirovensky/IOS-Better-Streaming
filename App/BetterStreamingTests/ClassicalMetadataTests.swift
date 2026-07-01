import XCTest
@testable import BetterStreaming

/// The network layer of `ClassicalMetadataClient` can't run in a unit test, but the
/// bug-prone part — decoding the MusicBrainz / OpenOpus JSON and mapping a recording's
/// relationships to credit fields — is pure and captured here against real response
/// shapes (verified against live MB/OpenOpus responses).
final class ClassicalMetadataTests: XCTestCase {

    func testRecordingSearchDecodesFirstID() throws {
        let json = Data("""
        { "recordings": [ {"id":"48ec0d0a-a998-4902-ac92-5b2e98392bc0","title":"Symphony no. 5","score":100} ] }
        """.utf8)
        let result = try JSONDecoder().decode(MBRecordingSearch.self, from: json)
        XCTAssertEqual(result.recordings.first?.id, "48ec0d0a-a998-4902-ac92-5b2e98392bc0")
    }

    func testRecordingRelationsMapToCredits() throws {
        let json = Data("""
        { "relations": [
            {"type":"conductor","target-type":"artist","artist":{"id":"a1","name":"Herbert von Karajan","type":"Person"}},
            {"type":"performing orchestra","target-type":"artist","artist":{"id":"a2","name":"Philharmonia Orchestra","type":"Orchestra"}},
            {"type":"performer","target-type":"artist","artist":{"id":"a3","name":"Anne-Sophie Mutter","type":"Person"}},
            {"type":"performance","target-type":"work","work":{"id":"w1","title":"Symphony no. 5 in E-flat major"}}
        ]}
        """.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        let (credits, workID) = ClassicalMetadataClient.credits(fromRecordingRelations: recording.relations ?? [])
        XCTAssertEqual(credits.conductor, "Herbert von Karajan")
        XCTAssertEqual(credits.orchestra, "Philharmonia Orchestra")
        XCTAssertEqual(credits.soloists, ["Anne-Sophie Mutter"])
        XCTAssertEqual(credits.work, "Symphony no. 5 in E-flat major")
        XCTAssertEqual(workID, "w1")
        XCTAssertNil(credits.composer, "composer is a work-level rel, filled by a second lookup")
        XCTAssertFalse(credits.isEmpty)
    }

    func testPerformerDedupedAndOrchestraNotCountedAsSoloist() throws {
        let json = Data("""
        { "relations": [
            {"type":"performer","target-type":"artist","artist":{"id":"a3","name":"Anne-Sophie Mutter"}},
            {"type":"performer","target-type":"artist","artist":{"id":"a3","name":"Anne-Sophie Mutter"}},
            {"type":"performing orchestra","target-type":"artist","artist":{"id":"a2","name":"Berlin Philharmonic"}}
        ]}
        """.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        let (credits, _) = ClassicalMetadataClient.credits(fromRecordingRelations: recording.relations ?? [])
        XCTAssertEqual(credits.soloists, ["Anne-Sophie Mutter"], "duplicate performers collapse")
        XCTAssertEqual(credits.orchestra, "Berlin Philharmonic")
    }

    func testWorkComposerParsing() throws {
        let json = Data("""
        { "relations": [ {"type":"composer","target-type":"artist","artist":{"id":"c1","name":"Ludwig van Beethoven","type":"Person"}} ] }
        """.utf8)
        let work = try JSONDecoder().decode(MBWork.self, from: json)
        let composer = work.relations?.first { $0.type == "composer" }?.artist?.name
        XCTAssertEqual(composer, "Ludwig van Beethoven")
    }

    func testOpenOpusComposerDecode() throws {
        let json = Data("""
        { "status": {"success":"true","rows":"1"},
          "composers": [ {"id":"145","name":"Beethoven","complete_name":"Ludwig van Beethoven","epoch":"Early Romantic","portrait":"https://x/y.jpg"} ] }
        """.utf8)
        let result = try JSONDecoder().decode(OpenOpusComposerSearch.self, from: json)
        XCTAssertEqual(result.composers?.first?.completeName, "Ludwig van Beethoven")
        XCTAssertEqual(result.composers?.first?.epoch, "Early Romantic")
    }

    func testEmptyRelationsYieldEmptyCredits() {
        let (credits, workID) = ClassicalMetadataClient.credits(fromRecordingRelations: [])
        XCTAssertTrue(credits.isEmpty)
        XCTAssertNil(workID)
    }

    func testNonClassicalRelationsIgnored() throws {
        // A pop recording's relations (mix engineer, etc.) shouldn't populate credits.
        let json = Data("""
        { "relations": [
            {"type":"mix","target-type":"artist","artist":{"id":"e1","name":"Some Engineer"}},
            {"type":"recording engineer","target-type":"artist","artist":{"id":"e2","name":"Another"}}
        ]}
        """.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        let (credits, workID) = ClassicalMetadataClient.credits(fromRecordingRelations: recording.relations ?? [])
        XCTAssertTrue(credits.isEmpty)
        XCTAssertNil(workID)
    }

    func testSoloistsAndWorkAloneAreNotClassical() throws {
        // A pop recording carries performer + performance(work) relations but no
        // composer/conductor/orchestra — it must read as empty so it's neither stored
        // nor shown as classical credits.
        let json = Data("""
        { "relations": [
            {"type":"performer","target-type":"artist","artist":{"id":"p1","name":"Some Singer"}},
            {"type":"performance","target-type":"work","work":{"id":"w9","title":"A Pop Song"}}
        ]}
        """.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        let (credits, _) = ClassicalMetadataClient.credits(fromRecordingRelations: recording.relations ?? [])
        XCTAssertEqual(credits.soloists, ["Some Singer"])
        XCTAssertEqual(credits.work, "A Pop Song")
        XCTAssertTrue(credits.isEmpty, "soloists + work without composer/conductor/orchestra isn't classical")
    }
}
