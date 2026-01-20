import AVFoundation
import Foundation
import OSLog

/// A streaming ASR manager using timer-based sliding window transcription.
///
/// Unlike `BatchStyleStreamingManager` which triggers transcription based on sample count,
/// this manager runs transcription at fixed intervals (configurable from 250ms to 5s).
/// Each transcription uses the last N seconds of audio (sliding window), providing
/// full context utilization up to the model's 14-second limit.
///
/// Key features:
/// - **Timer-based**: Transcription runs at regular intervals, not when buffers fill
/// - **Sliding window**: Always transcribes the last N seconds, not sequential chunks
/// - **Full context**: Can use up to 14 seconds of context per transcription
/// - **Performance metrics**: Emits pace, RTF, and buffer stats with each update
/// - **VAD-ready**: Architecture designed for future voice activity detection
public actor SlidingWindowStreamingManager {
    private let logger = AppLogger(category: "SlidingWindowStreaming")
    private let audioConverter: AudioConverter = AudioConverter()
    private let config: SlidingWindowStreamingConfig

    // Audio buffer with absolute indexing
    private var sampleBuffer: [Float] = []
    private var totalSamplesReceived: Int = 0
    private var absoluteBufferStartSample: Int = 0  // First sample index in buffer

    // Token tracking for merging
    private var confirmedTokens: [TokenWindow] = []
    private var lastTranscriptionEndSample: Int = 0

    // ASR components
    private var asrManager: AsrManager?
    private var audioSource: AudioSource = .microphone

    // Decoder state (only used when preserveDecoderState is true)
    private var decoderState: TdtDecoderState?

    // Window history for multi-window synthesis
    private var windowHistory: WindowHistory?

    // Strategy-based synthesis (new system)
    private let strategy: any TranscriptionStrategy = LatestWindowStrategy()
    private var strategyWindows: [TranscriptionWindow] = []
    private var lastStrategyOutput: StrategyOutput?

    // Input stream
    private let inputSequence: AsyncStream<AVAudioPCMBuffer>
    private let inputBuilder: AsyncStream<AVAudioPCMBuffer>.Continuation

    // Output stream
    private var updateContinuation: AsyncStream<SlidingWindowTranscriptionUpdate>.Continuation?

    // Processing state
    private var audioReceiveTask: Task<Void, Error>?
    private var transcriptionTimerTask: Task<Void, Never>?
    private var isTranscribing: Bool = false
    private var isRunning: Bool = false

    // Two-tier transcription state (like Apple's Speech API)
    public private(set) var volatileTranscript: String = ""
    public private(set) var confirmedTranscript: String = ""

    // Metrics tracking
    private var startTime: Date?
    private var chunkCount: Int = 0
    private var lastTranscriptionDuration: TimeInterval = 0
    private var lastAudioDuration: TimeInterval = 0

    // Token window type (matches ChunkProcessor)
    private typealias TokenWindow = (token: Int, timestamp: Int, confidence: Float)

    /// Initialize the sliding window streaming manager
    public init(config: SlidingWindowStreamingConfig = .default) {
        self.config = config

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.inputSequence = stream
        self.inputBuilder = continuation

        logger.info(
            "Initialized SlidingWindowStreamingManager with interval=\(config.intervalSeconds)s " +
            "context=\(config.contextWindowSeconds)s overlap=\(config.overlapSeconds)s"
        )
    }

    /// Start the streaming engine with automatic model download
    public func start(source: AudioSource = .microphone) async throws {
        logger.info("Starting SlidingWindowStreamingManager...")

        let models = try await AsrModels.downloadAndLoad()
        try await start(models: models, source: source)
    }

    /// Start with pre-loaded models
    public func start(models: AsrModels, source: AudioSource = .microphone) async throws {
        logger.info("Starting SlidingWindowStreamingManager with pre-loaded models...")

        self.audioSource = source
        self.isRunning = true

        // Initialize ASR manager
        asrManager = AsrManager(config: ASRConfig(sampleRate: 16000, tdtConfig: TdtConfig()))
        try await asrManager?.initialize(models: models)

        // Reset state
        sampleBuffer.removeAll()
        totalSamplesReceived = 0
        absoluteBufferStartSample = 0
        confirmedTokens.removeAll()
        lastTranscriptionEndSample = 0
        chunkCount = 0
        lastTranscriptionDuration = 0
        lastAudioDuration = 0
        startTime = Date()

        // Reset transcript state
        volatileTranscript = ""
        confirmedTranscript = ""

        // Initialize decoder state if preserving
        if config.preserveDecoderState {
            decoderState = TdtDecoderState.make()
            logger.info("Initialized persistent decoder state")
        } else {
            decoderState = nil
        }

        // Initialize window history for multi-window synthesis
        if config.enableSynthesis {
            windowHistory = WindowHistory(maxWindows: config.synthesisMaxWindows)
            logger.info("Initialized window history for synthesis (max \(config.synthesisMaxWindows) windows)")
        } else {
            windowHistory = nil
        }

        // Start audio receive task
        audioReceiveTask = Task {
            logger.info("Audio receive task started, waiting for audio...")

            for await pcmBuffer in self.inputSequence {
                do {
                    let samples = try audioConverter.resampleBuffer(pcmBuffer)
                    self.appendSamples(samples)
                } catch {
                    logger.error("Audio conversion error: \(error.localizedDescription)")
                }
            }

            logger.info("Audio receive task completed")
        }

        // Start transcription timer
        transcriptionTimerTask = Task {
            logger.info("Transcription timer started with interval=\(self.config.intervalSeconds)s")

            while !Task.isCancelled && self.isRunning {
                // Wait for the configured interval
                try? await Task.sleep(for: .milliseconds(Int(config.intervalSeconds * 1000)))

                guard !Task.isCancelled && self.isRunning else { break }

                await self.runTranscriptionTick()
            }

            logger.info("Transcription timer stopped")
        }

        logger.info("SlidingWindowStreamingManager started successfully")
    }

    /// Stream audio data for transcription
    public func streamAudio(_ buffer: AVAudioPCMBuffer) {
        inputBuilder.yield(buffer)
    }

    /// Get async stream of transcription updates
    public var transcriptionUpdates: AsyncStream<SlidingWindowTranscriptionUpdate> {
        AsyncStream { continuation in
            self.updateContinuation = continuation

            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.clearUpdateContinuation()
                }
            }
        }
    }

    /// Finish streaming and get final transcription
    public func finish() async throws -> String {
        logger.info("Finishing SlidingWindowStreamingManager...")

        isRunning = false
        inputBuilder.finish()
        transcriptionTimerTask?.cancel()

        do {
            try await audioReceiveTask?.value
        } catch {
            logger.error("Audio receive task failed: \(error)")
            throw error
        }

        // Run final transcription with all remaining audio
        await runTranscriptionTick(isFinal: true)

        let finalText = await getFinalTranscription()
        logger.info("Final transcription: \(finalText.count) characters")
        return finalText
    }

    /// Cancel streaming
    public func cancel() async {
        isRunning = false
        inputBuilder.finish()
        transcriptionTimerTask?.cancel()
        audioReceiveTask?.cancel()
        updateContinuation?.finish()
        logger.info("SlidingWindowStreamingManager cancelled")
    }

    /// Get current metrics
    public func getMetrics() -> TranscriptionMetrics {
        let bufferSeconds = Double(sampleBuffer.count) / Double(SlidingWindowStreamingConfig.sampleRate)
        let rtf = lastAudioDuration > 0 ? Float(lastTranscriptionDuration / lastAudioDuration) : 0
        let pace = lastTranscriptionDuration > 0
            ? Float(min(1.0, config.intervalSeconds / lastTranscriptionDuration))
            : 1.0

        return TranscriptionMetrics(
            pace: pace,
            lastTranscriptionDuration: lastTranscriptionDuration,
            lastAudioDuration: lastAudioDuration,
            realTimeFactor: rtf,
            bufferSeconds: bufferSeconds,
            intervalSeconds: config.intervalSeconds,
            contextWindowSeconds: config.contextWindowSeconds,
            overlapSeconds: config.overlapSeconds,
            chunkCount: chunkCount,
            samplesBehind: 0  // TODO: Calculate based on buffer growth rate
        )
    }

    // MARK: - Private Methods

    private func clearUpdateContinuation() {
        updateContinuation = nil
    }

    /// Append samples to buffer without triggering transcription
    private func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)
        totalSamplesReceived += samples.count

        // Trim buffer if it exceeds max size
        let maxSamples = config.maxBufferSamples
        if sampleBuffer.count > maxSamples {
            let removeCount = sampleBuffer.count - maxSamples
            sampleBuffer.removeFirst(removeCount)
            absoluteBufferStartSample += removeCount
        }
    }

    /// Run a transcription tick (called by timer)
    private func runTranscriptionTick(isFinal: Bool = false) async {
        // Skip if already transcribing
        guard !isTranscribing else {
            logger.debug("Skipping transcription tick - already transcribing")
            return
        }

        // Check if we have enough audio
        let availableSeconds = Double(sampleBuffer.count) / Double(SlidingWindowStreamingConfig.sampleRate)
        guard availableSeconds >= config.minInitialSeconds || isFinal else {
            logger.debug("Waiting for more audio: \(String(format: "%.2f", availableSeconds))s available")
            return
        }

        guard !sampleBuffer.isEmpty else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        // Calculate how much to transcribe (sliding window from the end)
        let contextSamples = min(sampleBuffer.count, config.contextWindowSamples)
        let startIndex = sampleBuffer.count - contextSamples
        let samplesToTranscribe = Array(sampleBuffer[startIndex...])

        // Calculate absolute sample position
        let absoluteStartSample = absoluteBufferStartSample + startIndex

        await processWindow(
            samplesToTranscribe,
            absoluteStartSample: absoluteStartSample,
            isFinal: isFinal
        )
    }

    /// Process a sliding window of audio
    private func processWindow(_ samples: [Float], absoluteStartSample: Int, isFinal: Bool) async {
        guard let asrManager = asrManager else { return }
        guard samples.count >= SlidingWindowStreamingConfig.sampleRate else {
            logger.debug("Skipping window with insufficient samples: \(samples.count)")
            return
        }

        let transcriptionStart = Date()
        chunkCount += 1

        do {
            // Use preserved decoder state or create fresh one
            var workingDecoderState: TdtDecoderState
            if config.preserveDecoderState, let existingState = decoderState {
                workingDecoderState = existingState
            } else {
                workingDecoderState = TdtDecoderState.make()
            }

            // Pad audio to model input size
            let paddedSamples = asrManager.padAudioIfNeeded(samples, targetLength: 240_000)
            let actualFrameCount = ASRConstants.calculateEncoderFrames(from: samples.count)
            let globalFrameOffset = absoluteStartSample / ASRConstants.samplesPerEncoderFrame

            // Run inference
            let (hypothesis, _) = try await asrManager.executeMLInferenceWithTimings(
                paddedSamples,
                originalLength: samples.count,
                actualAudioFrames: actualFrameCount,
                decoderState: &workingDecoderState,
                contextFrameAdjustment: 0,
                isLastChunk: isFinal,
                globalFrameOffset: globalFrameOffset
            )

            // Save decoder state if preserving
            if config.preserveDecoderState {
                decoderState = workingDecoderState
            }

            // Convert to TokenWindow format
            let tokenWindows: [TokenWindow] = zip(
                zip(hypothesis.ySequence, hypothesis.timestamps),
                hypothesis.tokenConfidences
            ).map { (token: $0.0.0, timestamp: $0.0.1, confidence: $0.1) }

            // Update metrics
            lastTranscriptionDuration = Date().timeIntervalSince(transcriptionStart)
            lastAudioDuration = Double(samples.count) / Double(SlidingWindowStreamingConfig.sampleRate)

            let rtf = lastAudioDuration > 0 ? lastTranscriptionDuration / lastAudioDuration : 0

            logger.debug(
                "Window \(self.chunkCount): \(tokenWindows.count) tokens, " +
                "\(String(format: "%.2f", lastAudioDuration))s audio in " +
                "\(String(format: "%.3f", lastTranscriptionDuration))s (RTF: \(String(format: "%.3f", rtf)))" +
                (config.preserveDecoderState ? " [stateful]" : " [stateless]")
            )

            // Get raw text from this chunk BEFORE merging
            let chunkResult = asrManager.processTranscriptionResult(
                tokenIds: tokenWindows.map { $0.token },
                timestamps: tokenWindows.map { $0.timestamp },
                confidences: tokenWindows.map { $0.confidence },
                encoderSequenceLength: 0,
                audioSamples: [],
                processingTime: lastTranscriptionDuration
            )

            // Build window token data if debug mode is enabled
            var windowData: TranscriptionWindowData?
            if config.emitWindowData {
                windowData = buildWindowTokenData(
                    tokenWindows: tokenWindows,
                    windowStartSample: absoluteStartSample,
                    windowDurationSamples: samples.count,
                    asrManager: asrManager
                )
            }

            // Add to window history for synthesis if enabled
            var synthesisResult: SynthesisResult?
            if config.enableSynthesis, let windowHistory = windowHistory {
                let synthesisWindow = buildSynthesisWindowData(
                    tokenWindows: tokenWindows,
                    windowIndex: chunkCount - 1,
                    windowStartSample: absoluteStartSample,
                    windowDurationSamples: samples.count,
                    asrManager: asrManager
                )
                windowHistory.addWindow(synthesisWindow)

                // Run synthesis across all accumulated windows
                let context = SynthesisContext(
                    windows: windowHistory.allWindows(),
                    confirmedTokens: windowHistory.allConfirmedTokens(),
                    strategy: config.mergeStrategy,
                    config: config.synthesisConfig
                )
                synthesisResult = synthesizeTokens(context: context)

                // Update confirmed tokens in history
                if !synthesisResult!.newlyConfirmed.isEmpty {
                    let confirmedToAdd = synthesisResult!.newlyConfirmed.map { token in
                        ConfirmedToken(
                            tokenId: token.tokenId,
                            text: token.text,
                            confidence: token.confidence,
                            startTimeMs: token.startTimeMs,
                            durationMs: token.durationMs,
                            sourceWindowIndex: token.sourceWindowIndex,
                            confirmedAtWindowIndex: chunkCount - 1,
                            upvotes: token.upvotes,
                            downvotes: token.downvotes
                        )
                    }
                    windowHistory.addConfirmedTokens(confirmedToAdd)
                }

                logger.debug(
                    "Synthesis: \(synthesisResult!.tokens.count) tokens, " +
                    "\(synthesisResult!.newlyConfirmed.count) newly confirmed, " +
                    "\(windowHistory.windowCount) windows in history"
                )
            }

            // Strategy-based synthesis (new system)
            if config.enableStrategySystem {
                // Build TranscriptionWindow from token results
                let strategyWindow = buildStrategyWindow(
                    tokenWindows: tokenWindows,
                    windowIndex: chunkCount - 1,
                    windowStartSample: absoluteStartSample,
                    windowDurationSamples: samples.count,
                    asrManager: asrManager
                )
                strategyWindows.append(strategyWindow)

                // Prune old windows (keep last N based on config)
                let maxWindows = config.synthesisMaxWindows
                if strategyWindows.count > maxWindows {
                    strategyWindows.removeFirst(strategyWindows.count - maxWindows)
                }

                // Calculate latest audio time in milliseconds
                let latestAudioTimeMs = Int(Double(totalSamplesReceived) / Double(SlidingWindowStreamingConfig.sampleRate) * 1000)

                // Build input and execute strategy
                let strategyInput = StrategyInput(
                    windows: strategyWindows,
                    config: config.strategyConfig,
                    latestAudioTimeMs: latestAudioTimeMs
                )
                let strategyOutput = strategy.execute(strategyInput)
                lastStrategyOutput = strategyOutput

                // Handle decoder reset decision
                if strategyOutput.shouldResetDecoder && config.preserveDecoderState {
                    decoderState = TdtDecoderState.make()
                    logger.info("Strategy requested decoder reset: \(strategyOutput.resetReason ?? "no reason")")
                }

                // Log diagnostics
                for diagnostic in strategyOutput.diagnostics {
                    switch diagnostic.level {
                    case .info:
                        logger.info("Strategy: \(diagnostic.message)")
                    case .warning:
                        logger.warning("Strategy: \(diagnostic.message)")
                    case .error:
                        logger.error("Strategy: \(diagnostic.message)")
                    }
                }

                // Log summary
                let confirmedCount = strategyOutput.tokens.filter(\.isConfirmed).count
                let volatileCount = strategyOutput.tokens.count - confirmedCount
                logger.debug(
                    "Strategy [\(strategy.name)]: \(strategyOutput.tokens.count) tokens " +
                    "(\(confirmedCount) confirmed, \(volatileCount) volatile), " +
                    "\(strategyWindows.count) windows"
                )
            }

            // Merge with confirmed tokens
            await mergeTokens(tokenWindows, windowStartSample: absoluteStartSample)

            // Update volatile/confirmed state if using confirmation model
            if config.useConfirmationModel {
                await updateTranscriptionState(with: chunkResult)
            }

            // Emit update with raw chunk text and optional window/synthesis data
            await emitUpdate(
                isFinal: isFinal,
                latestChunkText: chunkResult.text,
                chunkConfidence: chunkResult.confidence,
                windowData: windowData,
                synthesisResult: synthesisResult,
                strategyOutput: lastStrategyOutput
            )

        } catch {
            logger.error("Window processing failed: \(error.localizedDescription)")
            await attemptErrorRecovery(error: error)
        }
    }

    /// Update transcription state based on confidence and context duration
    private func updateTranscriptionState(with result: ASRResult) async {
        let totalAudioProcessed = Double(totalSamplesReceived) / Double(SlidingWindowStreamingConfig.sampleRate)
        let hasMinimumContext = totalAudioProcessed >= config.minContextForConfirmation
        let isHighConfidence = Double(result.confidence) >= config.confirmationThreshold

        // Progressive confidence model:
        // 1. Always show text immediately as volatile for responsiveness
        // 2. Only confirm text when we have both high confidence AND sufficient context
        let shouldConfirm = isHighConfidence && hasMinimumContext

        if shouldConfirm {
            // Move volatile text to confirmed and set new text as volatile
            if !volatileTranscript.isEmpty {
                var components: [String] = []
                if !confirmedTranscript.isEmpty {
                    components.append(confirmedTranscript)
                }
                components.append(volatileTranscript)
                confirmedTranscript = components.joined(separator: " ")
            }
            volatileTranscript = result.text
            logger.debug(
                "CONFIRMED (\(result.confidence), \(String(format: "%.1f", totalAudioProcessed))s context): " +
                "promoted to confirmed; new volatile '\(result.text.prefix(30))...'"
            )
        } else {
            // Only update volatile text (hypothesis)
            volatileTranscript = result.text
            let reason = !hasMinimumContext
                ? "insufficient context (\(String(format: "%.1f", totalAudioProcessed))s)"
                : "low confidence (\(String(format: "%.2f", result.confidence)))"
            logger.debug("VOLATILE: \(reason) - '\(result.text.prefix(30))...'")
        }
    }

    // MARK: - Error Recovery

    /// Attempt to recover from processing errors
    private func attemptErrorRecovery(error: Error) async {
        logger.warning("Attempting error recovery for: \(error)")

        // Reset decoder state if we're preserving it
        if config.preserveDecoderState {
            await resetDecoderForRecovery()
        }
    }

    /// Reset decoder state for error recovery
    private func resetDecoderForRecovery() async {
        if config.preserveDecoderState {
            decoderState = TdtDecoderState.make()
            logger.info("Reset decoder state during error recovery")
        }
    }

    /// Manually reset decoder state (can be called from outside)
    public func resetDecoderState() async {
        if config.preserveDecoderState {
            decoderState = TdtDecoderState.make()
            logger.info("Manually reset decoder state")
        }
    }

    /// Merge new tokens with confirmed tokens
    private func mergeTokens(_ newTokens: [TokenWindow], windowStartSample: Int) async {
        // For now, simply replace tokens that overlap with the new window
        // TODO: Implement proper overlap-based merging with confidence weighting

        if confirmedTokens.isEmpty {
            confirmedTokens = newTokens
            return
        }

        // Find the cutoff point in confirmed tokens based on the new window's start
        let windowStartFrame = windowStartSample / ASRConstants.samplesPerEncoderFrame
        let overlapFrames = Int(config.overlapSeconds * Double(SlidingWindowStreamingConfig.sampleRate))
            / ASRConstants.samplesPerEncoderFrame

        // Keep tokens that are before the overlap region
        let cutoffFrame = windowStartFrame + overlapFrames
        let tokensToKeep = confirmedTokens.filter { $0.timestamp < cutoffFrame }

        // Add new tokens that are at or after the cutoff
        let newTokensToAdd = newTokens.filter { $0.timestamp >= cutoffFrame }

        confirmedTokens = tokensToKeep + newTokensToAdd

        // Sort by timestamp
        confirmedTokens.sort { $0.timestamp < $1.timestamp }
    }

    /// Build window token data for visualization
    private func buildWindowTokenData(
        tokenWindows: [TokenWindow],
        windowStartSample: Int,
        windowDurationSamples: Int,
        asrManager: AsrManager
    ) -> TranscriptionWindowData {
        let windowStartMs = (windowStartSample * 1000) / SlidingWindowStreamingConfig.sampleRate
        let windowDurationMs = (windowDurationSamples * 1000) / SlidingWindowStreamingConfig.sampleRate
        let edgeBufferMs = config.edgeBufferMs

        // Convert tokens to WindowToken format with edge buffer detection
        let tokens: [WindowToken] = tokenWindows.map { tw in
            // Convert frame timestamp to milliseconds
            // Frames are at ~80 frames per second (1280 samples per frame at 16kHz)
            let frameMs = (tw.timestamp * 1000 * ASRConstants.samplesPerEncoderFrame) / SlidingWindowStreamingConfig.sampleRate
            let timestampMs = windowStartMs + frameMs
            let positionInWindowMs = frameMs

            // Determine if token is in edge buffer zones
            let isInStartBuffer = positionInWindowMs < edgeBufferMs
            let isInEndBuffer = positionInWindowMs > (windowDurationMs - edgeBufferMs)

            // Decode token text
            let tokenText = asrManager.decodeToken(tw.token)

            return WindowToken(
                tokenId: tw.token,
                text: tokenText,
                confidence: tw.confidence,
                timestampMs: timestampMs,
                positionInWindowMs: positionInWindowMs,
                isInStartBuffer: isInStartBuffer,
                isInEndBuffer: isInEndBuffer
            )
        }

        // Calculate average confidence
        let avgConfidence: Float = tokens.isEmpty ? 0 : tokens.map(\.confidence).reduce(0, +) / Float(tokens.count)

        return TranscriptionWindowData(
            windowIndex: chunkCount - 1,  // 0-based index
            windowStartMs: windowStartMs,
            durationMs: windowDurationMs,
            bufferDurationMs: edgeBufferMs,
            tokens: tokens,
            averageConfidence: avgConfidence
        )
    }

    /// Build synthesis window data for multi-window token merging
    private func buildSynthesisWindowData(
        tokenWindows: [TokenWindow],
        windowIndex: Int,
        windowStartSample: Int,
        windowDurationSamples: Int,
        asrManager: AsrManager
    ) -> SynthesisWindowData {
        let windowStartMs = (windowStartSample * 1000) / SlidingWindowStreamingConfig.sampleRate
        let windowDurationMs = (windowDurationSamples * 1000) / SlidingWindowStreamingConfig.sampleRate
        let edgeBufferMs = config.edgeBufferMs

        // Convert tokens to TokenCandidate format
        let tokens: [TokenCandidate] = tokenWindows.enumerated().map { idx, tw in
            // Convert frame timestamp to milliseconds
            let frameMs = (tw.timestamp * 1000 * ASRConstants.samplesPerEncoderFrame) / SlidingWindowStreamingConfig.sampleRate
            let absoluteStartMs = windowStartMs + frameMs

            // Estimate duration from token spacing (last token gets remaining duration)
            let durationMs: Int
            if idx < tokenWindows.count - 1 {
                let nextFrameMs = (tokenWindows[idx + 1].timestamp * 1000 * ASRConstants.samplesPerEncoderFrame)
                    / SlidingWindowStreamingConfig.sampleRate
                durationMs = nextFrameMs - frameMs
            } else {
                durationMs = max(50, windowDurationMs - frameMs)  // At least 50ms for last token
            }

            // Calculate position ratio (0.0 = start, 1.0 = end)
            let positionRatio = windowDurationMs > 0 ? Float(frameMs) / Float(windowDurationMs) : 0.0

            // Determine if in edge buffer
            let isEdgeToken = frameMs < edgeBufferMs || frameMs > (windowDurationMs - edgeBufferMs)

            // Decode token text
            let tokenText = asrManager.decodeToken(tw.token)

            return TokenCandidate(
                tokenId: tw.token,
                text: tokenText,
                confidence: tw.confidence,
                startTimeMs: absoluteStartMs,
                durationMs: durationMs,
                windowIndex: windowIndex,
                positionRatio: positionRatio,
                isEdgeToken: isEdgeToken
            )
        }

        return SynthesisWindowData(
            windowIndex: windowIndex,
            startTimeMs: windowStartMs,
            durationMs: windowDurationMs,
            tokens: tokens
        )
    }

    /// Build a TranscriptionWindow for the new strategy system
    private func buildStrategyWindow(
        tokenWindows: [TokenWindow],
        windowIndex: Int,
        windowStartSample: Int,
        windowDurationSamples: Int,
        asrManager: AsrManager
    ) -> TranscriptionWindow {
        let windowStartMs = (windowStartSample * 1000) / SlidingWindowStreamingConfig.sampleRate
        let windowDurationMs = (windowDurationSamples * 1000) / SlidingWindowStreamingConfig.sampleRate

        // Convert tokens to InputToken format
        let tokens: [InputToken] = tokenWindows.map { tw in
            // Convert frame timestamp to milliseconds
            let frameMs = (tw.timestamp * 1000 * ASRConstants.samplesPerEncoderFrame) / SlidingWindowStreamingConfig.sampleRate
            let absoluteTimestampMs = windowStartMs + frameMs

            // Calculate position ratio (0.0 = start, 1.0 = end)
            let positionRatio = windowDurationMs > 0 ? Float(frameMs) / Float(windowDurationMs) : 0.0

            // Decode token text
            let tokenText = asrManager.decodeToken(tw.token)

            return InputToken(
                tokenId: tw.token,
                text: tokenText,
                confidence: tw.confidence,
                timestampMs: absoluteTimestampMs,
                positionInWindow: positionRatio
            )
        }

        return TranscriptionWindow(
            windowIndex: windowIndex,
            startTimeMs: windowStartMs,
            durationMs: windowDurationMs,
            tokens: tokens,
            wasStateful: config.preserveDecoderState && decoderState != nil
        )
    }

    /// Emit transcription update with metrics
    private func emitUpdate(
        isFinal: Bool,
        latestChunkText: String = "",
        chunkConfidence: Float = 0,
        windowData: TranscriptionWindowData? = nil,
        synthesisResult: SynthesisResult? = nil,
        strategyOutput: StrategyOutput? = nil
    ) async {
        guard let asrManager = asrManager else { return }

        let metrics = getMetrics()

        // Determine text based on which system is enabled
        let text: String
        let confirmed: String
        let volatile: String
        let confidence: Float

        if config.enableStrategySystem, let output = strategyOutput {
            // Use NEW strategy system output
            text = output.text
            confirmed = output.confirmedText
            volatile = output.volatileText
            confidence = output.tokens.isEmpty ? 0 : output.tokens.map(\.confidence).reduce(0, +) / Float(output.tokens.count)
        } else {
            // Use OLD system output
            let result = asrManager.processTranscriptionResult(
                tokenIds: confirmedTokens.map { $0.token },
                timestamps: confirmedTokens.map { $0.timestamp },
                confidences: confirmedTokens.map { $0.confidence },
                encoderSequenceLength: 0,
                audioSamples: [],
                processingTime: lastTranscriptionDuration
            )
            text = result.text
            confirmed = confirmedTranscript
            volatile = volatileTranscript
            confidence = result.confidence
        }

        // Determine if this chunk should be marked as confirmed
        let totalAudioProcessed = Double(totalSamplesReceived) / Double(SlidingWindowStreamingConfig.sampleRate)
        let hasMinimumContext = totalAudioProcessed >= config.minContextForConfirmation
        let isHighConfidence = Double(chunkConfidence) >= config.confirmationThreshold
        let isConfirmed = config.useConfirmationModel && isHighConfidence && hasMinimumContext

        let update = SlidingWindowTranscriptionUpdate(
            text: text,
            volatileTranscript: volatile,
            confirmedTranscript: confirmed,
            isConfirmed: isConfirmed,
            latestChunkText: latestChunkText,
            isFinal: isFinal,
            confidence: confidence,
            timestamp: Date(),
            tokenTimings: [],
            metrics: metrics,
            windowData: windowData,
            synthesizedTokens: synthesisResult?.tokens,
            synthesisWindowCount: config.enableStrategySystem ? strategyWindows.count : windowHistory?.windowCount
        )

        updateContinuation?.yield(update)

        if isFinal {
            updateContinuation?.finish()
        }
    }

    /// Get final transcription text
    private func getFinalTranscription() async -> String {
        guard let asrManager = asrManager else { return "" }
        guard !confirmedTokens.isEmpty else { return "" }

        let result = asrManager.processTranscriptionResult(
            tokenIds: confirmedTokens.map { $0.token },
            timestamps: confirmedTokens.map { $0.timestamp },
            confidences: confirmedTokens.map { $0.confidence },
            encoderSequenceLength: 0,
            audioSamples: [],
            processingTime: 0
        )

        return result.text
    }
}

// MARK: - Configuration

/// Configuration for SlidingWindowStreamingManager
public struct SlidingWindowStreamingConfig: Sendable {
    /// Sample rate (fixed at 16kHz)
    public static let sampleRate: Int = 16000

    /// How often to run transcription (timer interval)
    public let intervalSeconds: TimeInterval

    /// Max audio context per transcription (up to model limit of ~14s)
    public let contextWindowSeconds: TimeInterval

    /// Overlap for merging successive transcriptions
    public let overlapSeconds: TimeInterval

    /// Minimum audio before first transcription
    public let minInitialSeconds: TimeInterval

    /// Max buffer size in memory
    public let maxBufferSeconds: TimeInterval

    // MARK: - Decoder State Options

    /// Whether to preserve decoder state between windows (default: false)
    /// When true, LSTM state carries forward providing linguistic continuity.
    /// When false, each window starts with fresh decoder state (stateless).
    public let preserveDecoderState: Bool

    // MARK: - Confirmation Options

    /// Whether to use two-tier volatile/confirmed transcript model (default: true)
    public let useConfirmationModel: Bool

    /// Confidence threshold for promoting volatile text to confirmed (0.0...1.0)
    public let confirmationThreshold: Double

    /// Minimum audio duration before confirming text (seconds)
    public let minContextForConfirmation: TimeInterval

    // MARK: - Debug/Visualization Options

    /// Whether to emit detailed window token data for visualization (default: false)
    /// When enabled, each update includes full token-level data for the current window.
    public let emitWindowData: Bool

    /// Size of the "edge distrust" buffer zones at start/end of each window (seconds)
    /// Tokens within this buffer are marked as lower trust.
    public let edgeBufferSeconds: TimeInterval

    // MARK: - Multi-Window Synthesis Options

    /// Whether to enable multi-window token synthesis (default: false)
    /// When enabled, tokens from multiple overlapping windows are compared and merged.
    public let enableSynthesis: Bool

    /// Maximum number of windows to keep in synthesis history
    public let synthesisMaxWindows: Int

    /// Strategy for merging tokens across windows
    public let mergeStrategy: MergeStrategy

    /// Configuration for the synthesis process
    public let synthesisConfig: SynthesisConfig

    /// Whether to enable the new strategy-based synthesis system (default: false)
    /// When enabled, uses TranscriptionStrategy protocol for token merging decisions.
    public let enableStrategySystem: Bool

    /// Configuration for the strategy system (used when enableStrategySystem is true)
    public let strategyConfig: StrategyConfig

    /// Default configuration optimized for quality
    public static let `default` = SlidingWindowStreamingConfig(
        intervalSeconds: 2.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 2.0,
        minInitialSeconds: 2.0,
        maxBufferSeconds: 30.0,
        preserveDecoderState: false,
        useConfirmationModel: true,
        confirmationThreshold: 0.85,
        minContextForConfirmation: 10.0,
        emitWindowData: false,
        edgeBufferSeconds: 1.0,
        enableSynthesis: false,
        synthesisMaxWindows: 20,
        mergeStrategy: .latestWindow,
        synthesisConfig: .default,
        enableStrategySystem: false,
        strategyConfig: .default
    )

    /// Low-latency configuration for faster updates
    public static let lowLatency = SlidingWindowStreamingConfig(
        intervalSeconds: 0.5,
        contextWindowSeconds: 6.0,
        overlapSeconds: 1.0,
        minInitialSeconds: 1.0,
        maxBufferSeconds: 20.0,
        preserveDecoderState: false,
        useConfirmationModel: true,
        confirmationThreshold: 0.80,
        minContextForConfirmation: 5.0,
        emitWindowData: false,
        edgeBufferSeconds: 0.5,
        enableSynthesis: false,
        synthesisMaxWindows: 10,
        mergeStrategy: .latestWindow,
        synthesisConfig: .default,
        enableStrategySystem: false,
        strategyConfig: .default
    )

    /// High quality configuration with longer context
    public static let highQuality = SlidingWindowStreamingConfig(
        intervalSeconds: 3.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 3.0,
        minInitialSeconds: 3.0,
        maxBufferSeconds: 45.0,
        preserveDecoderState: false,
        useConfirmationModel: true,
        confirmationThreshold: 0.90,
        minContextForConfirmation: 15.0,
        emitWindowData: false,
        edgeBufferSeconds: 1.5,
        enableSynthesis: false,
        synthesisMaxWindows: 30,
        mergeStrategy: .latestWindow,
        synthesisConfig: .default,
        enableStrategySystem: false,
        strategyConfig: .default
    )

    /// Stateful configuration - preserves decoder state for linguistic continuity
    public static let stateful = SlidingWindowStreamingConfig(
        intervalSeconds: 2.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 2.0,
        minInitialSeconds: 2.0,
        maxBufferSeconds: 30.0,
        preserveDecoderState: true,
        useConfirmationModel: true,
        confirmationThreshold: 0.85,
        minContextForConfirmation: 10.0,
        emitWindowData: false,
        edgeBufferSeconds: 1.0,
        enableSynthesis: false,
        synthesisMaxWindows: 20,
        mergeStrategy: .latestWindow,
        synthesisConfig: .default,
        enableStrategySystem: false,
        strategyConfig: .default
    )

    /// Debug configuration - emits detailed window data for visualization
    public static let debug = SlidingWindowStreamingConfig(
        intervalSeconds: 2.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 2.0,
        minInitialSeconds: 2.0,
        maxBufferSeconds: 30.0,
        preserveDecoderState: false,
        useConfirmationModel: true,
        confirmationThreshold: 0.85,
        minContextForConfirmation: 10.0,
        emitWindowData: true,
        edgeBufferSeconds: 1.0,
        enableSynthesis: true,
        synthesisMaxWindows: 20,
        mergeStrategy: .weightedComposite(weights: .default),
        synthesisConfig: .default,
        enableStrategySystem: true,
        strategyConfig: .default
    )

    public init(
        intervalSeconds: TimeInterval = 2.0,
        contextWindowSeconds: TimeInterval = 14.0,
        overlapSeconds: TimeInterval = 2.0,
        minInitialSeconds: TimeInterval = 2.0,
        maxBufferSeconds: TimeInterval = 30.0,
        preserveDecoderState: Bool = false,
        useConfirmationModel: Bool = true,
        confirmationThreshold: Double = 0.85,
        minContextForConfirmation: TimeInterval = 10.0,
        emitWindowData: Bool = false,
        edgeBufferSeconds: TimeInterval = 1.0,
        enableSynthesis: Bool = false,
        synthesisMaxWindows: Int = 20,
        mergeStrategy: MergeStrategy = .latestWindow,
        synthesisConfig: SynthesisConfig = .default,
        enableStrategySystem: Bool = false,
        strategyConfig: StrategyConfig = .default
    ) {
        self.intervalSeconds = intervalSeconds
        self.contextWindowSeconds = contextWindowSeconds
        self.overlapSeconds = overlapSeconds
        self.minInitialSeconds = minInitialSeconds
        self.maxBufferSeconds = maxBufferSeconds
        self.preserveDecoderState = preserveDecoderState
        self.useConfirmationModel = useConfirmationModel
        self.confirmationThreshold = confirmationThreshold
        self.minContextForConfirmation = minContextForConfirmation
        self.emitWindowData = emitWindowData
        self.edgeBufferSeconds = edgeBufferSeconds
        self.enableSynthesis = enableSynthesis
        self.synthesisMaxWindows = synthesisMaxWindows
        self.mergeStrategy = mergeStrategy
        self.synthesisConfig = synthesisConfig
        self.enableStrategySystem = enableStrategySystem
        self.strategyConfig = strategyConfig
    }

    // Sample counts at 16kHz
    var contextWindowSamples: Int { Int(contextWindowSeconds * Double(Self.sampleRate)) }
    var overlapSamples: Int { Int(overlapSeconds * Double(Self.sampleRate)) }
    var minInitialSamples: Int { Int(minInitialSeconds * Double(Self.sampleRate)) }
    var maxBufferSamples: Int { Int(maxBufferSeconds * Double(Self.sampleRate)) }
    var minContextForConfirmationSamples: Int { Int(minContextForConfirmation * Double(Self.sampleRate)) }
    var edgeBufferMs: Int { Int(edgeBufferSeconds * 1000) }
}

// MARK: - Window Token Data (for visualization)

/// A single token with metadata for visualization
public struct WindowToken: Sendable {
    /// The raw token ID from the model
    public let tokenId: Int

    /// The decoded text for this token
    public let text: String

    /// Confidence score for this token (0.0 - 1.0)
    public let confidence: Float

    /// Position in the full recording (milliseconds)
    public let timestampMs: Int

    /// Position within the window (milliseconds from window start)
    public let positionInWindowMs: Int

    /// Whether this token is in the START edge buffer zone
    public let isInStartBuffer: Bool

    /// Whether this token is in the END edge buffer zone
    public let isInEndBuffer: Bool
}

/// Data for a single transcription window
public struct TranscriptionWindowData: Sendable {
    /// Sequential index of this window (0-based)
    public let windowIndex: Int

    /// Start time of this window relative to recording start (milliseconds)
    public let windowStartMs: Int

    /// Total duration of this window (milliseconds)
    public let durationMs: Int

    /// Size of the edge distrust buffer (milliseconds)
    public let bufferDurationMs: Int

    /// All tokens in this window
    public let tokens: [WindowToken]

    /// Average confidence across all tokens
    public let averageConfidence: Float
}

// MARK: - Metrics

/// Performance metrics for sliding window transcription
public struct TranscriptionMetrics: Sendable {
    /// How well we're keeping up (0.0 to 1.0, where 1.0 = 100%)
    public let pace: Float

    /// Time taken for last transcription
    public let lastTranscriptionDuration: TimeInterval

    /// Audio duration that was transcribed
    public let lastAudioDuration: TimeInterval

    /// Real-time factor (< 1.0 means faster than real-time)
    public let realTimeFactor: Float

    /// Current buffer size in seconds
    public let bufferSeconds: TimeInterval

    /// Current config values (for display)
    public let intervalSeconds: TimeInterval
    public let contextWindowSeconds: TimeInterval
    public let overlapSeconds: TimeInterval

    /// Chunks processed so far
    public let chunkCount: Int

    /// Samples behind (0 if keeping up)
    public let samplesBehind: Int

    public init(
        pace: Float,
        lastTranscriptionDuration: TimeInterval,
        lastAudioDuration: TimeInterval,
        realTimeFactor: Float,
        bufferSeconds: TimeInterval,
        intervalSeconds: TimeInterval,
        contextWindowSeconds: TimeInterval,
        overlapSeconds: TimeInterval,
        chunkCount: Int,
        samplesBehind: Int
    ) {
        self.pace = pace
        self.lastTranscriptionDuration = lastTranscriptionDuration
        self.lastAudioDuration = lastAudioDuration
        self.realTimeFactor = realTimeFactor
        self.bufferSeconds = bufferSeconds
        self.intervalSeconds = intervalSeconds
        self.contextWindowSeconds = contextWindowSeconds
        self.overlapSeconds = overlapSeconds
        self.chunkCount = chunkCount
        self.samplesBehind = samplesBehind
    }
}

// MARK: - Output Types

/// Transcription update from sliding window streaming
public struct SlidingWindowTranscriptionUpdate: Sendable {
    /// Current transcription text (merged/accumulated)
    public let text: String

    /// Current volatile (unconfirmed) transcript - may change with future updates
    public let volatileTranscript: String

    /// Confirmed transcript - high-confidence text that won't change
    public let confirmedTranscript: String

    /// Whether the current update has been confirmed (high confidence + sufficient context)
    public let isConfirmed: Bool

    /// Raw text from the latest chunk BEFORE merging (for debugging)
    public let latestChunkText: String

    /// Whether this is the final update (stream ended)
    public let isFinal: Bool

    /// Average confidence score
    public let confidence: Float

    /// Timestamp of this update
    public let timestamp: Date

    /// Token-level timing information
    public let tokenTimings: [TokenTiming]

    /// Performance metrics for this update
    public let metrics: TranscriptionMetrics

    /// Detailed window token data for visualization (only when emitWindowData is enabled)
    public let windowData: TranscriptionWindowData?

    /// Synthesized tokens from multi-window merging (only when enableSynthesis is true)
    public let synthesizedTokens: [SynthesizedToken]?

    /// Number of windows in synthesis history
    public let synthesisWindowCount: Int?

    public init(
        text: String,
        volatileTranscript: String = "",
        confirmedTranscript: String = "",
        isConfirmed: Bool = false,
        latestChunkText: String,
        isFinal: Bool,
        confidence: Float,
        timestamp: Date,
        tokenTimings: [TokenTiming],
        metrics: TranscriptionMetrics,
        windowData: TranscriptionWindowData? = nil,
        synthesizedTokens: [SynthesizedToken]? = nil,
        synthesisWindowCount: Int? = nil
    ) {
        self.text = text
        self.volatileTranscript = volatileTranscript
        self.confirmedTranscript = confirmedTranscript
        self.isConfirmed = isConfirmed
        self.latestChunkText = latestChunkText
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.tokenTimings = tokenTimings
        self.metrics = metrics
        self.windowData = windowData
        self.synthesizedTokens = synthesizedTokens
        self.synthesisWindowCount = synthesisWindowCount
    }
}
