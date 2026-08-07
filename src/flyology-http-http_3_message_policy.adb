package body Flyology.HTTP.HTTP_3_Message_Policy
  with SPARK_Mode => On
is
   use type Varint_Policy.Value_Type;

   function Is_Known_Frame
     (Frame_Type : Varint_Policy.Value_Type) return Boolean
   is
     (Frame_Type = HTTP_3_Frame_Policy.Data_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Headers_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Cancel_Push_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Settings_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Push_Promise_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Goaway_Frame
      or else Frame_Type = HTTP_3_Frame_Policy.Max_Push_ID_Frame);

   function On_Request_Frame
     (State      : Request_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers) return Request_Update
   is
      Result : Request_Update := (Status => Accepted, State => State);
   begin
      if Frame_Type = HTTP_3_Frame_Policy.Headers_Frame then
         case State.Phase is
            when Expecting_Request =>
               if Headers = Request_Headers then
                  Result.State.Phase := Request_Open;
               else
                  Result.Status := Message_Error;
               end if;
            when Request_Open =>
               if Headers = Trailer_Headers then
                  Result.State.Phase := Request_Trailers;
               else
                  Result.Status := Message_Error;
               end if;
            when Request_Trailers =>
               Result.Status := Frame_Unexpected;
         end case;
      elsif Headers /= Not_Headers then
         Result.Status := Message_Error;
      elsif Frame_Type = HTTP_3_Frame_Policy.Data_Frame then
         if State.Phase /= Request_Open then
            Result.Status := Frame_Unexpected;
         end if;
      elsif Is_Known_Frame (Frame_Type) then
         Result.Status := Frame_Unexpected;
      end if;
      return Result;
   end On_Request_Frame;

   function On_Response_Frame
     (State      : Response_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers) return Response_Update
   is
      Result : Response_Update := (Status => Accepted, State => State);
   begin
      if Frame_Type = HTTP_3_Frame_Policy.Headers_Frame then
         case State.Phase is
            when Expecting_Response | Awaiting_Final =>
               if Headers = Interim_Response_Headers then
                  Result.State.Phase := Awaiting_Final;
               elsif Headers = Final_Response_Headers then
                  Result.State.Phase := Final_Response_Open;
               else
                  Result.Status := Message_Error;
               end if;
            when Final_Response_Open =>
               if Headers = Trailer_Headers then
                  Result.State.Phase := Response_Trailers;
               else
                  Result.Status := Message_Error;
               end if;
            when Response_Trailers =>
               Result.Status := Frame_Unexpected;
         end case;
      elsif Headers /= Not_Headers then
         Result.Status := Message_Error;
      elsif Frame_Type = HTTP_3_Frame_Policy.Data_Frame then
         if State.Phase /= Final_Response_Open then
            Result.Status := Frame_Unexpected;
         end if;
      elsif Frame_Type = HTTP_3_Frame_Policy.Push_Promise_Frame then
         null;
      elsif Is_Known_Frame (Frame_Type) then
         Result.Status := Frame_Unexpected;
      end if;
      return Result;
   end On_Response_Frame;

   function Finish_Request (State : Request_State) return Finish_Status is
     (if State.Phase = Expecting_Request
      then Message_Incomplete
      else Message_Complete);

   function Finish_Response (State : Response_State) return Finish_Status is
     (if State.Phase in Final_Response_Open | Response_Trailers
      then Message_Complete
      else Message_Incomplete);
end Flyology.HTTP.HTTP_3_Message_Policy;
