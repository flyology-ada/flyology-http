# Byte-exact HTTP client fixtures

The `.bin` files are the canonical wire payloads referenced by
`../http-client-scenarios.json`. The adjacent `.hex` files are review mirrors;
`../../http_client_corpus.py` checks that each mirror decodes to the canonical
bytes and that the JSON SHA-256 digest matches.

Files contain only the response fragment named by the vector. Protocol peers
remain responsible for connection setup and for inserting a fragment at the
scenario's declared point.

Static HTTP/1 response messages are also stored here instead of being hidden
as Ada or Python string literals. Stateful cases remain in the protocol peers:
connection loss, delayed readiness, cancellation, multiplex ordering, and
pool pressure cannot be represented by one byte string. The validator rejects
an unreferenced `.bin` file, a missing mirror, or a reduction below the
maintained byte-fixture floor.
