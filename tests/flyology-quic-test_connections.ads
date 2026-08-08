with Flyology.QUIC.Connections;

package Flyology.QUIC.Test_Connections is
   procedure Initialize_Client
     (Client : in out Flyology.QUIC.Connections.Connection);

   procedure Connect
     (Client : in out Flyology.QUIC.Connections.Connection;
      Server : in out Flyology.QUIC.Connections.Connection);

   procedure Deliver
     (Packet : Flyology.QUIC.Connections.Datagram;
      Target : in out Flyology.QUIC.Connections.Connection);
end Flyology.QUIC.Test_Connections;
