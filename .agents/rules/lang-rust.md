---
paths:
  - "**/*.rs"
  - "**/Cargo.toml"
---

# Rust Standards (RFC 2119)

1. **Error Propagation:** ALWAYS propagate fallible operations using `Result<T, E>` and `Option<T>` with the `?` operator. Production code MUST NOT call `.unwrap()` or `.expect()` on fallible external inputs.
2. **Memory Efficiency:** Avoid unnecessary `.clone()` calls; use references and borrowing where lifetimes permit.
3. **Linter Compliance:** Zero warnings tolerated under `cargo clippy`.
