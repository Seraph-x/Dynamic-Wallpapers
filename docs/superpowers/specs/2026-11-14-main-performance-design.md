# Main application performance: six sequential changes

The user approved the six findings from the source review and requested one
verified commit per optimization, in order. Playback quality, frame rate,
permission checks, error reporting, and resource-release barriers remain part of
the acceptance contract. Work stays in the clean current checkout, with commits
providing the six requested review/recovery points; no parallel implementation.

1. **Thumbnails:** share in-flight decoding for equal media sources. Each caller
   owns a subscription; cancellation detaches only that caller and cancels the
   decoder when the final subscriber leaves. Removal/shutdown still drain real
   decoder cleanup and preserve release failures. Cache entries carry the source
   metadata so changed scene properties or source paths cannot return old images.
2. **Audio editing:** slider motion updates the active audio immediately; one
   persistent commit follows the completed edit. Closing/replacing the editor or
   terminating the app must finish or explicitly fail the pending edit. Keep
   ordinary discrete setting changes transactional. Do not silently defer errors.
3. **Library lookups:** use per-validation media/playlist indexes and reuse a
   filtered collection within a view update. Avoid invalidation policies that
   require maintaining a second mutable source of truth.
4. **Extended video:** reuse released RGBA allocations without ever rewriting
   pixels retained by a delivered frame. Preserve libmpv's required render/drain
   semantics and the one-in-flight/latest-pending presentation policy. Use the
   existing software output as the first concrete optimization; GPU output is not
   required to remove allocation churn and needs a separate backend design.
5. **Web/scene frames:** carry CEF dirty rectangles into a frame-storage component
   and avoid redundant full-frame copying while preserving immutable delivered
   images, first-paint readiness, thumbnails, screenshots, resize, and close.
   Choose the implementation after validating CEF's callback buffer lifetime.
   A GPU path must not replace these contracts without equivalent acceptance.
6. **Background work:** tie Finder interaction work to actual eligible playback
   targets, refreshing evidence before accepting input on resume. Reduce page
   lifecycle polling independently of CEF's required external message pump.
   Readiness, error delivery, and close deadlines must still complete promptly.

Each stage includes targeted regression tests, relevant existing integration
checks, source/diff review, and its own commit. Performance claims distinguish
operation/allocation/copy counts from process CPU, GPU, or resident memory.
