import XCTest
@testable import Evensong

/// `artistMatchRank` decides whether (and how well) a search query matches an artist
/// name — the logic behind "type part of an artist, see the artist as the top result".
/// It's pure and case/diacritic-insensitive, so it's captured here.
final class ArtistSearchTests: XCTestCase {

    func testExactMatchIsBestRank() {
        XCTAssertEqual(AppModel.artistMatchRank(name: "Radiohead", query: "radiohead"), 0)
        XCTAssertEqual(AppModel.artistMatchRank(name: "Radiohead", query: "  RADIOHEAD  "), 0)
    }

    func testLeadingPrefixMatches() {
        // "my chemical" → "My Chemical Romance", the reported case.
        XCTAssertEqual(AppModel.artistMatchRank(name: "My Chemical Romance", query: "my chemical"), 1)
        XCTAssertEqual(AppModel.artistMatchRank(name: "My Chemical Romance", query: "my"), 1)
    }

    func testInteriorWordPrefixMatches() {
        // A word other than the first starts with the query.
        XCTAssertEqual(AppModel.artistMatchRank(name: "My Chemical Romance", query: "chemical"), 2)
        XCTAssertEqual(AppModel.artistMatchRank(name: "Ludwig van Beethoven", query: "beethoven"), 2)
    }

    func testContainsButNotWordStartIsWeakestMatch() {
        // "hemical" appears mid-word, so it's a contains-match, not a prefix.
        XCTAssertEqual(AppModel.artistMatchRank(name: "My Chemical Romance", query: "hemical"), 3)
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(AppModel.artistMatchRank(name: "Fauré", query: "faure"), 0)
        XCTAssertEqual(AppModel.artistMatchRank(name: "Björk", query: "bjork"), 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(AppModel.artistMatchRank(name: "Radiohead", query: "beatles"))
        XCTAssertNil(AppModel.artistMatchRank(name: "Radiohead", query: ""))
        XCTAssertNil(AppModel.artistMatchRank(name: "Radiohead", query: "   "))
    }

    func testBetterRankSortsAhead() {
        // The ordering artistResults relies on: exact(0) < prefix(1) < word(2) < contains(3).
        let exact = AppModel.artistMatchRank(name: "The Cure", query: "the cure")!
        let prefix = AppModel.artistMatchRank(name: "The Cured", query: "the cure")!
        let word = AppModel.artistMatchRank(name: "Robert Cure", query: "cure")!
        XCTAssertLessThan(exact, prefix)
        XCTAssertLessThan(prefix, word)
    }

    func testHyphenatedInteriorWordIsAPrefixMatch() {
        // A hyphen counts as a word boundary, so "sophie" is a word-prefix (rank 2),
        // not a mid-string contains (rank 3).
        XCTAssertEqual(AppModel.artistMatchRank(name: "Anne-Sophie Mutter", query: "sophie"), 2)
    }

    // MARK: rankedArtists — the ordering/gating the search UI actually depends on

    private func artist(_ name: String, tracks: Int = 1) -> Artist {
        Artist(id: name.lowercased(), name: name, albumCount: 1, trackCount: tracks, artworkURL: nil)
    }

    func testRankedArtistsPutsBestMatchFirst() {
        let all = [artist("The Cure Tribute"), artist("The Cure"), artist("Robert Cure")]
        // exact "The Cure" (0) beats the prefix "The Cure Tribute" (1); "Robert Cure"
        // doesn't match "the cure" at all.
        XCTAssertEqual(AppModel.rankedArtists(all, query: "the cure").map(\.name), ["The Cure", "The Cure Tribute"])
    }

    func testRankedArtistsTieBreaksByTrackCount() {
        // Both are name-prefix matches on "metal" (rank 1) → the bigger artist wins.
        let all = [artist("Metallica", tracks: 5), artist("Metal Church", tracks: 99)]
        XCTAssertEqual(AppModel.rankedArtists(all, query: "metal").first?.name, "Metal Church")
    }

    func testRankedArtistsCapsAtSix() {
        let all = (1...8).map { artist("Artist \($0)") }   // all contain "artist"
        XCTAssertEqual(AppModel.rankedArtists(all, query: "artist").count, 6)
    }

    func testSingleCharQueryMatchesOnlyExactName() {
        // "M" reaches the artist literally named "M" but not everyone starting with "m".
        let all = [artist("M"), artist("Metallica"), artist("Madonna")]
        XCTAssertEqual(AppModel.rankedArtists(all, query: "M").map(\.name), ["M"])
    }

    func testRankedArtistsEmptyQueryReturnsNothing() {
        XCTAssertTrue(AppModel.rankedArtists([artist("X")], query: "  ").isEmpty)
    }
}
