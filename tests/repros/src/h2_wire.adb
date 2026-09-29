with Interfaces;

package body H2_Wire is

   use type Interfaces.Unsigned_32;

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

   function Frame_Name (Kind : Stream_Element) return String is
     (case Kind is
         when 16#00# => "DATA",
         when 16#01# => "HEADERS",
         when 16#02# => "PRIORITY",
         when 16#03# => "RST_STREAM",
         when 16#04# => "SETTINGS",
         when 16#05# => "PUSH_PROMISE",
         when 16#06# => "PING",
         when 16#07# => "GOAWAY",
         when 16#08# => "WINDOW_UPDATE",
         when 16#09# => "CONTINUATION",
         when others => "UNKNOWN");

   procedure Connect_Peer
     (Socket : in out Sockets.Socket_Type;
      Where  : Sockets.Endpoint) is
   begin
      Connect_Peer (Socket, Where, Empty);
   end Connect_Peer;

   procedure Connect_Peer
     (Socket   : in out Sockets.Socket_Type;
      Where    : Sockets.Endpoint;
      Settings : Stream_Element_Array) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Where.Port),
         Timeout => 10.0);
      Sockets.Send_All (Socket, Preface, Timeout => 10.0);
      Send_Frame (Socket, Settings_Frame, 0, 0, Settings);
   end Connect_Peer;

   function Listen_Loopback
     (Listener : in out Sockets.Socket_Type) return Sockets.Endpoint is
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
      return Sockets.Get_Socket_Name (Listener);
   end Listen_Loopback;

end H2_Wire;
