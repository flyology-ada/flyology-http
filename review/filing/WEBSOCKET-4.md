Title: Accept_WebSocket refuses an upgrade whose Sec-WebSocket-Protocol list has a leading or interior empty element
Labels: bug
Refs: none

## Summary

`Accept_WebSocket` probes every upgrade that carries `Sec-WebSocket-Protocol` with `Header_Has_Exact_Token`, and that helper validates each comma-separated element as a token, which raises on the empty string. An offer such as `chat, , superchat`, `, chat` or `chat,,superchat` therefore makes the upgrade fail with `Protocol_Error` and no response at all, although RFC 9110's list rule requires a recipient to ignore empty elements and RFC 6455 defines the field with that rule. The two other list parsers in the same file already skip empty elements, so this is an inconsistency inside one file rather than a deliberate policy.

## Problem

Commit `f078732`.

The probe runs on every upgrade that carries the field, even when the application selects no subprotocol (`src/flyology-http-server.adb:3961-3973`):

```ada
      if Header_Field_Count (Value, "Sec-WebSocket-Protocol") > 0 then
         if Trim (Header (Value, "Sec-WebSocket-Protocol")) = "" then
            raise Protocol_Error with
              "empty WebSocket subprotocol offer";
         end if;
         declare
            Validated : constant Boolean := Header_Has_Exact_Token
              (Value, "Sec-WebSocket-Protocol", "flyology-no-match");
            pragma Unreferenced (Validated);
         begin
            null;
         end;
      end if;
```

`Header_Has_Exact_Token` validates each element (`src/flyology-http-server.adb:3625-3638`):

```ada
      while First <= List'Length loop
         declare
            Comma : constant Natural :=
              Ada.Strings.Fixed.Index (List (First .. List'Last), ",");
            Last : constant Natural :=
              (if Comma = 0 then List'Last else Comma - 1);
            Candidate : constant String := Trim (List (First .. Last));
         begin
            Validate_Token (Candidate, "header token");
            if Candidate = Value then
               Found := True;
            end if;
            exit when Comma = 0;
            First := Comma + 1;
         end;
      end loop;
```

and `Validate_Token` raises on the empty string (`src/flyology-http-server.adb:319-320`):

```ada
      if Value'Length = 0 then
         raise Protocol_Error with Description & " is empty";
      end if;
```

A trailing comma is not affected, because the loop bound at `:3625` is `First <= List'Length` and `First` is advanced to `Comma + 1` at `:3638`. For `"chat,"` the comma is the last character, so `First` becomes 6 while `List'Length` is 5 and the loop ends without ever forming the empty final element. A leading or interior empty element, by contrast, produces an empty `Candidate` and reaches `Validate_Token`.

The two other list parsers in the same file skip empty elements. `Header_Has_Token`, used for `Connection` and `Upgrade`, compares without validating each element (`src/flyology-http-server.adb:527-550`), and `Negotiate_WebSocket_Deflate` skips one explicitly (`src/flyology-http-server.adb:3798-3799`):

```ada
            elsif Offer'Length = 0 then
               null;
```

RFC 9110 section 5.6.1.2 states the list rule:

> "Empty elements do not contribute to the count of elements present. A recipient MUST parse and ignore a reasonable number of empty list elements."

and the same section gives `"foo , ,bar,charlie"` among its valid examples of a `1#element` list. RFC 6455 section 11.3.4 defines `Sec-WebSocket-Protocol` with that list rule.

There is no existing coverage. `tests/websocket_server_audit.adb:229-236` builds fixed, well-formed upgrade requests. The Autobahn baselines do not reach the code at all: the fuzzing client never sends the field, so `Header_Field_Count (Value, "Sec-WebSocket-Protocol")` is zero on every Autobahn upgrade and the probe never runs. `tests/autobahn/fuzzingclient-native.json` configures only a URL, an agent name and the case selection, with no subprotocol, and the limits and compression configurations are the same in this respect.

## What happens now

Spike: an in-memory transport driving `Read_Request` and then `Accept_WebSocket (Client, Request, Protocol => "chat")`, once per offer, as `tests/websocket_server_audit.adb` does. Five offers are sent: a well-formed control, an interior empty element, a leading empty element, adjacent commas, and a trailing comma. Each case asserts a 101 response selecting `chat`.

```ada
   Run_Case ("control", "chat, superchat");
   Run_Case ("interior empty element", "chat, , superchat");
   Run_Case ("leading empty element", ", chat");
   Run_Case ("adjacent commas", "chat,,superchat");
   Run_Case ("trailing comma", "chat,");
```

```
  ok   control: the upgrade offering "chat, superchat" is accepted
  ok   control: the response is 101 Switching Protocols
  ok   control: the response selects chat
  note interior empty element: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL interior empty element: the upgrade offering "chat, , superchat" is accepted
  FAIL interior empty element: the response is 101 Switching Protocols
  FAIL interior empty element: the response selects chat
  note leading empty element: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL leading empty element: the upgrade offering ", chat" is accepted
  FAIL leading empty element: the response is 101 Switching Protocols
  FAIL leading empty element: the response selects chat
  note adjacent commas: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL adjacent commas: the upgrade offering "chat,,superchat" is accepted
  FAIL adjacent commas: the response is 101 Switching Protocols
  FAIL adjacent commas: the response selects chat
  ok   trailing comma: the upgrade offering "chat," is accepted
  ok   trailing comma: the response is 101 Switching Protocols
  ok   trailing comma: the response selects chat
checks: 15  failures: 9
BUG REPRODUCED
```

The control shows the fixture is sound. The three offers with a leading or interior empty element each raise `Protocol_Error "header token is empty"` and no response is written at all. The trailing comma is accepted and selects `chat`, for the reason given above.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An empty element anywhere in a `Sec-WebSocket-Protocol` list should be ignored and the remaining tokens matched normally, so `chat, , superchat` selects `chat` exactly as `chat, superchat` does. RFC 9110 section 5.6.1.2 requires a recipient to parse and ignore empty list elements, and RFC 6455 section 11.3.4 defines the field with that rule.

## Suggested treatment

Skip an empty `Candidate` in `Header_Has_Exact_Token` at `src/flyology-http-server.adb:3631-3633` instead of passing it to `Validate_Token`, matching what `Negotiate_WebSocket_Deflate` already does at `:3798-3799` and what `Header_Has_Token` does implicitly at `:527-550`. A list that is empty or whitespace only is still rejected, by the `Trim` check at `:3962-3965`, so a genuinely empty offer keeps its current treatment. The non-empty elements keep going through `Validate_Token`, so a malformed token is still refused. No new value and no configuration is involved.

The regression test belongs in `tests/websocket_server_audit.adb`, whose raw upgrade requests are built at `:229-236`: add offers with an interior empty element, a leading empty element and adjacent commas against a handler configured with `Protocol => "chat"`, asserting 101 and `Sec-WebSocket-Protocol: chat`, and keep the trailing-comma case as the control that already passes. The spike is the test.

## Severity

An upgrade that RFC 9110's list rule makes acceptable is refused with `Protocol_Error` and no response, so the client sees the connection fail rather than a status it can act on. Whether any stock client emits an empty list element is not verified against a peer here; browsers and the common libraries do not, and the offers that reach this are the ones produced by two lists merged with a stray separator or by a generator that emits a leading comma, which is why this is an interoperability gap rather than a break in ordinary use. The refusal happens before any response is written, and no request is mishandled or misrouted. Deterministic.
