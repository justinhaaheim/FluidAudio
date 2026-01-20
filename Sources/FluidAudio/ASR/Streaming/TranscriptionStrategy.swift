import Foundation

// MARK: - Strategy Protocol

/// A transcription strategy that synthesizes tokens from multiple overlapping windows.
///
/// Strategies are pure functions: same input always produces same output.
/// This enables easy testing, comparison, and deterministic behavior.
public protocol TranscriptionStrategy: Sendable {
    /// Execute the strategy on the given input.
    /// - Parameter input: All available window data and configuration
    /// - Returns: Synthesized tokens and decisions
    func execute(_ input: StrategyInput) -> StrategyOutput

    /// Name of this strategy (for logging/debugging)
    var name: String { get }
}

// MARK: - Strategy Input

/// Everything the strategy needs to make decisions.
///
/// The strategy re-derives output tokens from windows on each call.
/// Windows are the source of truth.
public struct StrategyInput: Sendable, Codable {
    /// All recent transcription windows (typically last 30-45+ seconds worth).
    /// Each window represents one transcription run over a segment of audio.
    public let windows: [TranscriptionWindow]

    /// Configuration for the strategy
    public let config: StrategyConfig

    /// The end time of the most recent audio received (milliseconds).
    /// Used to determine which tokens can be confirmed (no more windows coming).
    public let latestAudioTimeMs: Int

    public init(
        windows: [TranscriptionWindow],
        config: StrategyConfig,
        latestAudioTimeMs: Int
    ) {
        self.windows = windows
        self.config = config
        self.latestAudioTimeMs = latestAudioTimeMs
    }
}

// MARK: - Transcription Window

/// One transcription run over a segment of audio.
///
/// A window captures the result of running the ASR model on a time range.
/// Multiple windows may overlap, covering the same audio from different
/// starting points or with different decoder states.
public struct TranscriptionWindow: Sendable, Codable {
    /// Sequential index of this window (0, 1, 2, ...)
    public let windowIndex: Int

    /// Absolute start time in the recording (milliseconds)
    public let startTimeMs: Int

    /// Duration of this window (milliseconds)
    public let durationMs: Int

    /// All tokens produced by this transcription run
    public let tokens: [InputToken]

    /// Whether this run used preserved decoder state from a previous run
    public let wasStateful: Bool

    /// End time of this window (computed)
    public var endTimeMs: Int { startTimeMs + durationMs }

    public init(
        windowIndex: Int,
        startTimeMs: Int,
        durationMs: Int,
        tokens: [InputToken],
        wasStateful: Bool
    ) {
        self.windowIndex = windowIndex
        self.startTimeMs = startTimeMs
        self.durationMs = durationMs
        self.tokens = tokens
        self.wasStateful = wasStateful
    }
}

// MARK: - Input Token

/// A single token from a transcription window (input to the strategy).
///
/// This represents the model's prediction for one token, including
/// metadata about where it appeared within the window.
public struct InputToken: Sendable, Codable {
    /// The raw token ID from the model vocabulary
    public let tokenId: Int

    /// The decoded text for this token
    public let text: String

    /// Model confidence score (0.0 - 1.0)
    public let confidence: Float

    /// Absolute position in the recording (milliseconds)
    public let timestampMs: Int

    /// Position within the window (0.0 = start, 1.0 = end).
    /// Useful for center-preference scoring - tokens in the middle
    /// of a window may be more reliable than those at edges.
    public let positionInWindow: Float

    public init(
        tokenId: Int,
        text: String,
        confidence: Float,
        timestampMs: Int,
        positionInWindow: Float
    ) {
        self.tokenId = tokenId
        self.text = text
        self.confidence = confidence
        self.timestampMs = timestampMs
        self.positionInWindow = positionInWindow
    }
}

// MARK: - Strategy Configuration

/// Configuration for strategy behavior.
public struct StrategyConfig: Sendable, Codable {
    /// Margin for considering tokens at "same position" (milliseconds).
    /// Tokens within this margin of each other may be grouped as candidates
    /// for the same output position.
    public let positionMarginMs: Int

    /// Minimum confidence to consider a token valid
    public let minConfidence: Float

    /// Number of agreeing windows needed to confirm a token early
    /// (before it ages out of the window range)
    public let earlyConfirmationThreshold: Int

    /// Duration of the sliding window (milliseconds).
    /// Used to determine when tokens are "de facto confirmed"
    /// (no more windows will cover them).
    public let windowDurationMs: Int

    public static let `default` = StrategyConfig(
        positionMarginMs: 100,
        minConfidence: 0.3,
        earlyConfirmationThreshold: 3,
        windowDurationMs: 15000
    )

    public init(
        positionMarginMs: Int,
        minConfidence: Float,
        earlyConfirmationThreshold: Int,
        windowDurationMs: Int
    ) {
        self.positionMarginMs = positionMarginMs
        self.minConfidence = minConfidence
        self.earlyConfirmationThreshold = earlyConfirmationThreshold
        self.windowDurationMs = windowDurationMs
    }
}

// MARK: - Strategy Output

/// Everything the strategy decided.
public struct StrategyOutput: Sendable, Codable {
    /// The synthesized token sequence
    public let tokens: [OutputToken]

    /// Whether to reset decoder state before next window
    public let shouldResetDecoder: Bool

    /// Reason for decoder reset (for logging/debugging)
    public let resetReason: String?

    /// Diagnostics for logging/debugging
    public let diagnostics: [StrategyDiagnostic]

    public init(
        tokens: [OutputToken],
        shouldResetDecoder: Bool = false,
        resetReason: String? = nil,
        diagnostics: [StrategyDiagnostic] = []
    ) {
        self.tokens = tokens
        self.shouldResetDecoder = shouldResetDecoder
        self.resetReason = resetReason
        self.diagnostics = diagnostics
    }

    /// Convenience: render tokens to text by concatenation
    public var text: String {
        tokens.map(\.text).joined()
    }

    /// Convenience: confirmed portion of the transcript
    public var confirmedText: String {
        tokens.filter(\.isConfirmed).map(\.text).joined()
    }

    /// Convenience: volatile (unconfirmed) portion of the transcript
    public var volatileText: String {
        tokens.filter { !$0.isConfirmed }.map(\.text).joined()
    }
}

// MARK: - Output Token

/// A token in the output transcript.
///
/// This is the result of synthesizing across multiple windows -
/// the "best" token for each position in the transcript.
public struct OutputToken: Sendable, Codable {
    /// The token ID
    public let tokenId: Int

    /// The text
    public let text: String

    /// Confidence of the chosen candidate
    public let confidence: Float

    /// Absolute position in recording (milliseconds)
    public let timestampMs: Int

    /// Whether this token is confirmed (locked in) or volatile.
    /// Confirmed tokens won't change; volatile tokens may be revised
    /// as more windows arrive.
    public let isConfirmed: Bool

    /// Which window this token was sourced from
    public let sourceWindowIndex: Int

    /// How many windows agreed on this token (same tokenId at this position)
    public let agreementCount: Int

    /// How many windows had a different token at this position
    public let disagreementCount: Int

    public init(
        tokenId: Int,
        text: String,
        confidence: Float,
        timestampMs: Int,
        isConfirmed: Bool,
        sourceWindowIndex: Int,
        agreementCount: Int,
        disagreementCount: Int
    ) {
        self.tokenId = tokenId
        self.text = text
        self.confidence = confidence
        self.timestampMs = timestampMs
        self.isConfirmed = isConfirmed
        self.sourceWindowIndex = sourceWindowIndex
        self.agreementCount = agreementCount
        self.disagreementCount = disagreementCount
    }
}

// MARK: - Diagnostic

/// A diagnostic message from the strategy.
public struct StrategyDiagnostic: Sendable, Codable {
    public enum Level: String, Sendable, Codable {
        case info
        case warning
        case error
    }

    public let level: Level
    public let message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}
