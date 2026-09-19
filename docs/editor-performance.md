# Editor and preview performance

The September 2026 investigation identified these hot paths by inspecting the
note-switch and scroll handlers:

- Each editor scroll counted newlines in a newly allocated prefix of the note.
  Cost grew with the distance scrolled. Scroll synchronization now uses the
  logical-line index shared with the gutter: binary search from character to
  line, direct lookup from line to character. Edits refresh the index before
  deferred highlighting, including for large notes.
- SwiftUI scroll notifications reevaluated the outline and compared complete
  editor/preview strings. The document store now caches outline and statistics
  by session and revision (at most 16 entries); native views use those identifiers
  to detect content changes without comparing strings on every scroll.
- The preview waited 120 ms for both edits and tab switches. Only edits now wait;
  note switches render immediately on the background queue. A generation check
  discards obsolete background results, including when another document is
  selected before the shell finishes loading. Empty notes render too.
- Preview scroll scanned preceding DOM blocks and read each rectangle. It now
  retains the source-block list and binary-searches live positions. Live geometry
  keeps image loads, math, zoom, and resizing from invalidating cached positions.
  Mermaid replacements retain their source-line mapping. Repeated reports of
  the same source line are suppressed.

A test-runner process sample also found a separate startup hang: opening the
chat database lock with `O_EXLOCK` blocked indefinitely while another instance
owned it. The lock now includes `O_NONBLOCK`, preserving exclusive ownership
while returning the existing storage-unavailable error instead of freezing the
main thread. A regression test opens competing connections to a temporary DB.

## Validation

A release-optimized Swift microbenchmark used the original newline-counting
expression and the production `LineIndex` implementation on a 10,000-line note.
For 300 lookups near the bottom, both returned identical line numbers:

| Implementation | Total time |
| --- | ---: |
| Prefix allocation and newline counting | 2703.78 ms |
| Reused line index and binary search | 0.009 ms |

These timings isolate lookup work, exclude index construction (once per content
change), and are not end-to-end frame-rate or tab-switch measurements.

Regression coverage checks analysis invalidation across edits, tab switches,
and reopenings; UTF-16 scroll offsets before deferred highlighting; and executes
the preview's JavaScript with 10,000 source blocks, checking bounded geometry
reads, layout changes, and duplicate-message suppression.

The Debug build and focused suite for document state, editor styling/scrolling,
line numbers, preview rendering, chat storage, and inline replacement passed.
Two full-suite attempts hit a native AppKit window-animation crash during
different `PreferencesStoreTests`; those runs are not claimed as green. The
captured crash stack starts in `objc_release` / `_NSWindowTransformAnimation`
destruction. The focused run completed successfully without that suite.

## Remaining profiling targets

Initial file reads, full syntax highlighting, and AppKit text layout still have
costs proportional to document size. The changes above remove repeated work
from scrolling, but do not virtualize the editor or move file I/O off the main
thread. Profile a Release build with representative notes to measure complete
switch latency and frame times before undertaking those larger changes.
