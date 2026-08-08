with Ada.IO_Exceptions;
with Ada.Streams;

package body Flyology.QUIC.Connections.IO is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Packet  : Datagram;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      if Packet.Length = 0 then
         return;
      end if;
      Flyology.IO.Sockets.Send
        (Socket,
         Packet.Data (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Last, Timeout);
      if Last /= Ada.Streams.Stream_Element_Offset (Packet.Length) then
         raise Ada.IO_Exceptions.Device_Error with
           "partial QUIC datagram send";
      end if;
   end Send;

   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Output  : Datagram_Batch;
      Timeout : Duration := Flyology.IO.Infinite) is
   begin
      for Index in 1 .. Output.Count loop
         Send (Socket, Output.Items (Index), Timeout);
      end loop;
   end Send;

   procedure Receive
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection;
      Output  : out Datagram_Batch;
      Status  : out Operation_Status;
      Now     : Timestamp := 0;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Flyology.IO.Sockets.Receive (Socket, Packet, Last, Timeout);
      if Last < Packet'First then
         Output := (others => <>);
         Status := Packet_Error;
         return;
      end if;
      Process_Datagram
        (Item, Packet (Packet'First .. Last), Output, Status, Now);
   end Receive;
end Flyology.QUIC.Connections.IO;
