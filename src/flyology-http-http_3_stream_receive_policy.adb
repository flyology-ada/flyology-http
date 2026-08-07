with Flyology.HTTP.HTTP_3_Frame_Policy;
with Flyology.HTTP.HTTP_3_Header_Policy;

package body Flyology.HTTP.HTTP_3_Stream_Receive_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type HTTP_3_Control_Policy.Operation_Status;
   use type HTTP_3_Frame_Policy.Parse_Status;
   use type HTTP_3_Header_Policy.Validation_Status;
   use type HTTP_3_Message_Policy.Update_Status;
   use type HTTP_3_Message_Policy.Finish_Status;
   use type HTTP_3_Message_Policy.Request_Phase;
   use type HTTP_3_Stream_Policy.Endpoint_Role;
   use type QPACK_Field_Section_Policy.Decode_Status;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Kind (Item : Stream_State) return Stream_Kind is
     (Item.Stream_Type);

   function Has_Peer_Settings (Item : Connection_State) return Boolean is
     (HTTP_3_Control_Policy.Has_Peer_Settings (Item.Control));

   procedure Open
     (Item       : out Stream_State;
      Stream_ID  : Varint_Policy.Value_Type;
      Local_Role : HTTP_3_Stream_Policy.Endpoint_Role;
      Status     : out Receive_Status)
   is
   begin
      Item := (ID => Stream_ID, Local_Role => Local_Role, others => <>);
      Status := Consumed;
      if HTTP_3_Stream_Policy.Is_Unidirectional (Stream_ID) then
         if HTTP_3_Stream_Policy.Is_Peer_Initiated (Stream_ID, Local_Role) then
            Item.Stream_Type := Awaiting_Type;
         else
            Status := Stream_Creation_Error;
         end if;
      elsif Local_Role = HTTP_3_Stream_Policy.Server
        and then HTTP_3_Stream_Policy.Is_Peer_Initiated (Stream_ID, Local_Role)
      then
         Item.Stream_Type := Request_Stream;
      elsif Local_Role = HTTP_3_Stream_Policy.Client
        and then not HTTP_3_Stream_Policy.Is_Peer_Initiated
          (Stream_ID, Local_Role)
      then
         Item.Stream_Type := Response_Stream;
      else
         Status := Stream_Creation_Error;
      end if;
   end Open;

   procedure Register_Type
     (Connection  : in out Connection_State;
      Stream      : in out Stream_State;
      Stream_Type : Varint_Policy.Value_Type;
      Status      : out Receive_Status)
   is
      Control_Status : HTTP_3_Control_Policy.Operation_Status;
   begin
      Status := Consumed;
      if Stream_Type = HTTP_3_Stream_Policy.Control_Stream then
         HTTP_3_Control_Policy.Register_Peer_Control
           (Connection.Control, Stream.ID, Stream.Local_Role, Control_Status);
         if Control_Status /= HTTP_3_Control_Policy.Accepted then
            Status := Stream_Creation_Error;
            return;
         end if;
         Stream.Stream_Type := Control_Stream;
      elsif Stream_Type = HTTP_3_Stream_Policy.Push_Stream then
         if Stream.Local_Role /= HTTP_3_Stream_Policy.Client then
            Status := Stream_Creation_Error;
            return;
         end if;
         Stream.Stream_Type := Awaiting_Push_ID;
      elsif Stream_Type = HTTP_3_Stream_Policy.QPACK_Encoder_Stream then
         if Connection.QPACK_Encoder_Seen then
            Status := Stream_Creation_Error;
            return;
         end if;
         Connection.QPACK_Encoder_Seen := True;
         Connection.QPACK_Encoder_ID := Stream.ID;
         Stream.Stream_Type := QPACK_Encoder_Stream;
      elsif Stream_Type = HTTP_3_Stream_Policy.QPACK_Decoder_Stream then
         if Connection.QPACK_Decoder_Seen then
            Status := Stream_Creation_Error;
            return;
         end if;
         Connection.QPACK_Decoder_Seen := True;
         Connection.QPACK_Decoder_ID := Stream.ID;
         Stream.Stream_Type := QPACK_Decoder_Stream;
      else
         Stream.Stream_Type := Ignored_Stream;
      end if;
   end Register_Type;

   procedure Process_Prefix
     (Connection : in out Connection_State;
      Stream     : in out Stream_State;
      Data       : Ada.Streams.Stream_Element_Array;
      Result     : out Receive_Result)
   is
      Decoded : Varint_Policy.Decode_Result;
   begin
      Result := (others => <>);
      if Data'Length = 0 then
         return;
      end if;
      Decoded := Varint_Policy.Decode (Data);
      if Decoded.Status /= Varint_Policy.Decoded then
         return;
      end if;
      Register_Type
        (Connection, Stream, Decoded.Value, Result.Status);
      if Result.Status = Consumed then
         Result.Consumed := Natural (Decoded.Consumed);
      end if;
   end Process_Prefix;

   procedure Process_Push_ID
     (Stream : in out Stream_State;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Receive_Result)
   is
      Decoded : Varint_Policy.Decode_Result;
   begin
      Result := (others => <>);
      if Data'Length = 0 then
         return;
      end if;
      Decoded := Varint_Policy.Decode (Data);
      if Decoded.Status /= Varint_Policy.Decoded then
         return;
      end if;
      Stream.Push_ID := Decoded.Value;
      Stream.Stream_Type := Push_Stream;
      Result.Status := Consumed;
      Result.Consumed := Natural (Decoded.Consumed);
   end Process_Push_ID;

   procedure Process_Control
     (Connection : in out Connection_State;
      Data       : Ada.Streams.Stream_Element_Array;
      Frame      : HTTP_3_Frame_Policy.Parse_Result;
      Result     : in out Receive_Result)
   is
      Status : HTTP_3_Control_Policy.Operation_Status;
   begin
      if Frame.Payload_Length = 0 then
         HTTP_3_Control_Policy.Process_Frame
           (Connection.Control, Frame.Frame_Type,
            Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
      else
         HTTP_3_Control_Policy.Process_Frame
           (Connection.Control, Frame.Frame_Type,
            Data
              (Data'First
                 + Ada.Streams.Stream_Element_Offset (Frame.Payload_Offset)
               .. Data'First
                    + Ada.Streams.Stream_Element_Offset
                        (Frame.Payload_Offset + Frame.Payload_Length - 1)),
            Status);
      end if;
      Result.Status :=
        (case Status is
            when HTTP_3_Control_Policy.Accepted => Consumed,
            when HTTP_3_Control_Policy.Stream_Creation_Error =>
              Stream_Creation_Error,
            when HTTP_3_Control_Policy.Missing_Settings => Missing_Settings,
            when HTTP_3_Control_Policy.Frame_Unexpected => Frame_Unexpected,
            when HTTP_3_Control_Policy.Settings_Error => Settings_Error,
            when HTTP_3_Control_Policy.Critical_Stream_Closed =>
              Closed_Critical_Stream);
      if Result.Status = Consumed
        and then Frame.Frame_Type = HTTP_3_Frame_Policy.Settings_Frame
      then
         Result.Event := Settings_Received;
      end if;
   end Process_Control;

   procedure Process_Message
     (Stream : in out Stream_State;
      Data   : Ada.Streams.Stream_Element_Array;
      Frame  : HTTP_3_Frame_Policy.Parse_Result;
      Result : in out Receive_Result)
   is
      Decoded    : QPACK_Field_Section_Policy.Decode_Result;
      Validation : HTTP_3_Header_Policy.Validation_Result;
      Header     : HTTP_3_Message_Policy.Header_Kind :=
        HTTP_3_Message_Policy.Not_Headers;
      Request    : HTTP_3_Message_Policy.Request_Update;
      Response   : HTTP_3_Message_Policy.Response_Update;
   begin
      if Frame.Frame_Type = HTTP_3_Frame_Policy.Headers_Frame then
         if Frame.Payload_Length = 0 then
            Decoded := QPACK_Field_Section_Policy.Decode
              (Ada.Streams.Stream_Element_Array'(1 .. 0 => 0));
         else
            Decoded := QPACK_Field_Section_Policy.Decode
              (Data
                 (Data'First
                    + Ada.Streams.Stream_Element_Offset (Frame.Payload_Offset)
                  .. Data'First
                       + Ada.Streams.Stream_Element_Offset
                           (Frame.Payload_Offset + Frame.Payload_Length - 1)));
         end if;
         if Decoded.Status /= QPACK_Field_Section_Policy.Decoded then
            Result.Status := QPACK_Decompression_Failed;
            return;
         end if;
         Result.Headers := Decoded.Block;
         if Stream.Stream_Type = Request_Stream then
            if Stream.Request_State.Phase =
              HTTP_3_Message_Policy.Expecting_Request
            then
               Validation := HTTP_3_Header_Policy.Validate_Request
                 (Decoded.Block);
               Header := HTTP_3_Message_Policy.Request_Headers;
            else
               Validation := HTTP_3_Header_Policy.Validate_Trailers
                 (Decoded.Block);
               Header := HTTP_3_Message_Policy.Trailer_Headers;
            end if;
         else
            if Stream.Response_State.Phase in
              HTTP_3_Message_Policy.Expecting_Response |
              HTTP_3_Message_Policy.Awaiting_Final
            then
               Validation := HTTP_3_Header_Policy.Validate_Response
                 (Decoded.Block);
               Header :=
                 (if Validation.Is_Interim
                  then HTTP_3_Message_Policy.Interim_Response_Headers
                  else HTTP_3_Message_Policy.Final_Response_Headers);
            else
               Validation := HTTP_3_Header_Policy.Validate_Trailers
                 (Decoded.Block);
               Header := HTTP_3_Message_Policy.Trailer_Headers;
            end if;
         end if;
         if Validation.Status /= HTTP_3_Header_Policy.Valid then
            Result.Status := Header_Error;
            return;
         end if;
      end if;

      if Stream.Stream_Type = Request_Stream then
         Request := HTTP_3_Message_Policy.On_Request_Frame
           (Stream.Request_State, Frame.Frame_Type, Header);
         if Request.Status = HTTP_3_Message_Policy.Accepted then
            Stream.Request_State := Request.State;
         end if;
         Result.Status :=
           (case Request.Status is
               when HTTP_3_Message_Policy.Accepted => Consumed,
               when HTTP_3_Message_Policy.Frame_Unexpected => Frame_Unexpected,
               when HTTP_3_Message_Policy.Message_Error => Message_Error);
      else
         Response := HTTP_3_Message_Policy.On_Response_Frame
           (Stream.Response_State, Frame.Frame_Type, Header);
         if Response.Status = HTTP_3_Message_Policy.Accepted then
            Stream.Response_State := Response.State;
         end if;
         Result.Status :=
           (case Response.Status is
               when HTTP_3_Message_Policy.Accepted => Consumed,
               when HTTP_3_Message_Policy.Frame_Unexpected => Frame_Unexpected,
               when HTTP_3_Message_Policy.Message_Error => Message_Error);
      end if;
      if Result.Status = Consumed then
         if Frame.Frame_Type = HTTP_3_Frame_Policy.Headers_Frame then
            Result.Event := Headers_Received;
         elsif Frame.Frame_Type = HTTP_3_Frame_Policy.Data_Frame then
            Result.Event := Data_Received;
         elsif Frame.Frame_Type = HTTP_3_Frame_Policy.Push_Promise_Frame then
            Result.Event := Push_Promise_Received;
         end if;
      end if;
   end Process_Message;

   procedure Process
     (Connection : in out Connection_State;
      Stream     : in out Stream_State;
      Data       : Ada.Streams.Stream_Element_Array;
      Result     : out Receive_Result)
   is
      Frame : HTTP_3_Frame_Policy.Parse_Result;
   begin
      Result := (others => <>);
      if Stream.Stream_Type = Awaiting_Type then
         Process_Prefix (Connection, Stream, Data, Result);
         return;
      elsif Stream.Stream_Type = Awaiting_Push_ID then
         Process_Push_ID (Stream, Data, Result);
         return;
      elsif Stream.Stream_Type = Ignored_Stream then
         Result.Status := Consumed;
         Result.Consumed := Natural (Data'Length);
         return;
      elsif Stream.Stream_Type in
        QPACK_Encoder_Stream | QPACK_Decoder_Stream
      then
         Result.Status := Consumed;
         Result.Event := QPACK_Data_Received;
         Result.Consumed := Natural (Data'Length);
         Result.Payload_Length := Natural (Data'Length);
         return;
      end if;

      Frame := HTTP_3_Frame_Policy.Parse (Data);
      case Frame.Status is
         when HTTP_3_Frame_Policy.Truncated =>
            return;
         when HTTP_3_Frame_Policy.Frame_Length_Too_Large =>
            Result.Status := Frame_Error;
            return;
         when HTTP_3_Frame_Policy.Parsed =>
            Result.Payload_Offset := Natural (Frame.Payload_Offset);
            Result.Payload_Length := Natural (Frame.Payload_Length);
      end case;

      if Stream.Stream_Type = Control_Stream then
         Process_Control (Connection, Data, Frame, Result);
      elsif Stream.Stream_Type in
        Request_Stream | Response_Stream | Push_Stream
      then
         Process_Message (Stream, Data, Frame, Result);
      else
         Result.Status := Frame_Unexpected;
      end if;
      if Result.Status = Consumed then
         Result.Consumed := Natural (Frame.Consumed);
      end if;
   end Process;

   procedure Finish
     (Connection : Connection_State;
      Stream     : Stream_State;
      Status     : out Receive_Status)
   is
      Control_Status : HTTP_3_Control_Policy.Operation_Status;
   begin
      case Stream.Stream_Type is
         when Awaiting_Type | Awaiting_Push_ID =>
            Status := Stream_Creation_Error;
         when Control_Stream =>
            HTTP_3_Control_Policy.Peer_Stream_Closed
              (Connection.Control, Stream.ID, Control_Status);
            Status :=
              (if Control_Status = HTTP_3_Control_Policy.Critical_Stream_Closed
               then Closed_Critical_Stream else Consumed);
         when QPACK_Encoder_Stream | QPACK_Decoder_Stream =>
            Status := Closed_Critical_Stream;
         when Request_Stream =>
            Status :=
              (if HTTP_3_Message_Policy.Finish_Request (Stream.Request_State) =
                    HTTP_3_Message_Policy.Message_Complete
               then Consumed else Message_Error);
         when Response_Stream | Push_Stream =>
            Status :=
              (if HTTP_3_Message_Policy.Finish_Response
                    (Stream.Response_State) =
                    HTTP_3_Message_Policy.Message_Complete
               then Consumed else Message_Error);
         when Ignored_Stream =>
            Status := Consumed;
      end case;
   end Finish;
end Flyology.HTTP.HTTP_3_Stream_Receive_Policy;
