# PWasm Persistence Notes

Private research notes and diagrams for Persistent Wasm persistence primitives,
transaction-region backends, and WAL-oriented durability semantics.

## Main questions

- What should the persistence backend interface expose?
- Which durability operations belong in the region abstraction?
- How should WAL ordering be represented in the API?
- Where does the current class hierarchy force downcasting or backend-specific leakage?
- What crash/recovery states must the abstraction make explicit?

## Diagram index

- `diagrams/current-backend-hierarchy.puml`
- `diagrams/wal-write-path.puml`
- `diagrams/recovery-states.puml`
- `diagrams/backend-capabilities.puml`

Rendered SVGs go in `rendered/`.
