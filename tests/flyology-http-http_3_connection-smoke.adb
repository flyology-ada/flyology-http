with Flyology.QUIC.Test_Connections;

procedure Flyology.HTTP.HTTP_3_Connection.Smoke is
   use type Ada.Streams.Stream_Element;
   use type QUIC.Open_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;

   Client_Transport, Server_Transport : QUIC.Connection;
   Client, Server : Connection;
   Settings : HTTP_3_Settings_Policy.Settings;
   Client_Control, Server_Control : QUIC.Datagram;
   Client_Event, Server_Event : Event;
   Client_Status, Server_Status : Operation_Status;
begin
   Flyology.QUIC.Test_Connections.Connect
     (Client_Transport, Server_Transport);
   Initialize (Client, HTTP_3_Connection.Client, Settings);
   Initialize (Server, HTTP_3_Connection.Server, Settings);

   --  An exact tombstone must not classify an unseen lower stream as already
   --  released merely because a higher-numbered stream completed first.
   Server.Released_Messages (1) := True;
   pragma Assert (Is_Released_Message (Server, Server_Transport, 4));
   pragma Assert
     (not Is_Released_Message (Server, Server_Transport, 0));
   Server.Released_Messages (1) := False;

   Start
     (Client, Client_Transport, Now => 1_000,
      Packet => Client_Control, Status => Client_Status);
   Start
     (Server, Server_Transport, Now => 1_000,
      Packet => Server_Control, Status => Server_Status);
   pragma Assert
     (Client_Status = Succeeded and then Server_Status = Succeeded);

   Flyology.QUIC.Test_Connections.Deliver
     (Client_Control, Server_Transport);
   Flyology.QUIC.Test_Connections.Deliver
     (Server_Control, Client_Transport);

   Poll (Server, Server_Transport, Server_Event, Server_Status);
   Poll (Client, Client_Transport, Client_Event, Client_Status);
   pragma Assert
     (Server_Status = Succeeded
      and then Server_Event.Kind = Settings_Received
      and then Server_Event.Stream = 2
      and then Has_Peer_Settings (Server));
   pragma Assert
     (Client_Status = Succeeded
      and then Client_Event.Kind = Settings_Received
      and then Client_Event.Stream = 3
      and then Has_Peer_Settings (Client));

   declare
      Empty_Stream : QUIC.Stream_ID;
      Empty_Packet : QUIC.Datagram;
      Opened       : QUIC.Open_Status;
      Sent         : QUIC.Send_Status;
   begin
      QUIC.Open_Stream
        (Server_Transport, QUIC.Unidirectional, Empty_Stream, Opened);
      pragma Assert (Opened = QUIC.Opened and then Empty_Stream = 7);
      QUIC.Build_Stream_Datagram
        (Server_Transport, Empty_Stream, 0, Fin => True,
         Data => Ada.Streams.Stream_Element_Array'(1 .. 0 => 0),
         Now => 1_500, Packet => Empty_Packet, Status => Sent);
      pragma Assert (Sent = QUIC.Sent);
      Flyology.QUIC.Test_Connections.Deliver
        (Empty_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = No_Event and then Client_Event.Kind = No_Event);

      QUIC.Open_Stream
        (Server_Transport, QUIC.Unidirectional, Empty_Stream, Opened);
      pragma Assert (Opened = QUIC.Opened and then Empty_Stream = 11);
      QUIC.Build_Stream_Datagram
        (Server_Transport, Empty_Stream, 0, Fin => True,
         Data => Ada.Streams.Stream_Element_Array'(1 => 16#40#),
         Now => 1_600, Packet => Empty_Packet, Status => Sent);
      pragma Assert (Sent = QUIC.Sent);
      Flyology.QUIC.Test_Connections.Deliver
        (Empty_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = No_Event and then Client_Event.Kind = No_Event);
   end;

   declare
      Request_Headers  : QPACK_Field_Section_Policy.Header_Block;
      Response_Headers : QPACK_Field_Section_Policy.Header_Block;
      Request_Stream   : QUIC.Stream_ID;
      Request_Packet, Response_Packet, Data_Packet : QUIC.Datagram;
      Sent             : QUIC.Send_Status;
   begin
      Request_Headers.Count := 4;
      Request_Headers.Fields (1) :=
        QPACK_Field_Section_Policy.Make_Field (":method", "GET");
      Request_Headers.Fields (2) :=
        QPACK_Field_Section_Policy.Make_Field (":scheme", "https");
      Request_Headers.Fields (3) :=
        QPACK_Field_Section_Policy.Make_Field (":path", "/hello");
      Request_Headers.Fields (4) :=
        QPACK_Field_Section_Policy.Make_Field
          (":authority", "example.com");

      Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      Build_Headers
        (Client, Client_Transport, Request_Stream, Request_Headers,
         Fin => True, Now => 2_000, Packet => Request_Packet,
         Status => Client_Status);
      pragma Assert
        (Client_Status = Succeeded and then Request_Stream = 0);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Headers_Received
         and then Server_Event.Stream = Request_Stream
         and then Server_Event.Headers.Count = 4);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Stream_Ended
         and then Server_Event.Stream = Request_Stream);

      Response_Headers.Count := 1;
      Response_Headers.Fields (1) :=
        QPACK_Field_Section_Policy.Make_Field (":status", "200");
      Build_Headers
        (Server, Server_Transport, Request_Stream, Response_Headers,
         Fin => False, Now => 3_000, Packet => Response_Packet,
         Status => Server_Status);
      pragma Assert (Server_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Response_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Headers_Received
         and then Client_Event.Stream = Request_Stream
         and then Client_Event.Headers.Count = 1);

      Build_Data
        (Server, Server_Transport, Request_Stream,
         Ada.Streams.Stream_Element_Array'(16#68#, 16#65#, 16#6C#,
                                            16#6C#, 16#6F#),
         Fin => True, Now => 4_000, Packet => Data_Packet,
         Status => Server_Status);
      pragma Assert (Server_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver (Data_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Data_Received
         and then Client_Event.Stream = Request_Stream
         and then Client_Event.Data_Length = 5
         and then Client_Event.Data (1) = 16#68#
         and then Client_Event.Data (5) = 16#6F#);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Stream_Ended
         and then Client_Event.Stream = Request_Stream);

      Request_Headers.Fields (1) :=
        QPACK_Field_Section_Policy.Make_Field (":method", "HEAD");
      Request_Headers.Fields (3) :=
        QPACK_Field_Section_Policy.Make_Field (":path", "/metadata");
      Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      Build_Headers
        (Client, Client_Transport, Request_Stream, Request_Headers,
         Fin => True, Now => 4_500, Packet => Request_Packet,
         Status => Client_Status);
      pragma Assert
        (Client_Status = Succeeded and then Request_Stream = 4);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Headers_Received
         and then Server_Event.Stream = Request_Stream);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Stream_Ended
         and then Server_Event.Stream = Request_Stream);

      Response_Headers.Count := 2;
      Response_Headers.Fields (2) :=
        QPACK_Field_Section_Policy.Make_Field ("content-length", "5");
      Build_Headers
        (Server, Server_Transport, Request_Stream, Response_Headers,
         Fin => True, Now => 4_600, Packet => Response_Packet,
         Status => Server_Status);
      pragma Assert (Server_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Response_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Headers_Received
         and then Client_Event.Stream = Request_Stream
         and then Client_Event.Headers.Count = 2);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Stream_Ended
         and then Client_Event.Stream = Request_Stream);

      Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert
        (Client_Status = Succeeded and then Request_Stream = 8);
      Build_Request_Cancellation
        (Client, Client_Transport, Request_Stream,
         Application_Error => 16#10C#, Now => 4_700,
         Packet => Request_Packet, Status => Client_Status);
      pragma Assert (Client_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Stream_Reset
         and then Server_Event.Stream = Request_Stream
         and then Server_Event.Application_Error = 16#10C#);

      Request_Headers.Fields (1) :=
        QPACK_Field_Section_Policy.Make_Field (":method", "GET");
      Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert
        (Client_Status = Succeeded and then Request_Stream = 12);
      Build_Headers
        (Client, Client_Transport, Request_Stream, Request_Headers,
         Fin => False, Now => 4_800, Packet => Request_Packet,
         Status => Client_Status);
      pragma Assert (Client_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert
        (Server_Status = Succeeded
         and then Server_Event.Kind = Headers_Received);
      Build_Request_Cancellation
        (Server, Server_Transport, Request_Stream,
         Application_Error => 16#10B#, Now => 4_900,
         Packet => Response_Packet, Status => Server_Status);
      pragma Assert (Server_Status = Succeeded);
      Flyology.QUIC.Test_Connections.Deliver
        (Response_Packet, Client_Transport);
      Poll (Client, Client_Transport, Client_Event, Client_Status);
      pragma Assert
        (Client_Status = Succeeded
         and then Client_Event.Kind = Stream_Reset
         and then Client_Event.Stream = Request_Stream
         and then Client_Event.Application_Error = 16#10B#);

      Open_Request
        (Client, Client_Transport, Request_Stream, Client_Status);
      pragma Assert
        (Client_Status = Succeeded and then Request_Stream = 16);
      QUIC.Build_Stream_Datagram
        (Client_Transport, Request_Stream, 0, Fin => True,
         Data => Ada.Streams.Stream_Element_Array'(1, 2, 0),
         Now => 5_000, Packet => Request_Packet, Status => Sent);
      pragma Assert (Sent = QUIC.Sent);
      Flyology.QUIC.Test_Connections.Deliver
        (Request_Packet, Server_Transport);
      Poll (Server, Server_Transport, Server_Event, Server_Status);
      pragma Assert (Server_Status = Frame_Error);
   end;
end Flyology.HTTP.HTTP_3_Connection.Smoke;
