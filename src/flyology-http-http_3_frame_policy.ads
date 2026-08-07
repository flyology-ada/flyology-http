with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 frame envelope codec.
--
--  HTTP/3 frames consist of a QUIC variable-length type, a variable-length
--  payload length, and that many payload octets. Unknown frame types remain
--  representable so the HTTP/3 stream layer can ignore extensions as required.
private package Flyology.HTTP.HTTP_3_Frame_Policy
  with SPARK_Mode => On
is
   package Varint_Policy renames Flyology.QUIC.Varint_Policy;

   use type Ada.Streams.Stream_Element_Offset;

   Max_Frame_Length   : constant := 65_535;
   Max_Payload_Length : constant := Max_Frame_Length - 16;

   subtype Frame_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Frame_Length;

   Data_Frame         : constant Varint_Policy.Value_Type := 16#00#;
   Headers_Frame      : constant Varint_Policy.Value_Type := 16#01#;
   Cancel_Push_Frame  : constant Varint_Policy.Value_Type := 16#03#;
   Settings_Frame     : constant Varint_Policy.Value_Type := 16#04#;
   Push_Promise_Frame : constant Varint_Policy.Value_Type := 16#05#;
   Goaway_Frame       : constant Varint_Policy.Value_Type := 16#07#;
   Max_Push_ID_Frame  : constant Varint_Policy.Value_Type := 16#0D#;

   type Parse_Status is (Parsed, Truncated, Frame_Length_Too_Large);

   type Parse_Result is record
      Status         : Parse_Status := Truncated;
      Frame_Type     : Varint_Policy.Value_Type := 0;
      Payload_Offset : Frame_Offset := 0;
      Payload_Length : Frame_Offset := 0;
      Consumed       : Frame_Offset := 0;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Frame_Length,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Payload_Offset <= Frame_Offset (Data'Length)
           and then Parse'Result.Payload_Length <=
             Frame_Offset (Data'Length) - Parse'Result.Payload_Offset
           and then Parse'Result.Consumed =
             Parse'Result.Payload_Offset + Parse'Result.Payload_Length
           and then Parse'Result.Consumed <= Frame_Offset (Data'Length));

   subtype Encoded_Length is Natural range 0 .. Max_Frame_Length;

   type Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Frame_Length) :=
        (others => 0);
      Length : Encoded_Length := 0;
   end record;

   function Encode
     (Frame_Type : Varint_Policy.Value_Type;
      Payload    : Ada.Streams.Stream_Element_Array) return Encode_Result
   with
     Global => null,
     Pre => Payload'Length <= Max_Payload_Length,
     Post => Encode'Result.Length >= Payload'Length + 2
       and then Encode'Result.Length <= Payload'Length + 16;
end Flyology.HTTP.HTTP_3_Frame_Policy;
