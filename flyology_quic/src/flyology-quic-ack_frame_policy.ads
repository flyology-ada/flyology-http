with Ada.Streams;
with Flyology.QUIC.ACK_Range_Policy;
with Flyology.QUIC.Connection_State_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved ACK frame generation from authenticated packet state.
--
--  At most the newest 64 ranges from the 256-packet receive window are
--  emitted. Older sparse ranges may be omitted by QUIC receivers and remain
--  eligible for acknowledgment in a later frame.
private package Flyology.QUIC.ACK_Frame_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   Max_Frame_Length : constant := 1_050;
   subtype Frame_Length is Natural range 0 .. Max_Frame_Length;

   type Encode_Status is (Encoded, Nothing_To_ACK);

   type Encode_Result is record
      Status : Encode_Status := Nothing_To_ACK;
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Frame_Length) :=
        (others => 0);
      Length : Frame_Length := 0;
   end record;

   function Encode
     (Item      : Connection_State_Policy.Connection_State;
      ACK_Delay : Varint_Policy.Value_Type) return Encode_Result
   with
     Global => null,
     Post =>
       (if Encode'Result.Status = Encoded then
           Encode'Result.Length >= 5
        else Encode'Result.Length = 0);
end Flyology.QUIC.ACK_Frame_Policy;
