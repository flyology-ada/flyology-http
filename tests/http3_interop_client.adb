with Ada.Command_Line;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.HTTP.HTTP_3;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections.IO;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Interop_Client is
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;

   use type Ada.Streams.Stream_Element;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Operation_Status;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count = 0 then 4_433
      else Sockets.Port'Value (Ada.Command_Line.Argument (1)));

   Socket    : Sockets.Socket_Type;
   Transport : QUIC.Connection;
   Session   : H3.Session;
   Flight    : QUIC.Datagram_Batch;
   Status    : QUIC.Operation_Status;

   procedure Send (Packet : QUIC.Datagram) is
   begin
      QUIC_IO.Send (Socket, Packet, Timeout => 2.0);
   end Send;

   procedure Receive_One is
   begin
      QUIC_IO.Receive
        (Socket, Transport, Flight, Status, Timeout => 2.0);
      Ada.Text_IO.Put_Line
        ("QUIC receive: " & QUIC.Operation_Status'Image (Status)
         & ", state=" & QUIC.Connection_State'Image (QUIC.State (Transport))
         & ", output=" & Natural'Image (Flight.Count));
      if Status not in QUIC.Succeeded | QUIC.Waiting_For_More then
         raise Program_Error with "QUIC oracle receive failed";
      end if;
      QUIC_IO.Send (Socket, Flight, Timeout => 2.0);
   end Receive_One;
begin
   Flyology.QUIC.Test_Connections.Initialize_Client (Transport);
   Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Socket, Sockets.Network_Endpoint
        (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Connect_Socket
     (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));

   QUIC.Start_Client (Transport, Flight, Status);
   if Status /= QUIC.Succeeded then
      raise Program_Error with "QUIC oracle client did not start";
   end if;
   QUIC_IO.Send (Socket, Flight, Timeout => 2.0);

   for Attempt in 1 .. 8 loop
      exit when QUIC.Is_Connected (Transport);
      Receive_One;
   end loop;
   if not QUIC.Is_Connected (Transport) then
      raise Program_Error with "QUIC oracle handshake did not complete";
   end if;

   H3.Initialize (Session, H3.Client);
   declare
      Control   : QUIC.Datagram;
      H3_Status : H3.Operation_Status;
   begin
      H3.Start
        (Session, Transport, Now => 1_000,
         Packet => Control, Status => H3_Status);
      if H3_Status /= H3.Succeeded then
         raise Program_Error with "HTTP/3 control stream did not start";
      end if;
      Send (Control);
   end;

   declare
      Headers   : H3.Header_Block;
      Stream    : QUIC.Stream_ID;
      Packet    : QUIC.Datagram;
      H3_Status : H3.Operation_Status;
   begin
      H3.Append (Headers, H3.Make_Field (":method", "GET"));
      H3.Append (Headers, H3.Make_Field (":scheme", "https"));
      H3.Append (Headers, H3.Make_Field (":path", "/hello"));
      H3.Append
        (Headers, H3.Make_Field (":authority", "localhost:4433"));
      H3.Open_Request (Session, Transport, Stream, H3_Status);
      if H3_Status /= H3.Succeeded then
         raise Program_Error with "HTTP/3 request stream did not open";
      end if;
      H3.Send_Headers
        (Session, Transport, Stream, Headers, Fin => True, Now => 2_000,
         Packet => Packet, Status => H3_Status);
      if H3_Status /= H3.Succeeded then
         raise Program_Error with "HTTP/3 request HEADERS did not encode";
      end if;
      Send (Packet);
   end;

   declare
      Item       : H3.Event;
      H3_Status  : H3.Operation_Status;
      Saw_Status : Boolean := False;
      Saw_Hello  : Boolean := False;
   begin
      for Attempt in 1 .. 16 loop
         Receive_One;
         loop
            H3.Poll (Session, Transport, Item, H3_Status);
            exit when H3_Status = H3.No_Event;
            if H3_Status /= H3.Succeeded then
               raise Program_Error with
                 "HTTP/3 oracle response failed: "
                 & H3.Operation_Status'Image (H3_Status);
            elsif Item.Kind = H3.Headers_Received then
               for Index in 1 .. H3.Header_Count (Item.Headers) loop
                  if H3.Field_Name (H3.Field_At (Item.Headers, Index)) =
                       ":status"
                    and then
                      H3.Field_Value (H3.Field_At (Item.Headers, Index)) =
                        "200"
                  then
                     Saw_Status := True;
                  end if;
               end loop;
            elsif Item.Kind = H3.Data_Received
              and then Item.Data_Length = 5
              and then Item.Data (1) = Character'Pos ('h')
              and then Item.Data (2) = Character'Pos ('e')
              and then Item.Data (3) = Character'Pos ('l')
              and then Item.Data (4) = Character'Pos ('l')
              and then Item.Data (5) = Character'Pos ('o')
            then
               Saw_Hello := True;
            end if;
         end loop;
         exit when Saw_Status and Saw_Hello;
      end loop;
      if not Saw_Status or else not Saw_Hello then
         raise Program_Error with "incomplete HTTP/3 oracle response";
      end if;
   end;

   Ada.Text_IO.Put_Line
     ("Ada HTTP/3 client interoperated with an independent oracle");
   Sockets.Close_Socket (Socket);
exception
   when Ada.IO_Exceptions.End_Error =>
      raise Program_Error with "HTTP/3 oracle timed out";
end HTTP3_Interop_Client;
