with Ada.Strings.Unbounded;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.ALPN;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;
with Flyology.QUIC.Connections;

--  Provides deterministic method-and-path routing above HTTP.Server.
--  @formal App_Context Application-owned context passed to every endpoint
generic
   --  Application context shared by routed handlers.
   type App_Context is limited private;
package Flyology.HTTP.Server.Routing is

   use type Flyology.IO.Sockets.Address_Family;
   use type Flyology.IO.Sockets.Port;

   --  Raised after a unified listener's TCP or UDP serving task fails.
   Unified_Server_Error : exception;

   --  Typed middleware API used by this router instance. Applications may
   --  also instantiate Server.Middleware independently of routing.
   package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);

   --  Application endpoint invoked with the typed context and borrowed
   --  request exchange.
   subtype Handler_Access is Components.Handler_Access;

   --  Around-handler component accepted by router middleware registration.
   subtype Middleware_Access is Components.Middleware_Access;

   --  Middleware execution boundary relative to request-body admission. The
   --  router's own fail-closed authentication backstop runs between the two
   --  stages, so a component that installs a principal must be registered at
   --  Request_Head; at Application it runs too late and every request to a
   --  Required_Authentication route is answered by the backstop instead.
   --  @enum Request_Head Run before body acceptance and 100 Continue
   --  @enum Application Run after the selected body policy is applied
   type Middleware_Stage is (Request_Head, Application);

   --  Authentication policy interpreted by authentication middleware.
   subtype Authentication_Policy is
     Flyology.HTTP.Server.Applications.Authentication_Mode;
   --  Route does not request authentication.
   No_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.No_Authentication;
   --  Install a principal when valid credentials exist.
   Optional_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.Optional_Authentication;
   --  Reject requests without valid credentials.
   Required_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.Required_Authentication;

   --  Upgrade permission for higher-level endpoint adapters.
   subtype Upgrade_Policy is
     Flyology.HTTP.Server.Applications.Upgrade_Mode;
   --  Ordinary HTTP responses only.
   No_Upgrade : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.No_Upgrade;
   --  Permit an SSE lifecycle on the route.
   Allow_SSE : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.Allow_SSE;
   --  Permit a WebSocket lifecycle on the route.
   Allow_WebSocket : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.Allow_WebSocket;

   --  Route-local policy consumed incrementally by optional toolkit layers.
   --  A zero concurrency or rate value means unlimited. CORS_Policy is an
   --  application-defined bounded registry slot interpreted by CORS
   --  middleware; zero means no CORS policy.
   --  @field Body_Handling Request body handling
   --  @field Max_Body Maximum decoded body bytes
   --  @field Timeout Deadline narrowing in seconds; negative preserves it
   --  @field Concurrency Maximum active handlers; zero is unlimited
   --  @field Rate_Per_Second Per-client admission rate; zero is unlimited
   --  @field Authentication Route authentication requirement
   --  @field CORS_Policy Bounded application CORS policy slot
   --  @field Upgrade Permitted endpoint lifecycle
   type Route_Policy is record
      Body_Handling   :
        Flyology.HTTP.Server.Applications.Request_Body_Policy :=
          Flyology.HTTP.Server.Applications.Reject_Body;
      Max_Body        : Natural := Max_Request_Body;
      Timeout         : Duration := -1.0;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0;
      Authentication  : Authentication_Policy := No_Authentication;
      CORS_Policy     : Natural := 0;
      Upgrade         : Upgrade_Policy := No_Upgrade;
   end record;

   --  Baseline route policy: reject bodies and preserve the server deadline.
   Default_Route_Policy : constant Route_Policy := (others => <>);

   --  Trailing slash treatment.
   --  @enum Strict_Slashes Route pattern and target must agree
   --  @enum Ignore_Slashes A final slash does not affect matching
   --  @enum Redirect_Slashes Mismatches receive a permanent 308 redirect
   type Trailing_Slash_Policy is
     (Strict_Slashes, Ignore_Slashes, Redirect_Slashes);

   --  Invalid route registration or decoded request path.
   Route_Error : exception;

   --  Bounded route registry. Registration is intended during application
   --  setup, before concurrent dispatch begins.
   --  @field Capacity Maximum registered routes
   --  @field Slashes Explicit final-slash behavior
   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited private;

   --  Immutable copy of one registered route's public configuration.
   --  Introspection is intended for diagnostics after setup; it is not part of
   --  request dispatch and adds no work to the routing hot path.
   --  @field Method Configured HTTP method
   --  @field Pattern Configured path pattern
   --  @field Name Stable route name
   --  @field Policy Route-local application policy
   --  @field Middleware_Count Route-local or mounted middleware count
   type Route_Description is record
      Method           : Ada.Strings.Unbounded.Unbounded_String;
      Pattern          : Ada.Strings.Unbounded.Unbounded_String;
      Name             : Ada.Strings.Unbounded.Unbounded_String;
      Policy           : Route_Policy;
      Middleware_Count : Natural;
   end record;

   --  Immutable copy of one middleware registration.
   --  An empty name means the application used the source-compatible unnamed
   --  registration form.
   --  @field Name Application-provided diagnostic name
   --  @field Stage Body-admission boundary where the component runs
   type Middleware_Description is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Stage : Middleware_Stage;
   end record;

   --  Return the number of configured routes without allocating.
   --  Registration and introspection must not occur concurrently.
   --  @param Item Router registry
   --  @return Number of routes in registration order
   function Route_Count (Item : Router) return Natural;

   --  Copy one configured route description.
   --  @param Item Router registry
   --  @param Index One-based registration index
   --  @return Owned route metadata that may outlive the router
   --  @exception Constraint_Error Index is outside 1 .. Route_Count
   function Describe_Route
     (Item  : Router;
      Index : Positive) return Route_Description;

   --  Return the number of global middleware registrations.
   --  @param Item Router registry
   --  @return Global middleware count in registration order
   function Global_Middleware_Count (Item : Router) return Natural;

   --  Copy one global middleware description.
   --  @param Item Router registry
   --  @param Index One-based registration index
   --  @return Owned middleware metadata
   --  @exception Constraint_Error Index is outside the configured range
   function Describe_Global_Middleware
     (Item  : Router;
      Index : Positive) return Middleware_Description;

   --  Return route-local and mounted middleware count for one route.
   --  @param Item Router registry
   --  @param Route_Index One-based route registration index
   --  @return Middleware count in execution order after global components
   --  @exception Constraint_Error Route_Index is outside the configured range
   function Route_Middleware_Count
     (Item        : Router;
      Route_Index : Positive) return Natural;

   --  Copy one route-local or mounted middleware description.
   --  @param Item Router registry
   --  @param Route_Index One-based route registration index
   --  @param Middleware_Index One-based middleware index for that route
   --  @return Owned middleware metadata
   --  @exception Constraint_Error Either index is outside its configured range
   function Describe_Route_Middleware
     (Item             : Router;
      Route_Index      : Positive;
      Middleware_Index : Positive) return Middleware_Description;

   --  Append global middleware. Global components wrap every matched route in
   --  registration order and are copied into mounted subrouter routes.
   --  @param Item Router registry
   --  @param Component Around-handler component
   --  @param Stage Body-admission boundary for the component
   --  @param Name Optional stable diagnostic name for introspection
   --  @exception Route_Error Item has already been mounted, so the component
   --  would not reach the copied routes
   procedure Add_Middleware
     (Item      : in out Router;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : String := "");

   --  Append middleware to one route selected by its unique configured name.
   --  Route-local components run after router-global components.
   --  @param Item Router registry
   --  @param Name Configured route name
   --  @param Component Around-handler component
   --  @param Stage Body-admission boundary for the component
   --  @param Middleware_Name Optional stable diagnostic name
   --  @exception Route_Error Item has already been mounted, so the component
   --  would not reach the copied routes
   procedure Add_Route_Middleware
     (Item      : in out Router;
      Name      : String;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Middleware_Name : String := "");

   --  Register one exact method and path pattern.
   --  @param Item Router registry
   --  @param Method Case-sensitive HTTP method token
   --  @param Pattern Static, {name}, or final {*name} path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name; empty derives Method and Pattern
   --  @param Policy Route-local application policy
   --  @exception Route_Error Item has already been mounted, so the route
   --  would not reach the copied routes
   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a GET route. HEAD falls back to it when no exact HEAD exists.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Get
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register an explicit HEAD route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Head
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a POST route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Post
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a PUT route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Put
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a PATCH route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Patch
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a DELETE route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Delete
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register an OPTIONS route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Options
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Set the per-client admission policy applied to the router's own
   --  automatic responses: 404, 405, CORS preflight, OPTIONS, the trailing
   --  slash redirect, and the malformed-path 400. Those responses match no
   --  route, so they carry no route policy of their own, yet they run the
   --  whole global middleware chain and write a response. Zero is unlimited
   --  and is the default, which leaves that surface unmetered.
   --  @param Item Router registry
   --  @param Concurrency Maximum active automatic responses; zero is
   --  unlimited
   --  @param Rate_Per_Second Per-client automatic response rate; zero is
   --  unlimited
   procedure Set_Automatic_Admission
     (Item            : in out Router;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0);

   --  Return the configured automatic-response concurrency bound.
   --  @param Item Router registry
   --  @return Maximum active automatic responses; zero is unlimited
   function Automatic_Concurrency (Item : Router) return Natural;

   --  Return the configured automatic-response per-client rate.
   --  @param Item Router registry
   --  @return Automatic responses per second; zero is unlimited
   function Automatic_Rate_Per_Second (Item : Router) return Natural;

   --  Set the WWW-Authenticate challenge the router's own fail-closed
   --  backstop advertises when a Required_Authentication route is reached
   --  with no principal installed. The router cannot see the authentication
   --  middleware's own challenge, so an application that does not use Bearer
   --  must state its scheme here. The default is "Bearer".
   --  @param Item Router registry
   --  @param Challenge Complete WWW-Authenticate field value
   --  @exception Route_Error Challenge is empty or carries control bytes
   procedure Set_Authentication_Challenge
     (Item      : in out Router;
      Challenge : String);

   --  Return the configured fail-closed authentication challenge.
   --  @param Item Router registry
   --  @return WWW-Authenticate field value the backstop advertises
   function Authentication_Challenge (Item : Router) return String;

   --  Copy routes from Source under Prefix. Capacity is checked before any
   --  route is copied. Prefix must be a static path without parameters.
   --  Mounting snapshots Source, so Source is sealed against further route
   --  and middleware registration: a later registration on it raises rather
   --  than silently leaving the copied routes unprotected. Register
   --  everything on a subrouter before mounting it.
   --  @param Item Destination router
   --  @param Prefix Static mount path
   --  @param Source Source subrouter, sealed by this call
   --  @param Name_Prefix Optional prefix for nonempty route names
   procedure Mount
     (Item        : in out Router;
      Prefix      : String;
      Source      : in out Router;
      Name_Prefix : String := "");

   --  Match and invoke one already parsed request. Automatic 404, 405, HEAD
   --  fallback, slash handling, body policy, and deadline narrowing occur
   --  before the endpoint is called.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Connection Sole-writer HTTP connection
   --  @param Value Parsed request head
   --  @param Peer Connected peer address
   --  @param Token Optional cancellation token
   --  @param Alt_Svc Optional HTTP/3 alternative-service field value
   procedure Dispatch
     (Item       : in out Router;
      Context    : in out App_Context;
      Connection : aliased in out Flyology.HTTP.Server.Connection;
      Value      : aliased in out Request;
      Peer       : Flyology.IO.Sockets.Endpoint;
      Token      : access Flyology.Cancellation.Token := null;
      Alt_Svc    : String := "");

   --  Match and invoke one protocol-neutral application exchange. Protocol
   --  engines use this overload after parsing and admitting a stream.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param X Borrowed request exchange
   procedure Dispatch
     (Item    : in out Router;
      Context : in out App_Context;
      X       : in out Applications.Exchange);

   --  Read and route persistent requests until close or upgrade. This optional
   --  adapter leaves the lower-level Connection_Handlers package available.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Connection Sole-writer HTTP connection
   --  @param Peer Connected peer address
   --  @param Timeout Original per-request deadline interval
   --  @param Max_Connection_Age Absolute lifetime bound for the connection;
   --  negative disables this additional bound
   --  @param Max_Requests Requests before connection close; zero is unlimited
   --  @param Token Optional cancellation token
   --  @param Header_Timeout Absolute slow-header budget for each request;
   --  negative uses the remaining request/connection lifetime
   --  @param Alt_Svc Optional HTTP/3 alternative-service field value
   procedure Serve
     (Item         : in out Router;
      Context      : in out App_Context;
      Connection   : aliased in out Flyology.HTTP.Server.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Timeout      : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests : Natural := 1_000;
      Token        : access Flyology.Cancellation.Token := null;
      Header_Timeout : Duration := -1.0;
      Alt_Svc      : String := "");

   --  Select HTTP/1.x or HTTP/2 for one accepted Flyology connection and
   --  serve it through this router. Route registration, middleware, body
   --  policy, and endpoint handlers are identical for both protocols.
   --  HTTP_2_Only expects cleartext prior knowledge or TLS already selected
   --  as h2. ALPN_Negotiated requires an upgraded ALPN-capable TLS channel and
   --  accepts only h2, http/1.1, or an empty fallback selection.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Channel Sole owning plaintext or TLS Flyology connection
   --  @param Peer Connected peer address
   --  @param Mode Accepted-connection protocol policy
   --  @param Timeout Per-request or per-stream deadline interval
   --  @param Max_Connection_Age Absolute connection lifetime bound
   --  @param Max_Requests HTTP/1.x request limit; ignored for HTTP/2
   --  @param Token Optional cancellation token
   --  @param Header_Timeout HTTP/1.x slow-header budget; ignored for HTTP/2
   --  @param Ingress Optional HTTP/1.x retained-body budget
   --  @param Alt_Svc Optional HTTP/3 alternative-service field value
   procedure Serve
     (Item               : in out Router;
      Context            : in out App_Context;
      Channel            : aliased in out Flyology.IO.Connections.Connection;
      Peer               : Flyology.IO.Sockets.Endpoint;
      Mode               : Protocol_Mode := HTTP_1_Only;
      Timeout            : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Natural := 1_000;
      Token              : access Flyology.Cancellation.Token := null;
      Header_Timeout     : Duration := -1.0;
      Ingress            : access Ingress_Budget := null;
      Alt_Svc            : String := "");

   --  Bind one endpoint as TLS/TCP for HTTP/1.1 and HTTP/2 and as UDP for
   --  HTTP/3, then serve every protocol through this router until Token is
   --  requested. TLS_Backend must be a server provider configured to select
   --  h2 or http/1.1. H1/H2 responses advertise the active H3 endpoint with
   --  Alt-Svc; H3 responses do not. Mutable router context must synchronize
   --  access across concurrent protocol workers.
   --  @param Item Frozen router shared by all protocol workers
   --  @param Context Shared application context
   --  @param Endpoint Non-ephemeral local TCP and UDP endpoint
   --  @param TLS_Backend Initialized ALPN-capable TLS server provider
   --  @param Certificate_DER DER-encoded Ed25519 HTTP/3 certificate
   --  @param Private_Key Raw Ed25519 HTTP/3 private key
   --  @param TCP_Capacity Maximum concurrent H1/H2 connections
   --  @param HTTP_3_Capacity Maximum concurrent H3 connections
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request or stream application deadline
   --  @param Handshake_Timeout TLS and QUIC handshake deadline
   --  @param Max_Connection_Age Per-connection lifetime
   --  @param TCP_Max_Requests HTTP/1.x persistent request limit
   --  @param HTTP_3_Max_Requests H3 request limit per connection
   --  @param Header_Timeout HTTP/1.x slow-header deadline
   --  @param Ingress Optional shared HTTP/1.x retained-body budget
   --  @param Alt_Svc_Max_Age Alt-Svc lifetime in seconds
   --  @param Drain_Timeout TCP handler drain after shutdown
   --  @param Token Required unified server shutdown source
   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      Endpoint             : Flyology.IO.Sockets.Endpoint;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 1_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token)
   with Pre => Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then Certificate_DER'Length in 1 .. 4_096
     and then HTTP_3_Capacity <= 256
     and then HTTP_3_Max_Requests <= 1_000
     and then Handshake_Timeout > 0.0
     and then
       (Drain_Timeout = Flyology.IO.Infinite or else Drain_Timeout >= 0.0);

   --  Bind explicit IPv4 and IPv6 endpoints concurrently, serving TLS/TCP
   --  HTTP/1.1 and HTTP/2 plus UDP HTTP/3 on both families. The endpoints
   --  must use the same concrete port so one Alt-Svc authority remains valid
   --  regardless of the address family selected by a client. Capacity values
   --  are totals divided between the two listeners; each must therefore admit
   --  at least two transports. Failure of either family stops the whole
   --  server. Route, context, TLS, certificate, timeout, and shutdown
   --  semantics are otherwise identical to the single-endpoint overload.
   --  @param Item Frozen router shared by all protocol workers
   --  @param Context Shared application context
   --  @param IPv4_Endpoint Concrete local IPv4 TCP and UDP endpoint
   --  @param IPv6_Endpoint Concrete local IPv6 TCP and UDP endpoint
   --  @param TLS_Backend Initialized ALPN-capable TLS server provider
   --  @param Certificate_DER DER-encoded Ed25519 HTTP/3 certificate
   --  @param Private_Key Raw Ed25519 HTTP/3 private key
   --  @param TCP_Capacity Total concurrent H1/H2 connections
   --  @param HTTP_3_Capacity Total concurrent H3 connections
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request or stream application deadline
   --  @param Handshake_Timeout TLS and QUIC handshake deadline
   --  @param Max_Connection_Age Per-connection lifetime
   --  @param TCP_Max_Requests HTTP/1.x persistent request limit
   --  @param HTTP_3_Max_Requests H3 request limit per connection
   --  @param Header_Timeout HTTP/1.x slow-header deadline
   --  @param Ingress Optional shared HTTP/1.x retained-body budget
   --  @param Alt_Svc_Max_Age Alt-Svc lifetime in seconds
   --  @param Drain_Timeout TCP handler drain after shutdown
   --  @param Token Required unified server shutdown source
   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      IPv4_Endpoint        : Flyology.IO.Sockets.Endpoint;
      IPv6_Endpoint        : Flyology.IO.Sockets.Endpoint;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 1_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token)
   with Pre => IPv4_Endpoint.Family = Flyology.IO.Sockets.IPv4
     and then IPv6_Endpoint.Family = Flyology.IO.Sockets.IPv6
     and then IPv4_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then IPv4_Endpoint.Port = IPv6_Endpoint.Port
     and then Certificate_DER'Length in 1 .. 4_096
     and then TCP_Capacity >= 2
     and then HTTP_3_Capacity in 2 .. 256
     and then HTTP_3_Max_Requests <= 1_000
     and then Handshake_Timeout > 0.0
     and then
       (Drain_Timeout = Flyology.IO.Infinite or else Drain_Timeout >= 0.0);

   --  Receive and serve one HTTP/3 connection on an exclusively owned bound
   --  UDP socket. Requests use the same routes, middleware, body policies, and
   --  application exchange helpers as HTTP/1.1 and HTTP/2. The server identity
   --  is an Ed25519 certificate and raw private key. A secure server
   --  connection identifier is generated for the connection.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Socket Exclusively owned bound UDP socket
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish QUIC
   --  @param Max_Connection_Age Absolute connection lifetime
   --  @param Max_Requests Requests served before Serve_HTTP_3 returns
   --  @param Token Optional connection cancellation source
   procedure Serve_HTTP_3
     (Item               : in out Router;
      Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 1_000;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000;

   --  Receive and serve one HTTP/3 connection with an application-supplied
   --  server connection identifier. This overload is intended for connection
   --  managers that own identifier generation.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Socket Exclusively owned bound UDP socket
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Source Fresh server source connection identifier
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish QUIC
   --  @param Max_Connection_Age Absolute connection lifetime
   --  @param Max_Requests Requests served before Serve_HTTP_3 returns
   --  @param Token Optional connection cancellation source
   procedure Serve_HTTP_3
     (Item               : in out Router;
      Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Source             : Flyology.QUIC.Connections.Connection_ID;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 1_000;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000
     and then Source.Length in 1 ..
       Flyology.QUIC.Connections.Max_Connection_ID_Length;

   --  Serve multiple concurrent HTTP/3 connections through this router on an
   --  unconnected bound UDP socket until Token is requested.
   --  @param Item Frozen router shared by all connection workers
   --  @param Context Shared application context; mutable parts synchronize
   --  @param Socket Exclusively owned bound UDP listener
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Capacity Maximum concurrent QUIC connections
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish each QUIC connection
   --  @param Max_Connection_Age Per-connection lifetime
   --  @param Max_Requests Requests served by each connection
   --  @param Token Required listener shutdown and connection cancellation
   procedure Serve_HTTP_3_Listener
     (Item               : aliased in out Router;
      Context            : aliased in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Capacity           : Positive := 128;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 1_000;
      Token              : not null access Flyology.Cancellation.Token)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Capacity <= 256
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000;

private
   use Ada.Strings.Unbounded;

   Max_Global_Middleware : constant := 16;
   Max_Route_Middleware  : constant := 16;
   Max_Segments          : constant := 64;

   type Segment_Array is
     array (Positive range 1 .. Max_Segments) of Unbounded_String;
   type Segment_List is record
      Values   : Segment_Array;
      Count    : Natural := 0;
      Trailing : Boolean := False;
   end record;

   type Middleware_Entry is record
      Component : Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : Unbounded_String;
   end record;
   type Middleware_Array is
     array (Positive range <>) of Middleware_Entry;

   --  Registration compiles each pattern into bounded segment storage so
   --  dispatch does not split and allocate the same pattern per request.
   type Route_Entry is record
      Method              : Unbounded_String;
      Pattern             : Unbounded_String;
      Pattern_Segments    : Segment_List;
      Pattern_Specificity : Natural := 0;
      Name                : Unbounded_String;
      Handler             : Handler_Access;
      Policy              : Route_Policy;
      Middleware          : Middleware_Array (1 .. Max_Route_Middleware);
      Middleware_Count    : Natural := 0;
   end record;
   type Route_Array is array (Positive range <>) of Route_Entry;

   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited record
      Routes : Route_Array (1 .. Capacity);
      Count  : Natural := 0;
      Middleware : Middleware_Array (1 .. Max_Global_Middleware);
      Middleware_Count : Natural := 0;
      Automatic_Concurrency : Natural := 0;
      Automatic_Rate        : Natural := 0;
      Mounted               : Boolean := False;
      --  Empty selects the Default_Challenge, so an unconfigured router
      --  needs no per-object allocation.
      Challenge             : Unbounded_String;
   end record;

end Flyology.HTTP.Server.Routing;
