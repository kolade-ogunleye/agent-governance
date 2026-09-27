---
paths:
  - "**/*.{ts,tsx,mts,cts}"
  - "**/*.{js,jsx,mjs,cjs}"
---

# TypeScript & JavaScript Standards (RFC 2119)

1. **Strict Type Safety:** Zero tolerance for `any`. Use `unknown` with runtime type narrowing or generic constraints.
2. **Explicit Signatures:** All exported functions and methods MUST specify explicit return types.
3. **Immutability:** Use `const` by default; avoid in-place array/object mutation where practical (prefer map, filter, spread).
4. **Boundary Validation:** Use schema validation (e.g. `zod` or `valibot`) for all external inputs (API payloads, query params, environment variables).
5. **Modern Modules:** Use ECMAScript Modules (ESM: `import`/`export`). Never use CommonJS `require()` or `module.exports`.
