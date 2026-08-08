with Ada.IO_Exceptions;
with Ada.Streams;
with Flyology.IO;

package body Flyology.QUIC.Connection_IO is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Packet  : Connection_Driver.Datagram;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      if Packet.Length = 0 then
         return;
      end if;
      Flyology.IO.Sockets.Send
        (Socket,
         Packet.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Last, Timeout);
      if Last /= Ada.Streams.Stream_Element_Offset (Packet.Length) then
         raise Ada.IO_Exceptions.Device_Error with
           "partial QUIC datagram send";
      end if;
   end Send;

   procedure Send
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Output  : Connection_Driver.Datagram_Batch;
      Timeout : Duration := Flyology.IO.Infinite) is
   begin
      for Index in 1 .. Output.Count loop
         Send (Socket, Output.Items (Index), Timeout);
      end loop;
   end Send;

   procedure Receive
     (Socket  : Flyology.IO.Sockets.Socket_Type;
      Item    : in out Connection_Driver.Connection;
      Output  : out Connection_Driver.Datagram_Batch;
      Result  : out Connection_Driver.Operation_Result;
      Now     : Application_Space.Timestamp := 0;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Packet : Ada.Streams.Stream_Element_Array
        (1 .. Connection_Driver.Max_Datagram_Length);
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Flyology.IO.Sockets.Receive (Socket, Packet, Last, Timeout);
      if Last < Packet'First then
         Output := (others => <>);
         Result := (Status => Connection_Driver.Packet_Error, others => <>);
         return;
      end if;
      Connection_Driver.Process_Datagram
        (Item, Packet (Packet'First .. Last), Output, Result, Now);
   end Receive;
end Flyology.QUIC.Connection_IO;
