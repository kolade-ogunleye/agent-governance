---
paths:
  - "**/*.sql"
  - "**/{migrations,db,database,repositories,models}/**"
---

# SQL & Database Operations Standards (RFC 2119)

1. **100% Parameterization:** All SQL queries MUST use parameterized placeholders (`?`, `$1`, or named params). String concatenation or f-string interpolation in SQL is strictly prohibited.
2. **Atomic Transactions:** Wrap multi-step mutations in explicit database transactions (`BEGIN` ... `COMMIT` / `ROLLBACK`).
3. **Schema Integrity:** Explicit foreign keys, non-null constraints, and proper indexes on query lookup columns.
