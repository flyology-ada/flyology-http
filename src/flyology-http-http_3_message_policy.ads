with Flyology.HTTP.HTTP_3_Frame_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 request-stream message sequencing.
--
--  Each direction of a request stream carries its own HTTP message sequence.
--  Unknown extension frames remain ignorable, while known frames in invalid
--  locations are classified as H3_FRAME_UNEXPECTED conditions.
private package Flyology.HTTP.HTTP_3_Message_Policy
  with SPARK_Mode => On
is
   package Varint_Policy renames Flyology.QUIC.Varint_Policy;

   type Header_Kind is
     (Not_Headers,
      Request_Headers,
      Interim_Response_Headers,
      Final_Response_Headers,
      Trailer_Headers);

   type Update_Status is (Accepted, Frame_Unexpected, Message_Error);

   type Request_Phase is (Expecting_Request, Request_Open, Request_Trailers);

   type Request_State is record
      Phase              : Request_Phase := Expecting_Request;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Content_Received   : Varint_Policy.Value_Type := 0;
      Is_Head            : Boolean := False;
   end record;

   type Request_Update is record
      Status : Update_Status := Accepted;
      State  : Request_State;
   end record;

   function On_Request_Frame
     (State      : Request_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Data_Length        : Varint_Policy.Value_Type := 0;
      Is_Head            : Boolean := False)
      return Request_Update
   with Global => null;

   type Response_Phase is
     (Expecting_Response,
      Awaiting_Final,
      Final_Response_Open,
      Response_Trailers);

   type Response_State is record
      Phase              : Response_Phase := Expecting_Response;
      Request_Is_Head    : Boolean := False;
      Body_Allowed       : Boolean := True;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Content_Received   : Varint_Policy.Value_Type := 0;
   end record;

   type Response_Update is record
      Status : Update_Status := Accepted;
      State  : Response_State;
   end record;

   function On_Response_Frame
     (State      : Response_State;
      Frame_Type : Varint_Policy.Value_Type;
      Headers    : Header_Kind := Not_Headers;
      Response_Code      : Natural := 0;
      Has_Content_Length : Boolean := False;
      Content_Length     : Varint_Policy.Value_Type := 0;
      Data_Length        : Varint_Policy.Value_Type := 0)
      return Response_Update
   with Global => null;

   type Finish_Status is (Message_Complete, Message_Incomplete);

   function Finish_Request (State : Request_State) return Finish_Status
   with Global => null;

   function Finish_Response (State : Response_State) return Finish_Status
   with Global => null;
end Flyology.HTTP.HTTP_3_Message_Policy;
