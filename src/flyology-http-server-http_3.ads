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
generic
   type App_Context is limited private;
   with procedure Handle
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange);
package Flyology.HTTP.Server.HTTP_3 is

   --  Conservative request count available after the peer's mandatory HTTP/3
   --  unidirectional streams occupy the current bounded QUIC stream table.
   Maximum_Requests_Per_Connection : constant Positive := 5;

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
      Max_Requests       : Positive := Maximum_Requests_Per_Connection;
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
      Max_Requests       : Positive := Maximum_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null)
   with Pre => Flyology.IO.Sockets.Is_Open (Socket)
     and then Certificate_DER'Length in 1 .. 4_096
     and then Handshake_Timeout > 0.0
     and then Max_Requests <= Maximum_Requests_Per_Connection
     and then Source.Length in 1 ..
       Flyology.QUIC.Connections.Max_Connection_ID_Length;

end Flyology.HTTP.Server.HTTP_3;
