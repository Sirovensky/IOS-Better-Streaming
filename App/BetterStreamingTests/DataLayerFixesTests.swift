import XCTest
import BetterStreamingDomain
import MetadataReader
@testable import BetterStreaming

/// Data-layer regression coverage: embedded-title handling and the conservative
/// identity re-key map, both pure so they're captured here without a live scan.
final class DataLayerFixesTests: XCTestCase {

    // MARK: Embedded titles are authoritative (item 7)

    func testEmbeddedTitleWithLeadingDigitsKeptVerbatim() {
        // "99 Problems" must NOT lose its leading number to parseTrack — an embedded
        // TITLE tag is authoritative, only filenames need number-stripping.
        let r = LibraryService.resolvedTrackMetadata(
            fileName: "05 99 Problems.mp3",
            pathComponents: ["Music", "Jay-Z", "The Black Album", "05 99 Problems.mp3"],
            rootComponents: ["Music"],
            sourceName: "NAS",
            embedded: EmbeddedMediaMetadata(title: "99 Problems", artist: "Jay-Z", album: "The Black Album")
        )
        XCTAssertEqual(r.title, "99 Problems")
        XCTAssertEqual(r.artist, "Jay-Z")
    }

    func testEmbeddedTitleSevenYearsKeptVerbatim() {
        let r = LibraryService.resolvedTrackMetadata(
            fileName: "7 Years.flac",
            pathComponents: ["Music", "Lukas Graham", "Lukas Graham", "7 Years.flac"],
            rootComponents: ["Music"],
            sourceName: "NAS",
            embedded: EmbeddedMediaMetadata(title: "7 Years")
        )
        XCTAssertEqual(r.title, "7 Years")
    }

    func testEmbeddedTrackNumberPreferredOverTitleDigits() {
        // The leading digits of a title must never be stolen as the track number.
        let r = LibraryService.resolvedTrackMetadata(
            fileName: "99 Problems.mp3",
            pathComponents: ["Music", "Jay-Z", "The Black Album", "99 Problems.mp3"],
            rootComponents: ["Music"],
            sourceName: "NAS",
            embedded: EmbeddedMediaMetadata(title: "99 Problems", trackNumber: 10)
        )
        XCTAssertEqual(r.title, "99 Problems")
        XCTAssertEqual(r.trackNumber, 10)
    }

    // MARK: Conservative identity re-key map (item 3)

    private func key(_ source: SourceID, _ share: ShareID, path: String, size: Int64, modified: Double) -> String {
        RemoteItemIdentity(
            sourceID: source, shareID: share,
            path: RemotePath(displayPath: path),
            size: size, modifiedAt: Date(timeIntervalSince1970: modified)
        ).stableKey
    }

    func testUniquePathMatchRemapsOldToNew() {
        let s = SourceID(); let sh = ShareID()
        let oldA = key(s, sh, path: "Music/A.mp3", size: 10, modified: 1)
        let newA = key(s, sh, path: "Music/A.mp3", size: 20, modified: 99)   // re-tagged: new key, same path
        let stable = key(s, sh, path: "Music/B.mp3", size: 5, modified: 2)   // unchanged

        let remap = LibraryService.identityRemap(oldIDs: [oldA, stable], newIDs: [newA, stable])
        XCTAssertEqual(remap[oldA], newA)
        XCTAssertNil(remap[stable], "an unchanged (surviving) key is never remapped")
        XCTAssertEqual(remap.count, 1)
    }

    func testRemovedFileIsNotRemapped() {
        let s = SourceID(); let sh = ShareID()
        let gone = key(s, sh, path: "Music/Gone.mp3", size: 10, modified: 1)
        let added = key(s, sh, path: "Music/New.mp3", size: 3, modified: 4)   // different path
        let remap = LibraryService.identityRemap(oldIDs: [gone], newIDs: [added])
        XCTAssertTrue(remap.isEmpty, "0 path-prefix matches → no remap (conservative)")
    }

    func testNoChangeYieldsNoRemap() {
        let s = SourceID(); let sh = ShareID()
        let a = key(s, sh, path: "Music/A.mp3", size: 10, modified: 1)
        let remap = LibraryService.identityRemap(oldIDs: [a], newIDs: [a])
        XCTAssertTrue(remap.isEmpty)
    }
}
