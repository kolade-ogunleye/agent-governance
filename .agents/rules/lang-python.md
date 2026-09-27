---
paths:
  - "**/*.{py,pyi}"
  - "**/pyproject.toml"
---

# Python (3.11+) Standards (RFC 2119)

1. **Type Annotations:** All function arguments and return types MUST have type hints (`typing`, `Callable`, `Literal`, `TypeVar`).
2. **Data Modeling:** Prefer `dataclasses` (standard library) or `pydantic` (external APIs) over raw dictionaries.
3. **Filesystem:** ALWAYS use `pathlib.Path` over `os.path` or raw string concatenation.
4. **Resource Management:** ALWAYS use context managers (`with` / `async with`) for file I/O, database sessions, and locks.
5. **Safe Subprocesses:** NEVER use `os.system` or `shell=True`. Use `subprocess.run(..., check=True, text=True)`.
6. **Non-Blocking I/O:** For concurrent I/O-bound tasks, use `asyncio` or thread pools; never block the async event loop with synchronous calls.
