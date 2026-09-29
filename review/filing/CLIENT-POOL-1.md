Title: Same-origin relative redirect whose query contains `://` raises `Redirect_Error`
Labels: bug
Refs: none

## Summary

`Resolve_Redirect` picks its absolute-URI branch by searching the whole `Location` value for `://` instead of testing for a scheme at the start of the reference. For a same-origin relative reference such as `/next?u=https://example.com/home` the text before the first `://` becomes the scheme name `/next?u=https`, which is neither `http` nor `https`, so `Follow_Same_Origin` raises `Redirect_Error` with "unsupported redirect URI scheme". Return-to links and OAuth `redirect_uri` parameters have exactly this shape, so an ordinary same-origin redirect the client promises to follow fails instead. The identical unanchored scan was already fixed on the server side and the fix pattern is one file over.

## Problem

Commit `f078732`.

The absolute-URI branch is selected by an unanchored scan (`src/flyology-http-client.adb:6301-6315`):

```ada
      elsif Ada.Strings.Fixed.Index (Reference, "://") /= 0 then
         declare
            Separator : constant Natural :=
              Ada.Strings.Fixed.Index (Reference, "://");
            Name : constant String :=
              Ada.Characters.Handling.To_Lower
                (Reference (Reference'First .. Separator - 1));
         begin
            if Name /= "http" and then Name /= "https" then
               raise Redirect_Error with "unsupported redirect URI scheme";
            end if;
            Parse_Absolute (Reference, False);
         end;
      elsif Has_URI_Scheme (Reference) then
         raise Redirect_Error with "unsupported redirect URI scheme";
```

An anchored classifier exists in the same subprogram and does require the colon to precede any `/` or `?` (`src/flyology-http-client.adb:6257-6265`):

```ada
      function Has_URI_Scheme (Value : String) return Boolean is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Value, ":");
         Slash : constant Natural := Ada.Strings.Fixed.Index (Value, "/");
         Query : constant Natural := Ada.Strings.Fixed.Index (Value, "?");
      begin
         return Colon /= 0
           and then (Slash = 0 or else Colon < Slash)
           and then (Query = 0 or else Colon < Query);
      end Has_URI_Scheme;
```

It sits in the `elsif` after the unanchored one, so it never sees a reference that contains `://` anywhere.

RFC 9110 section 10.2.2 defines the field this code is classifying: "The field value consists of a single URI-reference. When it has the form of relative-ref ([URI], Section 4.2), the final value is computed by resolving it against the target URI ([URI], Section 5)." RFC 3986 section 3.1 defines what a scheme is: "Scheme names consist of a sequence of characters beginning with a letter and followed by any combination of letters, digits, plus ("+"), period ("."), or hyphen ("-")." A reference beginning with `/` has no scheme component and is a relative reference under RFC 3986 section 4.2, so it must be resolved against the base, not rejected.

The contract the client states for this mode is `src/flyology-http-client.ads:46-47`:

```ada
   --  @enum Follow_Same_Origin Follow eligible redirects within the client
   --     origin
```

`Resolve_Redirect` is reached from `Execute_Redirects` (`src/flyology-http-client.adb:6663`) and from the SSE client's `Resolve_Redirect_Target` (`src/flyology-http-client-sse.adb:761`), so both the synchronous redirect follower and the SSE reconnect path refuse the same references. Under the default `Return_Redirects` mode the response is handed back untouched, so only following is affected.

**This is not an open redirect.** The misclassification was checked for a retargeting direction and there is none. `Name` can equal `http` or `https` only when the reference genuinely begins with that scheme, and `Parse_Absolute` recomputes the authority split from the first `://` (`src/flyology-http-client.adb:6268-6270`), so a hostile `http://good/x?u=https://evil/` still parses `good` as the authority. The failure mode is refusal, not redirection to the wrong origin.

**The same defect was already fixed one file over.** The server's `Raw_Path` had the identical unanchored `://` scan and now uses an anchored test, with the reasoning recorded in place (`src/flyology-http-server-routing.adb:278-286`):

```ada
   --  Absolute form is recognized by an anchored scheme prefix only, matching
   --  how the request-head parser and Requests.Authority classify the target.
   --  Searching the whole target for "://" would treat a query string that
   --  carries a URL as the request-target's own authority and route the path
   --  found inside it.
   function Absolute_Form_Authority (Target : String) return Natural is
     (if Has_Scheme_Prefix (Target, "http://") then Target'First + 7
      elsif Has_Scheme_Prefix (Target, "https://") then Target'First + 8
      else 0);
```

Why the tests do not catch it: the closest case is `Location: ../next?x=1#ignored` (`tests/http_client_redirects.adb:266`), a query with no scheme in it. No `Location` value anywhere under `tests/` contains `://` after the first path character.

## What happens now

Spike: a loopback origin answers `GET /login` with `302 Found` and `Location: /next?u=https://example.com/home`, then waits to serve `200 OK` with body `ok` on the resolved same-origin target. The client runs one `Execute` with `Default_Same_Origin_Redirects`. The program asserts what the contract requires: the second request reaches the peer on the reused transport and `Execute` returns the target's status and body.

```ada
   Location_Value : constant String := "/next?u=https://example.com/home";
...
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: " & Location_Value & CRLF &
               "Content-Length: 0" & CRLF & CRLF);
...
         Client.Set_Target (Request, "/login");
         Client.Set_Redirects (Request, Client.Default_Same_Origin_Redirects);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 5.0);
```

```
  note Location served: /next?u=https://example.com/home
  note peer saw request 1: GET /login HTTP/1.1
  note peer saw request 2: 
  note Execute raised: FLYOLOGY.HTTP.CLIENT.REDIRECT_ERROR: unsupported redirect URI scheme
  FAIL Execute follows a same-origin relative redirect whose query contains "://" instead of raising Redirect_Error
  FAIL the resolved same-origin target is requested on the reused transport
         expected: [GET /next?u=https://example.com/home HTTP/1.1]
         actual:   []
  FAIL Execute returns the status served at the target
         expected: 200   actual:-1
  FAIL Execute returns the target's body
         expected: [ok]
         actual:   []
checks: 4  failures: 4
BUG REPRODUCED
```

The peer never receives a second request. The caller gets an exception where the contract promises the resource.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A `Location` value that does not begin with a scheme is a relative reference and must be resolved against the request target, per RFC 9110 section 10.2.2 and RFC 3986 section 5. `/next?u=https://example.com/home` resolves to the same origin, so `Follow_Same_Origin` must follow it, as `src/flyology-http-client.ads:46-47` says it does.

## Suggested treatment

Select the absolute-URI branch with the anchored test instead of the unanchored scan: make the branch condition `Has_URI_Scheme (Reference)` and decide inside it whether the scheme is `http`, `https`, or unsupported, which collapses the two `elsif` arms at `src/flyology-http-client.adb:6301-6315` into one. `Absolute_Form_Authority` in `src/flyology-http-server-routing.adb:283-286` is the model: an anchored `http://` / `https://` prefix test with the same reasoning already written down beside it. `Parse_Absolute` already recomputes its own split, so it needs no change.

The regression test belongs in the existing redirect suite, `tests/http_client_redirects.adb`, beside the `../next?x=1#ignored` case at `:266`: serve `Location: /next?u=http://127.0.0.1:1/x`, then `200` on `/next?u=http://127.0.0.1:1/x`, and assert the resolved status. The spike above is that test. A second case should cover the SSE reconnect path through `src/flyology-http-client-sse.adb:761`.

No existing test asserts the current behaviour, so nothing has to change to accommodate the fix. The fix is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove, so no proof obligation is affected.

## Severity

A same-origin redirect whose query carries a URL cannot be followed at all: `Execute` raises `Redirect_Error` and the caller never reaches the target. Return-to links and OAuth `redirect_uri` query parameters are the common shape, and the only configuration needed is `Follow_Same_Origin`, which is the documented following mode. It is not a security defect: the reference is refused, never retargeted. Deterministic.
