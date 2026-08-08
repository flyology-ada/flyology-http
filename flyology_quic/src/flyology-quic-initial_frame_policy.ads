with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved decoder for frames permitted in QUIC Initial packets.
--
--  Offsets are zero-based from the first element of authenticated packet
--  plaintext. CRYPTO and CONNECTION_CLOSE data remain borrowed from that
--  plaintext; this policy reports their bounds without allocating or copying.
private package Flyology.QUIC.Initial_Frame_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   subtype Frame_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. 65_535;
   subtype Varint_Bytes is Natural range 0 .. 8;

   type Frame_Kind is
     (Padding,
      Ping,
      Acknowledgment,
      Crypto,
      Transport_Close);

   type Parse_Status is
     (Parsed,
      End_Of_Input,
      Truncated,
      Frame_Type_Not_Allowed,
      Frame_Value_Too_Large,
      Invalid_ACK_Range);

   type Parse_Result is record
      Status                : Parse_Status := End_Of_Input;
      Kind                  : Frame_Kind := Padding;
      Start_Offset          : Frame_Offset := 0;
      Frame_Type            : Varint_Policy.Value_Type := 0;
      Frame_Type_Bytes      : Varint_Bytes := 0;
      Consumed              : Frame_Offset := 0;
      Padding_Length        : Frame_Offset := 0;
      Largest_Acknowledged  : Varint_Policy.Value_Type := 0;
      ACK_Delay             : Varint_Policy.Value_Type := 0;
      ACK_Range_Count       : Frame_Offset := 0;
      First_ACK_Range       : Varint_Policy.Value_Type := 0;
      ACK_Ranges_Offset     : Frame_Offset := 0;
      ECT0_Count            : Varint_Policy.Value_Type := 0;
      ECT1_Count            : Varint_Policy.Value_Type := 0;
      ECN_CE_Count          : Varint_Policy.Value_Type := 0;
      Crypto_Offset         : Varint_Policy.Value_Type := 0;
      Crypto_Length         : Frame_Offset := 0;
      Crypto_Data_Offset    : Frame_Offset := 0;
      Close_Error_Code      : Varint_Policy.Value_Type := 0;
      Close_Frame_Type      : Varint_Policy.Value_Type := 0;
      Close_Reason_Length   : Frame_Offset := 0;
      Close_Reason_Offset   : Frame_Offset := 0;
   end record;

   function Parse_Next
     (Data   : Ada.Streams.Stream_Element_Array;
      Cursor : Frame_Offset) return Parse_Result
   with
     Global => null,
     Pre =>
       Data'Length <= 65_535
       and then Cursor <= Frame_Offset (Data'Length),
     Post =>
       Parse_Next'Result.Start_Offset = Cursor
       and then
         (if Parse_Next'Result.Status = Parsed then
             Parse_Next'Result.Consumed > 0
             and then
               Parse_Next'Result.Consumed <=
                 Frame_Offset (Data'Length) - Cursor
          elsif Parse_Next'Result.Status = End_Of_Input then
             Cursor = Frame_Offset (Data'Length)
             and then Parse_Next'Result.Consumed = 0
          else
             Parse_Next'Result.Consumed = 0);

   --  Encode a transport CONNECTION_CLOSE with an empty reason phrase.
   Max_Transport_Close_Length : constant := 18;
   subtype Transport_Close_Length is
     Natural range 0 .. Max_Transport_Close_Length;

   type Transport_Close_Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array
        (1 .. Max_Transport_Close_Length) := (others => 0);
      Length : Transport_Close_Length := 0;
   end record;

   function Encode_Transport_Close
     (Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type)
      return Transport_Close_Encode_Result
   with
     Global => null,
     Post => Encode_Transport_Close'Result.Length in 4 ..
       Max_Transport_Close_Length;
end Flyology.QUIC.Initial_Frame_Policy;
