with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;

--  Serves multiplexed HTTP/2 streams through the high-level application
--  exchange API. The owning connection may be plaintext prior knowledge or
--  an ALPN-negotiated TLS connection.
--  @formal App_Context Application-owned context shared by stream handlers
--  @formal Handle Synchronous application dispatcher for one request stream
generic
   type App_Context is limited private;
   with procedure Handle
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange);
package Flyology.HTTP.Server.HTTP_2 is

   --  Maximum active streams admitted on one server connection.
   Maximum_Concurrent_Streams : constant Positive := 32;

   --  Validate the client preface and serve streams until peer closure,
   --  cancellation, connection failure, or the configured age bound. Each
   --  admitted stream invokes Handle in a lightweight task; application body
   --  and response calls retain synchronous deadline and backpressure
   --  semantics.
   --  @param Context Shared application context
   --  @param Channel Sole owning plaintext or TLS Flyology connection
   --  @param Peer Connected peer endpoint
   --  @param Timeout Per-stream application deadline
   --  @param Max_Connection_Age Connection deadline; negative is unlimited
   --  @param Token Optional connection cancellation source
   --  @param Scheme Origin scheme used to receive streams on this connection
   procedure Serve
     (Context            : in out App_Context;
      Channel            : in out Flyology.IO.Connections.Connection;
      Peer               : Flyology.IO.Sockets.Endpoint;
      Timeout            : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Token              : access Flyology.Cancellation.Token := null;
      Scheme             : Flyology.HTTP.Origin_Scheme :=
        Flyology.HTTP.Plain_HTTP);

end Flyology.HTTP.Server.HTTP_2;
