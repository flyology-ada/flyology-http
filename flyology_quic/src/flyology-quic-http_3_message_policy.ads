with Flyology.QUIC.HTTP_3_Frame_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 request-stream message sequencing.
--
--  Each direction of a request stream carries its own HTTP message sequence.
--  Unknown extension frames remain ignorable, while known frames in invalid
--  locations are classified as H3_FRAME_UNEXPECTED conditions.
private package Flyology.QUIC.HTTP_3_Message_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   type Header_Kind is
     (Not_Headers,
      Request_Headers,
      Interim_Response_Headers,
      Final_Response_Headers,
      Trailer_Headers);

   type Update_Status is (Accepted, Frame_Unexpected, Message_Error);

   type Request_Phase is (Expecting_Request, Request_Open, Request_Trailers);

   type Request_State is record
      Phase : Request_Phase := Expecting_Request;
   end record;

   type Request_Update is record
      Status : Update_Status := Accepted;
      State  : Request_State;
   end record;

   function On_Request_Frame
     (State      : Request_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers) return Request_Update
   with Global => null;

   type Response_Phase is
     (Expecting_Response, Awaiting_Final, Final_Response_Open, Response_Trailers);

   type Response_State is record
      Phase : Response_Phase := Expecting_Response;
   end record;

   type Response_Update is record
      Status : Update_Status := Accepted;
      State  : Response_State;
   end record;

   function On_Response_Frame
     (State      : Response_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers) return Response_Update
   with Global => null;

   type Finish_Status is (Message_Complete, Message_Incomplete);

   function Finish_Request (State : Request_State) return Finish_Status
   with Global => null;

   function Finish_Response (State : Response_State) return Finish_Status
   with Global => null;
end Flyology.QUIC.HTTP_3_Message_Policy;
