# Polyglot Engineering Standards & Idioms (RFC 2119)

When generating, modifying, or refactoring code in any of the following languages, you MUST adhere strictly to these engineering standards.

---

## 1. TypeScript & JavaScript

1. **Strict Type Safety:** Zero tolerance for `any`. Use `unknown` with runtime type narrowing or generic constraints.
2. **Explicit Signatures:** All exported functions and methods MUST specify explicit return types.
3. **Immutability:** Use `const` by default; avoid in-place array/object mutation where practical (prefer map, filter, spread).
4. **Boundary Validation:** Use schema validation (e.g. `zod` or `valibot`) for all external inputs (API payloads, query params, environment variables).
5. **Modern Modules:** Use ECMAScript Modules (ESM: `import`/`export`). Never use CommonJS `require()` or `module.exports`.

---

## 2. Python (3.11+)

1. **Type Annotations:** All function arguments and return types MUST have type hints (`typing`, `Callable`, `Literal`, `TypeVar`).
2. **Data Modeling:** Prefer `dataclasses` (standard library) or `pydantic` (external APIs) over raw dictionaries.
3. **Filesystem:** ALWAYS use `pathlib.Path` over `os.path` or raw string concatenation.
4. **Resource Management:** ALWAYS use context managers (`with` / `async with`) for file I/O, database sessions, and locks.
5. **Safe Subprocesses:** NEVER use `os.system` or `shell=True`. Use `subprocess.run(..., check=True, text=True)`.
6. **Non-Blocking I/O:** For concurrent I/O-bound tasks, use `asyncio` or thread pools; never block the async event loop with synchronous calls.

---

## 3. SQL & Database Operations

1. **100% Parameterization:** All SQL queries MUST use parameterized placeholders (`?`, `$1`, or named params). String concatenation or f-string interpolation in SQL is strictly prohibited.
2. **Atomic Transactions:** Wrap multi-step mutations in explicit database transactions (`BEGIN` ... `COMMIT` / `ROLLBACK`).
3. **Schema Integrity:** Explicit foreign keys, non-null constraints, and proper indexes on query lookup columns.

---

## 4. Rust

1. **Error Propagation:** ALWAYS propagate fallible operations using `Result<T, E>` and `Option<T>` with the `?` operator. Production code MUST NOT call `.unwrap()` or `.expect()` on fallible external inputs.
2. **Memory Efficiency:** Avoid unnecessary `.clone()` calls; use references and borrowing where lifetimes permit.
3. **Linter Compliance:** Zero warnings tolerated under `cargo clippy`.

---

## 5. Go (Golang)

1. **Error Handling:** Explicit error checking (`if err != nil`) immediately following fallible calls. Wrap errors with context: `fmt.Errorf("action failed: %w", err)`.
2. **Concurrency Safety:** Propagate `context.Context` across all function boundaries. Prevent goroutine leaks using `sync.WaitGroup` and proper channel closures.
3. **Resource Cleanup:** ALWAYS `defer` resource cleanup (`res.Body.Close()`, `file.Close()`) immediately after successful acquisition.

---

## 6. Shell & Scripting (Bash & PowerShell)

1. **Bash:** Script headers MUST include `set -euo pipefail`. ALWAYS double-quote variables (`"$VAR"`). Use `[[ ... ]]` for test conditions.
2. **PowerShell:** Script headers MUST include `$ErrorActionPreference = 'Stop'`. Explicitly invoke child processes with `-NoProfile`.
