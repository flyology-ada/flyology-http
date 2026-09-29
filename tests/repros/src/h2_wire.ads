with Ada.Streams;
with Flyology.IO.Sockets;

--  Raw HTTP/2 wire helpers shared by the H2 area reproduction spikes.  The
--  shapes mirror tests/http2_server_audit.adb so a spike and the maintained
--  audit describe the same bytes.
package H2_Wire is

   use Ada.Streams;
   package Sockets renames Flyology.IO.Sockets;

   Data_Frame          : constant Stream_Element := 16#00#;
   Headers_Frame       : constant Stream_Element := 16#01#;
   Priority_Frame      : constant Stream_Element := 16#02#;
   Reset_Stream_Frame  : constant Stream_Element := 16#03#;
   Settings_Frame      : constant Stream_Element := 16#04#;
   Ping_Frame          : constant Stream_Element := 16#06#;
   Goaway_Frame        : constant Stream_Element := 16#07#;
   Window_Update_Frame : constant Stream_Element := 16#08#;
   Continuation_Frame  : constant Stream_Element := 16#09#;

   End_Stream_Flag  : constant Stream_Element := 16#01#;
   Ack_Flag         : constant Stream_Element := 16#01#;
   End_Headers_Flag : constant Stream_Element := 16#04#;

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
      Stream_ID : Natural) return Stream_Element_Array;

   function U32 (Value : Natural) return Stream_Element_Array;

   function Text_Bytes (Value : String) return Stream_Element_Array;

   --  One HPACK literal field without indexing and with a new name.  Names
   --  and values stay under 127 bytes so the length prefixes are one octet.
   function Literal (Name, Value : String) return Stream_Element_Array;

   function Request_Block
     (Method, Path : String) return Stream_Element_Array;

   procedure Send_Frame
     (Socket    : Sockets.Socket_Type;
      Kind      : Stream_Element;
      Flags     : Stream_Element;
      Stream_ID : Natural;
      Payload   : Stream_Element_Array);

   type Frame_Info is record
      Kind      : Stream_Element := 0;
      Flags     : Stream_Element := 0;
      Stream_ID : Natural := 0;
      Length    : Natural := 0;
   end record;

   procedure Read_Frame_Header
     (Socket : Sockets.Socket_Type;
      Info   : out Frame_Info;
      Wait   : Duration);

   procedure Read_Payload
     (Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : out Stream_Element_Array;
      Wait    : Duration);

   function Frame_Name (Kind : Stream_Element) return String;

   --  Connect to Where, send the client preface and an empty SETTINGS frame.
   procedure Connect_Peer
     (Socket : in out Sockets.Socket_Type;
      Where  : Sockets.Endpoint);

   --  Connect and send the preface followed by a SETTINGS frame carrying
   --  Payload, without reading anything the server has already written.
   procedure Connect_Peer
     (Socket   : in out Sockets.Socket_Type;
      Where    : Sockets.Endpoint;
      Settings : Stream_Element_Array);

   function Listen_Loopback
     (Listener : in out Sockets.Socket_Type) return Sockets.Endpoint;

end H2_Wire;
