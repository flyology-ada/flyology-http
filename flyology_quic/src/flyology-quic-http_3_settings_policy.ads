with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 SETTINGS payload codec.
--
--  Unknown identifiers are accepted and ignored after duplicate checking.
--  The bounded profile accepts at most 64 settings in one frame.
private package Flyology.QUIC.HTTP_3_Settings_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Payload_Length : constant := 65_535;
   Max_Setting_Count  : constant := 64;
   Max_Encoded_Length : constant := 48;

   QPACK_Max_Table_Capacity : constant Varint_Policy.Value_Type := 16#01#;
   Max_Field_Section_Size   : constant Varint_Policy.Value_Type := 16#06#;
   QPACK_Blocked_Streams    : constant Varint_Policy.Value_Type := 16#07#;

   subtype Payload_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Payload_Length;

   type Settings is record
      QPACK_Table_Capacity : Varint_Policy.Value_Type := 0;
      QPACK_Blocked        : Varint_Policy.Value_Type := 0;
      Has_Max_Field_Size   : Boolean := False;
      Max_Field_Size       : Varint_Policy.Value_Type := 0;
   end record;

   type Decode_Status is
     (Decoded,
      Truncated,
      Duplicate_Identifier,
      Forbidden_Identifier,
      Too_Many_Settings);

   type Decode_Result is record
      Status : Decode_Status := Truncated;
      Value  : Settings;
      Count  : Natural range 0 .. Max_Setting_Count := 0;
   end record;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Payload_Length;

   subtype Encoded_Length is Natural range 0 .. Max_Encoded_Length;

   type Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Encoded_Length) :=
        (others => 0);
      Length : Encoded_Length := 0;
   end record;

   function Encode (Value : Settings) return Encode_Result
   with
     Global => null,
     Post => Encode'Result.Length in 4 .. Max_Encoded_Length;
end Flyology.QUIC.HTTP_3_Settings_Policy;
