procedure Flyology.HTTP.HTTP_3_Message_Policy.Smoke is
   Request  : Request_State;
   R_Update : Request_Update;
   Response : Response_State;
   S_Update : Response_Update;
begin
   R_Update := On_Request_Frame (Request, HTTP_3_Frame_Policy.Data_Frame);
   pragma Assert (R_Update.Status = Frame_Unexpected);

   R_Update :=
     On_Request_Frame
       (Request, HTTP_3_Frame_Policy.Headers_Frame, Request_Headers);
   pragma Assert
     (R_Update.Status = Accepted and then R_Update.State.Phase = Request_Open);
   Request := R_Update.State;
   R_Update := On_Request_Frame (Request, HTTP_3_Frame_Policy.Data_Frame);
   pragma Assert (R_Update.Status = Accepted);
   R_Update := On_Request_Frame (Request, 16#21#);
   pragma Assert (R_Update.Status = Accepted);
   pragma Assert
     (On_Request_Frame (Request, HTTP_3_Frame_Policy.Priority_Frame).Status =
        Frame_Unexpected);
   pragma Assert
     (On_Request_Frame (Request, HTTP_3_Frame_Policy.Ping_Frame).Status =
        Frame_Unexpected);
   pragma Assert
     (On_Request_Frame
        (Request, HTTP_3_Frame_Policy.Window_Update_Frame).Status =
          Frame_Unexpected);
   pragma Assert
     (On_Request_Frame
        (Request, HTTP_3_Frame_Policy.Continuation_Frame).Status =
          Frame_Unexpected);
   R_Update :=
     On_Request_Frame
       (Request, HTTP_3_Frame_Policy.Headers_Frame, Trailer_Headers);
   pragma Assert
     (R_Update.Status = Accepted
      and then R_Update.State.Phase = Request_Trailers);
   Request := R_Update.State;
   pragma Assert (Finish_Request (Request) = Message_Complete);
   pragma Assert
     (On_Request_Frame (Request, HTTP_3_Frame_Policy.Data_Frame).Status =
        Frame_Unexpected);
   pragma Assert
     (On_Request_Frame (Request, HTTP_3_Frame_Policy.Settings_Frame).Status =
        Frame_Unexpected);

   declare
      Sized : Request_State;
   begin
      R_Update := On_Request_Frame
        (Sized, HTTP_3_Frame_Policy.Headers_Frame, Request_Headers,
         Has_Content_Length => True, Content_Length => 3);
      Sized := R_Update.State;
      R_Update := On_Request_Frame
        (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 2);
      pragma Assert (R_Update.Status = Accepted);
      Sized := R_Update.State;
      pragma Assert (Finish_Request (Sized) = Message_Incomplete);
      pragma Assert
        (On_Request_Frame
           (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 2).Status =
             Message_Error);
      R_Update := On_Request_Frame
        (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 1);
      pragma Assert
        (R_Update.Status = Accepted
         and then Finish_Request (R_Update.State) = Message_Complete);
   end;

   S_Update :=
     On_Response_Frame
       (Response,
        HTTP_3_Frame_Policy.Headers_Frame,
        Interim_Response_Headers);
   pragma Assert
     (S_Update.Status = Accepted
      and then S_Update.State.Phase = Awaiting_Final);
   Response := S_Update.State;
   pragma Assert (Finish_Response (Response) = Message_Incomplete);
   S_Update :=
     On_Response_Frame
       (Response,
        HTTP_3_Frame_Policy.Headers_Frame,
        Interim_Response_Headers);
   pragma Assert (S_Update.Status = Accepted);
   Response := S_Update.State;
   S_Update :=
     On_Response_Frame
       (Response,
        HTTP_3_Frame_Policy.Headers_Frame,
        Final_Response_Headers);
   pragma Assert
     (S_Update.Status = Accepted
      and then S_Update.State.Phase = Final_Response_Open);
   Response := S_Update.State;
   pragma Assert
     (On_Response_Frame
        (Response, HTTP_3_Frame_Policy.Push_Promise_Frame).Status = Accepted);
   pragma Assert
     (On_Response_Frame (Response, HTTP_3_Frame_Policy.Data_Frame).Status =
        Accepted);
   S_Update :=
     On_Response_Frame
       (Response, HTTP_3_Frame_Policy.Headers_Frame, Trailer_Headers);
   pragma Assert
     (S_Update.Status = Accepted
      and then S_Update.State.Phase = Response_Trailers);
   Response := S_Update.State;
   pragma Assert (Finish_Response (Response) = Message_Complete);
   pragma Assert (On_Response_Frame (Response, 16#21#).Status = Accepted);
   pragma Assert
     (On_Response_Frame
        (Response, HTTP_3_Frame_Policy.Priority_Frame).Status =
          Frame_Unexpected);
   pragma Assert
     (On_Response_Frame (Response, HTTP_3_Frame_Policy.Data_Frame).Status =
        Frame_Unexpected);
   pragma Assert
    (On_Response_Frame
        (Response,
         HTTP_3_Frame_Policy.Headers_Frame,
         Final_Response_Headers).Status = Frame_Unexpected);

   declare
      Sized : Response_State;
   begin
      S_Update := On_Response_Frame
        (Sized, HTTP_3_Frame_Policy.Headers_Frame, Final_Response_Headers,
         Response_Code => 200,
         Has_Content_Length => True, Content_Length => 3);
      pragma Assert (S_Update.Status = Accepted);
      Sized := S_Update.State;
      S_Update := On_Response_Frame
        (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 2);
      pragma Assert (S_Update.Status = Accepted);
      Sized := S_Update.State;
      pragma Assert (Finish_Response (Sized) = Message_Incomplete);
      pragma Assert
        (On_Response_Frame
           (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 2).Status =
             Message_Error);
      S_Update := On_Response_Frame
        (Sized, HTTP_3_Frame_Policy.Data_Frame, Data_Length => 1);
      pragma Assert
        (S_Update.Status = Accepted
         and then Finish_Response (S_Update.State) = Message_Complete);
   end;

   declare
      Head : constant Response_State :=
        (Request_Is_Head => True, others => <>);
   begin
      S_Update := On_Response_Frame
        (Head, HTTP_3_Frame_Policy.Headers_Frame, Final_Response_Headers,
         Response_Code => 200,
         Has_Content_Length => True, Content_Length => 42);
      pragma Assert
        (S_Update.Status = Accepted
         and then not S_Update.State.Body_Allowed
         and then Finish_Response (S_Update.State) = Message_Complete);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => 1).Status = Message_Error);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Headers_Frame,
            Trailer_Headers).Status = Message_Error);
   end;

   declare
      No_Content : Response_State;
   begin
      S_Update := On_Response_Frame
        (No_Content, HTTP_3_Frame_Policy.Headers_Frame,
         Final_Response_Headers, Response_Code => 204);
      pragma Assert
        (S_Update.Status = Accepted
         and then not S_Update.State.Body_Allowed
         and then Finish_Response (S_Update.State) = Message_Complete);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => 1).Status = Message_Error);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Headers_Frame,
            Trailer_Headers).Status = Message_Error);

      No_Content := (others => <>);
      S_Update := On_Response_Frame
        (No_Content, HTTP_3_Frame_Policy.Headers_Frame,
         Final_Response_Headers, Response_Code => 304,
         Has_Content_Length => True, Content_Length => 42);
      pragma Assert
        (S_Update.Status = Accepted
         and then not S_Update.State.Body_Allowed
         and then Finish_Response (S_Update.State) = Message_Complete);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => 1).Status = Message_Error);
      pragma Assert
        (On_Response_Frame
           (S_Update.State, HTTP_3_Frame_Policy.Headers_Frame,
            Trailer_Headers).Status = Message_Error);
   end;
end Flyology.HTTP.HTTP_3_Message_Policy.Smoke;
