import Foundation

/// A simple strategy that picks tokens from the latest (most recent) window at each position.
///
/// This is the baseline strategy - it groups tokens by timestamp, then for each
/// position picks the token from the highest-indexed window. Tokens are confirmed
/// when they're old enough that no future windows will cover them.
///
/// This strategy is useful as a starting point and for comparison with more
/// sophisticated approaches.
public struct LatestWindowStrategy: TranscriptionStrategy {
    public let name = "LatestWindow"

    public init() {}

    public func execute(_ input: StrategyInput) -> StrategyOutput {
        guard !input.windows.isEmpty else {
            return StrategyOutput(tokens: [])
        }

        // Build position groups from all windows
        let groups = buildPositionGroups(
            windows: input.windows,
            marginMs: input.config.positionMarginMs
        )

        // Select best token for each position and determine confirmation status
        var outputTokens: [OutputToken] = []

        for group in groups {
            guard !group.candidates.isEmpty else { continue }

            // Pick from the latest (highest index) window
            let selected = group.candidates.max(by: { $0.windowIndex < $1.windowIndex })!

            // Count agreement/disagreement
            let agreementCount = group.candidates.filter { $0.tokenId == selected.tokenId }.count
            let disagreementCount = group.candidates.count - agreementCount

            // Determine if this token should be confirmed
            let isConfirmed = shouldConfirm(
                tokenTimestampMs: selected.timestampMs,
                agreementCount: agreementCount,
                latestAudioTimeMs: input.latestAudioTimeMs,
                config: input.config
            )

            let outputToken = OutputToken(
                tokenId: selected.tokenId,
                text: selected.text,
                confidence: selected.confidence,
                timestampMs: selected.timestampMs,
                isConfirmed: isConfirmed,
                sourceWindowIndex: selected.windowIndex,
                agreementCount: agreementCount,
                disagreementCount: disagreementCount
            )

            outputTokens.append(outputToken)
        }

        // Sort by timestamp to ensure correct order
        outputTokens.sort { $0.timestampMs < $1.timestampMs }

        return StrategyOutput(tokens: outputTokens)
    }

    // MARK: - Private Helpers

    /// Determine if a token should be confirmed.
    ///
    /// A token is confirmed if:
    /// 1. It's old enough that no future windows will cover it (de facto confirmed), OR
    /// 2. It has enough agreement across windows (early confirmation)
    private func shouldConfirm(
        tokenTimestampMs: Int,
        agreementCount: Int,
        latestAudioTimeMs: Int,
        config: StrategyConfig
    ) -> Bool {
        // De facto confirmation: token is old enough that no future window will cover it.
        // If the latest audio is at time T, and windows are W ms long, then any token
        // at time < (T - W) is de facto confirmed.
        let deFactoConfirmationThreshold = latestAudioTimeMs - config.windowDurationMs
        if tokenTimestampMs < deFactoConfirmationThreshold {
            return true
        }

        // Early confirmation: enough windows agree
        if agreementCount >= config.earlyConfirmationThreshold {
            return true
        }

        return false
    }

    /// Build position groups from all windows.
    ///
    /// Collects all tokens from all windows, sorts by timestamp, and groups
    /// tokens that are within `marginMs` of each other.
    private func buildPositionGroups(
        windows: [TranscriptionWindow],
        marginMs: Int
    ) -> [Candidate.Group] {
        // Collect all candidates with their window index
        var allCandidates: [Candidate] = []
        for window in windows {
            for inputToken in window.tokens {
                let candidate = Candidate(
                    tokenId: inputToken.tokenId,
                    text: inputToken.text,
                    confidence: inputToken.confidence,
                    timestampMs: inputToken.timestampMs,
                    positionInWindow: inputToken.positionInWindow,
                    windowIndex: window.windowIndex
                )
                allCandidates.append(candidate)
            }
        }

        // Sort by timestamp
        allCandidates.sort { $0.timestampMs < $1.timestampMs }

        // Group candidates that are within marginMs of each other
        var groups: [Candidate.Group] = []
        var currentGroup: Candidate.Group?

        for candidate in allCandidates {
            if let group = currentGroup {
                // Check if this candidate overlaps with the current group
                let groupEnd = group.referenceTimestampMs + marginMs
                if candidate.timestampMs <= groupEnd {
                    // Add to current group
                    currentGroup?.candidates.append(candidate)
                } else {
                    // Finalize current group and start new one
                    groups.append(group)
                    currentGroup = Candidate.Group(
                        referenceTimestampMs: candidate.timestampMs,
                        candidates: [candidate]
                    )
                }
            } else {
                // First candidate
                currentGroup = Candidate.Group(
                    referenceTimestampMs: candidate.timestampMs,
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

    // MARK: - Internal Types (nested to avoid namespace conflicts)

    /// A token candidate for a position, with metadata about which window it came from.
    private struct Candidate {
        let tokenId: Int
        let text: String
        let confidence: Float
        let timestampMs: Int
        let positionInWindow: Float
        let windowIndex: Int

        /// A group of token candidates at approximately the same time position.
        struct Group {
            let referenceTimestampMs: Int
            var candidates: [Candidate]
        }
    }
}
