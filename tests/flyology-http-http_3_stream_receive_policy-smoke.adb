with Flyology.HTTP.HTTP_3_Frame_Policy;

procedure Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   Connection : Connection_State;
   Stream     : Stream_State;
   Result     : Receive_Result;
   Status     : Receive_Status;
begin
   declare
      Untyped : Stream_State;
   begin
      Open (Untyped, 7, HTTP_3_Stream_Policy.Client, Status);
      pragma Assert
        (Status = Consumed and then Kind (Untyped) = Awaiting_Type);
      Finish (Connection, Untyped, Status);
      pragma Assert (Status = Consumed);
   end;

   Open (Stream, 3, HTTP_3_Stream_Policy.Client, Status);
   pragma Assert
     (Status = Consumed and then Kind (Stream) = Awaiting_Type);
   Process
     (Connection, Stream,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Result);
   pragma Assert
     (Result.Status = Need_More_Data and then Result.Consumed = 0);
   Process
     (Connection, Stream, Ada.Streams.Stream_Element_Array'(1 => 0), Result);
   pragma Assert
     (Result.Status = Consumed and then Result.Consumed = 1
      and then Kind (Stream) = Control_Stream);
   Process
     (Connection, Stream,
      Ada.Streams.Stream_Element_Array'(4, 4, 1), Result);
   pragma Assert
     (Result.Status = Need_More_Data and then Result.Consumed = 0);
   Process
     (Connection, Stream,
      Ada.Streams.Stream_Element_Array'(4, 4, 1, 0, 7, 0), Result);
   pragma Assert
     (Result.Status = Consumed and then Result.Consumed = 6
      and then Result.Event = Settings_Received
      and then Has_Peer_Settings (Connection));
   Process
     (Connection, Stream,
      Ada.Streams.Stream_Element_Array'(7, 1, 4), Result);
   pragma Assert
     (Result.Status = Consumed and then Result.Consumed = 3
      and then Result.Event = Goaway_Received
      and then Result.Identifier = 4
      and then Has_Peer_Goaway (Connection)
      and then Peer_Goaway_ID (Connection) = 4);
   Finish (Connection, Stream, Status);
   pragma Assert (Status = Closed_Critical_Stream);

   declare
      Duplicate : Stream_State;
   begin
      Open (Duplicate, 7, HTTP_3_Stream_Policy.Client, Status);
      Process
        (Connection, Duplicate,
         Ada.Streams.Stream_Element_Array'(1 => 0), Result);
      pragma Assert (Result.Status = Stream_Creation_Error);
   end;

   declare
      Unknown : Stream_State;
   begin
      Open (Unknown, 11, HTTP_3_Stream_Policy.Client, Status);
      Process
        (Connection, Unknown,
         Ada.Streams.Stream_Element_Array'(1 => 16#21#), Result);
      pragma Assert
        (Result.Status = Consumed and then Kind (Unknown) = Ignored_Stream);
      Process
        (Connection, Unknown,
         Ada.Streams.Stream_Element_Array'(1, 2, 3), Result);
      pragma Assert
        (Result.Status = Consumed and then Result.Consumed = 3);
   end;

   declare
      Encoder : Stream_State;
      Decoder : Stream_State;
   begin
      Open (Encoder, 15, HTTP_3_Stream_Policy.Client, Status);
      Process
        (Connection, Encoder,
         Ada.Streams.Stream_Element_Array'(1 => 2), Result);
      pragma Assert
        (Result.Status = Consumed
         and then Kind (Encoder) = QPACK_Encoder_Stream);
      Process
        (Connection, Encoder,
         Ada.Streams.Stream_Element_Array'(1 => 0), Result);
      pragma Assert (Result.Status = QPACK_Encoder_Stream_Error);
      Finish (Connection, Encoder, Status);
      pragma Assert (Status = Closed_Critical_Stream);

      Open (Decoder, 19, HTTP_3_Stream_Policy.Client, Status);
      Process
        (Connection, Decoder,
         Ada.Streams.Stream_Element_Array'(1 => 3), Result);
      pragma Assert
        (Result.Status = Consumed
         and then Kind (Decoder) = QPACK_Decoder_Stream);
      Process
        (Connection, Decoder,
         Ada.Streams.Stream_Element_Array'(1 => 16#7F#), Result);
      pragma Assert (Result.Status = Need_More_Data);
      Process
        (Connection, Decoder,
         Ada.Streams.Stream_Element_Array'(16#7F#, 0), Result);
      pragma Assert
        (Result.Status = Consumed and then Result.Consumed = 2);
      Process
        (Connection, Decoder,
         Ada.Streams.Stream_Element_Array'(1 => 0), Result);
      pragma Assert (Result.Status = QPACK_Decoder_Stream_Error);
      Finish (Connection, Decoder, Status);
      pragma Assert (Status = Closed_Critical_Stream);
   end;

   declare
      Request : Stream_State;
      Block   : QPACK_Field_Section_Policy.Header_Block;
   begin
      Open (Request, 0, HTTP_3_Stream_Policy.Server, Status);
      pragma Assert
        (Status = Consumed and then Kind (Request) = Request_Stream);
      Block.Count := 4;
      Block.Fields (1) :=
        QPACK_Field_Section_Policy.Make_Field (":method", "GET");
      Block.Fields (2) :=
        QPACK_Field_Section_Policy.Make_Field (":scheme", "https");
      Block.Fields (3) :=
        QPACK_Field_Section_Policy.Make_Field (":path", "/");
      Block.Fields (4) :=
        QPACK_Field_Section_Policy.Make_Field
          (":authority", "example.com");
      declare
         Encoded : constant QPACK_Field_Section_Policy.Encode_Result :=
           QPACK_Field_Section_Policy.Encode (Block);
         Frame : constant HTTP_3_Frame_Policy.Encode_Result :=
           HTTP_3_Frame_Policy.Encode
             (HTTP_3_Frame_Policy.Headers_Frame,
              Encoded.Data
                (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
      begin
         Process
           (Connection, Request,
            Frame.Data (1 .. 1), Result);
         pragma Assert
           (Result.Status = Need_More_Data and then Result.Consumed = 0);
         Process
           (Connection, Request,
            Frame.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
            Result);
         pragma Assert
           (Result.Status = Consumed
            and then Result.Event = Headers_Received
            and then Result.Headers.Count = 4
            and then Result.Consumed = Frame.Length);
      end;
      Process
        (Connection, Request,
         Ada.Streams.Stream_Element_Array'(0, 3, 97, 98, 99), Result);
      pragma Assert
        (Result.Status = Consumed and then Result.Event = Data_Received
         and then Result.Payload_Offset = 2
         and then Result.Payload_Length = 3);
      Process
        (Connection, Request,
         Ada.Streams.Stream_Element_Array'(5, 1, 0), Result);
      pragma Assert (Result.Status = Frame_Unexpected);
      Process
        (Connection, Request,
         Ada.Streams.Stream_Element_Array'(2, 0), Result);
      pragma Assert (Result.Status = Frame_Unexpected);
      Finish (Connection, Request, Status);
      pragma Assert (Status = Consumed);
   end;

   declare
      Response : Stream_State;
      Invalid  : Stream_State;
   begin
      Open (Response, 0, HTTP_3_Stream_Policy.Client, Status);
      pragma Assert
        (Status = Consumed and then Kind (Response) = Response_Stream);
      Process
        (Connection, Response,
         Ada.Streams.Stream_Element_Array'(0, 1, 120), Result);
      pragma Assert (Result.Status = Frame_Unexpected);
      Process
        (Connection, Response,
         Ada.Streams.Stream_Element_Array'(5, 1, 0), Result);
      pragma Assert (Result.Status = ID_Error);
      Finish (Connection, Response, Status);
      pragma Assert (Status = Message_Error);

      Open (Invalid, 1, HTTP_3_Stream_Policy.Client, Status);
      pragma Assert (Status = Stream_Creation_Error);
   end;

   declare
      Push : Stream_State;
   begin
      Open (Push, 7, HTTP_3_Stream_Policy.Client, Status);
      Process
        (Connection, Push, Ada.Streams.Stream_Element_Array'(1 => 1), Result);
      pragma Assert
        (Result.Status = Consumed and then Kind (Push) = Awaiting_Push_ID);
      Process
        (Connection, Push, Ada.Streams.Stream_Element_Array'(1 => 5), Result);
      pragma Assert
        (Result.Status = ID_Error and then Kind (Push) = Awaiting_Push_ID);
      Finish (Connection, Push, Status);
      pragma Assert (Status = Stream_Creation_Error);
   end;
end Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Smoke;
