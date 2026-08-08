with Flyology.IO;
with Flyology.IO.Sockets;

--  Synchronous connected-datagram I/O for QUIC connections.
--
--  Flyology suspends lightweight callers and blocks native callers behind the
--  same Ada call. A receive performs one protocol transition; callers send the
--  returned bounded response flight on the same connected socket.
package Flyology.QUIC.Connections.IO is

   --  Send every populated datagram in a bounded response flight.
   --  @param Socket Connected UDP socket
   --  @param Output Datagrams to transmit in order
   --  @param Timeout Maximum wait for each datagram send
   --  @exception Device_Error A datagram send is partial
   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Output  : Datagram_Batch;
      Timeout : Duration := Flyology.IO.Infinite);

   --  Send one populated datagram.
   --  @param Socket Connected UDP socket
   --  @param Packet Datagram to transmit
   --  @param Timeout Maximum wait for the send
   --  @exception Device_Error The datagram send is partial
   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Packet  : Datagram;
      Timeout : Duration := Flyology.IO.Infinite);

   --  Receive and process one UDP payload.
   --  @param Socket Connected UDP socket
   --  @param Item Connection that owns packet and TLS state
   --  @param Output Immediate response flight
   --  @param Status Protocol transition outcome
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Timeout Maximum wait for the receive
   procedure Receive
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection;
      Output  : out Datagram_Batch;
      Status  : out Operation_Status;
      Now     : Timestamp := 0;
      Timeout : Duration := Flyology.IO.Infinite);
end Flyology.QUIC.Connections.IO;
