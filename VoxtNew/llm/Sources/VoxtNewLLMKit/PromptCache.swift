import Foundation

/// A model's state after the shared part of its prompts (the system prompt
/// and any turns before the user's message), kept to skip evaluating it
/// again: the most recently used first, bounded by count and by bytes.
/// What a snapshot is (an MLX model's KV and linear-attention caches) is
/// the engine's; this decides which one a prompt reuses and which to keep.
///
/// A snapshot is only ever reused whole: Qwen3.5's linear-attention state
/// cannot be rewound, so an entry serves a prompt that starts with all of
/// its tokens and has at least one more.
public struct PromptCache<Snapshot> {
    public struct Entry {
        public let tokens: [Int]
        public let snapshot: Snapshot
        public let bytes: Int
    }

    /// What a chat does with the cache: start from entry (nil: from
    /// nothing), evaluate the prompt up to storeAt on its own and keep a
    /// snapshot there (nil: keep none), then evaluate the rest.
    ///
    /// A cold prompt is split at its shared prefix whether or not it fits
    /// (maximumEntries 0 keeps nothing and still splits): the evaluation's
    /// chunks, and so a greedy answer to the last bit, do not depend on
    /// what the cache holds.
    public struct Plan {
        public let entry: Entry?
        public let storeAt: Int?

        /// Prompt tokens whose evaluation the entry saves.
        public var reusedTokens: Int { entry?.tokens.count ?? 0 }
    }

    public let maximumEntries: Int
    public let maximumBytes: Int
    /// A shared prefix shorter than this is not kept (its snapshot would
    /// cost more memory than its evaluation costs time).
    public let minimumTokens: Int
    public private(set) var entries: [Entry] = []

    public init(maximumEntries: Int, maximumBytes: Int, minimumTokens: Int) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.minimumTokens = minimumTokens
    }

    public var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    /// The plan for a prompt whose first sharedPrefix tokens are the part
    /// other prompts share (0: none). The entry it reuses becomes the most
    /// recently used.
    public mutating func plan(tokens: [Int], sharedPrefix: Int) -> Plan {
        var best: Int?
        for (i, e) in entries.enumerated() where e.tokens.count < tokens.count && tokens.starts(with: e.tokens) {
            if best.map({ e.tokens.count > entries[$0].tokens.count }) ?? true {
                best = i
            }
        }
        let entry = best.map { entries.remove(at: $0) }
        if let entry {
            entries.insert(entry, at: 0)
        }
        let reused = entry?.tokens.count ?? 0
        let store = sharedPrefix >= minimumTokens && sharedPrefix > reused && sharedPrefix < tokens.count
        return Plan(entry: entry, storeAt: store ? sharedPrefix : nil)
    }

    /// Keeps a snapshot of the state after tokens, as the most recently
    /// used, then drops the least recently used beyond the bounds. A
    /// snapshot larger than maximumBytes is not kept.
    public mutating func insert(tokens: [Int], snapshot: Snapshot, bytes: Int) {
        entries.removeAll { $0.tokens == tokens }
        guard maximumEntries > 0, bytes <= maximumBytes else { return }
        entries.insert(Entry(tokens: tokens, snapshot: snapshot, bytes: bytes), at: 0)
        while entries.count > maximumEntries || self.bytes > maximumBytes {
            entries.removeLast()
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

/// How many leading tokens a and b share.
public func sharedPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
    zip(a, b).prefix { $0 == $1 }.count
}
