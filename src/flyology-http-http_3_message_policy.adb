with Flyology.HTTP.HTTP_3_Frame_Policy;

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
      or else Frame_Type = HTTP_3_Frame_Policy.Max_Push_ID_Frame
      or else HTTP_3_Frame_Policy.Is_HTTP_2_Reserved (Frame_Type));

   function On_Request_Frame
     (State      : Request_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Data_Length        : Varint_Policy.Value_Type := 0;
      Is_Head            : Boolean := False)
      return Request_Update
   is
      Result : Request_Update := (Status => Accepted, State => State);
   begin
      if Frame_Type = HTTP_3_Frame_Policy.Headers_Frame then
         case State.Phase is
            when Expecting_Request =>
               if Headers = Request_Headers then
                  Result.State.Phase := Request_Open;
                  Result.State.Has_Content_Length := Has_Content_Length;
                  Result.State.Content_Length := Content_Length;
                  Result.State.Is_Head := Is_Head;
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
         elsif Data_Length >
           Varint_Policy.Value_Type'Last - State.Content_Received
         then
            Result.Status := Message_Error;
         elsif State.Has_Content_Length
           and then State.Content_Received + Data_Length > State.Content_Length
         then
            Result.Status := Message_Error;
         else
            Result.State.Content_Received :=
              State.Content_Received + Data_Length;
         end if;
      elsif Is_Known_Frame (Frame_Type) then
         Result.Status := Frame_Unexpected;
      end if;
      return Result;
   end On_Request_Frame;

   function On_Response_Frame
     (State      : Response_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers;
      Response_Code      : Natural := 0;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Data_Length        : Varint_Policy.Value_Type := 0)
      return Response_Update
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
                  Result.State.Body_Allowed :=
                    not State.Request_Is_Head
                    and then Response_Code not in 204 | 304;
                  Result.State.Has_Content_Length := Has_Content_Length;
                  Result.State.Content_Length := Content_Length;
               else
                  Result.Status := Message_Error;
               end if;
            when Final_Response_Open =>
               if Headers = Trailer_Headers and then State.Body_Allowed then
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
         elsif not State.Body_Allowed then
            Result.Status := Message_Error;
         elsif Data_Length >
           Varint_Policy.Value_Type'Last - State.Content_Received
         then
            Result.Status := Message_Error;
         elsif State.Has_Content_Length
           and then State.Content_Received + Data_Length > State.Content_Length
         then
            Result.Status := Message_Error;
         else
            Result.State.Content_Received :=
              State.Content_Received + Data_Length;
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
        or else
          (State.Has_Content_Length
           and then State.Content_Received /= State.Content_Length)
      then Message_Incomplete
      else Message_Complete);

   function Finish_Response (State : Response_State) return Finish_Status is
     (if State.Phase in Final_Response_Open | Response_Trailers
        and then
          (not State.Body_Allowed
           or else not State.Has_Content_Length
           or else State.Content_Received = State.Content_Length)
      then Message_Complete else Message_Incomplete);
end Flyology.HTTP.HTTP_3_Message_Policy;
