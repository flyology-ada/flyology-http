# Flyology IRI

`flyology_iri` is an experimental, allocation-conscious parser for URI
references, IRI references, and WHATWG URLs. It is a separate Alire crate
inside the Flyology HTTP repository and does not depend on the Flyology
runtime.

The public API has three explicit policies:

- `URI_Syntax` validates RFC 3986 ASCII URI references.
- `IRI_Syntax` accepts well-formed UTF-8 in RFC 3987 component positions.
- `Web_URL_Syntax` implements special and non-special URL parsing, IDNA host
  conversion, IPv4 and IPv6 normalization, `file:` URLs, and resolution against
  a parsed WHATWG base URL.

The parser matches all 919 parsing cases in Ada URL 4.0.0's pinned
`urltestdata.json` and `ada_extra_urltestdata.json`, including each expected
serialized URL and exposed structural component. This is parser conformance,
not a claim that the crate implements unrelated WHATWG URL APIs such as mutable
setters or `URLSearchParams`.

The standalone IDNA host conversion carries a subset of UTS #46, not the whole
specification. It applies the ignorable and fullwidth mappings, case folding,
RFC 3492 Punycode encoding, rejection of the domain code points that carry no
glyph — controls, private-use, separators, format characters including the
joiners and the bidi marks — and the clause of RFC 5893's bidi rule that
forbids one label from mixing strong letters of both directions. It does not
carry the full UTS #46 mapping table, the unassigned or mapped-symbol parts of
the disallowed set, the ContextJ joiner rules, the remaining clauses of the
bidi rule, or a Punycode decoder, so an already-encoded `xn--` label is copied
through rather than decoded and revalidated. Hosts outside that subset can
still differ from a full UTS #46 implementation.

## Use

```ada
with Flyology_IRI;

declare
   URL : constant Flyology_IRI.Reference := Flyology_IRI.Parse
     ("HTTPS://Example.COM/docs?q=iri", Flyology_IRI.Web_URL_Syntax);
begin
   pragma Assert (Flyology_IRI.Image (URL) =
     "https://example.com/docs?q=iri");
   pragma Assert (Flyology_IRI.Host (URL) = "example.com");
end;
```

For HTTP and WebSocket clients, parse a complete endpoint in web mode and
derive the two values required by the protocol API from the same reference:

```ada
Flyology.HTTP.Parse_Origin (Flyology_IRI.Origin (URL));
Flyology.HTTP.Client.Set_Target (Request, Flyology_IRI.Target (URL));
```

`Origin` returns a normalized HTTP(S) or WS(S) origin without credentials.
`Target` returns its path and optional query without the fragment. The
[website guide](https://http.flyology.org/guide/iri/) also covers the distinct
browser-origin field in a WebSocket handshake.

`Can_Parse` uses an allocation-free fast path for common absolute HTTP(S) URLs
and for URI/IRI validation; less common web forms may allocate while applying
normalization and IDNA. `Try_Parse` is the non-raising construction API and can
reuse the destination's owned string capacity. `Reference` owns one serialized
string and stores component offsets rather than separate component strings.
`Resolve` implements RFC 3986 section 5.2 reference resolution for URI and IRI
modes.

## Verify

```sh
cd flyology_iri
./scripts/test.sh
ADA_URL_ROOT=/tmp/ada-url ./scripts/test.sh
./scripts/docs.sh
```

## Benchmark

The comparison consumes the same `ada-url/url-dataset/out.txt` corpus as Ada
v4's `benchdata` target and runs the corresponding `can_parse` and compact
parse-plus-href-length operations:

```sh
./scripts/prepare-benchmark.sh
./scripts/benchmark.sh
```

The preparation script checks out both pinned inputs under the repository's
ignored `build/flyology-iri-benchmark/` directory. The benchmark refuses
unpinned revisions and prints both revisions, the number accepted by each
implementation, and nanoseconds per URL. See
[BENCHMARKS.md](BENCHMARKS.md) for pinned results and interpretation.
