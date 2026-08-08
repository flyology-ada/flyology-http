with Ada.Command_Line;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.HTTP.HTTP_3;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Connections.IO;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Interop_Server is
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Streams.Stream_Element_Offset;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Operation_Status;
   use type QUIC.Server_Initialize_Status;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count = 0 then 4_434
      else Sockets.Port'Value (Ada.Command_Line.Argument (1)));

   Socket    : Sockets.Socket_Type;
   Peer      : Sockets.Endpoint;
   Packet    : Ada.Streams.Stream_Element_Array (1 .. QUIC.Max_Datagram_Length);
   Last      : Ada.Streams.Stream_Element_Offset;
   Transport : QUIC.Connection;
   Flight    : QUIC.Datagram_Batch;
   Status    : QUIC.Operation_Status;

   procedure Send_To_Peer (Output : QUIC.Datagram_Batch) is
      Sent : Ada.Streams.Stream_Element_Offset;
   begin
      for Index in 1 .. Output.Count loop
         Sockets.Send_Socket
           (Socket,
            Output.Items (Index).Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Output.Items (Index).Length)),
            Sent, Peer);
         if Sent /= Ada.Streams.Stream_Element_Offset
              (Output.Items (Index).Length)
         then
            raise Program_Error with "partial QUIC oracle datagram";
         end if;
      end loop;
   end Send_To_Peer;

   procedure Receive_One is
   begin
      QUIC_IO.Receive
        (Socket, Transport, Flight, Status, Timeout => 2.0);
      if Status not in QUIC.Succeeded | QUIC.Waiting_For_More then
         raise Program_Error with
           "QUIC oracle receive failed: " & QUIC.Operation_Status'Image (Status);
      end if;
      QUIC_IO.Send (Socket, Flight, Timeout => 2.0);
   end Receive_One;
begin
   Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Ada.Text_IO.Put_Line
     ("Ada HTTP/3 oracle listening on 127.0.0.1:"
      & Sockets.Port'Image (Port));
   Ada.Text_IO.Flush;

   Sockets.Receive_Socket (Socket, Packet, Last, Peer);
   if Last < Packet'First then
      raise Program_Error with "empty QUIC Initial";
   end if;
   declare
      Initialized : QUIC.Server_Initialize_Status;
   begin
      Fixtures.Initialize_Server_From_Initial
        (Transport, Packet (Packet'First .. Last), Initialized);
      if Initialized /= QUIC.Initialized then
         raise Program_Error with
           "failed to initialize QUIC oracle server: "
           & QUIC.Server_Initialize_Status'Image (Initialized);
      end if;
   end;
   QUIC.Process_Datagram
     (Transport, Packet (Packet'First .. Last), Flight, Status);
   if Status /= QUIC.Succeeded then
      raise Program_Error with
        "failed to process client Initial: "
        & QUIC.Operation_Status'Image (Status);
   end if;
   Send_To_Peer (Flight);
   Sockets.Connect_Socket (Socket, Peer);

   for Attempt in 1 .. 8 loop
      exit when QUIC.Is_Connected (Transport);
      Receive_One;
   end loop;
   if not QUIC.Is_Connected (Transport) then
      raise Program_Error with "QUIC oracle handshake did not complete";
   end if;

   declare
      Session    : H3.Session;
      Control    : QUIC.Datagram;
      H3_Status  : H3.Operation_Status;
      Item       : H3.Event;
      Request_ID : QUIC.Stream_ID := 0;
      Saw_Request : Boolean := False;
   begin
      H3.Initialize (Session, H3.Server);
      H3.Start
        (Session, Transport, Now => 1_000,
         Packet => Control, Status => H3_Status);
      if H3_Status /= H3.Succeeded then
         raise Program_Error with "HTTP/3 server control stream failed";
      end if;
      QUIC_IO.Send (Socket, Control, Timeout => 2.0);

      for Attempt in 1 .. 16 loop
         Receive_One;
         loop
            H3.Poll (Session, Transport, Item, H3_Status);
            exit when H3_Status = H3.No_Event;
            if H3_Status /= H3.Succeeded then
               raise Program_Error with
                 "HTTP/3 oracle request failed: "
                 & H3.Operation_Status'Image (H3_Status);
            elsif Item.Kind = H3.Headers_Received then
               Request_ID := Item.Stream;
               Saw_Request := True;
            end if;
         end loop;
         exit when Saw_Request;
      end loop;
      if not Saw_Request then
         raise Program_Error with "HTTP/3 oracle request was not received";
      end if;

      declare
         Headers : H3.Header_Block;
         Response, Data : QUIC.Datagram;
      begin
         H3.Append (Headers, H3.Make_Field (":status", "200"));
         H3.Append (Headers, H3.Make_Field ("content-length", "5"));
         H3.Send_Headers
           (Session, Transport, Request_ID, Headers,
            Fin => False, Now => 2_000, Packet => Response,
            Status => H3_Status);
         if H3_Status /= H3.Succeeded then
            raise Program_Error with "HTTP/3 response HEADERS failed";
         end if;
         QUIC_IO.Send (Socket, Response, Timeout => 2.0);
         H3.Send_Data
           (Session, Transport, Request_ID,
            Ada.Streams.Stream_Element_Array'
              (16#68#, 16#65#, 16#6C#, 16#6C#, 16#6F#),
            Fin => True, Now => 3_000, Packet => Data,
            Status => H3_Status);
         if H3_Status /= H3.Succeeded then
            raise Program_Error with "HTTP/3 response DATA failed";
         end if;
         QUIC_IO.Send (Socket, Data, Timeout => 2.0);
      end;
   end;
   Ada.Text_IO.Put_Line ("Ada HTTP/3 server interoperated with aioquic");
   Sockets.Close_Socket (Socket);
end HTTP3_Interop_Server;
