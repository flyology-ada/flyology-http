Title: Resolve turns a path beginning with two slashes into an authority, so a relative reference can set the host
Labels: bug
Refs: none

## Summary

`Resolve` recomposes the target as a string and reparses it, and the recomposition has no guard against a path that begins with `//` when there is no authority. When the base carries a scheme but no authority, resolving a reference that reduces to such a path makes the reparse read the two slashes as an authority. `Resolve (Parse ("file:/var/www/index.html"), "/.//evil.com")` returns a reference whose host is `evil.com`, and `Resolve (Parse ("sc:/a/b"), "..//p")` returns host `p`. A reference that carries no scheme and does not begin with `//`, and therefore looks like a path, changes the host of the result.

## Problem

Commit `f078732`.

`Resolve` is a serialize-and-reparse (`flyology_iri/src/flyology_iri.adb:1666-1673`):

```ada
   function Resolve
     (Base       : Reference;
      Relative   : String;
      Max_Length : Positive := Default_Max_Length) return Reference
   is
     (Parse (Assemble (Base, Relative, Max_Length),
             Base.Syntax_Value,
             Max_Length));
```

`Assemble_Into` emits `//` only when an authority exists, and otherwise writes the dot-reduced path straight after the colon. When the relative reference has a scheme (`flyology_iri/src/flyology_iri.adb:1462-1469`):

```ada
      if Has_Scheme (Rel) then
         Put (Scheme (Rel));
         Put (":");
         if Has_Authority (Rel) then
            Put ("//");
            Put (Authority (Rel));
         end if;
         Append_Dot_Segments (Rel_Path, Output, Last, Overflow);
```

and when it does not, with a base that has no authority either (`flyology_iri/src/flyology_iri.adb:1489-1504`):

```ada
               if Has_Authority (Base) then
                  Put ("//");
                  Put (Authority (Base));
               end if;
...
                  if Rel_Path (Rel_Path'First) = '/' then
                     Append_Dot_Segments (Rel_Path, Output, Last, Overflow);
```

Nothing tests whether the path that `Append_Dot_Segments` produces begins with `//`. The reparse then reads those two slashes as the start of an authority, so an authority that RFC 3986 leaves undefined becomes a defined one.

RFC 3986 section 5.2.2 computes components rather than a string: with a scheme in the reference it sets `T.authority = R.authority`, and with neither a scheme nor an authority in the reference it sets `T.authority = Base.authority`. In both shapes above that value is undefined. Section 3.3 states the constraint the recomposition violates: "If a URI does not contain an authority component, then the path cannot begin with two slash characters (\"//\")". Section 5.3 recomposition appends `//` only "if defined(authority)".

There is a second route into the same fault under a web base. `Path` strips the WHATWG serialization guard (`flyology_iri/src/flyology_iri.adb:1270-1284`):

```ada
      if Value.Syntax_Value = Web_URL_Syntax
        and then not Value.Authority_Present
        and then Text'Length >= 4
        and then Text (Text'First .. Text'First + 3) = "/.//"
      then
         return Text (Text'First + 2 .. Text'Last);
      end if;
```

so `Parse ("sc:/.//p", Web_URL_Syntax)` keeps `Image = sc:/.//p` but reports `Path = //p`, and `Assemble_Into` consumes `Path`. The WHATWG URL serializer emits that `/.` prefix precisely to keep a null-host URL with an empty first path segment unambiguous, and the crate emits it from `Image` but drops it on the way into the recomposition.

A third defect sits in the same routine: a WHATWG opaque path is run through `Append_Dot_Segments`, although the WHATWG URL Standard never applies dot-segment removal to an opaque path, so `mailto:a/../b` resolves to `mailto:/b`.

The published contract says a resolved reference is what RFC 3986 section 5.2 gives (`flyology_iri/src/flyology_iri.ads:158-159`), and that the serialization overload "equals Image of the Reference this returns for the same arguments" (`flyology_iri/src/flyology_iri.ads:175-176`). Both overloads return the wrong host here, so they agree with each other on the wrong answer.

The existing resolution suite cannot see this because every base it uses carries an authority. `flyology_iri/tests/src/flyology_iri_tests.adb:577-598` runs eight `Check_Resolution_Base` cases, and each asserts the resolved host as well as the image, but seven of the eight bases are `http://good.com...` or `https://例え.テスト/x` and the eighth is `mailto:fred@example.com`, whose relative reference is a plain segment. When the base has an authority, the emitted `//authority` makes the recomposition unambiguous and the defect does not fire.

## What happens now

Spike: for each case it parses the base, calls `Resolve`, and prints the resulting image, `Has_Authority`, `Host` and `Path`. It asserts that the resolved reference has no authority and an empty host wherever RFC 3986 section 5.2.2 leaves the authority undefined, and that resolving an absolute reference against a base equals parsing that reference alone. Four control checks assert the shapes that must keep working.

```ada
      File_Base : constant Reference :=
        Parse ("file:/var/www/index.html", URI_Syntax);
      Resolved  : constant Reference := Resolve (File_Base, "/.//evil.com");
```

```ada
      Web  : constant Reference := Parse ("http://good.com/a/b", URI_Syntax);
      R1   : constant Reference := Resolve (Web, "/.//evil.com");
      R2   : constant Reference := Resolve (Web, "..//evil.com");
```

```
  note Parse  (sc:/.//p): image=[sc:/.//p] has_authority=FALSE host=[] path=[//p]
  note Resolve(sc:/.//p): image=[sc://p] has_authority=TRUE host=[p] path=[]
  FAIL Resolve (http://base/, "sc:/.//p") must have no authority
  FAIL resolved host for sc:/.//p
         expected: []
         actual:   [p]
  FAIL Resolve of an absolute reference must equal Parse of it
         expected: [sc:/.//p]
         actual:   [sc://p]
  note Parse  (mailto:a/../b): image=[mailto:a/../b] has_authority=FALSE host=[] path=[a/../b]
  note Resolve(mailto:a/../b): image=[mailto:/b] has_authority=FALSE host=[] path=[/b]
  FAIL an opaque path must not be dot-reduced by Resolve
         expected: [mailto:a/../b]
         actual:   [mailto:/b]
  note Resolve(sc:/a/b, ..//p): image=[sc://p] has_authority=TRUE host=[p] path=[]
  FAIL Resolve (sc:/a/b, "..//p") must have no authority
  FAIL resolved host for ..//p
         expected: []
         actual:   [p]
  note Resolve(file:/etc/x, ..//evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  FAIL Resolve (file:/etc/x, "..//evil.com") must have no authority
  FAIL resolved host for ..//evil.com
         expected: []
         actual:   [evil.com]
  note Resolve(file:/var/www/index.html, /.//evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  FAIL Resolve (file:/var/www/index.html, "/.//evil.com") must have no authority
  FAIL resolved host for /.//evil.com
         expected: []
         actual:   [evil.com]
  note controls: shapes that must resolve correctly
  note Resolve(http://good.com/a/b, /.//evil.com): image=[http://good.com//evil.com] has_authority=TRUE host=[good.com] path=[//evil.com]
  ok   authority-bearing base keeps its host (/.//)
  ok   authority-bearing base keeps its host (..//)
  note Resolve(file:/a/b, //evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  ok   an explicit network-path reference does supply the host
  note Diagnose ("sc://p", URI_Syntax) = NO_ERROR; Diagnose ("file://evil.com", URI_Syntax) = NO_ERROR
  note the String-returning Resolve gives [file://evil.com]
checks: 13  failures: 10
BUG REPRODUCED
```

The first two note lines show the crate giving two different answers for the same bytes: `Parse` of `sc:/.//p` has no authority, and `Resolve` of the same reference against a web base has host `p`. The `file:` cases are the realistic shape: an ordinary absolute `file:` URI with no authority plus a plain absolute-path reference. With `/.//` the base's path depth does not matter, so nothing about the base has to be unusual beyond its lack of an authority. The three `ok` lines pin what must not regress: an authority-bearing base keeps its own host in both shapes, and an explicit network-path reference still supplies the host, because there RFC 3986 section 5.2.2 really does set `T.authority = R.authority`.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

When the resolved target has no authority, the result must have no authority, whatever its path begins with, as RFC 3986 section 5.2.2 and section 3.3 require. An absolute reference resolved against any base must give the same reference that parsing it alone gives, which is what the specification of the serialization overload already promises. An opaque path must not be dot-reduced.

## Suggested treatment

The defect is structural: `Resolve` computes a string and then reparses it, which loses the distinction between an undefined authority and an empty one. The direct fix is to stop the round trip losing that bit. Either build the resolved `Reference` from components, which is what RFC 3986 section 5.2.2 describes and which removes the reparse entirely, or keep the recomposition and make it unambiguous by emitting the WHATWG `/.` guard whenever the target has no authority and the dot-reduced path begins with `//`, which is the same guard `Path` strips at `flyology_iri/src/flyology_iri.adb:1276-1282`. `Assemble_Into` should also stop calling `Append_Dot_Segments` on an opaque path.

This needs a maintainer decision, because the second option changes what bytes the crate emits for a URI or IRI result: `/.` in a path is legal RFC 3986 syntax but it is a WHATWG serialization device, and emitting it in URI mode is a visible output change for every caller that stores the serialization. The options are a private implementation value, a caller parameter, a generic formal, a discriminant, a value derived from a type or contract by taking the component-building route so that no serialization device is needed, build-time configuration, or a deliberately public documented change to the serialization. Do not settle it here.

Whichever route is taken, both overloads must change together. The serialization-returning `Resolve` validates a URI or IRI result with `Diagnose` on the assembled bytes rather than by building a second reference (`flyology_iri/src/flyology_iri.adb:1675-1700`), and the spike's last two note lines show `Diagnose` reports `NO_ERROR` for both `sc://p` and `file://evil.com`, so that overload returns the same wrong answer by a different route. `Check_Resolution_Base` asserts `Text = Image (Actual)`, so a guard added to only one overload would break that assertion.

The regression test belongs in the existing crate suite at `flyology_iri/tests/src/flyology_iri_tests.adb`, extending the `Check_Resolution_Base` block at :577-598 with authority-less bases rather than replacing what is there, not in a new file. The spike is the test, including its four controls. No existing test asserts the current behaviour, so none has to change. No unit `./scripts/prove.sh` proves is involved.

## Severity

This is a wrong result on valid input through a supported path, with a host-confusion shape: a relative reference that carries no scheme and does not begin with `//` changes the host of the resolved reference. The exposed caller is an application that resolves a reference it did not write against a base it trusts, which is what `Resolve` is for, and which the crate's own comment at `flyology_iri/tests/src/flyology_iri_tests.adb:600-605` treats as a supported shape. The condition is precise and easy to hit by accident: the base has a scheme and no authority, and the reference reduces to a path beginning with `//`. A base that carries an authority is safe in every shape tried. It is not higher than this because it is not a wire-level or memory defect and the consequence needs a consumer, and this repository has none: no source file or project file outside `flyology_iri/` references the crate, which is published for use elsewhere. Deterministic.
