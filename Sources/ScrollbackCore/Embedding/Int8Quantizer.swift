import Foundation

/// An int8-quantized embedding as stored in the vector index (tech-spec: sqlite-vec
/// `vec0(chunk_id, embedding int8[512])`). Quantizing 512× float32 → int8 cuts vector
/// storage 4× (2KB → 512B per chunk) at a negligible recall cost, which is what keeps
/// the "single-digit GB/year" budget with millions of chunks. Dequantize as
/// `float ≈ Int8 * scale`.
public struct QuantizedEmbedding: Sendable, Equatable {
    public let ints: [Int8]
    /// Per-vector symmetric scale: `float ≈ int * scale`.
    public let scale: Float
    public let modelID: String

    public var dim: Int { ints.count }

    public init(ints: [Int8], scale: Float, modelID: String) {
        self.ints = ints
        self.scale = scale
        self.modelID = modelID
    }
}

/// Matryoshka truncation + symmetric int8 quantization. EmbeddingGemma is trained so a
/// PREFIX of its vector is itself a valid (lower-dim) embedding — so we truncate 768→512
/// (or 256/128) by taking the first `dim` components and re-normalizing, then quantize.
///
/// Pure + deterministic so the quantization-error / recall tradeoff is unit-tested
/// without the model or sqlite-vec (the interface is the swap hedge).
public enum Int8Quantizer {

    public static let defaultDim = 512

    /// Truncate to `dim` Matryoshka components, re-L2-normalize (a prefix of a unit
    /// vector isn't unit), then symmetric-quantize to int8 with a per-vector scale.
    public static func quantize(_ embedding: Embedding, dim: Int = defaultDim) -> QuantizedEmbedding {
        let width = min(dim, embedding.values.count)
        let truncated = Array(embedding.values.prefix(width))
        let unit = HashingEmbeddingProvider.l2Normalized(truncated)

        // Symmetric quantizer: map the largest-magnitude component to ±127.
        let maxMag = unit.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        let scale = maxMag > 0 ? maxMag / 127.0 : 1.0
        let ints = unit.map { value -> Int8 in
            let q = (value / scale).rounded()
            return Int8(Swift.max(-127, Swift.min(127, q))) // clamp to symmetric range (avoid -128)
        }
        return QuantizedEmbedding(ints: ints, scale: scale, modelID: embedding.modelID)
    }

    /// Reconstruct the approximate float vector (`int * scale`).
    public static func dequantize(_ q: QuantizedEmbedding) -> [Float] {
        q.ints.map { Float($0) * q.scale }
    }

    /// Cosine similarity between two quantized vectors (both were L2-normalized before
    /// quantization, so a dot of the dequantized values approximates cosine). Returns 0
    /// for a dimension mismatch (a query embedded by a different model than the stored
    /// vectors — the caller should segregate indexes by `modelID`, this is a fail-safe).
    public static func similarity(_ a: QuantizedEmbedding, _ b: QuantizedEmbedding) -> Float {
        guard a.dim == b.dim, a.dim > 0 else { return 0 }
        var dot: Float = 0
        for i in 0..<a.dim {
            dot += Float(a.ints[i]) * Float(b.ints[i])
        }
        return dot * a.scale * b.scale
    }
}
