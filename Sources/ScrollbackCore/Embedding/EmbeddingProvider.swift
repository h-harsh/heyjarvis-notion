import Foundation

/// Whether a text is being embedded as a search QUERY or as a stored DOCUMENT.
/// Embedding models (EmbeddingGemma included) prepend different task prefixes for the
/// two — the abstraction lives here so a query and a document of the same words don't
/// have to produce the same vector, and so models stay swappable (tech-spec D3).
public enum EmbeddingKind: String, Sendable {
    case query
    case document
}

/// A dense embedding of a chunk or query, L2-normalized so a dot product IS cosine
/// similarity. Carries `modelID` so a later model change re-embeds lazily instead of
/// rewriting history (mirrors `Chunk.modelID`/`dim`).
public struct Embedding: Sendable, Equatable {
    public let values: [Float]
    public let modelID: String

    public var dim: Int { values.count }

    public init(values: [Float], modelID: String) {
        self.values = values
        self.modelID = modelID
    }
}

/// Produces embeddings. The real implementation is EmbeddingGemma-300m on bundled
/// llama.cpp (512d Matryoshka) — a large first-launch download that needs the founder's
/// networked Mac. This protocol is the seam so the whole vector-retrieval pipeline is
/// built + tested headless against a deterministic stand-in, and the real model drops
/// in without touching the store or ranker.
public protocol EmbeddingProvider: AnyObject {
    /// Stamped onto every vector so a model swap triggers lazy re-embedding.
    var modelID: String { get }
    /// Native embedding width before Matryoshka truncation (EmbeddingGemma: 768).
    var dimension: Int { get }
    func embed(_ text: String, kind: EmbeddingKind) -> Embedding
}

public extension EmbeddingProvider {
    /// Batch helper — the real backend overrides this to batch on the ANE/Metal.
    func embed(_ texts: [String], kind: EmbeddingKind) -> [Embedding] {
        texts.map { embed($0, kind: kind) }
    }
}

/// A deterministic, dependency-free embedding provider using the hashing trick
/// (feature-hashed word uni+bigrams → fixed-width vector → L2-normalize). It is BOTH:
///   - the test double that lets the vector pipeline be verified headless, and
///   - an honest no-model FALLBACK so semantic search degrades gracefully (returns
///     sane lexical-overlap rankings) BEFORE EmbeddingGemma has downloaded.
///
/// It is LEXICAL, not semantic: shared words raise similarity, synonyms do not. Real
/// meaning-aware recall needs the model — this just keeps the pipeline honest and
/// working meanwhile. Deterministic (fixed FNV seed) so vectors are reproducible.
public final class HashingEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let dimension: Int

    public init(dimension: Int = 512, modelID: String = "hashing-lexical-v1") {
        precondition(dimension > 0)
        self.dimension = dimension
        self.modelID = "\(modelID)-\(dimension)d"
    }

    /// `kind` is accepted for protocol compatibility with the real model (which uses
    /// per-kind task prefixes) but is deliberately IGNORED here: a lexical hashing
    /// embedder must map a query and a matching document of the same words into the
    /// SAME subspace, or they'd never match. Salting by kind would push them apart.
    public func embed(_ text: String, kind: EmbeddingKind) -> Embedding {
        var acc = [Float](repeating: 0, count: dimension)
        let tokens = Self.tokenize(text)

        // UNSIGNED term-frequency hashing (each feature adds +1 to its bucket). Unsigned
        // matters: a shared word then ALWAYS raises the dot product, so texts sharing
        // content reliably outscore unrelated ones — signed hashing can cancel the one
        // shared term on a short query via a bucket collision and score exactly 0.
        // Collisions only add baseline similarity; they never erase the real signal.
        // Unigrams + bigrams (bigrams give a little word-order signal).
        func add(_ feature: String) {
            acc[Int(Self.fnv1a(feature) % UInt64(dimension))] += 1
        }
        for token in tokens { add(token) }
        for pair in zip(tokens, tokens.dropFirst()) { add(pair.0 + "\u{1F}" + pair.1) }

        return Embedding(values: Self.l2Normalized(acc), modelID: modelID)
    }

    // MARK: - Helpers

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// L2-normalize so dot product == cosine. An all-zero vector (no tokens) stays zero
    /// — its similarity to anything is 0, which is the correct "no signal" answer.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// FNV-1a 64 (same family as NearDup's shingler) — deterministic across runs.
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
