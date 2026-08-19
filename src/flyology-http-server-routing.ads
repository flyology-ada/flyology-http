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
private with Ada.Finalization;
private with Interfaces;
private with System;

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

   --  Policy for the cleartext endpoint of a unified HTTP/HTTPS server.
   --  @enum Serve_Cleartext Route cleartext HTTP/1.x requests normally
   --  @enum Redirect_To_HTTPS Redirect each request to the configured origin
   type Cleartext_Policy is (Serve_Cleartext, Redirect_To_HTTPS);

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

   --  Raised when an update was built from a configuration generation that
   --  has since been replaced.
   Stale_Update : exception;

   --  Opaque runtime identity of one logical route. Identities are assigned
   --  by registration, remain stable across route updates, and are never
   --  reused after removal. They are meaningful only within this routing
   --  package instance and are not persistent deployment identifiers.
   type Route_ID is private;

   --  Identity that does not designate a route.
   No_Route : constant Route_ID;

   --  Opaque runtime identity of one middleware registration. The same
   --  component may be registered more than once and receives a distinct
   --  identity each time. Mounting copies a registration into the mounted
   --  routes without changing its identity, so one identity can name every
   --  copy of that registration.
   type Middleware_ID is private;

   --  Identity that does not designate middleware.
   No_Middleware : constant Middleware_ID;

   --  Transactional candidate cloned from one published router generation.
   --  Mutations affect only the candidate until Commit atomically publishes
   --  it. A candidate based on a superseded generation is rejected.
   type Update is limited private;

   --  Immutable view of one published generation. Every operation on one
   --  snapshot reads the same generation, so a count and the indexes taken
   --  from it stay consistent while another writer commits.
   type Snapshot is limited private;

   --  Bounded route registry. Direct registration writes the published
   --  generation in place, so it belongs to application setup: the first
   --  dispatch seals the router and every direct registration or setter
   --  afterwards raises Route_Error. Use Begin_Update and Commit to change
   --  a serving router.
   --  @field Capacity Maximum registered routes
   --  @field Slashes Explicit final-slash behavior
   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited private;

   --  Immutable copy of one registered route's public configuration.
   --  Introspection snapshots the currently published generation and is not
   --  part of request dispatch.
   --  @field ID Stable runtime route identity
   --  @field Method Configured HTTP method
   --  @field Pattern Configured path pattern
   --  @field Name Stable route name
   --  @field Policy Route-local application policy
   --  @field Middleware_Count Route-local or mounted middleware count
   type Route_Description is record
      ID               : Route_ID;
      Method           : Ada.Strings.Unbounded.Unbounded_String;
      Pattern          : Ada.Strings.Unbounded.Unbounded_String;
      Name             : Ada.Strings.Unbounded.Unbounded_String;
      Policy           : Route_Policy;
      Middleware_Count : Natural;
   end record;

   --  Immutable copy of one middleware registration.
   --  An empty name means the application used the source-compatible unnamed
   --  registration form.
   --  @field ID Stable runtime middleware registration identity
   --  @field Name Application-provided diagnostic name
   --  @field Stage Body-admission boundary where the component runs
   type Middleware_Description is record
      ID    : Middleware_ID;
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Stage : Middleware_Stage;
   end record;

   --  Return the number of configured routes without allocating. The result
   --  describes the generation current when this call takes its snapshot.
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

   --  Resolve a unique configured route name to its runtime identity.
   --  The copied identity remains stable across updates until removal.
   --  @param Item Router registry
   --  @param Name Configured route name
   --  @param Route Resolved identity, or No_Route when absent
   --  @param Found Whether Name identifies a route
   procedure Find_Route
     (Item  : Router;
      Name  : String;
      Route : out Route_ID;
      Found : out Boolean);

   --  Capture the published generation for a consistent traversal. Each
   --  Router introspection call reads the generation published when that
   --  call runs, so a count from one call and an index used in the next can
   --  straddle a commit. Take one snapshot and traverse that instead.
   --  @param Item Router registry
   --  @param Into Snapshot receiving the captured generation
   procedure Take_Snapshot (Item : Router; Into : out Snapshot);

   --  Return the number of routes in the captured generation.
   --  @param Item Captured generation
   --  @return Number of routes in registration order
   function Route_Count (Item : Snapshot) return Natural;

   --  Copy one route's public configuration from the captured generation.
   --  @param Item Captured generation
   --  @param Index Route position in registration order
   --  @return Owned copy of the route's public configuration
   --  @exception Constraint_Error Index exceeds the captured route count
   function Describe_Route
     (Item  : Snapshot;
      Index : Positive) return Route_Description;

   --  Return the number of global components in the captured generation.
   --  @param Item Captured generation
   --  @return Number of global middleware registrations
   function Global_Middleware_Count (Item : Snapshot) return Natural;

   --  Copy one global middleware registration from the captured generation.
   --  @param Item Captured generation
   --  @param Index Registration position in registration order
   --  @return Owned copy of the registration
   --  @exception Constraint_Error Index exceeds the captured count
   function Describe_Global_Middleware
     (Item  : Snapshot;
      Index : Positive) return Middleware_Description;

   --  Return one route's middleware count in the captured generation.
   --  @param Item Captured generation
   --  @param Route_Index Route position in registration order
   --  @return Number of components attached to the route
   --  @exception Constraint_Error Route_Index exceeds the captured count
   function Route_Middleware_Count
     (Item        : Snapshot;
      Route_Index : Positive) return Natural;

   --  Copy one route-local middleware registration from the captured
   --  generation.
   --  @param Item Captured generation
   --  @param Route_Index Route position in registration order
   --  @param Middleware_Index Component position within the route chain
   --  @return Owned copy of the registration
   --  @exception Constraint_Error Either index exceeds its captured count
   function Describe_Route_Middleware
     (Item             : Snapshot;
      Route_Index      : Positive;
      Middleware_Index : Positive) return Middleware_Description;

   --  Resolve a route name within the captured generation.
   --  @param Item Captured generation
   --  @param Name Configured route name
   --  @param Route Resolved identity, or No_Route when absent
   --  @param Found Whether Name identifies a route
   procedure Find_Route
     (Item  : Snapshot;
      Name  : String;
      Route : out Route_ID;
      Found : out Boolean);

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

   --  Append global middleware and return its runtime registration identity.
   --  @param Item Router registry
   --  @param Component Around-handler component
   --  @param Middleware Assigned registration identity
   --  @param Stage Body-admission boundary for the component
   --  @param Name Optional stable diagnostic name for introspection
   procedure Add_Middleware
     (Item       : in out Router;
      Component  : not null Middleware_Access;
      Middleware : out Middleware_ID;
      Stage      : Middleware_Stage := Request_Head;
      Name       : String := "");

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

   --  Append middleware to one route selected by name and return its runtime
   --  registration identity.
   --  @param Item Router registry
   --  @param Name Configured route name
   --  @param Component Around-handler component
   --  @param Middleware Assigned registration identity
   --  @param Stage Body-admission boundary for the component
   --  @param Middleware_Name Optional stable diagnostic name
   procedure Add_Route_Middleware
     (Item            : in out Router;
      Name            : String;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "");

   --  Append middleware to one route identity and return the registration
   --  identity. This setup-time overload avoids name lookup for applications
   --  that retain route identities.
   --  @param Item Router registry
   --  @param Route Route receiving the component
   --  @param Component Around-handler component
   --  @param Middleware Assigned registration identity
   --  @param Stage Body-admission boundary for the component
   --  @param Middleware_Name Optional stable diagnostic name
   procedure Add_Route_Middleware
     (Item            : in out Router;
      Route           : Route_ID;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "");

   --  Register one exact method and path pattern. Setup-only: this raises
   --  Route_Error once the router has dispatched.
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

   --  Register one route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Method Case-sensitive HTTP method token
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name; empty derives Method and Pattern
   --  @param Policy Route-local application policy
   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a GET route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Get
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a HEAD route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Head
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a POST route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Post
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a PUT route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Put
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a PATCH route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Patch
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register a DELETE route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Delete
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
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

   --  Register an OPTIONS route and return its stable runtime identity.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Options
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Clone the current immutable router generation into Change. Change must
   --  not already contain an uncommitted candidate.
   --  @param Item Router whose current generation is the update base
   --  @param Change Empty update object receiving the candidate
   --  @exception Route_Error Item has been mounted into another router
   procedure Begin_Update (Item : Router; Change : in out Update);

   --  Add one route to an unpublished candidate.
   --  @param Change Active candidate
   --  @param Method Case-sensitive HTTP method token
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Route Assigned route identity
   --  @param Name Stable route name; empty derives Method and Pattern
   --  @param Policy Route-local application policy
   procedure Add
     (Change  : in out Update;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Remove one route from an unpublished candidate. Its identity is never
   --  reused, including when the same name is subsequently registered.
   --  @param Change Active candidate
   --  @param Route Route to remove
   --  @exception Route_Error Route is not present in the candidate
   procedure Remove (Change : in out Update; Route : Route_ID);

   --  Replace one route's endpoint while preserving its identity and match.
   --  @param Change Active candidate
   --  @param Route Route to change
   --  @param Handler Replacement endpoint
   procedure Replace_Handler
     (Change  : in out Update;
      Route   : Route_ID;
      Handler : not null Handler_Access);

   --  Replace one route's complete application policy.
   --  @param Change Active candidate
   --  @param Route Route to change
   --  @param Policy Replacement route policy
   procedure Set_Policy
     (Change : in out Update;
      Route  : Route_ID;
      Policy : Route_Policy);

   --  Replace one route's method and pattern together while preserving its
   --  identity. Whole-candidate ambiguity validation occurs during Commit.
   --  @param Change Active candidate
   --  @param Route Route to change
   --  @param Method Replacement method token
   --  @param Pattern Replacement path pattern
   procedure Set_Match
     (Change  : in out Update;
      Route   : Route_ID;
      Method  : String;
      Pattern : String);

   --  Replace one route's unique diagnostic and external lookup name.
   --  @param Change Active candidate
   --  @param Route Route to rename
   --  @param Name Nonempty replacement name
   procedure Rename
     (Change : in out Update;
      Route  : Route_ID;
      Name   : String);

   --  Add one global middleware registration to a candidate.
   --  @param Change Active candidate
   --  @param Component Around-handler component
   --  @param Middleware Assigned registration identity
   --  @param Stage Body-admission boundary
   --  @param Name Optional diagnostic name
   procedure Add_Middleware
     (Change     : in out Update;
      Component  : not null Middleware_Access;
      Middleware : out Middleware_ID;
      Stage      : Middleware_Stage := Request_Head;
      Name       : String := "");

   --  Add middleware to one candidate route.
   --  @param Change Active candidate
   --  @param Route Route receiving the component
   --  @param Component Around-handler component
   --  @param Middleware Assigned registration identity
   --  @param Stage Body-admission boundary
   --  @param Middleware_Name Optional diagnostic name
   procedure Add_Route_Middleware
     (Change          : in out Update;
      Route           : Route_ID;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "");

   --  Remove a middleware registration from the global chain and from every
   --  route chain that carries it, including chains a mount copied it into.
   --  @param Change Active candidate
   --  @param Middleware Registration to remove
   procedure Remove_Middleware
     (Change     : in out Update;
      Middleware : Middleware_ID);

   --  Replace a middleware component while preserving its identity, stage,
   --  name, and position in every chain that references the registration.
   --  @param Change Active candidate
   --  @param Middleware Registration to change
   --  @param Component Replacement around-handler component
   procedure Replace_Middleware
     (Change     : in out Update;
      Middleware : Middleware_ID;
      Component  : not null Middleware_Access);

   --  Replace a middleware registration's body-admission stage.
   --  @param Change Active candidate
   --  @param Middleware Registration to change
   --  @param Stage Replacement execution stage
   procedure Set_Middleware_Stage
     (Change     : in out Update;
      Middleware : Middleware_ID;
      Stage      : Middleware_Stage);

   --  Set automatic-response admission policy in a candidate.
   --  @param Change Active candidate
   --  @param Concurrency Maximum active automatic responses
   --  @param Rate_Per_Second Per-client automatic response rate
   procedure Set_Automatic_Admission
     (Change          : in out Update;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0);

   --  Set the fail-closed authentication challenge in a candidate.
   --  @param Change Active candidate
   --  @param Challenge Complete WWW-Authenticate field value
   procedure Set_Authentication_Challenge
     (Change    : in out Update;
      Challenge : String);

   --  Validate and atomically publish a complete candidate. A candidate
   --  whose base generation was already replaced can never be published, so
   --  Stale_Update also releases it and the same update object can be rebuilt
   --  from the newer generation. A candidate rejected by validation stays
   --  active so it can be corrected and committed again.
   --  @param Item Router receiving the candidate
   --  @param Change Active candidate consumed on success
   --  @exception Stale_Update Base generation was replaced first
   --  @exception Route_Error Candidate is not a valid configuration
   procedure Commit (Item : in out Router; Change : in out Update);

   --  Discard an active candidate and return the update to its empty state.
   --  An update with no candidate is unchanged. Use this to give up on a
   --  candidate Commit rejected for a validation error.
   --  @param Change Update to reset
   procedure Abandon (Change : in out Update);

   --  Return the number of configuration generations the router holds: the
   --  published generation plus every superseded generation it still keeps.
   --  Each Commit adds one, and the router releases them only at
   --  finalization or at Reclaim, so this count grows with the number of
   --  commits. Use it to observe that growth.
   --  @param Item Router registry
   --  @return Retained generation count, at least one
   function Retained_Generations (Item : Router) return Natural;

   --  Release every superseded generation and keep the published one.
   --  Retention is what keeps an in-flight dispatch and a live Snapshot
   --  reading valid storage, so the caller must know that no dispatch is in
   --  progress and that no snapshot of a superseded generation is still in
   --  use. This precondition is not checked. Call it on a drained server,
   --  between serving cycles.
   --  @param Item Router registry
   procedure Reclaim (Item : in out Router);

   --  Set the per-client admission policy applied to the router's own
   --  automatic responses: 404, 405, CORS preflight, OPTIONS, the trailing
   --  slash redirect, and the malformed-path 400. Those responses match no
   --  route, so they carry no route policy of their own, yet they run the
   --  whole global middleware chain and write a response. Zero is unlimited
   --  and is the default, which leaves that surface unmetered. This direct
   --  setter is setup-only and raises Route_Error once the router has
   --  dispatched; use the Update overload after that.
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
   --  This direct setter is setup-only and raises Route_Error once the
   --  router has dispatched; use the Update overload after that.
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
   --  @param Scheme Origin scheme used to receive the request
   procedure Dispatch
     (Item       : in out Router;
      Context    : in out App_Context;
      Connection : aliased in out Flyology.HTTP.Server.Connection;
      Value      : aliased in out Request;
      Peer       : Flyology.IO.Sockets.Endpoint;
      Token      : access Flyology.Cancellation.Token := null;
      Alt_Svc    : String := "";
      Scheme     : Origin_Scheme := Plain_HTTP);

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
   --  @param Scheme Origin scheme used to receive each request
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
      Alt_Svc      : String := "";
      Scheme       : Origin_Scheme := Plain_HTTP);

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
   --  @param Scheme Origin scheme used to receive each request
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
      Alt_Svc            : String := "";
      Scheme             : Origin_Scheme := Plain_HTTP);

   --  Bind one endpoint as TLS/TCP for HTTP/1.1 and HTTP/2 and as UDP for
   --  HTTP/3, then serve every protocol through this router until Token is
   --  requested. TLS_Backend must be a server provider configured to select
   --  h2 or http/1.1. H1/H2 responses advertise the active H3 endpoint with
   --  Alt-Svc; H3 responses do not. Mutable router context must synchronize
   --  access across concurrent protocol workers.
   --  @param Item Router shared by all protocol workers
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
   --  @param Handler_Model Fixed lightweight or native handler designation
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
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   with Pre => Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then Certificate_DER'Length in 1 .. 4_096
     and then HTTP_3_Capacity <= 256
     and then HTTP_3_Max_Requests <= 1_000_000
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
   --  @param Item Router shared by all protocol workers
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
   --  @param Handler_Model Fixed lightweight or native handler designation
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
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   with Pre => IPv4_Endpoint.Family = Flyology.IO.Sockets.IPv4
     and then IPv6_Endpoint.Family = Flyology.IO.Sockets.IPv6
     and then IPv4_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then IPv4_Endpoint.Port = IPv6_Endpoint.Port
     and then Certificate_DER'Length in 1 .. 4_096
     and then TCP_Capacity >= 2
     and then HTTP_3_Capacity in 2 .. 256
     and then HTTP_3_Max_Requests <= 1_000_000
     and then Handshake_Timeout > 0.0
     and then
       (Drain_Timeout = Flyology.IO.Infinite or else Drain_Timeout >= 0.0);

   --  Bind distinct cleartext HTTP/TCP and secure HTTPS TCP+UDP endpoints.
   --  HTTPS serves HTTP/1.1 and HTTP/2 over TLS plus HTTP/3 over QUIC. The
   --  cleartext endpoint either routes HTTP/1.x through the same application
   --  or sends a 308 redirect to HTTPS_Origin without trusting Host. The two
   --  endpoints must use the same address family and different concrete
   --  ports. Capacities are independent totals for cleartext TCP, secure TCP,
   --  and QUIC connections.
   --  @param Item Router shared by all protocol workers
   --  @param Context Shared application context
   --  @param HTTP_Endpoint Cleartext HTTP/TCP endpoint
   --  @param HTTPS_Endpoint Secure TLS/TCP and QUIC/UDP endpoint
   --  @param HTTPS_Origin Configured public redirect origin
   --  @param TLS_Backend Initialized ALPN-capable TLS server provider
   --  @param Certificate_DER DER-encoded Ed25519 HTTP/3 certificate
   --  @param Private_Key Raw Ed25519 HTTP/3 private key
   --  @param Cleartext Cleartext routing or redirect policy
   --  @param Cleartext_Capacity Maximum concurrent cleartext connections
   --  @param TCP_Capacity Maximum concurrent secure H1/H2 connections
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
   --  @param Handler_Model Fixed lightweight or native handler designation
   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      HTTP_Endpoint        : Flyology.IO.Sockets.Endpoint;
      HTTPS_Endpoint       : Flyology.IO.Sockets.Endpoint;
      HTTPS_Origin         : Origin;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Cleartext            : Cleartext_Policy := Redirect_To_HTTPS;
      Cleartext_Capacity   : Positive := 64;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   with Pre => HTTP_Endpoint.Family = HTTPS_Endpoint.Family
     and then HTTP_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then HTTPS_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then HTTP_Endpoint.Port /= HTTPS_Endpoint.Port
     and then Scheme (HTTPS_Origin) = Secure_HTTPS
     and then Certificate_DER'Length in 1 .. 4_096
     and then HTTP_3_Capacity <= 256
     and then HTTP_3_Max_Requests <= 1_000_000
     and then Handshake_Timeout > 0.0
     and then
       (Drain_Timeout = Flyology.IO.Infinite or else Drain_Timeout >= 0.0);

   --  Bind explicit IPv4 and IPv6 cleartext and secure endpoints. Each pair
   --  uses one shared port across address families, while HTTP and HTTPS use
   --  different ports. Capacity values are totals divided between families.
   --  @param Item Router shared by all protocol workers
   --  @param Context Shared application context
   --  @param IPv4_HTTP_Endpoint IPv4 cleartext HTTP/TCP endpoint
   --  @param IPv6_HTTP_Endpoint IPv6 cleartext HTTP/TCP endpoint
   --  @param IPv4_HTTPS_Endpoint IPv4 TLS/TCP and QUIC/UDP endpoint
   --  @param IPv6_HTTPS_Endpoint IPv6 TLS/TCP and QUIC/UDP endpoint
   --  @param HTTPS_Origin Configured public redirect origin
   --  @param TLS_Backend Initialized ALPN-capable TLS server provider
   --  @param Certificate_DER DER-encoded Ed25519 HTTP/3 certificate
   --  @param Private_Key Raw Ed25519 HTTP/3 private key
   --  @param Cleartext Cleartext routing or redirect policy
   --  @param Cleartext_Capacity Total concurrent cleartext connections
   --  @param TCP_Capacity Total concurrent secure H1/H2 connections
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
   --  @param Handler_Model Fixed lightweight or native handler designation
   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      IPv4_HTTP_Endpoint   : Flyology.IO.Sockets.Endpoint;
      IPv6_HTTP_Endpoint   : Flyology.IO.Sockets.Endpoint;
      IPv4_HTTPS_Endpoint  : Flyology.IO.Sockets.Endpoint;
      IPv6_HTTPS_Endpoint  : Flyology.IO.Sockets.Endpoint;
      HTTPS_Origin         : Origin;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Cleartext            : Cleartext_Policy := Redirect_To_HTTPS;
      Cleartext_Capacity   : Positive := 64;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   with Pre => IPv4_HTTP_Endpoint.Family = Flyology.IO.Sockets.IPv4
     and then IPv6_HTTP_Endpoint.Family = Flyology.IO.Sockets.IPv6
     and then IPv4_HTTPS_Endpoint.Family = Flyology.IO.Sockets.IPv4
     and then IPv6_HTTPS_Endpoint.Family = Flyology.IO.Sockets.IPv6
     and then IPv4_HTTP_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then IPv4_HTTP_Endpoint.Port = IPv6_HTTP_Endpoint.Port
     and then IPv4_HTTPS_Endpoint.Port /= Flyology.IO.Sockets.Any_Port
     and then IPv4_HTTPS_Endpoint.Port = IPv6_HTTPS_Endpoint.Port
     and then IPv4_HTTP_Endpoint.Port /= IPv4_HTTPS_Endpoint.Port
     and then Scheme (HTTPS_Origin) = Secure_HTTPS
     and then Certificate_DER'Length in 1 .. 4_096
     and then Cleartext_Capacity >= 2
     and then TCP_Capacity >= 2
     and then HTTP_3_Capacity in 2 .. 256
     and then HTTP_3_Max_Requests <= 1_000_000
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
      Max_Requests       : Positive := 100_000;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000_000;

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
      Max_Requests       : Positive := 100_000;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000_000
     and then Source.Length in 1 ..
       Flyology.QUIC.Connections.Max_Connection_ID_Length;

   --  Serve multiple concurrent HTTP/3 connections through this router on an
   --  unconnected bound UDP socket until Token is requested.
   --  @param Item Router shared by all connection workers
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
      Max_Requests       : Positive := 100_000;
      Token              : not null access Flyology.Cancellation.Token)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Capacity <= 256
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= 1_000_000;

private
   use Ada.Strings.Unbounded;

   type Route_ID is new Interfaces.Unsigned_64;
   No_Route : constant Route_ID := 0;

   type Middleware_ID is new Interfaces.Unsigned_64;
   No_Middleware : constant Middleware_ID := 0;

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
      ID        : Middleware_ID := No_Middleware;
      Component : Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : Unbounded_String;
   end record;
   type Middleware_Array is
     array (Positive range <>) of Middleware_Entry;

   --  Registration compiles each pattern into bounded segment storage so
   --  dispatch does not split and allocate the same pattern per request.
   type Route_Entry is record
      ID                  : Route_ID := No_Route;
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

   type Router_Configuration;

   --  General access so an address recovered from the published atomic word
   --  converts without an unchecked conversion.
   type Configuration_Access is access all Router_Configuration;

   type Router_Configuration
     (Capacity : Positive;
      Slashes  : Trailing_Slash_Policy)
   is record
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
      --  Retired generations stay reachable through this chain, so a
      --  dispatch holding an older generation never reads freed storage.
      Previous              : Configuration_Access;
   end record;

   type Atomic_Word is new Interfaces.Unsigned_64
     with Size => 64, Alignment => 8;

   protected type Publication_Gate is
      procedure Initialize (Configuration : Configuration_Access);
      procedure Try_Publish
        (Expected : Configuration_Access;
         Desired  : Configuration_Access;
         Accepted : out Boolean);
   private
      Latest : Configuration_Access;
   end Publication_Gate;

   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is new Ada.Finalization.Limited_Controlled with record
      Current_Configuration : aliased Atomic_Word := 0;
      --  Set by the first dispatch. Direct registration writes the published
      --  generation in place, so it is refused once this is set.
      Sealed                : aliased Atomic_Word := 0;
      First_Configuration   : Configuration_Access;
      Publisher             : Publication_Gate;
   end record;

   overriding procedure Initialize (Item : in out Router);
   overriding procedure Finalize (Item : in out Router);

   type Update_State is new Ada.Finalization.Limited_Controlled with record
      Owner     : System.Address := System.Null_Address;
      Base      : Configuration_Access;
      Candidate : Configuration_Access;
   end record;

   overriding procedure Finalize (Item : in out Update_State);

   type Update is limited record
      State : Update_State;
   end record;

   type Snapshot_State is new Ada.Finalization.Limited_Controlled with record
      Configuration : Configuration_Access;
   end record;

   overriding procedure Finalize (Item : in out Snapshot_State);

   type Snapshot is limited record
      State : Snapshot_State;
   end record;

end Flyology.HTTP.Server.Routing;
