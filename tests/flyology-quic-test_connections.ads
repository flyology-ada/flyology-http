with Ada.Streams;
with Flyology.QUIC.Connections;

package Flyology.QUIC.Test_Connections is
   function Server_Certificate return Ada.Streams.Stream_Element_Array;

   function Server_Private_Key
      return Flyology.QUIC.Connections.Ed25519_Private_Key;

   function Server_Connection_ID
      return Flyology.QUIC.Connections.Connection_ID;

   procedure Initialize_Client
     (Client : in out Flyology.QUIC.Connections.Connection);

   procedure Initialize_Server_From_Initial
     (Server : in out Flyology.QUIC.Connections.Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Status : out Flyology.QUIC.Connections.Server_Initialize_Status);

   procedure Connect
     (Client : in out Flyology.QUIC.Connections.Connection;
      Server : in out Flyology.QUIC.Connections.Connection);

   procedure Deliver
     (Packet : Flyology.QUIC.Connections.Datagram;
      Target : in out Flyology.QUIC.Connections.Connection);
end Flyology.QUIC.Test_Connections;
