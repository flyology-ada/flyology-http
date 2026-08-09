with Ada.Streams;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections;

--  Serves one HTTP/3 connection through the high-level application exchange
--  API. The caller supplies an exclusively owned, bound UDP socket. Serve
--  receives the first client Initial, connects the socket to that peer, and
--  owns QUIC and HTTP/3 protocol state until the connection ends.
--  @formal App_Context Application-owned context shared by request handlers
--  @formal Handle Synchronous application dispatcher for one request stream
--  @formal Handler_Model Fixed lightweight or native worker designation
generic
   type App_Context is limited private;
   with procedure Handle
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange);
   Handler_Model : Flyology.Execution_Model := Flyology.Project_Default;
package Flyology.HTTP.Server.HTTP_3 is

   --  Default listener capacity for the task-per-connection profile.
   Default_Connection_Capacity : constant Positive := 128;
   --  Largest accepted listener capacity for the task-per-connection profile.
   Maximum_Connection_Capacity : constant Positive := 256;

   --  Default lifetime request policy. Completed request reassembly is
   --  recycled; 32 retained QUIC streams bound concurrency, while compact
   --  flow-control accounting supports long-lived connections without
   --  retaining completed request state.
   Default_Requests_Per_Connection : constant Positive := 100_000;
   --  Largest accepted lifetime request policy for the bounded profile.
   Maximum_Requests_Per_Connection : constant Positive := 1_000_000;

   --  Run a bounded multi-connection HTTP/3 listener on an unconnected bound
   --  UDP socket. One receiver dispatches datagrams by connection identifier
   --  to Capacity fixed worker tasks. The caller requests shutdown through
   --  Token; Serve_Listener then drains its workers and returns without
   --  closing Socket.
   --  @param Context Shared application context; mutable parts synchronize
   --  @param Socket Exclusively owned bound UDP listener
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Capacity Maximum concurrent QUIC connections
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish each QUIC connection
   --  @param Max_Connection_Age Absolute lifetime of each connection
   --  @param Max_Requests Requests served by each connection
   --  @param Token Required listener shutdown and connection cancellation
   procedure Serve_Listener
     (Context            : aliased in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Capacity           : Positive := Default_Connection_Capacity;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : not null access Flyology.Cancellation.Token)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Capacity <= Maximum_Connection_Capacity
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= Maximum_Requests_Per_Connection;

   --  Serve routed requests from one QUIC peer using a securely generated
   --  server connection identifier. This is the ordinary application entry
   --  point; use the Source overload when identifier ownership belongs to an
   --  external connection manager.
   --  @param Context Shared application context
   --  @param Socket Exclusively owned bound UDP socket
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish QUIC
   --  @param Max_Connection_Age Absolute connection lifetime; negative is
   --    unlimited
   --  @param Max_Requests Requests served before Serve returns
   --  @param Token Optional connection cancellation source
   procedure Serve
     (Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= Maximum_Requests_Per_Connection;

   --  Serve routed requests from one QUIC peer. Certificate_DER and
   --  Private_Key form the Ed25519 server identity used by the Ada-native QUIC
   --  handshake. Source must be a fresh server connection identifier.
   --  Operations retain ordinary synchronous Ada semantics in native and
   --  lightweight task lanes.
   --  @param Context Shared application context
   --  @param Socket Exclusively owned bound UDP socket
   --  @param Certificate_DER DER-encoded Ed25519 server certificate
   --  @param Private_Key Raw Ed25519 private key for Certificate_DER
   --  @param Source Fresh server source connection identifier
   --  @param Transport_Settings QUIC flow-control and stream limits
   --  @param Timeout Per-request application deadline
   --  @param Handshake_Timeout Maximum time to establish QUIC
   --  @param Max_Connection_Age Absolute connection lifetime; negative is
   --    unlimited
   --  @param Max_Requests Requests served before Serve returns
   --  @param Token Optional connection cancellation source
   procedure Serve
     (Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Source             : Flyology.QUIC.Connections.Connection_ID;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= Maximum_Requests_Per_Connection
     and then Source.Length in 1 ..
       Flyology.QUIC.Connections.Max_Connection_ID_Length;

end Flyology.HTTP.Server.HTTP_3;
