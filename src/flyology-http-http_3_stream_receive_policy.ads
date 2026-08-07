with Ada.Streams;
with Flyology.HTTP.HTTP_3_Control_Policy;
with Flyology.HTTP.HTTP_3_Message_Policy;
with Flyology.HTTP.HTTP_3_Stream_Policy;
with Flyology.HTTP.QPACK_Field_Section_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 consumer for ordered QUIC stream bytes.
--
--  QUIC retains bytes until this policy reports them consumed. Incomplete
--  stream-type prefixes and frame envelopes therefore consume no input and
--  can be retried when the transport exposes a longer contiguous prefix.
private package Flyology.HTTP.HTTP_3_Stream_Receive_Policy
  with SPARK_Mode => On
is
   package Varint_Policy renames Flyology.QUIC.Varint_Policy;

   Max_Input_Length : constant := 65_535;
   subtype Input_Offset is Natural range 0 .. Max_Input_Length;

   type Stream_Kind is
     (Awaiting_Type,
      Awaiting_Push_ID,
      Request_Stream,
      Response_Stream,
      Control_Stream,
      Push_Stream,
      QPACK_Encoder_Stream,
      QPACK_Decoder_Stream,
      Ignored_Stream);

   type Event_Kind is
     (No_Event,
      Settings_Received,
      Headers_Received,
      Data_Received,
      Push_Promise_Received,
      QPACK_Data_Received);

   type Receive_Status is
     (Consumed,
      Need_More_Data,
      Stream_Creation_Error,
      Closed_Critical_Stream,
      Missing_Settings,
      Frame_Unexpected,
      Settings_Error,
      Frame_Error,
      QPACK_Decompression_Failed,
      Message_Error,
      Header_Error);

   type Receive_Result is record
      Status         : Receive_Status := Need_More_Data;
      Event          : Event_Kind := No_Event;
      Consumed       : Input_Offset := 0;
      Payload_Offset : Input_Offset := 0;
      Payload_Length : Input_Offset := 0;
      Headers        : QPACK_Field_Section_Policy.Header_Block;
   end record;

   type Connection_State is limited private;
   type Stream_State is private;

   function Kind (Item : Stream_State) return Stream_Kind
   with Global => null;

   function Has_Peer_Settings (Item : Connection_State) return Boolean
   with Global => null;

   procedure Open
     (Item       : out Stream_State;
      Stream_ID  : Varint_Policy.Value_Type;
      Local_Role : HTTP_3_Stream_Policy.Endpoint_Role;
      Status     : out Receive_Status)
   with Global => null;

   procedure Process
     (Connection : in out Connection_State;
      Stream     : in out Stream_State;
      Data       : Ada.Streams.Stream_Element_Array;
      Result     : out Receive_Result)
   with
     Global => null,
     Pre => Data'Length <= Max_Input_Length,
     Post => Result.Consumed <= Data'Length
       and then Result.Payload_Offset <= Data'Length
       and then Result.Payload_Length <=
         Data'Length - Result.Payload_Offset
       and then
         (if Result.Status = Need_More_Data then Result.Consumed = 0);

   procedure Finish
     (Connection : Connection_State;
      Stream     : Stream_State;
      Status     : out Receive_Status)
   with Global => null;

private
   type Connection_State is limited record
      Control             : HTTP_3_Control_Policy.Control_State;
      QPACK_Encoder_Seen  : Boolean := False;
      QPACK_Decoder_Seen  : Boolean := False;
      QPACK_Encoder_ID    : Varint_Policy.Value_Type := 0;
      QPACK_Decoder_ID    : Varint_Policy.Value_Type := 0;
   end record;

   type Stream_State is record
      ID             : Varint_Policy.Value_Type := 0;
      Local_Role     : HTTP_3_Stream_Policy.Endpoint_Role :=
        HTTP_3_Stream_Policy.Client;
      Stream_Type    : Stream_Kind := Awaiting_Type;
      Request_State  : HTTP_3_Message_Policy.Request_State;
      Response_State : HTTP_3_Message_Policy.Response_State;
      Push_ID        : Varint_Policy.Value_Type := 0;
   end record;
end Flyology.HTTP.HTTP_3_Stream_Receive_Policy;
