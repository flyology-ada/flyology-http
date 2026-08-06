# Flyology HTTP agent guide

- Preserve ordinary synchronous Ada call semantics in native and lightweight
  task lanes.
- Keep HTTP protocol, routing, middleware, client-pool, streaming, SSE, and
  WebSocket policy in this crate. Keep task-aware sockets, files, TLS,
  connections, structured servers, buffers, and runtime integration in
  Flyology.
- Run `./scripts/test.sh` after client, server, test, or project-boundary
  changes. Run `./scripts/prove.sh` after changing the proved policy units.
- Keep tests under `tests/` and maintained examples and benchmarks under
  `showcases/`.
- Use GNATdoc leading comments for public package declarations. Run
  `./scripts/docs.sh` after public specification or API-documentation changes;
  it must generate `docs/api/index.html` without errors.
- Write modest, factual prose. Flyology HTTP is experimental; do not imply
  production qualification, HTTP/2 support, or portable benchmark results.
- Use focused Problem/Solution commit messages consistent with the parent
  Flyology repository.
