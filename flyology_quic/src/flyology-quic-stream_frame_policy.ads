with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved QUIC STREAM frame codec.
--
--  Parsing accepts every STREAM flag combination. Encoding always includes a
--  Length field and omits Offset only when it is zero, leaving packet assembly
--  free to append additional frames or padding.
private package Flyology.QUIC.Stream_Frame_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Frame_Length : constant := 65_535;
   Max_Data_Length  : constant := Max_Frame_Length - 25;

   subtype Frame_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Frame_Length;

   type Parse_Status is
     (Parsed,
      Truncated,
      Not_Stream_Frame,
      Stream_Range_Too_Large);

   type Parse_Result is record
      Status         : Parse_Status := Truncated;
      Frame_Type     : Varint_Policy.Value_Type := 0;
      Stream_ID      : Varint_Policy.Value_Type := 0;
      Stream_Offset  : Varint_Policy.Value_Type := 0;
      Data_Length    : Frame_Offset := 0;
      Data_Offset    : Frame_Offset := 0;
      Fin            : Boolean := False;
      Consumed       : Frame_Offset := 0;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Frame_Length,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Frame_Type in 16#08# .. 16#0F#
           and then Parse'Result.Data_Offset > 0
           and then Parse'Result.Data_Offset <= Frame_Offset (Data'Length)
           and then Parse'Result.Data_Length <=
             Frame_Offset (Data'Length) - Parse'Result.Data_Offset
           and then Parse'Result.Consumed =
             Parse'Result.Data_Offset + Parse'Result.Data_Length
           and then Parse'Result.Consumed <= Frame_Offset (Data'Length));

   type Encode_Status is (Encoded, Stream_Range_Too_Large);

   subtype Encoded_Length is Natural range 0 .. Max_Frame_Length;

   type Encode_Result is record
      Status : Encode_Status := Stream_Range_Too_Large;
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Frame_Length) :=
        (others => 0);
      Length : Encoded_Length := 0;
   end record;

   function Encode
     (Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array) return Encode_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Data_Length;
end Flyology.QUIC.Stream_Frame_Policy;
