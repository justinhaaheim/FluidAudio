#if os(macOS)
import FluidAudio
import Foundation

/// Terminal UI for live transcription display
/// Renders a split view with confirmed text, volatile text, and status bar
final class LiveTranscriptionTUI {
    private var terminalWidth: Int
    private var terminalHeight: Int
    private let minWidth = 60
    private let statusBarHeight = 3  // Status bar + border + help text
    private let volatileHeight = 4   // Volatile section height (border + label + text + border)

    private var confirmedText: String = ""
    private var volatileText: String = ""
    private var recordingStartTime: Date?
    private var lastMetrics: TranscriptionMetrics?
    private var isRunning = false

    init() {
        let size = TerminalUI.getTerminalSize()
        self.terminalWidth = max(size.columns, minWidth)
        self.terminalHeight = size.rows
    }

    /// Start the TUI - clears screen and draws initial layout
    func start() {
        isRunning = true
        recordingStartTime = Date()

        TerminalUI.hideCursor()
        TerminalUI.clearScreen()
        drawFullLayout()
    }

    /// Stop the TUI - restores terminal state
    func stop() {
        isRunning = false
        TerminalUI.showCursor()
        TerminalUI.moveTo(row: terminalHeight, column: 1)
        print("")  // Move to new line
    }

    /// Update with new transcription data
    func update(
        confirmedText: String,
        volatileText: String,
        metrics: TranscriptionMetrics
    ) {
        self.confirmedText = confirmedText
        self.volatileText = volatileText
        self.lastMetrics = metrics

        // Refresh terminal size in case of resize
        let size = TerminalUI.getTerminalSize()
        let newWidth = max(size.columns, minWidth)
        let newHeight = size.rows

        if newWidth != terminalWidth || newHeight != terminalHeight {
            terminalWidth = newWidth
            terminalHeight = newHeight
            TerminalUI.clearScreen()
            drawFullLayout()
        } else {
            drawContent()
        }
    }

    /// Draw the complete layout (borders and content)
    private func drawFullLayout() {
        let width = terminalWidth - 2  // Leave margin

        // Calculate section heights
        let confirmedHeight = terminalHeight - volatileHeight - statusBarHeight - 4

        var row = 1

        // Top border with title
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawTopBorder(width: width, title: "Live Transcription"))
        row += 1

        // Confirmed section label
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: " Confirmed ".green + "(high confidence)".dim))
        row += 1

        // Confirmed content area
        for i in 0..<confirmedHeight {
            TerminalUI.moveTo(row: row + i, column: 1)
            TerminalUI.print(drawContentLine(width: width, content: ""))
        }
        row += confirmedHeight

        // Middle border
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawMiddleBorder(width: width))
        row += 1

        // Volatile section label
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: " Volatile ".yellow + "(may change)".dim))
        row += 1

        // Volatile content area (2 lines)
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: ""))
        row += 1
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: ""))
        row += 1

        // Status bar border
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawMiddleBorder(width: width))
        row += 1

        // Status bar content
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: ""))
        row += 1

        // Bottom border
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print(drawBottomBorder(width: width))
        row += 1

        // Help text
        TerminalUI.moveTo(row: row, column: 1)
        TerminalUI.print("  Press ".dim + "Ctrl+C".bold + " to stop".dim)

        // Draw initial content
        drawContent()
    }

    /// Draw just the content areas (not borders)
    private func drawContent() {
        let width = terminalWidth - 2
        let contentWidth = width - 4  // Account for borders and padding

        // Calculate positions
        let confirmedHeight = terminalHeight - volatileHeight - statusBarHeight - 4
        let confirmedStartRow = 3
        let volatileStartRow = confirmedStartRow + confirmedHeight + 2
        let statusRow = volatileStartRow + 3

        // Draw confirmed text
        let confirmedLines = wrapText(confirmedText, width: contentWidth)
        let visibleConfirmedLines = Array(confirmedLines.suffix(confirmedHeight))

        for i in 0..<confirmedHeight {
            TerminalUI.moveTo(row: confirmedStartRow + i, column: 1)
            let content = i < visibleConfirmedLines.count ? visibleConfirmedLines[i] : ""
            TerminalUI.print(drawContentLine(width: width, content: " " + content))
        }

        // Draw volatile text
        let volatileLines = wrapText(volatileText, width: contentWidth)
        let visibleVolatileLines = Array(volatileLines.suffix(2))

        for i in 0..<2 {
            TerminalUI.moveTo(row: volatileStartRow + i, column: 1)
            let content = i < visibleVolatileLines.count ? visibleVolatileLines[i].yellow : ""
            TerminalUI.print(drawContentLine(width: width, content: " " + content))
        }

        // Draw status bar
        TerminalUI.moveTo(row: statusRow, column: 1)
        TerminalUI.print(drawContentLine(width: width, content: formatStatusBar()))
    }

    /// Format the status bar content
    private func formatStatusBar() -> String {
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let timeStr = formatDuration(elapsed)

        guard let metrics = lastMetrics else {
            return " ⏱ \(timeStr)  │  Waiting for audio...".cyan
        }

        let rtf = String(format: "%.2f", metrics.realTimeFactor)
        let pace = String(format: "%.0f%%", metrics.pace * 100)
        let buffer = String(format: "%.1fs", metrics.bufferSeconds)
        let chunk = "#\(metrics.chunkCount)"

        let paceColor: String
        if metrics.pace >= 0.9 {
            paceColor = TerminalUI.Color.green
        } else if metrics.pace >= 0.7 {
            paceColor = TerminalUI.Color.yellow
        } else {
            paceColor = TerminalUI.Color.red
        }

        return " ⏱ \(timeStr)  │  RTF: \(rtf)x  │  Pace: \(pace.colored(paceColor))  │  Buffer: \(buffer)  │  \(chunk)"
    }

    /// Format duration as MM:SS
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Wrap text to fit within width
    private func wrapText(_ text: String, width: Int) -> [String] {
        guard !text.isEmpty && width > 0 else { return [] }

        var lines: [String] = []
        var currentLine = ""

        let words = text.split(separator: " ", omittingEmptySubsequences: false)

        for word in words {
            let wordStr = String(word)
            if currentLine.isEmpty {
                currentLine = wordStr
            } else if currentLine.count + 1 + wordStr.count <= width {
                currentLine += " " + wordStr
            } else {
                lines.append(currentLine)
                currentLine = wordStr
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines
    }

    // MARK: - Box Drawing

    private func drawTopBorder(width: Int, title: String) -> String {
        let innerWidth = width - 2
        let titleWithSpaces = " \(title) "
        let remainingWidth = innerWidth - titleWithSpaces.count
        let leftPadding = remainingWidth / 2
        let rightPadding = remainingWidth - leftPadding

        return BoxChars.topLeft +
            String(repeating: BoxChars.horizontal, count: leftPadding) +
            titleWithSpaces.bold +
            String(repeating: BoxChars.horizontal, count: rightPadding) +
            BoxChars.topRight
    }

    private func drawMiddleBorder(width: Int) -> String {
        return BoxChars.leftTee +
            String(repeating: BoxChars.horizontal, count: width - 2) +
            BoxChars.rightTee
    }

    private func drawBottomBorder(width: Int) -> String {
        return BoxChars.bottomLeft +
            String(repeating: BoxChars.horizontal, count: width - 2) +
            BoxChars.bottomRight
    }

    private func drawContentLine(width: Int, content: String) -> String {
        // Calculate visible length (without ANSI codes)
        let visibleLength = content.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        ).count

        let padding = max(0, width - 2 - visibleLength)
        return BoxChars.vertical + content + String(repeating: " ", count: padding) + BoxChars.vertical
    }
}

// MARK: - Convenience for SlidingWindowTranscriptionUpdate

extension LiveTranscriptionTUI {
    /// Update from a SlidingWindowTranscriptionUpdate
    func update(from update: SlidingWindowTranscriptionUpdate) {
        self.update(
            confirmedText: update.confirmedTranscript,
            volatileText: update.volatileTranscript.isEmpty ? update.latestChunkText : update.volatileTranscript,
            metrics: update.metrics
        )
    }
}
#endif
