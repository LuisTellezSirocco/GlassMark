import AppKit

/// Thin gutter that labels every logical line with a faint monospaced number.
///
/// Installed beside the editor's scroll view inside `EditorContainerView` —
/// deliberately *not* as an `NSRulerView`. AppKit "compensates" the clip view
/// of a scroll view that shows a ruler by shifting its bounds under it
/// (e.g. `bounds.origin.x = -ruleThickness`); on macOS 26 that leaves the
/// scroll view's `NSTextView` unable to draw its text at all. A plain sibling
/// view keeps the clip view standard (`bounds.origin.x == 0`) and the text
/// keeps painting while still getting its numbers.
///
/// Only the first visual fragment of a logical line is labeled: soft-wrapped
/// text keeps one number per source line, never one per wrapped row.
final class LineNumberGutterView: NSView {
    /// Editor text size. Labels are drawn a couple of points smaller.
    var textSize: CGFloat = CGFloat(DocumentTextSize.defaultSize) {
        didSet {
            guard abs(oldValue - textSize) > 0.001 else { return }
            refresh()
        }
    }

    private weak var textView: NSTextView?
    /// Character offsets where each logical line starts (always contains 0).
    private var lineStarts: [Int] = [0]
    private var labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .light)
    private var labelWidth: CGFloat = 24

    private let horizontalPadding: CGFloat = 6
    private let minimumDigits = 2

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Top-down coordinates, like the text view, so converted fragment rects
    /// and text drawing line up without extra math.
    override var isFlipped: Bool { true }

    /// Width that fits the widest label plus breathing room.
    var preferredWidth: CGFloat { labelWidth }

    /// Recomputes the line cache, font and width. Call after the text or the
    /// font size changes.
    func refresh() {
        guard let textView else { return }
        lineStarts = LineIndex.lineStarts(in: textView.string as NSString)
        labelFont = NSFont.monospacedSystemFont(ofSize: max(9, textSize - 2), weight: .light)

        let digits = max(minimumDigits, String(max(lineStarts.count, 1)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        labelWidth = ceil(sample.size(withAttributes: [.font: labelFont]).width) + horizontalPadding * 2
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The label color is dynamic; repaint with the new appearance.
        needsDisplay = true
    }

    /// One gutter number: the logical line's number and where to paint it, in
    /// the gutter's own coordinates.
    struct GutterLabel: Equatable {
        let number: Int
        let rect: NSRect
    }

    /// The numbers to paint for the visible part of the document, one per
    /// logical line. Wrapped continuations produce no label of their own.
    func labels(in dirtyRect: NSRect) -> [GutterLabel] {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return [] }

        let nsString = textView.string as NSString
        var labels: [GutterLabel] = []

        if layoutManager.numberOfGlyphs > 0 {
            let origin = textView.textContainerOrigin
            let visibleInContainer = textView.visibleRect
                .offsetBy(dx: -origin.x, dy: -origin.y)
                .insetBy(dx: 0, dy: -8)
            let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleInContainer, in: textContainer)

            if visibleGlyphs.location != NSNotFound, visibleGlyphs.length > 0 {
                layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { fragmentRect, usedRect, _, fragmentGlyphRange, _ in
                    let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphRange, actualGlyphRange: nil)
                    let location = min(charRange.location, nsString.length)
                    // A fragment opens a logical line only at the very start of
                    // the document or right after a newline. The continuation of
                    // a soft wrap follows a regular character and stays bare.
                    guard location == 0 || nsString.character(at: location - 1) == 0x0A else { return }
                    let anchorRect = usedRect.height > 0 ? usedRect : fragmentRect
                    let label = GutterLabel(
                        number: LineIndex.lineNumber(forCharacterAt: location, lineStarts: self.lineStarts),
                        rect: self.gutterRect(forContainerRect: anchorRect)
                    )
                    if label.rect.intersects(dirtyRect) { labels.append(label) }
                }
            }
        }

        // The caret's empty last line (after a trailing newline, or in an empty
        // document) is not part of the fragment enumeration.
        if nsString.length == 0 {
            layoutManager.ensureLayout(for: textContainer)
        }
        if nsString.length == 0 || nsString.character(at: nsString.length - 1) == 0x0A,
           layoutManager.extraLineFragmentTextContainer != nil {
            let anchorRect = layoutManager.extraLineFragmentUsedRect.height > 0
                ? layoutManager.extraLineFragmentUsedRect
                : layoutManager.extraLineFragmentRect
            let label = GutterLabel(
                number: LineIndex.lineNumber(forCharacterAt: nsString.length, lineStarts: lineStarts),
                rect: gutterRect(forContainerRect: anchorRect)
            )
            if label.rect.intersects(dirtyRect) { labels.append(label) }
        }

        return labels
    }

    override func draw(_ dirtyRect: NSRect) {
        // Blend with the editor paper: no separator, just faint digits.
        (textView?.backgroundColor ?? NSColor.textBackgroundColor).setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        for label in labels(in: dirtyRect) {
            draw(label, attributes: attributes)
        }
    }

    /// Draws one number, right-aligned, vertically centered on its line's first
    /// fragment.
    private func draw(_ label: GutterLabel, attributes: [NSAttributedString.Key: Any]) {
        let text = "\(label.number)" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: bounds.width - horizontalPadding - size.width,
                y: label.rect.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// Converts a text container rectangle into the gutter's coordinates.
    private func gutterRect(forContainerRect rect: NSRect) -> NSRect {
        guard let textView else { return rect }
        let origin = textView.textContainerOrigin
        return convert(rect.offsetBy(dx: origin.x, dy: origin.y), from: textView)
    }
}

/// Hosts the line-number gutter and the editor scroll view side by side.
///
/// `layout()` gives the gutter a fixed strip on the left and the scroll view
/// the rest, so showing or hiding the numbers never touches the scroll view's
/// clip view geometry.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutterView

    private(set) var isGutterVisible = false

    init(scrollView: NSScrollView, gutter: LineNumberGutterView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setGutterVisible(_ visible: Bool) {
        guard isGutterVisible != visible else { return }
        isGutterVisible = visible
        gutter.isHidden = !visible
        needsLayout = true
    }

    /// Keeps the layout in sync when the gutter's preferred width changes.
    func gutterWidthChanged() {
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = isGutterVisible ? min(gutter.preferredWidth, bounds.width) : 0
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}
