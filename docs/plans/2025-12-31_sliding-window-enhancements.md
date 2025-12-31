# Sliding Window Streaming Manager Enhancements

## Goal
Enhance SlidingWindowStreamingManager with features ported from StreamingAsrManager, making it a more robust and feature-complete streaming solution.

## Tasks

### Phase 1: Core Enhancements to SlidingWindowStreamingManager - COMPLETED

- [x] Add optional decoder state preservation
  - [x] Add `preserveDecoderState: Bool` to config
  - [x] Store decoder state as optional property
  - [x] Reset decoder state on manager reset/start
  - [x] Use preserved state in processWindow when enabled

- [x] Add two-tier volatile/confirmed transcript model
  - [x] Add `volatileTranscript` and `confirmedTranscript` properties
  - [x] Update output type to include both (SlidingWindowTranscriptionUpdate)
  - [x] Implement confirmation logic based on confidence + context

- [x] Add confidence-based confirmation
  - [x] Add `confirmationThreshold: Double` to config
  - [x] Add `minContextForConfirmation: TimeInterval` to config
  - [x] Implement `updateTranscriptionState` method

- [x] Add error recovery with decoder reset
  - [x] Add `attemptErrorRecovery` method
  - [x] Add `resetDecoderForRecovery` method
  - [x] Add public `resetDecoderState` method for manual reset

### Phase 2: Expose to JavaScript via expo-fluid-audio - COMPLETED

- [x] Update `makeSlidingWindowConfig` to pass new options
- [x] Update event emission to include new fields
- [x] Add `getSlidingWindowVolatileTranscript` method
- [x] Add `getSlidingWindowConfirmedTranscript` method
- [x] Add `resetSlidingWindowDecoderState` method
- [x] Update TypeScript types (SlidingWindowStreamingConfig, SlidingWindowTranscriptionUpdateEvent)
- [x] Add new preset: `stateful` with preserveDecoderState=true

### Phase 3: Visualization - COMPLETED

- [x] Design data structures for window-level token data
  - Added `WindowToken` and `TranscriptionWindowData` structs in Swift
  - Added matching TypeScript interfaces
  - Added `emitWindowData` and `edgeBufferSeconds` config options
  - Added `debug` preset with emitWindowData=true

- [x] Update Swift to emit window-level debug data
  - Added `buildWindowTokenData` method in SlidingWindowStreamingManager
  - Added `decodeToken` method to AsrManager
  - Updated event emission to include windowData when enabled

- [x] Build stacked windows timeline component
  - Created `WindowDebugVisualization.tsx` in example app
  - Shows stacked windows with token-level detail
  - Time-based x-axis with scrollable timeline
  - Edge buffer zones visualized (red tint for start/end buffers)
  - Confidence-based token coloring (green/yellow/orange/red)

- [x] Build combined result row component
  - Shows merged transcript at top of visualization
  - Latest window stats (tokens, avg confidence, buffer count, duration)

- [x] Integrate visualization into example app
  - Added "Debug view" toggle in sliding window mode
  - Accumulates window data history during streaming
  - Renders WindowDebugVisualization when toggle enabled

## Current Status
Phases 1, 2, and 3 complete. Swift builds successfully. Ready for testing.

## Implementation Summary

### Visualization (Phase 3)

New files:
- `packages/expo-fluid-audio/example/WindowDebugVisualization.tsx` - React component for debug view

New config options:
- `emitWindowData: Bool` (default: false) - Emit token-level data for each window
- `edgeBufferSeconds: TimeInterval` (default: 1.0) - Duration of edge buffer zones

New TypeScript types:
- `WindowToken` - Token with confidence, timestamp, and edge buffer flags
- `TranscriptionWindowData` - Window with all its tokens and metadata

New preset:
- `SlidingWindowStreamingConfigPresets.debug` - Same as default but with emitWindowData=true

How to use:
1. In example app, switch to "Timer" mode
2. Enable "Debug view" toggle
3. Start recording - visualization will populate as windows are processed
4. Each window row shows tokens positioned by timestamp
5. Red-tinted zones indicate edge buffers (less reliable)
6. Token colors indicate confidence level

### New Config Options (SlidingWindowStreamingConfig)
- `preserveDecoderState: Bool` (default: false) - Preserves LSTM state across windows
- `useConfirmationModel: Bool` (default: true) - Enables volatile/confirmed model
- `confirmationThreshold: Double` (default: 0.85) - Confidence threshold for confirmation
- `minContextForConfirmation: TimeInterval` (default: 10.0) - Min audio before confirming

### New Output Fields (SlidingWindowTranscriptionUpdate)
- `volatileTranscript: String` - Current hypothesis (may change)
- `confirmedTranscript: String` - High-confidence finalized text
- `isConfirmed: Bool` - Whether current update is confirmed

### New Preset
- `SlidingWindowStreamingConfig.stateful` - Same as default but with preserveDecoderState=true

### New JS Methods
- `getSlidingWindowVolatileTranscript()` - Get current volatile text
- `getSlidingWindowConfirmedTranscript()` - Get current confirmed text
- `resetSlidingWindowDecoderState()` - Manually reset decoder state

## Notes
- Keep decoder state simple for now (on/off, no rolling context)
- Make new features toggleable so we can A/B test
- Match StreamingAsrManager patterns where sensible
