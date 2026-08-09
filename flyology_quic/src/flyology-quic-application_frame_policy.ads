with Ada.Streams;
with Flyology.QUIC.Initial_Frame_Policy;
with Flyology.QUIC.Stream_Frame_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved decoder for frames permitted in QUIC 1-RTT packets.
--
--  Common ACK, CRYPTO, and transport-close parsing is composed from the
--  Initial-space policy. STREAM parsing is composed from the dedicated STREAM
--  codec. Remaining application-space frames are decoded here.
private package Flyology.QUIC.Application_Frame_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   Max_Frame_Data : constant := 65_535;
   subtype Frame_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Frame_Data;
   subtype Connection_ID_Length is Natural range 0 .. 20;

   type Frame_Kind is
     (Padding,
      Ping,
      Acknowledgment,
      Reset_Stream,
      Stop_Sending,
      Crypto,
      New_Token,
      Stream,
      Max_Data,
      Max_Stream_Data,
      Max_Streams_Bidi,
      Max_Streams_Uni,
      Data_Blocked,
      Stream_Data_Blocked,
      Streams_Blocked_Bidi,
      Streams_Blocked_Uni,
      New_Connection_ID,
      Retire_Connection_ID,
      Path_Challenge,
      Path_Response,
      Transport_Close,
      Application_Close,
      Handshake_Done);

   type Parse_Status is
     (Parsed,
      End_Of_Input,
      Truncated,
      Unknown_Frame_Type,
      Frame_Value_Too_Large,
      Invalid_ACK_Range,
      Invalid_Connection_ID);

   type Parse_Result is record
      Status             : Parse_Status := End_Of_Input;
      Kind               : Frame_Kind := Padding;
      Frame_Type         : Varint_Policy.Value_Type := 0;
      Consumed           : Frame_Offset := 0;
      Base               : Initial_Frame_Policy.Parse_Result;
      Stream_Frame       : Stream_Frame_Policy.Parse_Result;
      Stream_Data_Offset : Frame_Offset := 0;
      Stream_ID          : Varint_Policy.Value_Type := 0;
      Application_Error  : Varint_Policy.Value_Type := 0;
      Final_Size         : Varint_Policy.Value_Type := 0;
      Maximum            : Varint_Policy.Value_Type := 0;
      Token_Offset       : Frame_Offset := 0;
      Token_Length       : Frame_Offset := 0;
      Sequence           : Varint_Policy.Value_Type := 0;
      Retire_Prior_To    : Varint_Policy.Value_Type := 0;
      CID_Offset         : Frame_Offset := 0;
      CID_Length         : Connection_ID_Length := 0;
      Reset_Token_Offset : Frame_Offset := 0;
      Path_Data_Offset   : Frame_Offset := 0;
      Reason_Offset      : Frame_Offset := 0;
      Reason_Length      : Frame_Offset := 0;
   end record;

   function Parse_Next
     (Data   : Ada.Streams.Stream_Element_Array;
      Cursor : Frame_Offset) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Frame_Data
       and then Cursor <= Frame_Offset (Data'Length),
     Post =>
         (if Parse_Next'Result.Status = Parsed then
             Parse_Next'Result.Consumed > 0
             and then Parse_Next'Result.Consumed <=
               Frame_Offset (Data'Length) - Cursor
          elsif Parse_Next'Result.Status = End_Of_Input then
             Cursor = Frame_Offset (Data'Length)
             and then Parse_Next'Result.Consumed = 0
          else Parse_Next'Result.Consumed = 0);

   --  RESET_STREAM followed by STOP_SENDING for both directions of one
   --  bidirectional application stream.
   Max_Abort_Length : constant := 42;
   subtype Abort_Length is Natural range 0 .. Max_Abort_Length;

   type Abort_Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Abort_Length) :=
        (others => 0);
      Length : Abort_Length := 0;
   end record;

   function Encode_Stream_Abort
     (Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type)
      return Abort_Encode_Result
   with
     Global => null,
     Post => Encode_Stream_Abort'Result.Length in 7 .. Max_Abort_Length;

   Max_Streams_Length : constant := 9;
   subtype Max_Streams_Encode_Length is Natural range 0 .. Max_Streams_Length;
   type Max_Streams_Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Streams_Length) :=
        (others => 0);
      Length : Max_Streams_Encode_Length := 0;
   end record;

   subtype Max_Data_Encode_Result is Max_Streams_Encode_Result;

   function Encode_Max_Data
     (Maximum : Varint_Policy.Value_Type)
      return Max_Data_Encode_Result
   with
     Global => null,
     Post => Encode_Max_Data'Result.Length in 3 .. Max_Streams_Length;

   function Encode_Max_Streams
     (Bidirectional : Boolean;
      Maximum       : Varint_Policy.Value_Type)
      return Max_Streams_Encode_Result
   with
     Global => null,
     Pre => Maximum <= 2**60,
     Post => Encode_Max_Streams'Result.Length in 3 .. Max_Streams_Length;
end Flyology.QUIC.Application_Frame_Policy;
