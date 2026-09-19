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

## Follow-up: typing, rich previews, and Quick Open

The next pass removed repeated work from three other paths:

- **Typing:** the editor now caches relative tokens and incoming/outgoing fence
  state per logical line. It reparses changed lines and propagates fence changes
  until the cached context matches again. Only the affected text range and its
  preceding newline are restyled, leaving distant AppKit layout intact. Font,
  spacing, document replacement and focus-mode changes still support a full
  attribute refresh. The gutter reuses the line offsets produced by this pass.
  CRLF offsets now refer to the original text rather than a normalized copy.
- **Preview updates:** a new rendered body is reconciled against the original
  HTML of each top-level block. Unchanged DOM nodes, including enhanced code,
  math, Mermaid and images, stay attached. Only new blocks run the rich
  renderers. Source-line attributes are updated independently, duplicate blocks
  keep separate nodes, pending frames are coalesced, and document switches reset
  reuse so relative assets cannot carry over from another note.
- **Quick Open:** the file list is flattened, sorted and lowercased once when
  the tree changes. Each view evaluation computes results once and search stops
  after 40 matches. Previously, each evaluation could recursively sort the tree
  twice and search the entire list twice.

### Reproducible measurements

`script/benchmark_performance.swift` compares full tokenization with the
incremental cache and retains the previous Quick Open algorithm as a baseline.
It asserts matching results before reporting timings. Run from the repository:

```sh
benchmark_dir="$(mktemp -d /tmp/glassmark-benchmark.XXXXXX)"
swiftc -O -module-cache-path "$benchmark_dir/modules" \
  GlassMark/Support/MarkdownSyntaxHighlighter.swift \
  GlassMark/Models/WorkspaceFile.swift \
  script/benchmark_performance.swift -o "$benchmark_dir/benchmark"
"$benchmark_dir/benchmark"
```

One local optimized run on September 19, 2026:

| Workload | Full/repeated work | Reused work |
| --- | ---: | ---: |
| 80 heading edits over 2,000 body lines / 90,000 UTF-16 units | 271.85 ms | 72.49 ms |
| 20 searches over 10,000 files / 100 directories | 273.77 ms | 134.85 ms |

The first workload reparses 80 lines in total with the cache. Its timings do not
include AppKit attribute application or layout. The second excludes initial
index construction and times one result computation per query, even though the
old view could compute it twice. These are isolated CPU measurements, not FPS or
end-to-end app speedups, and vary between runs.

### Follow-up validation

Regression tests cover incremental/full attribute equivalence after structural
edits, fence changes, Unicode normalization, CRLF, inherited typing attributes,
unaffected distant attributes, search ordering and limits. WebKit tests use its
real DOM with instrumented rich renderers and explicitly driven animation
frames: unchanged code, math and Mermaid each render once across edits, their
nodes survive source-line shifts, and rapid updates, duplicates, empty notes
and document switches are handled.

Debug and Release builds compile successfully. A focused run covering all eight
affected suites passed **65 tests with zero failures**, including the real-DOM
WebKit tests. The full-suite attempt and a
second run excluding preferences both reproduced the existing native crash in
`objc_release` / `_NSWindowTransformAnimation dealloc`. The new crash stacks match
the report captured before this follow-up; excluding preferences alone does not
isolate it, as a later run reached the preview suite before crashing. These runs
are not claimed as passing.

## Follow-up: sidebar note selection

File rows registered both single- and double-click gestures, even though both
opened the same note. SwiftUI waited for the double-click interval before
delivering the single-click action. This introduced a nearly fixed delay even
when switching between notes already open in the editor.

Each row now registers one gesture: a single click for files, a double click
for folders. Folder disclosure controls retain their existing behavior.

On September 19, 2026, six sidebar switches across the same four already-open
notes (approximately 3,800–16,000 characters) were measured before and after,
with identical settings and window geometry within each build configuration:

| Build | Before, median (range) | After, median (range) |
| --- | ---: | ---: |
| Debug | 403.5 ms (378–410 ms) | 32 ms (16–38 ms) |
| Release | 381.5 ms (372–390 ms) | 23.5 ms (21–35 ms) |

The measured interval starts at an AppKit local `leftMouseUp` event monitor and
ends immediately after text replacement and synchronous highlighting in
`MarkdownTextView.updateNSView`. Temporary unified-log markers recorded each
endpoint; the editor marker was paired with the most recent mouse-up from the
same process. The instrumentation was removed after measurement. To reproduce,
instrument these endpoints, switch through four distinct open notes and then
repeat the first two, keeping the notes, settings, click interval and build
configuration identical between versions. Capture real pointer events rather
than invoking selection callbacks directly, which bypasses gesture recognition.

These measurements include gesture dispatch and editor work before that endpoint,
but do not measure final screen presentation, preview completion, cold disk reads
or very large notes. Folder collapse/expansion by double click was also verified
in the running app.

The final Debug test build passed all 13 tests in `DocumentStoreTests` and
`FileTreeDragTests`; the final Release build also succeeded. The full suite was
not rerun for this gesture-only change.

## Remaining profiling targets

Initial file reads, saves and session restoration still perform file I/O on the
main thread. Outline/statistics analysis still runs synchronously after a text
revision. The highlight cache still splits/compares the document's lines, and
initial highlighting, focus-mode attribute refreshes, large structural edits and
AppKit layout can still do document-sized work. Notes beyond the existing
200,000-unit highlighting limit retain their plain-style fallback.

The preview still renders all Markdown in the background and parses the returned
HTML into a detached template; reuse reduces live DOM replacement and rich
rendering, not Markdown parsing itself. Quick Open still builds its initial index
on the main thread and scans it for queries with few matches.

Profile a Release build with representative notes to measure complete switch
latency, typing latency and frame times before undertaking those larger changes.
The existing `script/build_and_run.sh` builds Debug by default, so it should not
be used as a proxy for optimized Release performance.
