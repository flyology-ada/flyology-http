with Ada.Streams;
with Interfaces;

--  Encodes and validates the fixed HTTP/2 frame header. Payload-specific
--  parsers build on this bounded, allocation-free layer.
private package Flyology.HTTP.HTTP_2_Frames is

   Frame_Header_Size : constant Positive := 9;
   Default_Maximum_Frame_Size : constant Positive := 16_384;
   Largest_Frame_Size : constant Positive := 16_777_215;

   subtype Frame_Size is Natural range 0 .. Largest_Frame_Size;
   subtype Maximum_Frame_Size is
     Positive range Default_Maximum_Frame_Size .. Largest_Frame_Size;
   subtype Stream_Identifier is
     Interfaces.Unsigned_32 range 0 .. 16#7FFF_FFFF#;
   subtype Frame_Code is Interfaces.Unsigned_8;
   subtype Frame_Flags is Interfaces.Unsigned_8;
   subtype Error_Code is Interfaces.Unsigned_32;

   No_Error            : constant Error_Code := 16#00#;
   Protocol_Error_Code : constant Error_Code := 16#01#;
   Internal_Error      : constant Error_Code := 16#02#;
   Flow_Control_Error  : constant Error_Code := 16#03#;
   Settings_Timeout    : constant Error_Code := 16#04#;
   Stream_Closed_Error : constant Error_Code := 16#05#;
   Frame_Size_Error    : constant Error_Code := 16#06#;
   Refused_Stream      : constant Error_Code := 16#07#;
   Cancel              : constant Error_Code := 16#08#;
   Compression_Error   : constant Error_Code := 16#09#;
   Connect_Error       : constant Error_Code := 16#0A#;
   Enhance_Your_Calm   : constant Error_Code := 16#0B#;
   Inadequate_Security : constant Error_Code := 16#0C#;
   HTTP_1_1_Required   : constant Error_Code := 16#0D#;

   Data_Frame          : constant Frame_Code := 16#00#;
   Headers_Frame       : constant Frame_Code := 16#01#;
   Priority_Frame      : constant Frame_Code := 16#02#;
   Reset_Stream_Frame  : constant Frame_Code := 16#03#;
   Settings_Frame      : constant Frame_Code := 16#04#;
   Push_Promise_Frame  : constant Frame_Code := 16#05#;
   Ping_Frame          : constant Frame_Code := 16#06#;
   Goaway_Frame        : constant Frame_Code := 16#07#;
   Window_Update_Frame : constant Frame_Code := 16#08#;
   Continuation_Frame  : constant Frame_Code := 16#09#;

   Ack_Flag         : constant Frame_Flags := 16#01#;
   End_Stream_Flag  : constant Frame_Flags := 16#01#;
   End_Headers_Flag : constant Frame_Flags := 16#04#;
   Padded_Flag      : constant Frame_Flags := 16#08#;
   Priority_Flag    : constant Frame_Flags := 16#20#;

   subtype Wire_Header is Ada.Streams.Stream_Element_Array
     (1 .. Ada.Streams.Stream_Element_Offset (Frame_Header_Size));

   type Header is record
      Length    : Frame_Size := 0;
      Kind      : Frame_Code := Data_Frame;
      Flags     : Frame_Flags := 0;
      Stream_ID : Stream_Identifier := 0;
   end record;

   --  Decode one nine-byte frame header. The reserved stream bit is ignored,
   --  as required by RFC 9113 section 4.1.
   function Decode (Value : Wire_Header) return Header;

   --  Encode one frame header with the reserved stream bit clear.
   function Encode (Value : Header) return Wire_Header;

   type Header_Validity is
     (Valid_Header,
      Frame_Too_Large,
      Invalid_Stream,
      Invalid_Length,
      Invalid_Flags);

   --  Apply frame-wide and known frame-type header constraints. Unknown frame
   --  types are accepted within the negotiated maximum and ignored later.
   function Validate
     (Value : Header;
      Maximum : Maximum_Frame_Size := Default_Maximum_Frame_Size)
      return Header_Validity;

end Flyology.HTTP.HTTP_2_Frames;
