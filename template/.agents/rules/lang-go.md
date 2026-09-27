---
paths:
  - "**/*.go"
  - "**/go.mod"
---

# Go Standards (RFC 2119)

1. **Error Handling:** Explicit error checking (`if err != nil`) immediately following fallible calls. Wrap errors with context: `fmt.Errorf("action failed: %w", err)`.
2. **Concurrency Safety:** Propagate `context.Context` across all function boundaries. Prevent goroutine leaks using `sync.WaitGroup` and proper channel closures.
3. **Resource Cleanup:** ALWAYS `defer` resource cleanup (`res.Body.Close()`, `file.Close()`) immediately after successful acquisition.
