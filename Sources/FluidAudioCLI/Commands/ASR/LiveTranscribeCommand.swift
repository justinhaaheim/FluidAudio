#if os(macOS)
import AVFoundation
import FluidAudio
import Foundation

// Global flag for signal handling (must be outside the enum for C interop)
private var liveTranscribeShouldStop = false

/// Command to transcribe live microphone audio using SlidingWindowStreamingManager
enum LiveTranscribeCommand {
    private static let logger = AppLogger(category: "LiveTranscribe")

    static func run(arguments: [String]) async {
        // Parse arguments
        var configPreset: SlidingWindowStreamingConfig = .default
        var usePlainMode = false

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--help", "-h":
                printUsage()
                exit(0)
            case "--plain":
                usePlainMode = true
            case "--low-latency":
                configPreset = .lowLatency
            case "--high-quality":
                configPreset = .highQuality
            case "--stateful":
                configPreset = .stateful
            case "--debug":
                configPreset = .debug
            case "--interval":
                if i + 1 < arguments.count, let value = Double(arguments[i + 1]) {
                    configPreset = SlidingWindowStreamingConfig(
                        intervalSeconds: value,
                        contextWindowSeconds: configPreset.contextWindowSeconds,
                        overlapSeconds: configPreset.overlapSeconds,
                        minInitialSeconds: configPreset.minInitialSeconds,
                        maxBufferSeconds: configPreset.maxBufferSeconds,
                        preserveDecoderState: configPreset.preserveDecoderState,
                        useConfirmationModel: configPreset.useConfirmationModel,
                        confirmationThreshold: configPreset.confirmationThreshold,
                        minContextForConfirmation: configPreset.minContextForConfirmation,
                        emitWindowData: configPreset.emitWindowData,
                        edgeBufferSeconds: configPreset.edgeBufferSeconds,
                        enableSynthesis: configPreset.enableSynthesis,
                        synthesisMaxWindows: configPreset.synthesisMaxWindows,
                        mergeStrategy: configPreset.mergeStrategy,
                        synthesisConfig: configPreset.synthesisConfig
                    )
                    i += 1
                }
            case "--context":
                if i + 1 < arguments.count, let value = Double(arguments[i + 1]) {
                    configPreset = SlidingWindowStreamingConfig(
                        intervalSeconds: configPreset.intervalSeconds,
                        contextWindowSeconds: value,
                        overlapSeconds: configPreset.overlapSeconds,
                        minInitialSeconds: configPreset.minInitialSeconds,
                        maxBufferSeconds: configPreset.maxBufferSeconds,
                        preserveDecoderState: configPreset.preserveDecoderState,
                        useConfirmationModel: configPreset.useConfirmationModel,
                        confirmationThreshold: configPreset.confirmationThreshold,
                        minContextForConfirmation: configPreset.minContextForConfirmation,
                        emitWindowData: configPreset.emitWindowData,
                        edgeBufferSeconds: configPreset.edgeBufferSeconds,
                        enableSynthesis: configPreset.enableSynthesis,
                        synthesisMaxWindows: configPreset.synthesisMaxWindows,
                        mergeStrategy: configPreset.mergeStrategy,
                        synthesisConfig: configPreset.synthesisConfig
                    )
                    i += 1
                }
            default:
                logger.warning("Unknown option: \(arguments[i])")
            }
            i += 1
        }

        // Set up signal handler for graceful shutdown
        setupSignalHandler()

        // Create TUI if not in plain mode
        let tui: LiveTranscriptionTUI? = usePlainMode ? nil : LiveTranscriptionTUI()

        do {
            // Request microphone permission
            if usePlainMode {
                logger.info("Requesting microphone permission...")
            }
            let permissionGranted = await requestMicrophonePermission()
            guard permissionGranted else {
                logger.error("Microphone permission denied. Please grant access in System Settings.")
                exit(1)
            }

            // Create streaming manager
            let streamingManager = SlidingWindowStreamingManager(config: configPreset)

            // Load ASR models
            if usePlainMode {
                logger.info("Loading ASR models...")
            }
            let models = try await AsrModels.downloadAndLoad()

            // Start the streaming manager
            try await streamingManager.start(models: models, source: .microphone)

            // Set up AVAudioEngine for microphone capture
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            if usePlainMode {
                logger.info("Config: interval=\(configPreset.intervalSeconds)s, context=\(configPreset.contextWindowSeconds)s")
                logger.info("Microphone format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channel(s)")
                logger.info("Press Ctrl+C to stop and get final transcription\n")
            }

            // Install tap on input node
            let bufferSize: AVAudioFrameCount = 4096
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                // Stream audio to the manager
                Task {
                    await streamingManager.streamAudio(buffer)
                }
            }

            // Start the audio engine
            try audioEngine.start()

            // Start TUI or print plain mode message
            if let tui = tui {
                tui.start()
            } else {
                logger.info("Microphone capture started. Speak now...\n")
            }

            // Listen for transcription updates
            let updateTask = Task {
                for await update in await streamingManager.transcriptionUpdates {
                    if let tui = tui {
                        tui.update(from: update)
                    } else {
                        printPlainUpdate(update)
                    }
                }
            }

            // Wait for stop signal
            while !liveTranscribeShouldStop {
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }

            // Stop TUI first
            tui?.stop()

            // Stop audio capture
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()

            // Get final transcription
            let finalText = try await streamingManager.finish()
            updateTask.cancel()

            // Print final results
            print("")
            print(String(repeating: "=", count: 50))
            print("FINAL TRANSCRIPTION")
            print(String(repeating: "=", count: 50))
            print(finalText)
            print(String(repeating: "=", count: 50))

        } catch {
            tui?.stop()
            logger.error("Live transcription failed: \(error)")
            exit(1)
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func setupSignalHandler() {
        signal(SIGINT) { _ in
            liveTranscribeShouldStop = true
        }
    }

    private static func printPlainUpdate(_ update: SlidingWindowTranscriptionUpdate) {
        let statusIcon = update.isConfirmed ? "✓" : "~"
        if !update.latestChunkText.isEmpty {
            print("[\(statusIcon)] \(update.latestChunkText)")
        }
    }

    private static func printUsage() {
        logger.info(
            """

            Live Transcribe Command Usage:
                fluidaudio live-transcribe [options]

            Options:
                --help, -h         Show this help message
                --plain            Disable TUI, use simple line-by-line output
                --low-latency      Use low-latency preset (faster updates, shorter context)
                --high-quality     Use high-quality preset (longer context, slower updates)
                --stateful         Use stateful decoder (preserves LSTM state between windows)
                --debug            Enable debug mode with synthesis features
                --interval <sec>   Override transcription interval (default: 2.0)
                --context <sec>    Override context window size (default: 14.0)

            Presets:
                default            2.0s interval, 14.0s context
                --low-latency      0.5s interval, 6.0s context
                --high-quality     3.0s interval, 14.0s context
                --stateful         2.0s interval, 14.0s context, preserves decoder state
                --debug            2.0s interval, 14.0s context, synthesis enabled

            Examples:
                fluidaudio live-transcribe                    # Default with TUI
                fluidaudio live-transcribe --plain            # Simple output
                fluidaudio live-transcribe --low-latency      # Faster response
                fluidaudio live-transcribe --interval 1.0     # Custom interval

            Press Ctrl+C to stop recording and get final transcription.
            """
        )
    }
}
#endif
