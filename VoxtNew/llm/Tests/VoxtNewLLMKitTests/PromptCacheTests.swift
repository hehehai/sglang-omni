import XCTest
@testable import VoxtNewLLMKit

final class PromptCacheTests: XCTestCase {
    /// A cache holding Strings in place of a model's state.
    func makeCache(entries: Int = 4, bytes: Int = 100) -> PromptCache<String> {
        PromptCache(maximumEntries: entries, maximumBytes: bytes, minimumTokens: 3)
    }

    func testMissThenHit() {
        var c = makeCache()
        let system = [1, 2, 3, 4]
        let first = c.plan(tokens: system + [9, 9], sharedPrefix: 4)
        XCTAssertNil(first.entry)
        XCTAssertEqual(first.storeAt, 4)
        c.insert(tokens: system, snapshot: "system", bytes: 10)

        let second = c.plan(tokens: system + [7, 8, 9], sharedPrefix: 4)
        XCTAssertEqual(second.entry?.snapshot, "system")
        XCTAssertEqual(second.reusedTokens, 4)
        XCTAssertNil(second.storeAt, "the prefix is kept already")

        // Another system prompt with the same start: the entry is no prefix.
        let other = c.plan(tokens: [1, 2, 5, 6, 9], sharedPrefix: 4)
        XCTAssertNil(other.entry)
        XCTAssertEqual(other.storeAt, 4)
    }

    /// An entry is only reused whole, and leaves a token to evaluate.
    func testEntryMustBeAProperPrefix() {
        var c = makeCache()
        c.insert(tokens: [1, 2, 3, 4], snapshot: "a", bytes: 1)
        XCTAssertNil(c.plan(tokens: [1, 2, 3, 4], sharedPrefix: 0).entry)
        XCTAssertNil(c.plan(tokens: [1, 2, 3], sharedPrefix: 0).entry)
        XCTAssertEqual(c.plan(tokens: [1, 2, 3, 4, 5], sharedPrefix: 0).entry?.snapshot, "a")
    }

    /// The longest entry wins; a longer shared prefix is evaluated from it
    /// and kept too.
    func testLongestEntryAndExtension() {
        var c = makeCache()
        c.insert(tokens: [1, 2, 3], snapshot: "short", bytes: 1)
        c.insert(tokens: [1, 2, 3, 4, 5], snapshot: "long", bytes: 1)
        c.insert(tokens: [1, 2, 3, 9, 9, 9], snapshot: "other", bytes: 1)
        XCTAssertEqual(c.plan(tokens: [1, 2, 3, 4, 5, 6], sharedPrefix: 0).entry?.snapshot, "long")
        let p = c.plan(tokens: [1, 2, 3, 7, 7, 7, 7], sharedPrefix: 6)
        XCTAssertEqual(p.entry?.snapshot, "short")
        XCTAssertEqual(p.storeAt, 6)
    }

    func testShortOrWholePrefixesAreNotKept() {
        var c = makeCache()
        XCTAssertNil(c.plan(tokens: [1, 2, 3, 4], sharedPrefix: 2).storeAt, "under minimumTokens")
        XCTAssertNil(c.plan(tokens: [1, 2, 3, 4], sharedPrefix: 4).storeAt, "nothing would be left")
        XCTAssertNil(c.plan(tokens: [1, 2, 3, 4], sharedPrefix: 0).storeAt)
    }

    func testLeastRecentlyUsedGoesFirst() {
        var c = makeCache(entries: 2, bytes: 25)
        c.insert(tokens: [1, 1, 1], snapshot: "a", bytes: 10)
        c.insert(tokens: [2, 2, 2], snapshot: "b", bytes: 10)
        _ = c.plan(tokens: [1, 1, 1, 0], sharedPrefix: 0) // a is used
        c.insert(tokens: [3, 3, 3], snapshot: "c", bytes: 10)
        XCTAssertEqual(c.entries.map(\.snapshot), ["c", "a"], "count bound")
        c.insert(tokens: [4, 4, 4], snapshot: "d", bytes: 20)
        XCTAssertEqual(c.entries.map(\.snapshot), ["d"], "byte bound")
        c.insert(tokens: [5, 5, 5], snapshot: "huge", bytes: 26)
        XCTAssertEqual(c.entries.map(\.snapshot), ["d"], "larger than the bound: not kept")
        c.insert(tokens: [4, 4, 4], snapshot: "d2", bytes: 5)
        XCTAssertEqual(c.entries.map(\.snapshot), ["d2"], "same tokens: replaced")
        XCTAssertEqual(c.bytes, 5)
        c.removeAll()
        XCTAssertTrue(c.entries.isEmpty)
    }

    /// Turned off, it keeps nothing but plans the same split.
    func testOff() {
        var c = PromptCache<String>(maximumEntries: 0, maximumBytes: 100, minimumTokens: 3)
        XCTAssertEqual(c.plan(tokens: [1, 2, 3, 4, 5], sharedPrefix: 4).storeAt, 4)
        c.insert(tokens: [1, 2, 3, 4], snapshot: "a", bytes: 1)
        XCTAssertTrue(c.entries.isEmpty)
        XCTAssertNil(c.plan(tokens: [1, 2, 3, 4, 5], sharedPrefix: 4).entry)
    }

    func testSharedPrefixLength() {
        XCTAssertEqual(sharedPrefixLength([1, 2, 3], [1, 2, 4]), 2)
        XCTAssertEqual(sharedPrefixLength([1, 2], [1, 2, 3]), 2)
        XCTAssertEqual(sharedPrefixLength([], [1]), 0)
    }
}
