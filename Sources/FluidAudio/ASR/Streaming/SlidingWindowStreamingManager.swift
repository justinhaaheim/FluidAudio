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
            // Create a fresh decoder state (stateless, like batch)
            var decoderState = TdtDecoderState.make()

            // Pad audio to model input size
            let paddedSamples = asrManager.padAudioIfNeeded(samples, targetLength: 240_000)
            let actualFrameCount = ASRConstants.calculateEncoderFrames(from: samples.count)
            let globalFrameOffset = absoluteStartSample / ASRConstants.samplesPerEncoderFrame

            // Run inference
            let (hypothesis, _) = try await asrManager.executeMLInferenceWithTimings(
                paddedSamples,
                originalLength: samples.count,
                actualAudioFrames: actualFrameCount,
                decoderState: &decoderState,
                contextFrameAdjustment: 0,
                isLastChunk: isFinal,
                globalFrameOffset: globalFrameOffset
            )

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
                "\(String(format: "%.3f", lastTranscriptionDuration))s (RTF: \(String(format: "%.3f", rtf)))"
            )

            // Get raw text from this chunk BEFORE merging
            let rawChunkText = asrManager.processTranscriptionResult(
                tokenIds: tokenWindows.map { $0.token },
                timestamps: tokenWindows.map { $0.timestamp },
                confidences: tokenWindows.map { $0.confidence },
                encoderSequenceLength: 0,
                audioSamples: [],
                processingTime: lastTranscriptionDuration
            ).text

            // Merge with confirmed tokens
            await mergeTokens(tokenWindows, windowStartSample: absoluteStartSample)

            // Emit update with raw chunk text
            await emitUpdate(isFinal: isFinal, latestChunkText: rawChunkText)

        } catch {
            logger.error("Window processing failed: \(error.localizedDescription)")
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

    /// Emit transcription update with metrics
    private func emitUpdate(isFinal: Bool, latestChunkText: String = "") async {
        guard let asrManager = asrManager else { return }

        // Convert tokens to text (merged/accumulated)
        let result = asrManager.processTranscriptionResult(
            tokenIds: confirmedTokens.map { $0.token },
            timestamps: confirmedTokens.map { $0.timestamp },
            confidences: confirmedTokens.map { $0.confidence },
            encoderSequenceLength: 0,
            audioSamples: [],
            processingTime: lastTranscriptionDuration
        )

        let metrics = getMetrics()

        let update = SlidingWindowTranscriptionUpdate(
            text: result.text,
            latestChunkText: latestChunkText,
            isFinal: isFinal,
            confidence: result.confidence,
            timestamp: Date(),
            tokenTimings: result.tokenTimings ?? [],
            metrics: metrics
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

    /// Default configuration optimized for quality
    public static let `default` = SlidingWindowStreamingConfig(
        intervalSeconds: 2.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 2.0,
        minInitialSeconds: 2.0,
        maxBufferSeconds: 30.0
    )

    /// Low-latency configuration for faster updates
    public static let lowLatency = SlidingWindowStreamingConfig(
        intervalSeconds: 0.5,
        contextWindowSeconds: 6.0,
        overlapSeconds: 1.0,
        minInitialSeconds: 1.0,
        maxBufferSeconds: 20.0
    )

    /// High quality configuration with longer context
    public static let highQuality = SlidingWindowStreamingConfig(
        intervalSeconds: 3.0,
        contextWindowSeconds: 14.0,
        overlapSeconds: 3.0,
        minInitialSeconds: 3.0,
        maxBufferSeconds: 45.0
    )

    public init(
        intervalSeconds: TimeInterval = 2.0,
        contextWindowSeconds: TimeInterval = 14.0,
        overlapSeconds: TimeInterval = 2.0,
        minInitialSeconds: TimeInterval = 2.0,
        maxBufferSeconds: TimeInterval = 30.0
    ) {
        self.intervalSeconds = intervalSeconds
        self.contextWindowSeconds = contextWindowSeconds
        self.overlapSeconds = overlapSeconds
        self.minInitialSeconds = minInitialSeconds
        self.maxBufferSeconds = maxBufferSeconds
    }

    // Sample counts at 16kHz
    var contextWindowSamples: Int { Int(contextWindowSeconds * Double(Self.sampleRate)) }
    var overlapSamples: Int { Int(overlapSeconds * Double(Self.sampleRate)) }
    var minInitialSamples: Int { Int(minInitialSeconds * Double(Self.sampleRate)) }
    var maxBufferSamples: Int { Int(maxBufferSeconds * Double(Self.sampleRate)) }
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

    public init(
        text: String,
        latestChunkText: String,
        isFinal: Bool,
        confidence: Float,
        timestamp: Date,
        tokenTimings: [TokenTiming],
        metrics: TranscriptionMetrics
    ) {
        self.text = text
        self.latestChunkText = latestChunkText
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.tokenTimings = tokenTimings
        self.metrics = metrics
    }
}
