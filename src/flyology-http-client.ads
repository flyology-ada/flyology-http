with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Buffers;
with Flyology.Cancellation;
with Flyology.HTTP.Headers;
with Flyology.IO;
with Flyology.IO.TLS;
with Flyology.Operations;
private with Ada.Real_Time;

--  Provides origin-bound synchronous and owner-driven composable HTTP
--  exchanges with bounded connection pooling. Synchronous Execute drives the
--  same completion-set operation engine as Scoped exchanges. Lightweight
--  callers suspend on Flyology I/O; native callers block only their pthread.
--  Protocol modes enable HTTP/1.1, HTTP/2, and HTTP/3 without exposing
--  transport or stream ownership through the request/response API.
package Flyology.HTTP.Client is

   --  Maximum request-target bytes retained by a Request. This accommodates
   --  long presigned object URLs while keeping request metadata bounded.
   Max_Request_Target_Bytes : constant Positive := 16 * 1_024;

   --  Raised after client shutdown rejects a request or interrupts pool
   --  admission.
   Client_Closed : exception;
   --  Raised when the origin cannot be resolved or every resolved address
   --  fails before an HTTP exchange starts.
   Connection_Error : exception;
   --  Raised when retained response metadata or a Read_All body exceeds its
   --  bound.
   Response_Too_Large : exception;
   --  Raised when a streaming request body violates the progress contract or
   --  does not finish on exactly its positive declared length.
   Request_Body_Error : exception;
   --  Raised when an enabled redirect cannot be followed safely because its
   --  target is invalid, repeats a prior target, exceeds the configured hop
   --  limit, or requires replaying a one-shot request source.
   Redirect_Error : exception;

   --  Automatic redirect behavior. Returning redirects is the default and
   --  preserves the response exactly as received. Same-origin following never
   --  sends a request to a different scheme, host, or port.
   --  @enum Return_Redirects Return every redirect response to the caller
   --  @enum Follow_Same_Origin Follow eligible redirects within the client
   --     origin
   type Redirect_Mode is (Return_Redirects, Follow_Same_Origin);

   --  Supported bound for automatically followed redirect hops.
   subtype Redirect_Limit is Natural range 0 .. 20;

   --  Per-request redirect policy.
   --  @field Mode Whether redirects are returned or followed within the origin
   --  @field Maximum_Hops Maximum redirects followed before Redirect_Error
   type Redirect_Configuration is record
      Mode          : Redirect_Mode := Return_Redirects;
      Maximum_Hops  : Redirect_Limit := 5;
   end record;

   --  Default policy: return redirect responses without following them.
   No_Redirects : constant Redirect_Configuration := (others => <>);

   --  Opt-in policy that follows at most five same-origin redirects.
   Default_Same_Origin_Redirects : constant Redirect_Configuration :=
     (Mode => Follow_Same_Origin, Maximum_Hops => 5);

   --  Pool reuse and retention policy. Capacity remains the Client
   --  discriminant and bounds open plus connecting slots.
   --  @field Max_Idle Maximum reusable connections retained, capped by client
   --     capacity; zero disables reuse without disabling concurrent requests.
   --     Use at least two to keep both TCP and QUIC warm in Negotiate_HTTP_3
   --  @field Idle_Timeout Seconds an unused connection may remain reusable;
   --     negative disables the age check
   --  @field Max_Connection_Age Total reusable lifetime in seconds; negative
   --     disables the age check
   --  @field Max_Requests_Per_Connection Total requests before rotation; zero
   --     disables request-count rotation
   type Pool_Configuration is record
      Max_Idle                   : Natural := 1;
      Idle_Timeout               : Duration := 30.0;
      Max_Connection_Age         : Duration := 300.0;
      Max_Requests_Per_Connection : Natural := 0;
   end record;

   --  Default conservative pool policy.
   Default_Pool_Configuration : constant Pool_Configuration := (others => <>);

   --  Connection protocol selection. Existing Configure overloads retain
   --  HTTP/1.1-only behavior; callers opt into newer protocols with an
   --  overload that requires this value. HTTP/3 modes require a pinned DER
   --  certificate through an HTTP/3 Configure overload.
   --  @enum HTTP_1_Only Use HTTP/1.1 without offering HTTP/2
   --  @enum Negotiate_HTTP_2 Offer h2 then http/1.1 over TLS
   --  @enum Require_HTTP_2 Require h2 negotiation over TLS
   --  @enum HTTP_2_Prior_Knowledge Start HTTP/2 directly on cleartext HTTP
   --  @enum Negotiate_HTTP_3 Start with TLS HTTP/2 or HTTP/1.1, learn a
   --     same-origin h3 UDP port from Alt-Svc, and prefer HTTP/3 while
   --     retaining TCP for concurrent work and fallback
   --  @enum Require_HTTP_3 Use HTTP/3 directly on the HTTPS origin's UDP port
   type Protocol_Mode is
     (HTTP_1_Only,
      Negotiate_HTTP_2,
      Require_HTTP_2,
      HTTP_2_Prior_Knowledge,
      Negotiate_HTTP_3,
      Require_HTTP_3);

   --  Explicit Unix-domain stream transport configuration for macOS and
   --  Linux. The HTTP origin remains independent and supplies the request
   --  authority; this value selects only the local socket used to carry
   --  exchanges. The client retains an owned copy of the pathname when
   --  configured. It never creates, removes, changes permissions on, or
   --  assumes ownership of the filesystem entry. Filesystem permissions
   --  control connection admission but do not by themselves authenticate the
   --  peer; applications remain responsible for the local security boundary.
   type Unix_Socket_Transport is private;

   --  Construct a pathname Unix-domain stream transport. Path is operating-
   --  system configuration, not an HTTP request target. It must be nonempty,
   --  contain no NUL byte, and fit the host sockaddr_un pathname capacity.
   --  @param Path Filesystem pathname of the Unix-domain socket
   --  @return Validated transport configuration
   --  @exception Constraint_Error Path is empty, contains NUL, or is too long
   function Unix_Socket (Path : String) return Unix_Socket_Transport;

   --  Optional veto over one resolved Internet connect target. Configure
   --  retains it, and the client consults it once for every address the origin
   --  host resolves to before any socket is created for that address. An
   --  application can refuse loopback, link-local, or private destinations
   --  that a name
   --  resolves to. Returning False skips that address and the client tries the
   --  next one; refusing every resolved address raises Connection_Error and
   --  opens no socket. The owner-driven exchange tries permitted IPv4 and
   --  IPv6 addresses serially in resolver order. It advances after an
   --  immediate connection or handshake failure under the same absolute
   --  deadline. The filter runs on the requesting task before each attempt
   --  and must not block. Only the initial connect is
   --  filtered; this client is bound to one origin and never follows a
   --  redirect that leaves it.
   --  @param Host Configured origin host
   --  @param Address Canonical numeric text of one resolved address
   --  @param Port Origin port the client would connect to
   --  @return True to allow a connection attempt to Address
   type Connect_Target_Filter is access function
     (Host    : String;
      Address : String;
      Port    : Port_Number) return Boolean;

   --  Coherent client counters. Exchange and transport counts are separate so
   --  multiplexed protocols can report several exchanges on one transport
   --  without changing this record's meaning.
   --  @field Transport_Capacity Configured transport slot bound
   --  @field Pending_Transports Transports being established
   --  @field Active_Exchanges Requests that own protocol exchanges
   --  @field Reusable_Transports Established transports eligible for reuse
   --  @field Closing_Transports Transports being closed outside the pool lock
   --  @field Admission_Waiters Requests waiting for exchange capacity
   --  @field Transports_Created Successfully established transports
   --  @field Transport_Reuses Exchanges assigned an existing transport
   --  @field Transports_Closed Transports removed from the client
   --  @field Stale_Retries Idempotent exchanges retried once after an existing
   --     transport failed before producing response bytes
   --  @field Admission_Timeouts Pool waits whose request deadline expired
   type Client_Diagnostics is record
      Transport_Capacity : Positive;
      Pending_Transports : Natural;
      Active_Exchanges    : Natural;
      Reusable_Transports : Natural;
      Closing_Transports  : Natural;
      Admission_Waiters   : Natural;
      Transports_Created  : Natural;
      Transport_Reuses    : Natural;
      Transports_Closed   : Natural;
      Stale_Retries       : Natural;
      Admission_Timeouts  : Natural;
   end record;

   --  Mutable request value. Bodies are retained as owned bytes so request
   --  transmission remains valid across task suspension.
   type Request is private;

   --  Replace the request method.
   --  @param Item Request to change
   --  @param Value Validated method
   procedure Set_Method (Item : in out Request; Value : Method);

   --  Replace the origin-form request target. Asterisk-form is retained for
   --  OPTIONS and validated when Execute observes the complete Request.
   --  Absolute-form, authority-form, fragments, non-ASCII bytes, spaces,
   --  control characters, and targets over 16 KiB are rejected.
   --  @param Item Request to change
   --  @param Value Origin-form target
   --  @exception Constraint_Error Value is not a supported request target
   procedure Set_Target (Item : in out Request; Value : String);

   --  Replace the request's automatic redirect policy. One monotonic Execute
   --  deadline covers every hop and every intermediate response-body drain.
   --  Cross-origin redirects are always returned to the caller.
   --  @param Item Request to change
   --  @param Value Redirect mode and hop bound
   procedure Set_Redirects
     (Item : in out Request; Value : Redirect_Configuration);

   --  Append one end-to-end request field. Framing, connection, upgrade, and
   --  Expect fields are client-controlled and rejected here.
   --  @param Item Request to change
   --  @param Name Field name
   --  @param Value Field value
   --  @exception Constraint_Error Name, Value, or a client-controlled field
   --     is invalid
   --  @exception Flyology.HTTP.Headers.Headers_Too_Large Request field storage
   --     is exhausted
   procedure Add_Header
     (Item : in out Request; Name : String; Value : String);

   --  Enable or disable the Expect: 100-continue handshake. When enabled for
   --  a nonempty retained or streaming body, Execute sends the request head
   --  first and waits up to Wait_Timeout for 100 Continue or a final response.
   --  A positive wait expiry with no partial response sends the body; a
   --  negative value waits within the whole exchange deadline and zero sends
   --  immediately after the head. A final response suppresses body reads and
   --  transmission. A 417 final response received before body transmission
   --  is retried once on a fresh transport without the expectation, within
   --  the same deadline and shared automatic-retry budget. The whole exchange
   --  deadline is never extended.
   --  The current HTTP/2 and HTTP/3 engines reject this opt-in handshake; use
   --  it with an HTTP_1_Only client.
   --  @param Item Request to change
   --  @param Enabled Whether to generate Expect: 100-continue
   --  @param Wait_Timeout Maximum continue-specific wait in seconds
   procedure Set_Expect_Continue
     (Item         : in out Request;
      Enabled      : Boolean := True;
      Wait_Timeout : Duration := 1.0);

   --  Append one request trailer field. The client generates the Trailer
   --  declaration where required and sends retained trailer values after an
   --  unknown-length source finishes on HTTP/1.1, HTTP/2, or HTTP/3. Trailers
   --  are rejected for retained or known-length bodies. Known fields
   --  affecting framing, routing,
   --  authentication, request semantics, or payload interpretation are
   --  prohibited, and repeated names are rejected. The caller must know that
   --  the field definition permits use in trailers.
   --  @param Item Request to change
   --  @param Name Trailer field name
   --  @param Value Trailer field value retained by Item
   --  @exception Constraint_Error Name is prohibited or repeated in request
   --     trailers, or Name or Value has invalid HTTP field syntax
   --  @exception Flyology.HTTP.Headers.Headers_Too_Large Trailer storage is
   --     exhausted
   procedure Add_Trailer
     (Item : in out Request; Name : String; Value : String);

   --  Replace the request body using a one-to-one byte mapping.
   --  @param Item Request to change
   --  @param Value Request representation bytes
   procedure Set_Body (Item : in out Request; Value : String);

   --  Replace the request body from contiguous bytes.
   --  @param Item Request to change
   --  @param Value Request representation bytes
   procedure Set_Body
     (Item : in out Request; Value : Ada.Streams.Stream_Element_Array);

   --  Maximum representable request body byte count.
   subtype Body_Size is Flyology.HTTP.Body_Size;

   --  Known or unknown streaming request body length. Unknown bodies use the
   --  active protocol's streaming framing; HTTP/1.1 uses chunked coding.
   type Body_Length is private;

   --  Unknown streaming request body length.
   Unknown_Length : constant Body_Length;

   --  Construct a known streaming request body length.
   --  @param Bytes Exact number of source bytes to transmit
   --  @return Known body length
   function Known_Length (Bytes : Body_Size) return Body_Length;

   --  Pull source for a streaming request body. Execute queries
   --  Declared_Length once, calls Read serially, and never retains the source
   --  after returning. The declared length must remain stable during Execute.
   --  Implementations must honor the remaining whole-exchange timeout and
   --  cancellation token when they perform blocking work. A call must either
   --  produce at least one byte or set Finished. Last is Data'First - 1 when
   --  no bytes are produced.
   type Request_Body_Source is limited interface;

   --  Return the source's stable framing length. Known lengths generate
   --  Content-Length; Unknown_Length selects the protocol's streaming
   --  framing.
   --  @param Item Source to inspect before its first read
   --  @return Known byte count or Unknown_Length
   function Declared_Length
     (Item : Request_Body_Source) return Body_Length is abstract;

   --  Produce the next request body bytes.
   --  @param Item Source state to advance
   --  @param Data Client-owned destination buffer
   --  @param Last Last produced byte, or Data'First - 1
   --  @param Finished Whether the source has no bytes after this call
   --  @param Timeout Remaining whole-exchange deadline interval
   --  @param Token Optional cancellation source from Execute
   procedure Read
     (Item     : in out Request_Body_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is abstract;

   --  Request source that can reproduce exactly the same byte sequence after
   --  a failed transport attempt. Rewind must be nonblocking and restore the
   --  initial cursor without changing Declared_Length. Execute calls it only
   --  after discarding a failed reused transport and only when the method is
   --  idempotent and no response byte was received.
   type Rewindable_Request_Body_Source is
     limited interface and Request_Body_Source;

   --  Restore a rewindable source to its initial byte before one safe retry.
   --  @param Item Source whose exact initial sequence is restored
   procedure Rewind
     (Item : in out Rewindable_Request_Body_Source) is abstract;

   --  Origin-bound client. Capacity is the maximum number of open plus
   --  connecting transports. Configure must complete before concurrent use.
   --  Finalize requests shutdown and closes transports. Execute's aliased
   --  controlling parameter lets Ada accessibility reject a response that
   --  would escape Item's lifetime. Internal retention also protects cleanup
   --  during abort and finalization races.
   --  @field Capacity Maximum open plus connecting transport count
   type Client (Capacity : Positive := 4) is limited private;

   --  Bind a new client to one origin and immutable pool policy. The call does
   --  no DNS, socket, TLS, task, or event-loop work. Reconfiguration and an
   --  HTTPS origin without a retained TLS backend is rejected.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized origin
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured or arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null);

   --  Bind a client with an explicit cleartext protocol mode. Negotiated modes
   --  require TLS and are rejected here; HTTP_2_Prior_Knowledge is cleartext
   --  HTTP/2 without the deprecated Upgrade handshake.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized cleartext origin
   --  @param Mode HTTP/1.1 or HTTP/2 prior-knowledge behavior
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured or arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null);

   --  Bind a client to one cleartext HTTP origin carried over a pathname
   --  Unix-domain stream socket. Origin_Value supplies Host and HTTP/2
   --  :authority; Transport supplies only the connect pathname. Configure
   --  does not open the socket. Connect_Policy is intentionally absent
   --  because no DNS address or Internet endpoint is used.
   --  @param Item Unconfigured client
   --  @param Origin_Value Cleartext origin and request authority
   --  @param Transport Explicit pathname Unix-domain socket transport
   --  @param Pool Pool retention policy
   --  @exception Program_Error Item is configured, Origin_Value is HTTPS, or
   --     configuration arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Transport    : Unix_Socket_Transport;
      Pool         : Pool_Configuration := Default_Pool_Configuration);

   --  Bind a client to a cleartext Unix-domain stream transport with an
   --  explicit protocol. Mode must be HTTP_1_Only or
   --  HTTP_2_Prior_Knowledge. TLS negotiation and HTTP/3 are not Unix socket
   --  transport modes.
   --  @param Item Unconfigured client
   --  @param Origin_Value Cleartext origin and request authority
   --  @param Transport Explicit pathname Unix-domain socket transport
   --  @param Mode HTTP/1.1 or HTTP/2 prior-knowledge behavior
   --  @param Pool Pool retention policy
   --  @exception Program_Error Item is configured, Origin_Value is HTTPS,
   --     Mode is unsupported, or configuration arguments are invalid
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Transport    : Unix_Socket_Transport;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration);

   --  Bind a new client to one origin using an explicit TLS provider. The
   --  client retains independently owned provider state, so Backend may be
   --  finalized after Configure returns. This overload is required for HTTPS
   --  and accepted for HTTP so callers may share configuration code.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized origin
   --  @param Backend Initialized TLS provider retained by Item
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured or arguments are invalid
   --  @exception Flyology.IO.TLS.TLS_Error Backend cannot be retained
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null);

   --  Bind a client with a retained TLS provider and explicit protocol mode.
   --  Negotiate_HTTP_2 permits HTTP/1.1 fallback; Require_HTTP_2 rejects any
   --  other ALPN result. As with the existing provider overload, a cleartext
   --  origin is accepted for shared configuration code and does not use TLS.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized origin
   --  @param Backend Initialized TLS provider retained by Item
   --  @param Mode TLS protocol selection behavior
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured, arguments are invalid, or
   --     an HTTP/2 negotiation mode receives a backend without ALPN support
   --  @exception Flyology.IO.TLS.TLS_Error Backend cannot be retained
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null);

   --  Bind a direct HTTP/3 client. Require_HTTP_3 sends QUIC to the HTTPS
   --  origin's UDP port and authenticates the server with the pinned DER
   --  certificate. No TCP TLS provider is needed because fallback is disabled.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized HTTPS origin
   --  @param Mode Must be Require_HTTP_3
   --  @param HTTP_3_Certificate_DER Expected QUIC peer certificate
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured or arguments are invalid
   procedure Configure
     (Item                   : in out Client;
      Origin_Value           : Origin;
      Mode                   : Protocol_Mode;
      HTTP_3_Certificate_DER : Ada.Streams.Stream_Element_Array;
      Pool                   : Pool_Configuration :=
        Default_Pool_Configuration;
      Connect_Policy         : Connect_Target_Filter := null);

   --  Bind an HTTPS client with HTTP/3 authentication and TCP fallback.
   --  Negotiate_HTTP_3 begins with ALPN h2/http/1.1 and accepts only a
   --  same-origin Alt-Svc h3=":port" alternative. The pool retains healthy
   --  TCP and QUIC transports together: H3 is preferred when available, while
   --  a concurrent exchange can use TCP when the H3 lane is busy or still
   --  connecting. A failed H3 establishment is forgotten and retried once
   --  through TCP inside the original exchange deadline. Require_HTTP_3 is
   --  also accepted and does not use the retained TCP provider.
   --  @param Item Unconfigured client
   --  @param Origin_Value Normalized HTTPS origin
   --  @param Backend Initialized ALPN-capable TLS provider retained by Item
   --  @param Mode Negotiate_HTTP_3 or Require_HTTP_3
   --  @param HTTP_3_Certificate_DER Expected QUIC peer certificate
   --  @param Pool Pool retention policy
   --  @param Connect_Policy Optional veto over each resolved connect target
   --  @exception Program_Error Item is configured or arguments are invalid
   --  @exception Flyology.IO.TLS.TLS_Error Backend cannot be retained
   procedure Configure
     (Item                   : in out Client;
      Origin_Value           : Origin;
      Backend                : not null access Flyology.IO.TLS.Provider'Class;
      Mode                   : Protocol_Mode;
      HTTP_3_Certificate_DER : Ada.Streams.Stream_Element_Array;
      Pool                   : Pool_Configuration :=
        Default_Pool_Configuration;
      Connect_Policy         : Connect_Target_Filter := null);

   --  Limited response owning one exchange lease until its body is consumed.
   --  Reading the complete body returns an HTTP/1.1 or HTTP/3 transport lease
   --  or an HTTP/2 stream lease to the pool. Finalizing an incomplete HTTP/1.1
   --  or HTTP/3 response closes its transport; finalizing an incomplete
   --  HTTP/2 response resets only its stream when the multiplexed transport
   --  remains usable.
   type Response is limited private;

   --  Execute one request. One monotonic Timeout starts before pool admission
   --  and covers admission, DNS, all address attempts, TLS, request send, the
   --  response head, and later body reads. Negative is unlimited and zero is
   --  immediate. Token is borrowed only until the final response head is
   --  returned; body reads receive their own optional cancellation token.
   --  @param Item Shared configured client that outlives the result
   --  @param Value Request to execute
   --  @param Timeout Whole-exchange deadline interval
   --  @param Token Optional cancellation source
   --  An idempotent request assigned a reused transport is retried once when
   --  that transport fails before any response byte is received. Retained
   --  bodies can be replayed directly; streamed bodies are eligible only when
   --  Source implements Rewindable_Request_Body_Source. The retry remains
   --  inside the original deadline. Non-idempotent requests are never retried.
   --  HTTP/2 additionally applies this one-retry budget to streams that the
   --  peer explicitly leaves unprocessed with GOAWAY or REFUSED_STREAM.
   --  @return Response head with a streaming body lease
   --  @exception Client_Closed Client is stopping
   --  @exception Connection_Error Resolution fails, the connect policy
   --     refuses every resolved address, all Internet address attempts fail,
   --     or a configured Unix socket cannot be connected
   --  @exception Constraint_Error Request fields, target, or method-body
   --     combination is unsupported; CONNECT is not implemented
   --  @exception Protocol_Error Response framing is malformed or unsupported
   --  @exception Response_Too_Large Response head exceeds its bound
   --  @exception Redirect_Error An enabled redirect cannot be followed safely
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket transmission fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS setup or transmission fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response;

   --  Execute one request into a reusable response object. Any previous
   --  response in Result is finalized before the new exchange starts. This
   --  form avoids successive limited-function return slots in a long-running
   --  caller scope. Result is uninitialized and reusable if the new exchange
   --  raises. The exceptions are the same as the function overload above.
   --  @param Item Shared configured client that outlives the result
   --  @param Value Request to execute
   --  @param Result Reusable response destination
   --  @param Timeout Whole-exchange deadline interval
   --  @param Token Optional cancellation source
   --  @exception Client_Closed Client is stopping
   --  @exception Connection_Error Resolution or connection setup fails
   --  @exception Constraint_Error Request metadata is unsupported
   --  @exception Protocol_Error Response framing is malformed or unsupported
   --  @exception Response_Too_Large Response head exceeds its bound
   --  @exception Redirect_Error An enabled redirect cannot be followed safely
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket transmission fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS setup or transmission fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Result  : in out Response;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Execute one request while pulling its body from Source. The source's
   --  Declared_Length controls protocol framing. Source is not retained and
   --  is replayed only when it implements Rewindable_Request_Body_Source and
   --  the ordinary idempotent stale-transport retry conditions hold. Its
   --  exceptions propagate after the leased transport is discarded.
   --  HTTP/1.1, HTTP/2, and HTTP/3 all pull Source synchronously with bounded
   --  protocol flow-control storage. Request trailers terminate an
   --  unknown-length source on every supported protocol. Expect: 100-continue
   --  remains HTTP/1.1-only.
   --  @param Item Shared configured client that outlives the result
   --  @param Value Request metadata; a retained body is rejected
   --  @param Source Request body producer used only during this call
   --  @param Timeout Whole-exchange deadline interval
   --  @param Token Optional cancellation source
   --  @return Response head with a streaming response body lease
   --  @exception Client_Closed Client is stopping
   --  @exception Connection_Error Resolution fails, the connect policy
   --     refuses every resolved address, all Internet address attempts fail,
   --     or a configured Unix socket cannot be connected
   --  @exception Constraint_Error Request metadata is unsupported or already
   --     contains a retained body
   --  @exception Request_Body_Error Source violates its progress contract or
   --     ends before a known length is complete
   --  @exception Protocol_Error Response framing is malformed or unsupported
   --  @exception Response_Too_Large Response head exceeds its bound
   --  @exception Redirect_Error An enabled redirect cannot be followed safely
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket transmission fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS setup or transmission fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response;

   --  Execute a streamed request into a reusable response object. Result is
   --  uninitialized and reusable if the new exchange raises. The exceptions
   --  are the same as the streamed function overload above.
   --  @param Item Shared configured client that outlives the result
   --  @param Value Request metadata; a retained body is rejected
   --  @param Source Request body producer used only during this call
   --  @param Result Reusable response destination
   --  @param Timeout Whole-exchange deadline interval
   --  @param Token Optional cancellation source
   --  @exception Client_Closed Client is stopping
   --  @exception Connection_Error Resolution or connection setup fails
   --  @exception Constraint_Error Request metadata is unsupported or already
   --     contains a retained body
   --  @exception Request_Body_Error Source violates its progress contract
   --  @exception Protocol_Error Response framing is malformed or unsupported
   --  @exception Response_Too_Large Response head exceeds its bound
   --  @exception Redirect_Error An enabled redirect cannot be followed safely
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket transmission fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS setup or transmission fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Result  : in out Response;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Absolute monotonic budget shared by a parent operation and one HTTP
   --  exchange. Construct it before signing or other parent preparation so
   --  those steps and the later HTTP admission, transport, head, body, and
   --  drain consume one budget.
   type Monotonic_Deadline is private;

   --  Deadline without a time limit.
   No_Deadline : constant Monotonic_Deadline;

   --  Construct an absolute deadline from the current monotonic clock.
   --  Negative Timeout returns No_Deadline; zero is already due.
   --  @param Timeout Remaining relative budget in seconds
   --  @return Absolute monotonic deadline
   function Deadline_After (Timeout : Duration) return Monotonic_Deadline;

   --  Report whether a finite deadline is due.
   --  @param Value Deadline to inspect
   --  @return True when the monotonic clock reached Value
   function Expired (Value : Monotonic_Deadline) return Boolean;

   --  Monotonic knowledge about possible server admission. This state never
   --  moves backward. Response_Observed is diagnostic and does not by itself
   --  make a conditional mutation conclusive.
   --  @enum Not_Admitted No request head byte, frame, or datagram was handed
   --     to the kernel or a protocol queue
   --  @enum Possibly_Admitted At least one request handoff occurred, so the
   --     server may have accepted the request
   --  @enum Response_Observed At least one peer response byte or protocol
   --     response event was observed; only Response_Complete is conclusive
   type Admission_Certainty is
     (Not_Admitted, Possibly_Admitted, Response_Observed);

   --  Raw exchange stage retained for diagnostics and deterministic tests.
   --  Certainty must be consulted separately.
   --  @enum Not_Started No exchange was started
   --  @enum Admission_Wait Waiting for a pool lease or creation slot
   --  @enum Resolving Resolving the configured origin
   --  @enum Connecting Connecting one resolved address
   --  @enum Securing Establishing the TLS or QUIC security context
   --  @enum Sending_Request_Head Encoding or transmitting request metadata
   --  @enum Sending_Request_Body Pulling or transmitting request body bytes
   --  @enum Waiting_Response_Head Waiting for a complete final response head
   --  @enum Receiving_Response_Body Delivering decoded response body bytes
   --  @enum Draining Cancelling or draining retained protocol work
   type Exchange_Phase is
     (Not_Started,
      Admission_Wait,
      Resolving,
      Connecting,
      Securing,
      Sending_Request_Head,
      Sending_Request_Body,
      Waiting_Response_Head,
      Receiving_Response_Body,
      Draining);

   --  Typed terminal HTTP exchange result. Expected environmental outcomes do
   --  not raise from scoped Finish; exceptions are reserved for programming
   --  errors and violated provider invariants.
   --  @enum Response_Complete Complete valid response head and body
   --  @enum Pre_Admission_Rejected Unsupported request configuration rejected
   --     before any request handoff
   --  @enum Cancelled Caller cancellation completed its protocol drain
   --  @enum Timed_Out Absolute exchange deadline expired
   --  @enum Client_Unavailable Client is stopped or cannot admit new work
   --  @enum Connection_Failed Resolution or every address attempt failed
   --  @enum Transport_Failed Established transport or protocol I/O failed
   --  @enum Request_Source_Failed Request source violated its contract
   --  @enum Response_Invalid Response parsing or framing failed
   --  @enum Response_Body_Too_Large Bounded response destination overflowed
   --  @enum Response_Sink_Failed Response sink raised while consuming data
   type Exchange_Result_Kind is
     (Response_Complete,
      Pre_Admission_Rejected,
      Cancelled,
      Timed_Out,
      Client_Unavailable,
      Connection_Failed,
      Transport_Failed,
      Request_Source_Failed,
      Response_Invalid,
      Response_Body_Too_Large,
      Response_Sink_Failed);

   --  Optional exact response length requirement.
   --  @field Known Whether Bytes is exact
   --  @field Bytes Exact syntactically valid Content-Length when Known
   type Length_Requirement is record
      Known : Boolean := False;
      Bytes : Body_Size := 0;
   end record;

   --  Maximum sanitized diagnostic detail retained by a scoped exchange.
   Max_Failure_Detail_Bytes : constant Positive := 512;

   --  Bounded terminal exchange result.
   type Exchange_Result is private;

   --  Return the typed terminal result.
   --  @param Item Result to inspect
   --  @return Typed terminal outcome
   function Kind (Item : Exchange_Result) return Exchange_Result_Kind;
   --  Return admission certainty captured at terminal completion.
   --  @param Item Result to inspect
   --  @return Monotonic admission certainty
   function Certainty (Item : Exchange_Result) return Admission_Certainty;
   --  Return the causal terminal exchange phase. Protocol cleanup does not
   --  overwrite this value with Draining; use Scoped.Raw_Phase to observe an
   --  active drain before terminal completion.
   --  @param Item Result to inspect
   --  @return Causal terminal diagnostic phase
   function Phase (Item : Exchange_Result) return Exchange_Phase;
   --  Return an exact required body length when a trusted Content-Length was
   --  available before a bounded destination overflowed.
   --  @param Item Result to inspect
   --  @return Exact or unknown response body length requirement
   function Required_Body_Length
     (Item : Exchange_Result) return Length_Requirement;
   --  Return bounded sanitized failure detail. It never retains a request
   --  target, credentials, signed fields, cookies, or request/body bytes.
   --  @param Item Result to inspect
   --  @return Bounded safe diagnostic category
   function Failure_Detail (Item : Exchange_Result) return String;

   --  Immediate response-body consumer. Write receives nonempty bounded slices
   --  on the completion-set owner's stack. It must not block or retain Data.
   --  Bytes delivered before a later exchange failure are not rolled back.
   type Response_Body_Sink is limited interface;

   --  Consume one complete nonempty decoded response slice.
   --  @param Item Sink state to update
   --  @param Data Ephemeral decoded response bytes
   procedure Write
     (Item : in out Response_Body_Sink;
      Data : Ada.Streams.Stream_Element_Array) is abstract;

   --  Result of one immediate request-source step.
   --  @enum Source_Progress Data contains a nonempty produced slice
   --  @enum Source_Finished Source reached its declared end
   --  @enum Source_Needs_Read Source requires readable readiness
   --  @enum Source_Needs_Write Source requires writable readiness
   type Source_Step_Kind is
     (Source_Progress,
      Source_Finished,
      Source_Needs_Read,
      Source_Needs_Write);

   --  Source wait results accepted by Source_Wait_Source.
   subtype Source_Wait_Kind is Source_Step_Kind range
     Source_Needs_Read .. Source_Needs_Write;

   --  Definite set-independent streaming upload capability. It never owns a
   --  completion-set slot; the visible HTTP exchange owns the only slot and
   --  borrows the source through terminal Finish or cancellation drain.
   type Operation_Request_Body_Source is limited interface;

   --  Return the source's stable exact or unknown length.
   --  @param Item Source to inspect
   --  @return Stable declared body length
   function Declared_Length
     (Item : Operation_Request_Body_Source) return Body_Length is abstract;

   --  Perform one nonblocking bounded source step. Source_Progress must return
   --  a nonempty slice. Every other result returns Last = Data'First - 1.
   --  Cumulative progress must equal a known Declared_Length exactly.
   --  @param Item Source to advance
   --  @param Data Caller storage for one produced slice
   --  @param Last Last produced element or Data'First minus one
   --  @param Result Immediate source result
   procedure Read_Now
     (Item   : in out Operation_Request_Body_Source;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Source_Step_Kind) is abstract;

   --  Query the level-triggered or latched readiness source required after
   --  Read_Now requests a wait. This is one bounded nonblocking step and does
   --  not consume an unreported readiness transition. When Ready_Now is
   --  False, Descriptor is valid and a transition after this call remains
   --  observable through Descriptor until the next Read_Now. When Ready_Now
   --  is True, Descriptor is ignored. The client combines a returned
   --  descriptor with transport, outbound, shutdown, and cancellation
   --  readiness so an early final response cannot be hidden by a blocked
   --  upload source. It disarms that combined wait before the next Read_Now
   --  or Release_Source.
   --  @param Item Source whose readiness is queried
   --  @param Required Read or write readiness requested by Read_Now
   --  @param Descriptor Latched readiness descriptor when Ready_Now is false
   --  @param Ready_Now Whether the source can be polled again immediately
   procedure Source_Wait_Source
     (Item        : in out Operation_Request_Body_Source;
      Required    : Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean) is abstract;

   --  Idempotently release every source borrow. The client calls this exactly
   --  once after each successful source attachment and before terminal
   --  publication on every path.
   --  @param Item Source whose borrow is released
   procedure Release_Source
     (Item : in out Operation_Request_Body_Source) is abstract;

   --  Full request/response exchange driven on its completion-set owner's
   --  stack. The operation terminalizes only after the complete response body
   --  is delivered and every transport, stream, pool, source, sink, token, and
   --  request borrow is drained or detached.
   type Exchange_Operation is new Flyology.Operations.Operation with private;

   --  Constructors and typed completion for full scoped client exchanges.
   package Scoped is

      --  Start a retained-body exchange into an acquired writable buffer.
      --  Validation and completion-slot reservation precede ownership
      --  transfer. A typed Pre_Admission_Rejected result leaves Destination
      --  unchanged; any initiating exception restores it before returning.
      --  @param Set Owner completion set
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Destination Acquired writable response buffer moved on start
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      --  @return Started full-exchange operation
      function Exchange_To_Buffer
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
        with Pre => Flyology.Buffers.Has_Buffer (Destination);

      --  Start a streamed-body exchange into an acquired writable buffer.
      --  @param Set Owner completion set
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Source Request source borrowed through terminal drain
      --  @param Destination Acquired writable response buffer moved on start
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      --  @return Started full-exchange operation
      function Exchange_To_Buffer
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Source   : not null access Operation_Request_Body_Source'Class;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
        with Pre => Flyology.Buffers.Has_Buffer (Destination);

      --  Start a retained-body exchange whose decoded response is delivered to
      --  an immediate sink. Sink effects before failure are not rolled back.
      --  @param Set Owner completion set
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Sink Immediate response consumer borrowed through drain
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      --  @return Started full-exchange operation
      function Exchange_To_Sink
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Sink     : not null access Response_Body_Sink'Class;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation;

      --  Start a streamed-body exchange whose decoded response is delivered to
      --  an immediate sink.
      --  @param Set Owner completion set
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Source Request source borrowed through terminal drain
      --  @param Sink Immediate response consumer borrowed through drain
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      --  @return Started full-exchange operation
      function Exchange_To_Sink
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Source   : not null access Operation_Request_Body_Source'Class;
         Sink     : not null access Response_Body_Sink'Class;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation;

      --  Start or restart the retained-body/bounded-response form in an
      --  established child suitable for Operations.Continue_After.
      --  @param Operation Inactive established child to start
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Destination Acquired writable response buffer moved on start
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
        with Pre => Flyology.Buffers.Has_Buffer (Destination)
          and then not Flyology.Operations.Is_Active (Operation)
          and then not Flyology.Operations.Is_Terminal (Operation);

      --  Start or restart the streamed-body/bounded-response form.
      --  @param Operation Inactive established child to start
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Source Request source borrowed through terminal drain
      --  @param Destination Acquired writable response buffer moved on start
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Source    : not null access Operation_Request_Body_Source'Class;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
        with Pre => Flyology.Buffers.Has_Buffer (Destination)
          and then not Flyology.Operations.Is_Active (Operation)
          and then not Flyology.Operations.Is_Terminal (Operation);

      --  Start or restart the retained-body/sink form.
      --  @param Operation Inactive established child to start
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Sink Immediate response consumer borrowed through drain
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Sink      : not null access Response_Body_Sink'Class;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
        with Pre => not Flyology.Operations.Is_Active (Operation)
          and then not Flyology.Operations.Is_Terminal (Operation);

      --  Start or restart the streamed-body/sink form.
      --  @param Operation Inactive established child to start
      --  @param Item Configured origin client borrowed through terminal drain
      --  @param Value Request metadata borrowed through terminal drain
      --  @param Source Request source borrowed through terminal drain
      --  @param Sink Immediate response consumer borrowed through drain
      --  @param Deadline Absolute whole-exchange deadline
      --  @param Token Optional cancellation token borrowed through drain
      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Source    : not null access Operation_Request_Body_Source'Class;
         Sink      : not null access Response_Body_Sink'Class;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
        with Pre => not Flyology.Operations.Is_Active (Operation)
          and then not Flyology.Operations.Is_Terminal (Operation);

      --  Return current monotonic admission knowledge before typed Finish.
      --  @param Operation Started exchange to inspect
      --  @return Current admission certainty
      function Admission
        (Operation : Exchange_Operation) return Admission_Certainty;

      --  Return the current raw driver phase before typed Finish.
      --  @param Operation Started exchange to inspect
      --  @return Current diagnostic phase
      function Raw_Phase
        (Operation : Exchange_Operation) return Exchange_Phase;

      --  Consume a sink exchange. Response_Complete transfers a body-complete,
      --  lease-free metadata Response. Other expected outcomes leave Reply
      --  uninitialized and are reported in Result without raising.
      --  @param Operation Terminal sink exchange to consume
      --  @param Result Typed terminal result
      --  @param Reply Detached complete response metadata on success
      procedure Finish
        (Operation : in out Exchange_Operation;
         Result    : out Exchange_Result;
         Reply     : out Response);

      --  Consume a bounded-buffer exchange. When the operation owns a detached
      --  token, Destination must be vacant and from the same pool; this is
      --  validated
      --  before the terminal result is consumed. Finish always restores that
      --  exact token. Only Response_Complete commits received length; every
      --  other result restores length zero. A pre-admission rejection that did
      --  not move Destination leaves it unchanged.
      --  @param Operation Terminal bounded exchange to consume
      --  @param Result Typed terminal result
      --  @param Reply Detached complete response metadata on success
      --  @param Destination Vacant same-pool handle for token restoration
      procedure Finish
        (Operation : in out Exchange_Operation;
         Result    : out Exchange_Result;
         Reply     : out Response;
         Destination : in out Flyology.Buffers.Unique_Buffer);
   end Scoped;

   --  Return the final response status.
   --  @param Item Response to inspect
   --  @return Three-digit status
   --  @exception Program_Error Item is not initialized by Execute
   function Status (Item : Response) return Status_Code;

   --  Return the final response reason phrase. HTTP/2 and later protocols may
   --  return an empty string because they do not carry one.
   --  @param Item Response to inspect
   --  @return Preserved HTTP/1.x reason phrase after its status separator
   --  @exception Program_Error Item is not initialized by Execute
   function Reason_Phrase (Item : Response) return String;

   --  Return the negotiated protocol.
   --  @param Item Response to inspect
   --  @return HTTP_1_1_Protocol, HTTP_2_Protocol, or HTTP_3_Protocol
   --  @exception Program_Error Item is not initialized by Execute
   function Negotiated_Protocol (Item : Response) return Protocol;

   --  Count physical response fields with a case-insensitive name.
   --  @param Item Response to inspect
   --  @param Name Field name
   --  @return Physical occurrence count
   --  @exception Program_Error Item is not initialized by Execute
   function Header_Count (Item : Response; Name : String) return Natural;

   --  Return the number of physical response fields.
   --  @param Item Response to inspect
   --  @return Field count
   --  @exception Program_Error Item is not initialized by Execute
   function Header_Count (Item : Response) return Natural;

   --  Return one response field name by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field name
   --  @exception Program_Error Item is not initialized by Execute
   --  @exception Constraint_Error Index exceeds Header_Count
   function Header_Name (Item : Response; Index : Positive) return String;

   --  Return one response field value by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field value
   --  @exception Program_Error Item is not initialized by Execute
   --  @exception Constraint_Error Index exceeds Header_Count
   function Header_Value (Item : Response; Index : Positive) return String;

   --  Return one physical response field occurrence.
   --  @param Item Response to inspect
   --  @param Name Field name
   --  @param Occurrence One-based occurrence
   --  @return Field value or empty when absent
   --  @exception Program_Error Item is not initialized by Execute
   function Header
     (Item : Response; Name : String; Occurrence : Positive := 1)
      return String;

   --  Count completed chunked trailer fields with a case-insensitive name.
   --  @param Item Response whose body has completed
   --  @param Name Trailer name
   --  @return Physical occurrence count
   --  @exception Program_Error Item is uninitialized or its body is incomplete
   function Trailer_Count (Item : Response; Name : String) return Natural;

   --  Return the number of physical trailer fields available after body
   --  completion.
   --  @param Item Response to inspect
   --  @return Trailer field count
   --  @exception Program_Error Item is uninitialized or its body is incomplete
   function Trailer_Count (Item : Response) return Natural;

   --  Return one trailer field name by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved trailer name
   --  @exception Program_Error Item is uninitialized or its body is incomplete
   --  @exception Constraint_Error Index exceeds Trailer_Count
   function Trailer_Name (Item : Response; Index : Positive) return String;

   --  Return one trailer field value by wire order.
   --  @param Item Response to inspect
   --  @param Index One-based physical field index
   --  @return Preserved trailer value
   --  @exception Program_Error Item is uninitialized or its body is incomplete
   --  @exception Constraint_Error Index exceeds Trailer_Count
   function Trailer_Value (Item : Response; Index : Positive) return String;

   --  Return one completed chunked trailer occurrence.
   --  @param Item Response whose body has completed
   --  @param Name Trailer name
   --  @param Occurrence One-based occurrence
   --  @return Trailer value or empty when absent
   --  @exception Program_Error Item is uninitialized or its body is incomplete
   function Trailer
     (Item : Response; Name : String; Occurrence : Positive := 1)
      return String;

   --  Stream decoded response representation bytes. Fixed-length and chunked
   --  framing are removed. Last is Data'First - 1 when no bytes are produced.
   --  Finished becomes true only after complete framing; that transition
   --  releases the underlying HTTP/1.1 or HTTP/3 connection or HTTP/2 stream.
   --  The Execute deadline and token remain authoritative and are never
   --  restarted.
   --  @param Item Active response
   --  @param Data Caller-owned destination
   --  @param Last Last decoded byte, or Data'First - 1
   --  @param Finished Whether response framing is complete
   --  @param Token Optional cancellation source borrowed for this call
   --  @exception Program_Error Item is not initialized by Execute
   --  @exception Client_Closed Client shutdown interrupts the exchange
   --  @exception Protocol_Error Response body framing is malformed
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket reception fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS reception fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Read_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token := null);

   --  Report whether body framing is complete and no connection lease remains.
   --  @param Item Response to inspect
   --  @return True after complete body consumption
   --  @exception Program_Error Item is not initialized by Execute
   function Body_Complete (Item : Response) return Boolean;

   --  Read the complete remaining body into owned storage under the original
   --  deadline. Maximum bounds decoded bytes retained by this convenience
   --  operation.
   --  @param Item Active response
   --  @param Maximum Maximum decoded bytes
   --  @param Token Optional cancellation source borrowed for this call
   --  @return Complete retained body
   --  @exception Program_Error Item is not initialized by Execute
   --  @exception Response_Too_Large Maximum would be exceeded
   --  @exception Client_Closed Client shutdown interrupts the exchange
   --  @exception Protocol_Error Response body framing is malformed
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket reception fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS reception fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   function Read_All
     (Item    : in out Response;
      Maximum : Natural := 1_024 * 1_024;
      Token   : access Flyology.Cancellation.Token := null)
      return Flyology.Bytes.Unbounded_Bytes;

   --  Read the complete remaining body into reusable owned storage. Result is
   --  cleared before reading and is empty if the operation raises. This form
   --  avoids successive function-result temporaries in a long-running caller
   --  scope.
   --  @param Item Active response
   --  @param Result Reusable owned body destination
   --  @param Maximum Maximum decoded bytes
   --  @param Token Optional cancellation source borrowed for this call
   --  @exception Program_Error Item is not initialized by Execute
   --  @exception Response_Too_Large Maximum would be exceeded
   --  @exception Client_Closed Client shutdown interrupts the exchange
   --  @exception Protocol_Error Response body framing is malformed
   --  @exception Flyology.IO.Timeout_Error Whole-exchange deadline expires
   --  @exception Flyology.IO.Device_Error Established transport I/O fails
   --  @exception Flyology.IO.Sockets.Socket_Error Socket reception fails
   --  @exception Flyology.IO.TLS.TLS_Error TLS reception fails
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Read_All
     (Item    : in out Response;
      Result  : in out Flyology.Bytes.Unbounded_Bytes;
      Maximum : Natural := 1_024 * 1_024;
      Token   : access Flyology.Cancellation.Token := null);

   --  Return coherent exchange and transport diagnostics without starting I/O.
   --  @param Item Client to inspect
   --  @return Current and cumulative counters
   function Diagnostics (Item : Client) return Client_Diagnostics;

   --  Close every currently idle connection. Active leases are unaffected.
   --  @param Item Configured client
   procedure Prune_Idle (Item : in out Client);

   --  Terminally reject admission, cancel admitted transport operations,
   --  close idle connections, and wait up to Timeout for leases and connecting
   --  slots to drain. A timeout leaves Item stopping and may be retried.
   --  @param Item Client to stop
   --  @param Timeout Drain deadline interval; negative waits indefinitely
   --  @exception Flyology.IO.Timeout_Error Active leases do not drain
   procedure Shutdown (Item : in out Client; Timeout : Duration := 5.0);

private
   --  Implementation declarations are shared with separate pool, exchange,
   --  and HTTP/1 subunits. The public response abstraction can later represent
   --  a multiplexed protocol stream.
   type Client_State (Capacity : Positive);
   type Client_State_Access is access Client_State;

   type Unix_Socket_Transport is record
      Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  @exclude
   --  @param Value Origin serialized by the HTTP/1 implementation
   --  @return Host field authority without the field name
   function Host_Field (Value : Origin) return String;

   --  @exclude
   --  @param Value Complete response bytes for the parser test oracle
   procedure Validate_Response_Bytes_For_Testing
     (Value : Ada.Streams.Stream_Element_Array);

   --  @exclude
   --  @param Item Client whose later HTTP/2 exchanges use the probe
   --  @param Grace Bounded post-response readiness-probe interval
   procedure Set_HTTP_2_Settlement_Grace_For_Testing
     (Item : in out Client; Grace : Duration);

   type Client_Control is new Ada.Finalization.Limited_Controlled with record
      State : Client_State_Access := null;
   end record;

   type Request is record
      Method_Value : Method := To_Method ("GET");
      Target_Value : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("/");
      Fields       : Flyology.HTTP.Headers.List;
      Trailer_Fields : Flyology.HTTP.Headers.List;
      Body_Value   : Flyology.Bytes.Unbounded_Bytes;
      Expect_Continue : Boolean := False;
      Continue_Wait   : Duration := 1.0;
      Redirects       : Redirect_Configuration := No_Redirects;
   end record;

   type Body_Length is record
      Is_Known : Boolean := False;
      Bytes    : Body_Size := 0;
   end record;

   Unknown_Length : constant Body_Length :=
     (Is_Known => False, Bytes => 0);

   type Monotonic_Deadline is record
      Is_Limited : Boolean := False;
      Value      : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
   end record;

   No_Deadline : constant Monotonic_Deadline :=
     (Is_Limited => False, Value => Ada.Real_Time.Time_Last);

   type Exchange_Result is record
      Result_Kind : Exchange_Result_Kind := Pre_Admission_Rejected;
      Admission   : Admission_Certainty := Not_Admitted;
      Last_Phase  : Exchange_Phase := Not_Started;
      Required    : Length_Requirement := (others => <>);
      Detail      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Exchange_State (<>);
   type Exchange_State_Access is access Exchange_State;

   type Exchange_Operation is new Flyology.Operations.Operation with record
      State : Exchange_State_Access := null;
   end record;

   --  @exclude
   --  @param Item Owner-driven exchange state
   --  @param Event Completion-set driver event
   overriding procedure Drive
     (Item  : in out Exchange_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item Owner-driven exchange to cancel and drain
   overriding procedure Request_Cancellation
     (Item : in out Exchange_Operation);

   --  @exclude
   --  @param Item Owner-driven exchange state to drain and release
   overriding procedure Finalize (Item : in out Exchange_Operation);

   type Client (Capacity : Positive := 4) is limited record
      Control : Client_Control;
   end record;

   --  @exclude
   --  @param Item Controlled client state to release
   overriding procedure Finalize (Item : in out Client_Control);

   type Response_Data;
   type Response_Data_Access is access Response_Data;

   type Response is new Ada.Finalization.Limited_Controlled with record
      Data : Response_Data_Access := null;
   end record;

   --  @exclude
   --  @param Item Controlled response lease to release
   overriding procedure Finalize (Item : in out Response);

end Flyology.HTTP.Client;
