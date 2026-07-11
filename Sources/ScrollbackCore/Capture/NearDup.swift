import Foundation

/// Deterministic 64-bit PRNG (SplitMix64) — used ONCE at init to derive the
/// permutation coefficients. Not for security; only to spread fixed seeds into a
/// reproducible coefficient table so signatures are byte-for-byte stable across
/// runs and machines (a captured corpus dedups the same way every launch).
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// MinHash signature builder for near-duplicate detection over captured text.
///
/// Exact-hash dedup (`TextNormalizer.hash`) only collapses byte-identical re-reads.
/// A screen re-read of a *scrolling* or lightly-edited document is not byte-equal
/// but is ~identical — embedding both wastes the expensive embedding + vector
/// budget. MinHash estimates the Jaccard similarity of two texts' word-shingle sets
/// from a fixed-length signature; positions that match ≈ the true Jaccard.
///
/// Pure + deterministic: same text → same signature, always (the affine permutation
/// family is seeded from a fixed constant). No runtime randomness.
public struct MinHasher: Sendable {
    public let shingleSize: Int
    public let permutations: Int
    private let coeffA: [UInt64]
    private let coeffB: [UInt64]

    /// Largest prime < 2^32 — the modulus of the affine permutation family. Chosen
    /// so `a*x + b` never overflows UInt64 (a < prime < 2^32, x < 2^32) and every
    /// signature entry fits in a UInt32.
    static let prime: UInt64 = 4_294_967_291

    public init(shingleSize: Int = 3, permutations: Int = 128, seed: UInt64 = 0x5C70_1B6A_2F9E_4D13) {
        self.shingleSize = max(1, shingleSize)
        self.permutations = max(1, permutations)
        var rng = SplitMix64(state: seed)
        var a = [UInt64](); a.reserveCapacity(self.permutations)
        var b = [UInt64](); b.reserveCapacity(self.permutations)
        for _ in 0..<self.permutations {
            a.append(1 + rng.next() % (MinHasher.prime - 1)) // a ∈ [1, prime)
            b.append(rng.next() % MinHasher.prime)           // b ∈ [0, prime)
        }
        coeffA = a
        coeffB = b
    }

    /// Word-level k-shingles hashed to 32-bit values (a Set — order-independent).
    /// Text shorter than `shingleSize` words uses each word as its own shingle, so
    /// even a two-word chunk still yields a usable signature.
    func shingles(_ text: String) -> Set<UInt32> {
        let words = TextNormalizer.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var set = Set<UInt32>()
        if words.count < shingleSize {
            for word in words { set.insert(Self.fnv1a32(word)) }
            return set
        }
        for start in 0...(words.count - shingleSize) {
            let shingle = words[start..<(start + shingleSize)].joined(separator: " ")
            set.insert(Self.fnv1a32(shingle))
        }
        return set
    }

    /// The MinHash signature: for each permutation, the minimum permuted shingle
    /// value. Empty text → an all-`UInt32.max` signature (matches only other empties).
    public func signature(for text: String) -> [UInt32] {
        var sig = [UInt32](repeating: .max, count: permutations)
        let shingleSet = shingles(text)
        guard !shingleSet.isEmpty else { return sig }
        for shingle in shingleSet {
            let x = UInt64(shingle)
            for i in 0..<permutations {
                let h = (coeffA[i] &* x &+ coeffB[i]) % MinHasher.prime // < prime < 2^32
                let hv = UInt32(h)
                if hv < sig[i] { sig[i] = hv }
            }
        }
        return sig
    }

    /// Estimated Jaccard similarity ∈ [0, 1] = fraction of matching signature
    /// positions. The estimator's error is ~1/√permutations.
    public static func estimatedJaccard(_ lhs: [UInt32], _ rhs: [UInt32]) -> Double {
        let n = min(lhs.count, rhs.count)
        guard n > 0 else { return 0 }
        var match = 0
        for i in 0..<n where lhs[i] == rhs[i] { match += 1 }
        return Double(match) / Double(n)
    }

    /// FNV-1a 32-bit over UTF-8 bytes.
    static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

public struct NearDupConfig: Sendable {
    public var shingleSize: Int
    public var permutations: Int
    /// LSH bands. rows = permutations / bands. The banding S-curve is set BELOW
    /// `threshold` on purpose (128/16 → inflection ≈ 0.71) so candidates surface
    /// generously; the exact signature-Jaccard check then enforces `threshold`.
    public var bands: Int
    public var threshold: Double

    public init(shingleSize: Int = 3, permutations: Int = 128, bands: Int = 16, threshold: Double = 0.85) {
        self.shingleSize = max(1, shingleSize)
        self.permutations = max(1, permutations)
        self.bands = max(1, min(bands, self.permutations))
        self.threshold = threshold
    }

    /// Signature rows per band (trailing entries beyond `bands * rows` are unused).
    var rows: Int { max(1, permutations / bands) }
}

/// The result of offering a text to the collapser.
public enum NearDupResult: Sendable, Equatable {
    case unique(index: Int)                        // retained; assigned this signature index
    case duplicate(ofIndex: Int, jaccard: Double)  // collapsed into an earlier retained item
}

/// Streaming near-duplicate collapser: MinHash + LSH banding. Feed texts; each is
/// either RETAINED (novel) or reported as a near-duplicate of an earlier retained
/// item (≥ `threshold` estimated Jaccard). Sub-quadratic — a new text is only
/// compared against LSH-band candidates, not the whole corpus.
///
/// Not thread-safe by contract (confine to the daemon's capture run loop, like the
/// rest of the pipeline). Holds signatures in memory; for the spike this is bounded
/// by a session's chunk count. First-seen wins (the earliest retained item is the
/// representative). AX-over-OCR preference on collapse is a TODO — needs the
/// representative's source threaded through (see docs/decisions.md).
public final class NearDupCollapser {
    private let config: NearDupConfig
    private let hasher: MinHasher
    private var signatures: [[UInt32]] = []
    private var buckets: [UInt64: [Int]] = [:]
    public private(set) var retained = 0
    public private(set) var collapsed = 0

    public init(config: NearDupConfig = NearDupConfig()) {
        self.config = config
        self.hasher = MinHasher(shingleSize: config.shingleSize, permutations: config.permutations)
    }

    /// Offer `text`. Returns `.duplicate` (collapsed, not retained) if it is a
    /// near-duplicate of an already-retained item, else `.unique` (now retained and
    /// indexed for future comparisons).
    @discardableResult
    public func add(_ text: String) -> NearDupResult {
        let sig = hasher.signature(for: text)
        let keys = bandKeys(for: sig)

        var candidates = Set<Int>()
        for key in keys {
            if let bucket = buckets[key] { candidates.formUnion(bucket) }
        }

        // Verify candidates with the full signature; pick the smallest-index item
        // at the highest Jaccard (sorted iteration → deterministic tie-break).
        var best = -1
        var bestJaccard = -1.0
        for candidate in candidates.sorted() {
            let jaccard = MinHasher.estimatedJaccard(sig, signatures[candidate])
            if jaccard > bestJaccard { bestJaccard = jaccard; best = candidate }
        }
        if best >= 0, bestJaccard >= config.threshold {
            collapsed += 1
            return .duplicate(ofIndex: best, jaccard: bestJaccard)
        }

        let index = signatures.count
        signatures.append(sig)
        for key in keys { buckets[key, default: []].append(index) }
        retained += 1
        return .unique(index: index)
    }

    /// One FNV-1a-64 bucket key per band (band index folded in so identical row
    /// values in different bands land in different buckets).
    private func bandKeys(for sig: [UInt32]) -> [UInt64] {
        let rows = config.rows
        var keys = [UInt64]()
        keys.reserveCapacity(config.bands)
        for band in 0..<config.bands {
            let start = band * rows
            let end = start + rows
            guard end <= sig.count else { break }
            var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a-64 offset basis
            hash ^= UInt64(band)
            hash = hash &* 1_099_511_628_211
            for i in start..<end {
                var value = sig[i]
                for _ in 0..<4 { // fold the 4 bytes of the UInt32
                    hash ^= UInt64(value & 0xFF)
                    hash = hash &* 1_099_511_628_211
                    value >>= 8
                }
            }
            keys.append(hash)
        }
        return keys
    }
}
