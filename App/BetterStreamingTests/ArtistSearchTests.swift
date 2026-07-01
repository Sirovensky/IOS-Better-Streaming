import XCTest
@testable import BetterStreaming

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
}
