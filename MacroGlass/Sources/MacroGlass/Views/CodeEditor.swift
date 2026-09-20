import SwiftUI
import AppKit

/// A real code editor: NSTextView with a line-number gutter, current-line
/// highlight, tab handling, optional auto-indent and bracket closing, and —
/// critically — every "smart" substitution turned off, so quotes, dashes and
/// apostrophes stay ASCII instead of being curled into characters that break
/// shell and Python scripts.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var showsLineNumbers: Bool
    var highlightsCurrentLine: Bool
    var tabWidth: Int
    var insertsSpaces: Bool
    var wrapsLines: Bool = true
    var autoIndents: Bool = true
    var autoClosesBrackets: Bool = true
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Building the TextKit 1 stack by hand keeps `layoutManager`
        // available, which the gutter and line highlight both need.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        // NSSize has Int/Double/CGFloat initializers, so bare literals and
        // `.greatestFiniteMagnitude` are ambiguous — spell out CGFloat.
        let container = NSTextContainer(
            size: NSSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: CGFloat(8), height: CGFloat(10))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: CGFloat(0), height: CGFloat(0))
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        let scrollView = CodeScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showsLineNumbers

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.observeBounds(of: scrollView)

        apply(to: textView, ruler: ruler, coordinator: context.coordinator, force: true)
        applyWrapping(scrollView: scrollView, textView: textView)

        // Put the caret in the editor as soon as the tab opens, so the
        // first keystroke lands in the code rather than nowhere.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Keep the coordinator's binding fresh — a binding captured once at
        // makeCoordinator time can go stale across view identity changes.
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? CodeTextView else { return }

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
            context.coordinator.needsAttributeRefresh = true
        }

        scrollView.rulersVisible = showsLineNumbers
        apply(
            to: textView,
            ruler: scrollView.verticalRulerView as? LineNumberRulerView,
            coordinator: context.coordinator,
            force: false
        )

        if context.coordinator.appliedWrapping != wrapsLines {
            context.coordinator.appliedWrapping = wrapsLines
            applyWrapping(scrollView: scrollView, textView: textView)
        }
    }

    /// Restyling on every keystroke would stomp on undo grouping and IME
    /// marked text, so the attribute pass only runs when something that
    /// affects it actually changed.
    private func apply(to textView: CodeTextView, ruler: LineNumberRulerView?, coordinator: Coordinator, force: Bool) {
        let changed = force
            || coordinator.appliedFont != font
            || coordinator.appliedTabWidth != tabWidth
            || coordinator.needsAttributeRefresh

        textView.highlightsCurrentLine = highlightsCurrentLine
        textView.insertsSpaces = insertsSpaces
        textView.autoIndents = autoIndents
        textView.autoClosesBrackets = autoClosesBrackets
        textView.placeholder = placeholder

        if changed {
            textView.font = font
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.tabWidth = tabWidth
            textView.applyTypingAttributes()

            coordinator.appliedFont = font
            coordinator.appliedTabWidth = tabWidth
            coordinator.needsAttributeRefresh = false

            ruler?.gutterFont = NSFont.monospacedDigitSystemFont(
                ofSize: max(9, font.pointSize - 2),
                weight: .regular
            )
        }

        textView.needsDisplay = true
        ruler?.needsDisplay = true
    }

    /// Soft wrap pins the text container to the visible width; the other
    /// way round lets lines run off to the right with a horizontal
    /// scroller, which is what you want for long AHK Send lines.
    private func applyWrapping(scrollView: NSScrollView, textView: CodeTextView) {
        guard let container = textView.textContainer else { return }

        if wrapsLines {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            let width = scrollView.contentSize.width
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRulerView?

        var appliedFont: NSFont?
        var appliedTabWidth: Int?
        var appliedWrapping: Bool?
        var needsAttributeRefresh = false

        private var observer: NSObjectProtocol?

        init(_ parent: CodeEditor) {
            self.parent = parent
            self.appliedWrapping = parent.wrapsLines
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true
        }

        func observeBounds(of scrollView: NSScrollView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.ruler?.needsDisplay = true
            }
        }
    }
}

// MARK: - Scroll view

/// Views that don't draw their own background volunteer to drag the window,
/// which used to mean clicking the editor moved the window instead of
/// focusing the text. Both the scroll view and the text view opt out, and
/// both accept the very first click so one click into an unfocused window
/// lands the caret rather than only activating the app.
final class CodeScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A click in the empty space under the last line should focus the
        // editor and drop the caret at the end, like any code editor.
        if let textView = documentView as? NSTextView {
            window?.makeFirstResponder(textView)
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Text view

final class CodeTextView: NSTextView {
    var highlightsCurrentLine = true
    var tabWidth = 4
    var insertsSpaces = true
    var autoIndents = true
    var autoClosesBrackets = true
    var placeholder = ""

    private static let bracketPairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"
    ]
    private static let closers: Set<String> = [")", "]", "}", "\"", "'", "`"]

    /// See CodeScrollView — this is what makes the editor clickable.
    override var mouseDownCanMoveWindow: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func applyTypingAttributes() {
        let resolved = font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = resolved.maximumAdvancement.width
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.tabStops = []
        style.defaultTabInterval = max(advance, 6) * CGFloat(max(1, tabWidth))

        defaultParagraphStyle = style
        typingAttributes = [
            .font: resolved,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]

        if let storage = textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttributes(typingAttributes, range: full)
        }
    }

    override func insertTab(_ sender: Any?) {
        if insertsSpaces {
            insertText(String(repeating: " ", count: max(1, tabWidth)), replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
        }
    }

    /// Carries the current line's leading whitespace onto the next line,
    /// and adds one level after a line that opens a block.
    override func insertNewline(_ sender: Any?) {
        guard autoIndents else {
            super.insertNewline(sender)
            return
        }

        let content = string as NSString
        let caret = min(selectedRange().location, content.length)
        let line = content.substring(with: content.lineRange(for: NSRange(location: caret, length: 0)))

        var indent = ""
        for character in line {
            if character == " " || character == "\t" {
                indent.append(character)
            } else {
                break
            }
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let opensBlock = trimmed.hasSuffix("{")
            || trimmed.hasSuffix(":")
            || trimmed.hasSuffix("(")
            || trimmed.hasSuffix("[")
            || trimmed.hasSuffix(" then")
            || trimmed.hasSuffix(" do")
        if opensBlock {
            indent += insertsSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t"
        }

        super.insertNewline(sender)
        if !indent.isEmpty {
            super.insertText(indent, replacementRange: selectedRange())
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard autoClosesBrackets,
              let typed = string as? String,
              typed.count == 1,
              selectedRange().length == 0 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Typing the closer that's already sitting under the caret should
        // step over it rather than doubling it up.
        if Self.closers.contains(typed), nextCharacter() == typed {
            setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
            return
        }

        guard let closing = Self.bracketPairs[typed] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        super.insertText(typed + closing, replacementRange: replacementRange)
        let caret = selectedRange().location
        setSelectedRange(NSRange(location: max(0, caret - (closing as NSString).length), length: 0))
    }

    private func nextCharacter() -> String? {
        let content = string as NSString
        let caret = selectedRange().location
        guard caret < content.length else { return nil }
        return content.substring(with: NSRange(location: caret, length: 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCurrentLineHighlight()
        super.draw(dirtyRect)
        drawPlaceholderIfNeeded()
    }

    private func drawCurrentLineHighlight() {
        guard highlightsCurrentLine,
              let layoutManager,
              let container = textContainer else { return }

        let content = string as NSString
        let caret = min(selectedRange().location, content.length)
        let lineRange = content.lineRange(for: NSRange(location: caret, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        if rect.height < 1 {
            rect.size.height = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
        }
        rect.origin.x = 0
        rect.origin.y += textContainerInset.height
        rect.size.width = bounds.width

        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        rect.fill()
    }

    private func drawPlaceholderIfNeeded() {
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}

// MARK: - Line number gutter

final class LineNumberRulerView: NSRulerView {
    var gutterFont: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private weak var codeView: NSTextView?

    init(textView: NSTextView) {
        codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // No background fill — the glass behind the editor shows through.
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // Hairline separating the gutter from the code.
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSRect(
            x: ruleThickness - 0.5,
            y: CGFloat(0),
            width: CGFloat(0.5),
            height: bounds.height
        ).fill()

        let content = textView.string as NSString
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        // Count the lines above the visible range to know where to start.
        var lineNumber = 1
        content.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleChars.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let inset = textView.textContainerInset.height
        let originY = convert(NSPoint.zero, from: textView).y

        func drawNumber(_ number: Int, fragment: NSRect) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = originY + inset + fragment.minY + (fragment.height - size.height) / 2
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: y),
                withAttributes: attributes
            )
        }

        content.enumerateSubstrings(in: visibleChars, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            drawNumber(lineNumber, fragment: fragment)
            lineNumber += 1
        }

        // The empty line after a trailing newline (and line 1 of an empty
        // document) has no glyphs, so it needs drawing explicitly.
        if content.length == 0 || content.hasSuffix("\n") {
            drawNumber(lineNumber, fragment: layoutManager.extraLineFragmentRect)
        }
    }
}
