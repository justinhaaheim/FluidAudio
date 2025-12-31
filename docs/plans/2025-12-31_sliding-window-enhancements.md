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

### Phase 3: Visualization (next session)

- [ ] Build real-time token visualization
- [ ] Show agreement/disagreement across windows
- [ ] Display volatile vs confirmed in UI

## Current Status
Phase 1 and 2 complete. Swift builds successfully. TypeScript compiles. Ready for testing.

## Implementation Summary

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
