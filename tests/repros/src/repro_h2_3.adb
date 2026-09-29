with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-3.  RFC 9113 8.1: "a server MAY request that the client abort
--  transmission of a request without error by sending a RST_STREAM with an
--  error code of NO_ERROR after sending a complete response (i.e., a frame
--  with the END_STREAM flag set).  Clients MUST NOT discard responses as a
--  result of receiving such a RST_STREAM".
--
--  The raw peer answers a POST with a complete 413 response and then resets
--  the stream with NO_ERROR, which is exactly what golang.org/x/net/http2
--  does when a handler finishes while the request stream is still open
--  (http2/server.go, "Section 8.1: a server MAY request that the client
--  abort transmission of a request without error ...", sc.resetStream
--  (streamError (st.id, ErrCodeNo))).  The response must still be delivered.
procedure Repro_H2_3 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  ":status: 413" as a literal field with the static name index 8, then
   --  "content-length: 8".
   Reply_Block : constant Stream_Element_Array :=
     (16#08#, 16#03#, Character'Pos ('4'), Character'Pos ('1'),
      Character'Pos ('3')) &
     Literal ("content-length", "8");

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
begin
   Note ("H2-3: RST_STREAM(NO_ERROR) after a complete response");
   Address := Listen_Loopback (Listener);

   declare
      task Peer_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Peer_Task;

      task body Peer_Task is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Opened  : Natural := 0;
      begin
         Sockets.Accept_Connection
           (Listener, Socket, Where, Timeout => 10.0);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
         --  Credit the connection generously so the client's upload never
         --  stalls behind flow control; the finding is about the reset.
         Send_Frame
           (Socket, Window_Update_Frame, 0, 0, U32 (16#2000_0000#));
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
              (Socket, Window_Update_Frame, 0, Opened,
               U32 (16#2000_0000#));
            --  One burst: the complete response followed by the permitted
            --  RST_STREAM(NO_ERROR).
            Sockets.Send_All
              (Socket,
               Frame_Header
                 (Reply_Block'Length, Headers_Frame, End_Headers_Flag,
                  Opened) & Reply_Block &
               Frame_Header (8, Data_Frame, End_Stream_Flag, Opened) &
                 Text_Bytes ("rejected") &
               Frame_Header (4, Reset_Stream_Frame, 0, Opened) & U32 (0),
               Timeout => 10.0);
            --  Keep draining whatever the client still writes.
            begin
               loop
                  Read_Frame_Header (Socket, Info, Wait => 3.0);
                  Read_Payload (Socket, Info, Payload, Wait => 3.0);
               end loop;
            exception
               when others => null;
            end;
         end if;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Peer_Task;

      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Address.Port));
      Session : aliased Client.Client (Capacity => 1);
      Upload  : constant Stream_Element_Array (1 .. 64 * 1_024) :=
        (others => Character'Pos ('x'));
      Status  : Natural := 0;
      Content : String (1 .. 64) := (others => ' ');
      Content_Last : Natural := 0;
      Raised  : String (1 .. 240) := (others => ' ');
      Raised_Last : Natural := 0;
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/upload");
         Client.Set_Method (Ask, Flyology.HTTP.To_Method ("POST"));
         Client.Set_Body (Ask, Upload);
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 15.0);
         begin
            Status := Client.Status (Reply);
            declare
               Text : constant String :=
                 Flyology.Bytes.To_Byte_String (Client.Read_All (Reply));
            begin
               Content_Last := Natural'Min (Text'Length, Content'Length);
               Content (1 .. Content_Last) := Text (1 .. Content_Last);
            end;
         end;
      exception
         when Event : others =>
            declare
               Text : constant String :=
                 Ada.Exceptions.Exception_Name (Event) & ": " &
                 Ada.Exceptions.Exception_Message (Event);
            begin
               Raised_Last := Natural'Min (Text'Length, Raised'Length);
               Raised (1 .. Raised_Last) := Text (1 .. Raised_Last);
            end;
      end;
      if Raised_Last > 0 then
         Note ("  client raised " & Raised (1 .. Raised_Last));
      end if;
      Note ("  status" & Natural'Image (Status) & " body """ &
            Content (1 .. Content_Last) & """");
      Expect_Equal
        (Status, 413,
         "the complete 413 response survives RST_STREAM(NO_ERROR)");
      Expect_Equal
        (Content (1 .. Content_Last), "rejected",
         "the buffered response body is delivered");
      Client.Shutdown (Session, Timeout => 5.0);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_3;
