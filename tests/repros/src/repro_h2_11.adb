with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-11.  Two client-side stream-state gaps.
--
--  (a) RFC 9113 6.4: "RST_STREAM frames MUST NOT be sent for a stream in the
--  'idle' state.  If a RST_STREAM frame identifying an idle stream is
--  received, the recipient MUST treat this as a connection error
--  (Section 5.4.1) of type PROTOCOL_ERROR."  RFC 9113 5.1, idle: "Receiving
--  any frame other than HEADERS or PRIORITY on a stream in this state MUST
--  be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR",
--  which covers WINDOW_UPDATE too.  Reset_Stream and Window_Update both
--  return silently for an unknown stream
--  (http_2_client_connection.adb:1374-1378, :1344-1346).
--
--  (b) After Cancel_Stream the stream is Complete with Remote_End set, so a
--  late in-flight HEADERS or DATA for it takes the Reject_Stream path
--  (:1115-1118, :1229-1241) and the client answers with a second
--  RST_STREAM(PROTOCOL_ERROR) on a stream it has already closed.
procedure Repro_H2_11 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   Idle_Listener : Sockets.Socket_Type;
   Idle_Address  : Sockets.Endpoint;
   Late_Listener : Sockets.Socket_Type;
   Late_Address  : Sockets.Endpoint;

   Late_Resets : Natural := 0;
   Late_Codes  : Natural := 0;
begin
   Note ("H2-11: client stream-state handling for idle and closed streams");
   Idle_Address := Listen_Loopback (Idle_Listener);
   Late_Address := Listen_Loopback (Late_Listener);

   --  (a) idle-stream RST_STREAM and WINDOW_UPDATE -------------------------
   declare
      task Idle_Peer is
         pragma Task_Info (Flyology.Native_Task);
      end Idle_Peer;

      task body Idle_Peer is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Opened  : Natural := 0;
      begin
         Sockets.Accept_Connection
           (Idle_Listener, Socket, Where, Timeout => 15.0);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
         --  Streams 7 and 9 are idle at the client: it has never opened
         --  them and never will before these frames arrive.
         Send_Frame (Socket, Reset_Stream_Frame, 0, 7, U32 (8));
         Send_Frame (Socket, Window_Update_Frame, 0, 9, U32 (100));
         while Opened = 0 loop
            Read_Frame_Header (Socket, Info, Wait => 10.0);
            Read_Payload (Socket, Info, Payload, Wait => 10.0);
            if Info.Kind = Settings_Frame
              and then (Info.Flags and Ack_Flag) = 0
            then
               Send_Frame (Socket, Settings_Frame, Ack_Flag, 0, Empty);
            elsif Info.Kind = Goaway_Frame then
               exit;
            elsif Info.Kind = Headers_Frame then
               Opened := Info.Stream_ID;
            end if;
         end loop;
         if Opened /= 0 then
            Send_Frame
              (Socket, Headers_Frame, End_Headers_Flag, Opened,
               Stream_Element_Array'(1 => 16#88#));
            Send_Frame
              (Socket, Data_Frame, End_Stream_Flag, Opened,
               Text_Bytes ("ok"));
            delay 0.30;
         end if;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Idle_Peer;

      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Idle_Address.Port));
      Session : aliased Client.Client (Capacity => 1);
      Refused : Boolean := False;
      Status  : Natural := 0;
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 8.0);
         begin
            Status := Client.Status (Reply);
         end;
      exception
         when Flyology.HTTP.Protocol_Error =>
            Refused := True;
         when others => null;
      end;
      Client.Shutdown (Session, Timeout => 5.0);
      Note
        ("  the exchange " &
         (if Refused then "failed the connection"
          elsif Status /= 0 then "returned status" & Natural'Image (Status)
          else "ended without a status"));
      Check
        (Refused,
         "RST_STREAM and WINDOW_UPDATE on idle streams fail the connection");
   end;

   --  (b) a late in-flight response for a cancelled stream -----------------
   declare
      task Late_Peer is
         pragma Task_Info (Flyology.Native_Task);
      end Late_Peer;

      task body Late_Peer is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         First   : Natural := 0;
         Cancelled : Boolean := False;
      begin
         Sockets.Accept_Connection
           (Late_Listener, Socket, Where, Timeout => 15.0);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
         while First = 0 loop
            Read_Frame_Header (Socket, Info, Wait => 10.0);
            Read_Payload (Socket, Info, Payload, Wait => 10.0);
            if Info.Kind = Settings_Frame
              and then (Info.Flags and Ack_Flag) = 0
            then
               Send_Frame (Socket, Settings_Frame, Ack_Flag, 0, Empty);
            elsif Info.Kind = Headers_Frame then
               First := Info.Stream_ID;
            end if;
         end loop;
         --  Say nothing until the client's deadline expires and it cancels.
         while not Cancelled loop
            Read_Frame_Header (Socket, Info, Wait => 10.0);
            Read_Payload (Socket, Info, Payload, Wait => 10.0);
            Cancelled := Info.Kind = Reset_Stream_Frame
              and then Info.Stream_ID = First;
            exit when Info.Kind = Goaway_Frame;
         end loop;
         if Cancelled then
            --  The response the server had already put on the wire.
            Send_Frame
              (Socket, Headers_Frame, End_Headers_Flag, First,
               Stream_Element_Array'(1 => 16#88#));
            Send_Frame
              (Socket, Data_Frame, End_Stream_Flag, First,
               Text_Bytes ("late"));
            --  Answer the follow-up request so its owner drives the pump.
            declare
               Second : Natural := 0;
            begin
               while Second = 0 loop
                  Read_Frame_Header (Socket, Info, Wait => 8.0);
                  Read_Payload (Socket, Info, Payload, Wait => 8.0);
                  if Info.Kind = Reset_Stream_Frame
                    and then Info.Stream_ID = First
                  then
                     Late_Resets := Late_Resets + 1;
                     Late_Codes :=
                       Natural (Payload (1)) * 16#100_0000# +
                       Natural (Payload (2)) * 16#1_0000# +
                       Natural (Payload (3)) * 16#100# +
                       Natural (Payload (4));
                  elsif Info.Kind = Headers_Frame
                    and then Info.Stream_ID /= First
                  then
                     Second := Info.Stream_ID;
                  elsif Info.Kind = Goaway_Frame then
                     exit;
                  end if;
               end loop;
               if Second /= 0 then
                  Send_Frame
                    (Socket, Headers_Frame, End_Headers_Flag, Second,
                     Stream_Element_Array'(1 => 16#88#));
                  Send_Frame
                    (Socket, Data_Frame, End_Stream_Flag, Second,
                     Text_Bytes ("ok"));
               end if;
            end;
            --  Anything further the client emits for the cancelled stream.
            begin
               loop
                  Read_Frame_Header (Socket, Info, Wait => 3.0);
                  Read_Payload (Socket, Info, Payload, Wait => 3.0);
                  if Info.Kind = Reset_Stream_Frame
                    and then Info.Stream_ID = First
                  then
                     Late_Resets := Late_Resets + 1;
                     Late_Codes :=
                       Natural (Payload (1)) * 16#100_0000# +
                       Natural (Payload (2)) * 16#1_0000# +
                       Natural (Payload (3)) * 16#100# +
                       Natural (Payload (4));
                  end if;
               end loop;
            exception
               when others => null;
            end;
         end if;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Late_Peer;

      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Late_Address.Port));
      Session : aliased Client.Client (Capacity => 1);
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/slow");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 1.0);
            pragma Unreferenced (Reply);
         begin
            null;
         end;
      exception
         when others => null;
      end;
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/second");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 6.0);
            pragma Unreferenced (Reply);
         begin
            null;
         end;
      exception
         when others => null;
      end;
      delay 1.0;
      Client.Shutdown (Session, Timeout => 5.0);
   end;

   Note
     ("  RST_STREAM frames the client sent for the cancelled stream after " &
      "its own CANCEL:" & Natural'Image (Late_Resets) &
      (if Late_Resets > 0 then ", last error code" & Natural'Image (Late_Codes)
       else ""));
   Check
     (Late_Resets = 0,
      "the client sends no further frame on a stream it already cancelled");

   Sockets.Close_Socket (Late_Listener);
   Sockets.Close_Socket (Idle_Listener);
   Finish;
end Repro_H2_11;
