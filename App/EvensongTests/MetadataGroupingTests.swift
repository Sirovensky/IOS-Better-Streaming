import XCTest
@testable import Evensong

/// Disc-subfolder collapsing: every variant a real library uses must group into
/// ONE album, and album-like names must never be swallowed as disc markers.
final class MetadataGroupingTests: XCTestCase {

    private func albumID(_ path: String) -> String {
        MetadataGrouping.albumID(path: path, album: "Ignored")
    }

    func testDiscFolderVariantsCollapseIntoOneAlbum() {
        let base = "Music/Janáček - Jenůfa"
        let variants = [
            "CD1", "CD 2", "cd12", "Disc 1", "DISK 3", "Disc 1 - Act I",
            "Janáček - Jenůfa CD1", "Jenůfa CD2", "Vol. 2", "Volume 3",
            "Part 2", "CD II", "1", "02",
        ]
        let expected = albumID("\(base)/direct.flac")
        for v in variants {
            XCTAssertEqual(albumID("\(base)/\(v)/track.flac"), expected,
                           "\(v) should collapse into the parent album folder")
        }
    }

    func testAlbumLikeNamesAreNotTreatedAsDiscFolders() {
        let base = "Music/Artist"
        let albums = ["Discography", "Cadillac", "CD Collection", "Partisan",
                      "Volatile", "Room 237", "24K Magic", "Greatest Hits"]
        let parentID = albumID("\(base)/loose.flac")
        for a in albums {
            XCTAssertNotEqual(albumID("\(base)/\(a)/track.flac"), parentID,
                              "\(a) is an album, not a disc marker")
        }
    }

    func testMultiDiscTagsStillGroupByFolder() {
        // Per-disc album tags ("Jenůfa CD1" vs "Jenůfa CD2") must not matter —
        // the folder key wins for nested layouts.
        let a = MetadataGrouping.albumID(path: "Music/Opera/Jenůfa/CD1/t1.flac", album: "Jenůfa CD1")
        let b = MetadataGrouping.albumID(path: "Music/Opera/Jenůfa/CD2/t2.flac", album: "Jenůfa CD2")
        XCTAssertEqual(a, b)
    }
}
