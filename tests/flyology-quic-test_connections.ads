with Ada.Streams;
with Flyology.QUIC.Connections;

package Flyology.QUIC.Test_Connections is
   procedure Initialize_Client
     (Client : in out Flyology.QUIC.Connections.Connection);

   type Server_Initialize_Status is
     (Initialized, Not_A_V1_Initial, Parameter_Error);

   procedure Initialize_Server_From_Initial
     (Server : in out Flyology.QUIC.Connections.Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Status : out Server_Initialize_Status);

   procedure Connect
     (Client : in out Flyology.QUIC.Connections.Connection;
      Server : in out Flyology.QUIC.Connections.Connection);

   procedure Deliver
     (Packet : Flyology.QUIC.Connections.Datagram;
      Target : in out Flyology.QUIC.Connections.Connection);
end Flyology.QUIC.Test_Connections;
