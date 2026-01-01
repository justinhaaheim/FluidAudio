import Foundation

// MARK: - Token Candidate

/// A single token prediction from one window, used for cross-window comparison
public struct TokenCandidate: Sendable {
    /// The raw token ID from the model vocabulary
    public let tokenId: Int

    /// The decoded text for this token
    public let text: String

    /// Model confidence score (0.0 - 1.0)
    public let confidence: Float

    /// Absolute start time in the recording (milliseconds)
    public let startTimeMs: Int

    /// Duration of this token (milliseconds)
    public let durationMs: Int

    /// End time (computed)
    public var endTimeMs: Int { startTimeMs + durationMs }

    /// Which window this candidate came from
    public let windowIndex: Int

    /// Position within the window (0.0 = start, 1.0 = end)
    /// Used for center-preference scoring
    public let positionRatio: Float

    /// Whether this token was in the edge buffer zone
    public let isEdgeToken: Bool
}

// MARK: - Window Data (for synthesis)

/// A transcription window with all its token candidates
public struct SynthesisWindowData: Sendable {
    /// Sequential index of this window
    public let windowIndex: Int

    /// Absolute start time of this window (milliseconds)
    public let startTimeMs: Int

    /// Duration of this window (milliseconds)
    public let durationMs: Int

    /// All token candidates from this window
    public let tokens: [TokenCandidate]

    /// End time (computed)
    public var endTimeMs: Int { startTimeMs + durationMs }
}

// MARK: - Confirmed Token

/// A token that has been "locked in" and won't change
public struct ConfirmedToken: Sendable {
    public let tokenId: Int
    public let text: String
    public let confidence: Float
    public let startTimeMs: Int
    public let durationMs: Int
    public let sourceWindowIndex: Int
    public let confirmedAtWindowIndex: Int
    public let upvotes: Int
    public let downvotes: Int
}

// MARK: - Synthesized Token (Output)

/// Output token from synthesis with voting information
public struct SynthesizedToken: Sendable {
    /// The token text
    public let text: String

    /// Token ID
    public let tokenId: Int

    /// Confidence of the chosen candidate
    public let confidence: Float

    /// Absolute start time (milliseconds)
    public let startTimeMs: Int

    /// Duration (milliseconds)
    public let durationMs: Int

    /// Which window this token was chosen from
    public let sourceWindowIndex: Int

    /// How many windows agreed with this choice
    public let upvotes: Int

    /// How many windows had a different token at this position
    public let downvotes: Int

    /// Whether this token is now confirmed (locked in)
    public let isConfirmed: Bool

    /// All candidates that were considered for this position
    public let candidates: [TokenCandidate]
}

// MARK: - Merge Strategy

/// Strategy for choosing tokens when synthesizing across windows
public enum MergeStrategy: Sendable {
    /// Use tokens from the most recent window (current naive approach)
    case latestWindow

    /// Pick the token with highest confidence at each position
    case highestConfidence

    /// Pick the token that appears in the most windows (most votes)
    case mostVotes

    /// Pick the token closest to the center of its window
    case centerPreference

    /// Weighted combination of all factors
    case weightedComposite(weights: StrategyWeights)
}

/// Weights for the composite strategy
public struct StrategyWeights: Sendable {
    /// Weight for cross-window agreement (0.0 - 1.0)
    public var agreement: Float

    /// Weight for model confidence (0.0 - 1.0)
    public var confidence: Float

    /// Weight for center-of-window proximity (0.0 - 1.0)
    public var centerProximity: Float

    /// Weight for keeping tokens from same window (continuity) (0.0 - 1.0)
    public var continuity: Float

    public static let `default` = StrategyWeights(
        agreement: 0.3,
        confidence: 0.3,
        centerProximity: 0.2,
        continuity: 0.2
    )

    public init(agreement: Float, confidence: Float, centerProximity: Float, continuity: Float) {
        self.agreement = agreement
        self.confidence = confidence
        self.centerProximity = centerProximity
        self.continuity = continuity
    }
}

// MARK: - Synthesis Configuration

/// Configuration for the synthesis process
public struct SynthesisConfig: Sendable {
    /// Margin for considering tokens at the "same position" (milliseconds)
    /// Tokens with overlapping time ranges within this margin are candidates for the same position
    public let overlapMarginMs: Int

    /// Minimum votes needed to confirm a token
    public let confirmationVoteThreshold: Int

    /// Minimum confidence needed to confirm a token
    public let confirmationConfidenceThreshold: Float

    /// Whether to ignore tokens in edge buffer zones when counting votes
    public let ignoreEdgeTokensForVoting: Bool

    public static let `default` = SynthesisConfig(
        overlapMarginMs: 100,
        confirmationVoteThreshold: 2,
        confirmationConfidenceThreshold: 0.85,
        ignoreEdgeTokensForVoting: true
    )

    public init(
        overlapMarginMs: Int,
        confirmationVoteThreshold: Int,
        confirmationConfidenceThreshold: Float,
        ignoreEdgeTokensForVoting: Bool
    ) {
        self.overlapMarginMs = overlapMarginMs
        self.confirmationVoteThreshold = confirmationVoteThreshold
        self.confirmationConfidenceThreshold = confirmationConfidenceThreshold
        self.ignoreEdgeTokensForVoting = ignoreEdgeTokensForVoting
    }
}

// MARK: - Synthesis Context & Result

/// Input context for synthesis (pure function input)
public struct SynthesisContext: Sendable {
    /// All available windows
    public let windows: [SynthesisWindowData]

    /// Already confirmed tokens (won't change)
    public let confirmedTokens: [ConfirmedToken]

    /// Strategy to use
    public let strategy: MergeStrategy

    /// Configuration
    public let config: SynthesisConfig

    public init(
        windows: [SynthesisWindowData],
        confirmedTokens: [ConfirmedToken],
        strategy: MergeStrategy,
        config: SynthesisConfig = .default
    ) {
        self.windows = windows
        self.confirmedTokens = confirmedTokens
        self.strategy = strategy
        self.config = config
    }
}

/// Output from synthesis (pure function output)
public struct SynthesisResult: Sendable {
    /// Full synthesized token sequence
    public let tokens: [SynthesizedToken]

    /// Tokens that became confirmed in this pass
    public let newlyConfirmed: [SynthesizedToken]

    /// Combined text
    public var text: String {
        tokens.map(\.text).joined()
    }
}

// MARK: - Window History (Storage)

/// Accumulates windows and provides query access for synthesis
public final class WindowHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [SynthesisWindowData] = []
    private var confirmedTokens: [ConfirmedToken] = []

    /// Maximum number of windows to keep (for memory management)
    public let maxWindows: Int

    public init(maxWindows: Int = 50) {
        self.maxWindows = maxWindows
    }

    /// Add a new window to history
    public func addWindow(_ window: SynthesisWindowData) {
        lock.lock()
        defer { lock.unlock() }

        windows.append(window)

        // Prune old windows if needed
        if windows.count > maxWindows {
            windows.removeFirst(windows.count - maxWindows)
        }
    }

    /// Get all windows
    public func allWindows() -> [SynthesisWindowData] {
        lock.lock()
        defer { lock.unlock() }
        return windows
    }

    /// Get windows that overlap with a given time range
    public func windowsOverlapping(startMs: Int, endMs: Int) -> [SynthesisWindowData] {
        lock.lock()
        defer { lock.unlock() }

        return windows.filter { window in
            // Windows overlap if neither ends before the other starts
            window.startTimeMs < endMs && window.endTimeMs > startMs
        }
    }

    /// Get all confirmed tokens
    public func allConfirmedTokens() -> [ConfirmedToken] {
        lock.lock()
        defer { lock.unlock() }
        return confirmedTokens
    }

    /// Add newly confirmed tokens
    public func addConfirmedTokens(_ tokens: [ConfirmedToken]) {
        lock.lock()
        defer { lock.unlock() }
        confirmedTokens.append(contentsOf: tokens)
    }

    /// Reset all state
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        windows.removeAll()
        confirmedTokens.removeAll()
    }

    /// Get window count
    public var windowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return windows.count
    }
}

// MARK: - Synthesis Functions (Pure)

/// Synthesize tokens from multiple windows using the specified strategy
/// This is a PURE function - no side effects
public func synthesizeTokens(context: SynthesisContext) -> SynthesisResult {
    guard !context.windows.isEmpty else {
        // Even with no windows, return confirmed tokens if we have them
        let confirmedAsSynthesized = context.confirmedTokens.map { confirmed in
            SynthesizedToken(
                text: confirmed.text,
                tokenId: confirmed.tokenId,
                confidence: confirmed.confidence,
                startTimeMs: confirmed.startTimeMs,
                durationMs: confirmed.durationMs,
                sourceWindowIndex: confirmed.sourceWindowIndex,
                upvotes: confirmed.upvotes,
                downvotes: confirmed.downvotes,
                isConfirmed: true,
                candidates: []
            )
        }
        return SynthesisResult(tokens: confirmedAsSynthesized, newlyConfirmed: [])
    }

    // Find the earliest time covered by current windows
    let earliestWindowStartMs = context.windows.map(\.startTimeMs).min() ?? 0

    // Convert confirmed tokens that are BEFORE the current window range to synthesized tokens
    // These are tokens that have "aged out" of the window history but were already confirmed
    var synthesizedTokens: [SynthesizedToken] = context.confirmedTokens
        .filter { $0.startTimeMs < earliestWindowStartMs }
        .map { confirmed in
            SynthesizedToken(
                text: confirmed.text,
                tokenId: confirmed.tokenId,
                confidence: confirmed.confidence,
                startTimeMs: confirmed.startTimeMs,
                durationMs: confirmed.durationMs,
                sourceWindowIndex: confirmed.sourceWindowIndex,
                upvotes: confirmed.upvotes,
                downvotes: confirmed.downvotes,
                isConfirmed: true,
                candidates: []
            )
        }

    // Build position groups - tokens from different windows at the same time position
    let positionGroups = buildPositionGroups(
        windows: context.windows,
        marginMs: context.config.overlapMarginMs
    )

    // Apply strategy to select best token for each position
    var newlyConfirmed: [SynthesizedToken] = []

    for group in positionGroups {
        guard !group.candidates.isEmpty else { continue }

        let selected = selectToken(
            candidates: group.candidates,
            strategy: context.strategy,
            config: context.config
        )

        // Compute votes for the selected token
        let upvotes = group.upvotes(for: selected)
        let downvotes = group.downvotes(for: selected)

        // Check if this should be confirmed
        let shouldConfirm = upvotes >= context.config.confirmationVoteThreshold
            && selected.confidence >= context.config.confirmationConfidenceThreshold

        let token = SynthesizedToken(
            text: selected.text,
            tokenId: selected.tokenId,
            confidence: selected.confidence,
            startTimeMs: selected.startTimeMs,
            durationMs: selected.durationMs,
            sourceWindowIndex: selected.windowIndex,
            upvotes: upvotes,
            downvotes: downvotes,
            isConfirmed: shouldConfirm,
            candidates: group.candidates
        )

        synthesizedTokens.append(token)

        if shouldConfirm {
            newlyConfirmed.append(token)
        }
    }

    return SynthesisResult(tokens: synthesizedTokens, newlyConfirmed: newlyConfirmed)
}

// MARK: - Position Group

/// A group of token candidates at approximately the same time position
private struct PositionGroup {
    let approximateTimeMs: Int
    var candidates: [TokenCandidate]

    /// Count how many candidates match the given token
    func upvotes(for token: TokenCandidate) -> Int {
        candidates.filter { $0.tokenId == token.tokenId }.count
    }

    /// Count how many candidates differ from the given token
    func downvotes(for token: TokenCandidate) -> Int {
        candidates.filter { $0.tokenId != token.tokenId }.count
    }
}

/// Build position groups from all windows
private func buildPositionGroups(
    windows: [SynthesisWindowData],
    marginMs: Int
) -> [PositionGroup] {
    // Collect all candidates
    var allCandidates: [TokenCandidate] = []
    for window in windows {
        allCandidates.append(contentsOf: window.tokens)
    }

    // Sort by start time
    allCandidates.sort { $0.startTimeMs < $1.startTimeMs }

    // Group candidates that overlap
    var groups: [PositionGroup] = []
    var currentGroup: PositionGroup?

    for candidate in allCandidates {
        if let group = currentGroup {
            // Check if this candidate overlaps with the current group
            let groupEnd = group.approximateTimeMs + marginMs
            if candidate.startTimeMs <= groupEnd {
                // Add to current group
                currentGroup?.candidates.append(candidate)
            } else {
                // Start new group
                groups.append(group)
                currentGroup = PositionGroup(
                    approximateTimeMs: candidate.startTimeMs,
                    candidates: [candidate]
                )
            }
        } else {
            // First candidate
            currentGroup = PositionGroup(
                approximateTimeMs: candidate.startTimeMs,
                candidates: [candidate]
            )
        }
    }

    // Don't forget the last group
    if let group = currentGroup {
        groups.append(group)
    }

    return groups
}

/// Select the best token from candidates using the specified strategy
private func selectToken(
    candidates: [TokenCandidate],
    strategy: MergeStrategy,
    config: SynthesisConfig
) -> TokenCandidate {
    guard !candidates.isEmpty else {
        fatalError("selectToken called with empty candidates")
    }

    switch strategy {
    case .latestWindow:
        // Pick from the highest window index
        return candidates.max(by: { $0.windowIndex < $1.windowIndex })!

    case .highestConfidence:
        // Pick highest confidence
        return candidates.max(by: { $0.confidence < $1.confidence })!

    case .mostVotes:
        // Count occurrences of each token ID
        var voteCounts: [Int: Int] = [:]
        for candidate in candidates {
            if config.ignoreEdgeTokensForVoting && candidate.isEdgeToken {
                continue
            }
            voteCounts[candidate.tokenId, default: 0] += 1
        }

        // Find the token ID with most votes
        let bestTokenId = voteCounts.max(by: { $0.value < $1.value })?.key
            ?? candidates.first!.tokenId

        // Return the highest-confidence candidate with that token ID
        return candidates
            .filter { $0.tokenId == bestTokenId }
            .max(by: { $0.confidence < $1.confidence })!

    case .centerPreference:
        // Pick closest to center (positionRatio closest to 0.5)
        return candidates.min(by: {
            abs($0.positionRatio - 0.5) < abs($1.positionRatio - 0.5)
        })!

    case .weightedComposite(let weights):
        // Score each candidate
        var bestCandidate = candidates.first!
        var bestScore: Float = -Float.infinity

        // Precompute vote counts
        var voteCounts: [Int: Int] = [:]
        for candidate in candidates {
            if !config.ignoreEdgeTokensForVoting || !candidate.isEdgeToken {
                voteCounts[candidate.tokenId, default: 0] += 1
            }
        }
        let maxVotes = Float(voteCounts.values.max() ?? 1)

        // Find the most common previous window for continuity scoring
        var windowCounts: [Int: Int] = [:]
        for candidate in candidates {
            windowCounts[candidate.windowIndex, default: 0] += 1
        }
        let dominantWindow = windowCounts.max(by: { $0.value < $1.value })?.key ?? -1

        for candidate in candidates {
            let voteScore = Float(voteCounts[candidate.tokenId, default: 0]) / maxVotes
            let confidenceScore = candidate.confidence
            let centerScore = 1.0 - abs(candidate.positionRatio - 0.5) * 2  // 1.0 at center, 0.0 at edges
            let continuityScore: Float = candidate.windowIndex == dominantWindow ? 1.0 : 0.0

            let score = weights.agreement * voteScore
                + weights.confidence * confidenceScore
                + weights.centerProximity * centerScore
                + weights.continuity * continuityScore

            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }
}
