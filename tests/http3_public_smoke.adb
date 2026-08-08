with Ada.Streams;
with Flyology.HTTP.HTTP_3;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Public_Smoke is
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Stream_Offset;

   Client_Transport, Server_Transport : QUIC.Connection;
   Client, Server : H3.Session;
   Client_Control, Server_Control : QUIC.Datagram;
   Client_Event, Server_Event : H3.Event;
   Client_Status, Server_Status : H3.Operation_Status;
begin
   pragma Assert (QUIC.Max_Tracked_Streams = 1_024);
   declare
      Defaults : constant QUIC.Transport_Settings := (others => <>);
   begin
      pragma Assert
        (Defaults.Max_Streams_Bidi = 29
         and then Defaults.Max_Streams_Uni = 3
         and then Defaults.Max_Data = 524_288);
   end;

   declare
      First  : constant QUIC.Connection_ID := QUIC.Random_Connection_ID;
      Second : constant QUIC.Connection_ID := QUIC.Random_Connection_ID;
   begin
      pragma Assert
        (First.Length = 8
         and then Second.Length = 8
         and then First.Data (1 .. 8) /= Second.Data (1 .. 8));
   end;

   Flyology.QUIC.Test_Connections.Connect
     (Client_Transport, Server_Transport);
   H3.Initialize (Client, H3.Client);
   H3.Initialize
     (Server, H3.Server,
      (Has_Max_Field_Size => True, Max_Field_Size => 200));

   H3.Start
     (Client, Client_Transport, Now => 1_000,
      Packet => Client_Control, Status => Client_Status);
   H3.Start
     (Server, Server_Transport, Now => 1_000,
      Packet => Server_Control, Status => Server_Status);
   pragma Assert
     (Client_Status = H3.Succeeded and then Server_Status = H3.Succeeded);

   Flyology.QUIC.Test_Connections.Deliver
     (Client_Control, Server_Transport);
   Flyology.QUIC.Test_Connections.Deliver
     (Server_Control, Client_Transport);
   H3.Poll (Server, Server_Transport, Server_Event, Server_Status);
   H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
   pragma Assert
     (Server_Status = H3.Succeeded
      and then Server_Event.Kind = H3.Settings_Received
      and then H3.Has_Peer_Settings (Server));
   pragma Assert
     (Client_Status = H3.Succeeded
      and then Client_Event.Kind = H3.Settings_Received
      and then H3.Has_Peer_Settings (Client)
      and then H3.Peer_Settings (Client).Has_Max_Field_Size
      and then H3.Peer_Settings (Client).Max_Field_Size = 200);

   declare
      Request_Headers  : H3.Header_Block;
      Response_Headers : H3.Header_Block;
      Request_Stream   : QUIC.Stream_ID;
      Request_Packet, Response_Packet, Data_Packet : QUIC.Datagram;
   begin
      H3.Append (Request_Headers, H3.Make_Field (":method", "GET"));
      H3.Append (Request_Headers, H3.Make_Field (":scheme", "https"));
      H3.Append (Request_Headers, H3.Make_Field (":path", "/hello"));
      H3.Append
        (Request_Headers, H3.Make_Field (":authority", "example.com"));
      H3.Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      declare
         Too_Large : H3.Header_Block := Request_Headers;
      begin
         H3.Append (Too_Large, H3.Make_Field ("x-extra", "overflow"));
         H3.Send_Headers
           (Client, Client_Transport, Request_Stream, Too_Large,
            Fin => True, Now => 1_999, Packet => Request_Packet,
            Status => Client_Status);
         pragma Assert
           (Client_Status = H3.Peer_Field_Section_Too_Large
            and then Request_Packet.Length = 0);
      end;
      H3.Send_Headers
        (Client, Client_Transport, Request_Stream, Request_Headers,
         Fin => True, Now => 2_000, Packet => Request_Packet,
         Status => Client_Status);
      pragma Assert (Client_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      H3.Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = H3.Succeeded
         and then Server_Event.Kind = H3.Headers_Received
         and then H3.Header_Count (Server_Event.Headers) = 4);
      H3.Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = H3.Succeeded
         and then Server_Event.Kind = H3.Stream_Ended
         and then Server_Event.Stream = Request_Stream);

      H3.Append (Response_Headers, H3.Make_Field (":status", "200"));
      H3.Send_Headers
        (Server, Server_Transport, Request_Stream, Response_Headers,
         Fin => False, Now => 3_000, Packet => Response_Packet,
         Status => Server_Status);
      pragma Assert (Server_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Response_Packet, Client_Transport);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Headers_Received
         and then H3.Field_Value
           (H3.Field_At (Client_Event.Headers, 1)) = "200");

      H3.Send_Data
        (Server, Server_Transport, Request_Stream,
         Ada.Streams.Stream_Element_Array'
           (16#68#, 16#65#, 16#6C#, 16#6C#, 16#6F#),
         Fin => True, Now => 4_000, Packet => Data_Packet,
         Status => Server_Status);
      pragma Assert (Server_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Data_Packet, Client_Transport);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Data_Received
         and then Client_Event.Data_Length = 5
         and then Client_Event.Data (1) = 16#68#
         and then Client_Event.Data (5) = 16#6F#);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Stream_Ended
         and then Client_Event.Stream = Request_Stream);

      H3.Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert (Client_Status = H3.Succeeded);
      H3.Cancel_Request
        (Client, Client_Transport, Request_Stream,
         Reason => H3.Cancel_Processing, Now => 4_100,
         Packet => Request_Packet, Status => Client_Status);
      pragma Assert (Client_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      H3.Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = H3.Succeeded
         and then Server_Event.Kind = H3.Stream_Reset
         and then Server_Event.Stream = Request_Stream
         and then Server_Event.Application_Error =
           H3.H3_Request_Cancelled);

      H3.Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert (Client_Status = H3.Succeeded);
      H3.Send_Headers
        (Client, Client_Transport, Request_Stream, Request_Headers,
         Fin => False, Now => 4_200, Packet => Request_Packet,
         Status => Client_Status);
      pragma Assert (Client_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      H3.Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = H3.Succeeded
         and then Server_Event.Kind = H3.Headers_Received);
      H3.Cancel_Request
        (Server, Server_Transport, Request_Stream,
         Reason => H3.Reject_Unprocessed, Now => 4_300,
         Packet => Response_Packet, Status => Server_Status);
      pragma Assert (Server_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Response_Packet, Client_Transport);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Stream_Reset
         and then Client_Event.Stream = Request_Stream
         and then Client_Event.Application_Error =
           H3.H3_Request_Rejected);

      H3.Send_Goaway
        (Server, Server_Transport, Identifier => 4, Now => 5_000,
         Packet => Data_Packet, Status => Server_Status);
      pragma Assert (Server_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Data_Packet, Client_Transport);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Goaway_Received
         and then Client_Event.Identifier = 4
         and then H3.Has_Peer_Goaway (Client)
         and then H3.Peer_Goaway_ID (Client) = 4);
      H3.Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert (Client_Status = H3.Connection_Draining);

      H3.Send_Goaway
        (Server, Server_Transport, Identifier => 8, Now => 5_001,
         Packet => Data_Packet, Status => Server_Status);
      pragma Assert
        (Server_Status = H3.ID_Error and then Data_Packet.Length = 0);
      H3.Send_Goaway
        (Server, Server_Transport, Identifier => 0, Now => 5_002,
         Packet => Data_Packet, Status => Server_Status);
      pragma Assert (Server_Status = H3.Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Data_Packet, Client_Transport);
      H3.Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = H3.Succeeded
         and then Client_Event.Kind = H3.Goaway_Received
         and then Client_Event.Identifier = 0
         and then H3.Peer_Goaway_ID (Client) = 0);
   end;
end HTTP3_Public_Smoke;
