with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.QUIC.Application_Space;
with Flyology.QUIC.Connection_Driver;

--  Internal synchronous socket adapter for the packet-driven QUIC state.
--  Flyology sockets suspend lightweight callers and block native callers with
--  the same Ada call semantics; protocol state remains independent of I/O.
private package Flyology.QUIC.Connection_IO is
   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Output  : Connection_Driver.Datagram_Batch;
      Timeout : Duration := Flyology.IO.Infinite);

   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Packet  : Connection_Driver.Datagram;
      Timeout : Duration := Flyology.IO.Infinite);

   procedure Receive
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection_Driver.Connection;
      Output  : out Connection_Driver.Datagram_Batch;
      Result  : out Connection_Driver.Operation_Result;
      Now     : Application_Space.Timestamp := 0;
      Timeout : Duration := Flyology.IO.Infinite);
end Flyology.QUIC.Connection_IO;
