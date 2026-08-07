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
     (On_Response_Frame (Response, HTTP_3_Frame_Policy.Data_Frame).Status =
        Frame_Unexpected);
   pragma Assert
    (On_Response_Frame
        (Response,
         HTTP_3_Frame_Policy.Headers_Frame,
         Final_Response_Headers).Status = Frame_Unexpected);
end Flyology.HTTP.HTTP_3_Message_Policy.Smoke;
