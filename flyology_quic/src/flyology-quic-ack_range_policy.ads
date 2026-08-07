with Ada.Streams;
with Flyology.QUIC.Initial_Frame_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded expansion of a parsed QUIC ACK frame.
--
--  ACK gaps are converted into inclusive packet-number ranges in descending
--  wire order. Bounding the output prevents a peer from forcing unbounded
--  recovery work even though the frame format permits many ranges.
private package Flyology.QUIC.ACK_Range_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type Varint_Policy.Value_Type;

   Max_Ranges : constant := 64;
   subtype Range_Count is Natural range 0 .. Max_Ranges;
   subtype Range_Index is Positive range 1 .. Max_Ranges;

   type ACK_Range is record
      Smallest : Varint_Policy.Value_Type := 0;
      Largest  : Varint_Policy.Value_Type := 0;
   end record;

   type ACK_Range_Array is array (Range_Index) of ACK_Range;

   type Decode_Status is
     (Decoded,
      Too_Many_Ranges,
      Truncated,
      Invalid_Range);

   type Decode_Result is record
      Status : Decode_Status := Truncated;
      Count  : Range_Count := 0;
      Ranges : ACK_Range_Array;
   end record;

   function Decode
     (Data  : Ada.Streams.Stream_Element_Array;
      Frame : Initial_Frame_Policy.Parse_Result) return Decode_Result
   with
     Global => null,
     Pre => Data'Length <= 65_535
       and then Frame.Status = Initial_Frame_Policy.Parsed
       and then Frame.Kind = Initial_Frame_Policy.Acknowledgment,
     Post =>
       (if Decode'Result.Status = Decoded then
           Decode'Result.Count >= 1
           and then
             (for all Index in 1 .. Decode'Result.Count =>
                Decode'Result.Ranges (Index).Smallest <=
                  Decode'Result.Ranges (Index).Largest));

   function Acknowledges
     (Item   : Decode_Result;
      Number : Varint_Policy.Value_Type) return Boolean
   with
     Global => null,
     Pre => Item.Status = Decoded;
end Flyology.QUIC.ACK_Range_Policy;
