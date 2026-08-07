--  Regression coverage for the 2026-08-07 audit findings in the HTTP/2 server
--  engine. Every fix lands its failing reproduction here before the fix
--  itself. The peer speaks raw HTTP/2 frames over a loopback socket so that
--  connection-level flow control and output scheduling stay observable.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Interfaces;

procedure HTTP2_Server_Audit is
   use Ada.Streams;
   use type Interfaces.Unsigned_32;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Label : String) is
   begin
      if Condition then
         Ada.Text_IO.Put_Line ("  ok   " & Label);
      else
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("  FAIL " & Label);
      end if;
   end Check;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;

   procedure Handle (State : in out Context; X : in out App.Exchange);

   package Engine is new Flyology.HTTP.Server.HTTP_2 (Context, Handle);

   --  A response field section far larger than one frame, so the encoded head
   --  spans many CONTINUATION fragments and the connection output stays
   --  pinned to its slot for longer than the socket can buffer.
   Fragmented_Head_Size : constant := 2 * 1_024 * 1_024;
   type Text_Access is access String;
   Fragmented_Type : constant Text_Access :=
     new String'(1 .. Fragmented_Head_Size => 'p');

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      if X.Request_Target = "/slow" then
         delay 0.30;
         X.Text (200, "slow");
      elsif X.Request_Target = "/hold" then
         --  Deliberately never reads the request body, so the stream receive
         --  window stays depleted when the peer resets the stream.
         delay 0.30;
         X.No_Content;
      elsif X.Request_Target = "/bigheaders" then
         X.Respond (200, Fragmented_Type.all, "h");
      elsif X.Request_Target = "/flood" then
         X.Begin_Stream (200, "application/octet-stream");
         for Index in 1 .. 64 loop
            X.Write_Chunk (String'(1 .. 16_384 => 'f'));
         end loop;
         X.End_Stream;
      else
         X.Text (200, "ok");
      end if;
   end Handle;

   ---------------------------------------------------------------------------
   --  Raw HTTP/2 peer helpers
   ---------------------------------------------------------------------------

   Preface : constant Stream_Element_Array :=
     (Character'Pos ('P'), Character'Pos ('R'), Character'Pos ('I'),
      Character'Pos (' '), Character'Pos ('*'), Character'Pos (' '),
      Character'Pos ('H'), Character'Pos ('T'), Character'Pos ('T'),
      Character'Pos ('P'), Character'Pos ('/'), Character'Pos ('2'),
      Character'Pos ('.'), Character'Pos ('0'), 13, 10, 13, 10,
      Character'Pos ('S'), Character'Pos ('M'), 13, 10, 13, 10);

   Empty : constant Stream_Element_Array (1 .. 0) := (others => 0);

   function Frame_Header
     (Length    : Natural;
      Kind      : Stream_Element;
      Flags     : Stream_Element;
      Stream_ID : Natural) return Stream_Element_Array
   is
      Value : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Stream_ID);
   begin
      return
        (1 => Stream_Element (Length / 65_536),
         2 => Stream_Element ((Length / 256) mod 256),
         3 => Stream_Element (Length mod 256),
         4 => Kind,
         5 => Flags,
         6 => Stream_Element (Interfaces.Shift_Right (Value, 24) and 16#7F#),
         7 => Stream_Element (Interfaces.Shift_Right (Value, 16) and 16#FF#),
         8 => Stream_Element (Interfaces.Shift_Right (Value, 8) and 16#FF#),
         9 => Stream_Element (Value and 16#FF#));
   end Frame_Header;

   function U32 (Value : Natural) return Stream_Element_Array is
      Number : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value);
   begin
      return
        (1 => Stream_Element (Interfaces.Shift_Right (Number, 24) and 16#7F#),
         2 => Stream_Element (Interfaces.Shift_Right (Number, 16) and 16#FF#),
         3 => Stream_Element (Interfaces.Shift_Right (Number, 8) and 16#FF#),
         4 => Stream_Element (Number and 16#FF#));
   end U32;

   function Text_Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Value'Length);
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Text_Bytes;

   --  One HPACK literal field without indexing and with a new name. Names and
   --  values stay under 127 bytes so the length prefixes are single octets.
   function Literal (Name, Value : String) return Stream_Element_Array is
     ((1 => 16#00#, 2 => Stream_Element (Name'Length)) & Text_Bytes (Name) &
      (1 => Stream_Element (Value'Length)) & Text_Bytes (Value));

   function Request_Block
     (Method, Path : String) return Stream_Element_Array
   is
     (Literal (":method", Method) & Literal (":scheme", "http") &
      Literal (":authority", "localhost") & Literal (":path", Path));

   procedure Send_Frame
     (Socket    : Sockets.Socket_Type;
      Kind      : Stream_Element;
      Flags     : Stream_Element;
      Stream_ID : Natural;
      Payload   : Stream_Element_Array) is
   begin
      Sockets.Send_All
        (Socket,
         Frame_Header (Payload'Length, Kind, Flags, Stream_ID) & Payload,
         Timeout => 10.0);
   end Send_Frame;

   type Frame_Info is record
      Kind      : Stream_Element := 0;
      Flags     : Stream_Element := 0;
      Stream_ID : Natural := 0;
      Length    : Natural := 0;
   end record;

   procedure Read_Frame_Header
     (Socket : Sockets.Socket_Type;
      Info   : out Frame_Info;
      Wait   : Duration)
   is
      Wire : Stream_Element_Array (1 .. 9);
   begin
      Sockets.Receive_Exactly (Socket, Wire, Timeout => Wait);
      Info :=
        (Kind => Wire (4),
         Flags => Wire (5),
         Stream_ID =>
           Natural (Wire (6) and 16#7F#) * 16#100_0000# +
           Natural (Wire (7)) * 16#1_0000# +
           Natural (Wire (8)) * 16#100# + Natural (Wire (9)),
         Length =>
           Natural (Wire (1)) * 65_536 + Natural (Wire (2)) * 256 +
             Natural (Wire (3)));
   end Read_Frame_Header;

   procedure Read_Payload
     (Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : out Stream_Element_Array;
      Wait    : Duration) is
   begin
      if Info.Length > 0 then
         Sockets.Receive_Exactly
           (Socket,
            Payload (Payload'First ..
              Payload'First + Stream_Element_Offset (Info.Length) - 1),
            Timeout => Wait);
      end if;
   end Read_Payload;

   Data_Frame          : constant Stream_Element := 16#00#;
   Headers_Frame       : constant Stream_Element := 16#01#;
   Reset_Stream_Frame  : constant Stream_Element := 16#03#;
   Settings_Frame      : constant Stream_Element := 16#04#;
   Ping_Frame          : constant Stream_Element := 16#06#;
   Goaway_Frame        : constant Stream_Element := 16#07#;
   Window_Update_Frame : constant Stream_Element := 16#08#;
   Continuation_Frame  : constant Stream_Element := 16#09#;
   End_Stream_Flag     : constant Stream_Element := 16#01#;
   Ack_Flag            : constant Stream_Element := 16#01#;
   End_Headers_Flag    : constant Stream_Element := 16#04#;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
   Sessions : constant := 3;

   procedure Connect_Peer (Socket : in out Sockets.Socket_Type) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Address.Port),
         Timeout => 10.0);
      Sockets.Send_All (Socket, Preface, Timeout => 10.0);
      Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
   end Connect_Peer;

begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Address := Sockets.Get_Socket_Name (Listener);

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
      begin
         for Session in 1 .. Sessions loop
            declare
               Channel : Connections.Connection;
               Peer    : Sockets.Endpoint;
            begin
               Connections.Accept_Connection
                 (Manager, Listener, Channel, Peer, Timeout => 20.0);
               Engine.Serve
                 (State, Channel, Peer,
                  Timeout => 20.0, Max_Connection_Age => 20.0);
               Connections.Close (Channel);
            exception
               when others => null;
            end;
         end loop;
      end Server_Task;
   begin
      ------------------------------------------------------------------------
      --  Finding 7: DATA on a closed or half-closed-remote stream must be
      --  charged to, and credited back on, the connection receive window.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 7: closed-stream DATA connection window accounting");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Credit  : Natural := 0;
         Closed_Stream_Bytes : constant Natural := 2 * 16_384;
         Acknowledged : Boolean := False;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 3,
            Request_Block ("GET", "/slow"));
         --  Half-closed (remote): the handler is still running, so the slot
         --  is open with Remote_End set.
         Send_Frame (Socket, Data_Frame, 0, 3, Payload);
         --  Implicitly closed: stream 1 was skipped and is below the highest
         --  client stream, so no slot is ever found for it.
         Send_Frame (Socket, Data_Frame, 0, 1, Payload);
         Send_Frame
           (Socket, Ping_Frame, 0, 0,
            Stream_Element_Array'(1 .. 8 => 16#5A#));
         while not Acknowledged loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Kind = Window_Update_Frame and then Info.Stream_ID = 0 then
               Credit := Credit +
                 Natural (Payload (1) and 16#7F#) * 16#100_0000# +
                 Natural (Payload (2)) * 16#1_0000# +
                 Natural (Payload (3)) * 16#100# + Natural (Payload (4));
            elsif Info.Kind = Ping_Frame
              and then (Info.Flags and Ack_Flag) /= 0
            then
               Acknowledged := True;
            elsif Info.Kind = Goaway_Frame then
               Acknowledged := True;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("  connection credit returned: " & Decimal (Credit) &
              " of " & Decimal (Closed_Stream_Bytes) & " closed-stream bytes");
         Check
           (Credit >= Closed_Stream_Bytes,
            "closed-stream DATA is credited back on the connection window");
         Sockets.Close_Socket (Socket);
      end;

      ------------------------------------------------------------------------
      --  Finding 8: a reused stream slot must start from the advertised
      --  initial receive window, not the previous stream's residue.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 8: reused stream slot receive window");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Goaway_Error : Integer := -1;
         Responded : Boolean := False;
         Settled : Boolean := False;

         procedure Ping_Round_Trip is
            Seen : Boolean := False;
         begin
            Send_Frame
              (Socket, Ping_Frame, 0, 0,
               Stream_Element_Array'(1 .. 8 => 16#17#));
            while not Seen loop
               Read_Frame_Header (Socket, Info, Wait => 5.0);
               Read_Payload (Socket, Info, Payload, Wait => 5.0);
               Seen := Info.Kind = Ping_Frame
                 and then (Info.Flags and Ack_Flag) /= 0;
            end loop;
         end Ping_Round_Trip;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Headers_Flag, 1,
            Request_Block ("POST", "/hold"));
         Send_Frame
           (Socket, Data_Frame, 0, 1, Payload (1 .. 16_000));
         Send_Frame (Socket, Reset_Stream_Frame, 0, 1, U32 (8));
         --  Let the cancelled handler finish so the slot is reaped and reused.
         delay 0.80;
         Ping_Round_Trip;
         Ping_Round_Trip;
         Send_Frame
           (Socket, Headers_Frame, End_Headers_Flag, 3,
            Request_Block ("POST", "/hold"));
         --  Legal for a fresh stream: 1 000 bytes against the advertised
         --  16 384-byte initial stream receive window.
         Send_Frame
           (Socket, Data_Frame, End_Stream_Flag, 3, Payload (1 .. 1_000));
         while not Settled loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Kind = Goaway_Frame then
               Goaway_Error :=
                 Integer (Natural (Payload (5)) * 16#100_0000# +
                   Natural (Payload (6)) * 16#1_0000# +
                   Natural (Payload (7)) * 16#100# + Natural (Payload (8)));
               Settled := True;
            elsif Info.Kind = Headers_Frame and then Info.Stream_ID = 3 then
               Responded := True;
               Settled := True;
            end if;
         end loop;
         if Goaway_Error >= 0 then
            Ada.Text_IO.Put_Line
              ("  reused slot rejected a legal DATA frame; GOAWAY code " &
                 Decimal (Natural (Goaway_Error)));
         end if;
         Check
           (Responded,
            "a slot reused after a mid-upload reset accepts legal DATA");
         Sockets.Close_Socket (Socket);
      end;

      ------------------------------------------------------------------------
      --  Finding 14: a stream torn down while the connection output is
      --  pinned to its fragmented field section must not freeze the
      --  connection. Nothing else can be written until that block ends, so
      --  the block has to finish and the pin has to clear.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 14: continuation pin released on a torn-down stream");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Flood_Bytes : Natural := 0;
         Flood_Total : constant Natural := 64 * 16_384;
         Fragments : Natural := 0;
         Completed_Block : Boolean := False;
         Early_Ack : Boolean := False;
         Finished : Boolean := False;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 1,
            Request_Block ("GET", "/flood"));
         Send_Frame (Socket, Window_Update_Frame, 0, 0, U32 (4_000_000));
         Send_Frame (Socket, Window_Update_Frame, 0, 1, U32 (4_000_000));
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 3,
            Request_Block ("GET", "/bigheaders"));
         --  Read nothing while the server fills the socket send buffer. The
         --  field section is far larger than that buffer, so the connection
         --  output is still pinned to stream 3 when the reset below is
         --  parsed. The PING that follows proves it: a queued control frame
         --  can only be written once the pin clears, so its acknowledgement
         --  must arrive after the last field-section fragment.
         delay 1.00;
         Send_Frame (Socket, Reset_Stream_Frame, 0, 3, U32 (8));
         Send_Frame
           (Socket, Ping_Frame, 0, 0,
            Stream_Element_Array'(1 .. 8 => 16#33#));
         while not Finished loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Stream_ID = 3
              and then Info.Kind in Headers_Frame | Continuation_Frame
            then
               Fragments := Fragments + 1;
               Completed_Block := Completed_Block
                 or else (Info.Flags and End_Headers_Flag) /= 0;
            elsif Info.Kind = Ping_Frame
              and then (Info.Flags and Ack_Flag) /= 0
            then
               Early_Ack := not Completed_Block;
            elsif Info.Kind = Data_Frame and then Info.Stream_ID = 1 then
               Flood_Bytes := Flood_Bytes + Info.Length;
               Finished := (Info.Flags and End_Stream_Flag) /= 0;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("  flood delivered " & Decimal (Flood_Bytes) & " of " &
              Decimal (Flood_Total) & " bytes across " & Decimal (Fragments) &
              " field-section fragments");
         Check
           (Fragments > 1 and then Completed_Block,
            "the pinned field section is completed, never truncated");
         Check
           (not Early_Ack,
            "the reset was parsed while the connection output was pinned");
         Check
           (Flood_Bytes = Flood_Total,
            "connection output resumes after the pinned stream is released");
         Sockets.Close_Socket (Socket);
      exception
         when Flyology.IO.Timeout_Error =>
            Ada.Text_IO.Put_Line
              ("  connection output froze after " & Decimal (Fragments) &
                 " field-section fragments and " & Decimal (Flood_Bytes) &
                 " of " & Decimal (Flood_Total) & " flood bytes");
            Check (False,
              "connection output resumes after the pinned stream is released");
            Sockets.Close_Socket (Socket);
      end;
   end;

   Sockets.Close_Socket (Listener);
   if Failures /= 0 then
      raise Program_Error with
        "HTTP/2 server audit regressions: " & Decimal (Failures);
   end if;
   Ada.Text_IO.Put_Line ("HTTP/2 server audit passed");
end HTTP2_Server_Audit;
