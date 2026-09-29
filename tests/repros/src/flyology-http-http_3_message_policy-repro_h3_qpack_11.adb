--  H3-QPACK-11.  On_Response_Frame rejects any DATA frame when Body_Allowed
--  is False (http_3_message_policy.adb:113-117) without exempting
--  Data_Length = 0.  Body_Allowed is False for a HEAD request and for status
--  204 and 304 (:94-96).  A peer that terminates such a response with a
--  zero-length DATA frame carrying FIN therefore gets Message_Error, which
--  the client turns into Stream_Reset 0x10E.  Commit 80e7f6b made this
--  repository's own HTTP/2 client accept exactly that shape.
--
--  This program asserts the CORRECT behaviour: an empty DATA frame carries no
--  content and so does not violate RFC 9110 section 6.4.1.
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Message_Policy.Repro_H3_QPACK_11
  with SPARK_Mode => Off
is
   Data_Frame : constant Varint_Policy.Value_Type := 16#00#;
   Headers_Frame : constant Varint_Policy.Value_Type := 16#01#;

   function After_Final
     (Code : Natural; Head : Boolean) return Response_State
   is
      Start : Response_State := (others => <>);
   begin
      Start.Request_Is_Head := Head;
      return On_Response_Frame
        (Start, Headers_Frame,
         Headers => Final_Response_Headers,
         Response_Code => Code).State;
   end After_Final;

   procedure Probe (Label : String; Code : Natural; Head : Boolean) is
      State  : constant Response_State := After_Final (Code, Head);
      Update : constant Response_Update :=
        On_Response_Frame (State, Data_Frame, Data_Length => 0);
   begin
      Repro_Support.Note
        (Label & ": Body_Allowed " & Boolean'Image (State.Body_Allowed) &
           ", empty DATA gives " & Update_Status'Image (Update.Status));
      Repro_Support.Check
        (Update.Status = Accepted,
         "an empty DATA frame on " & Label & " is accepted");
   end Probe;
begin
   Probe ("a HEAD response", 200, True);
   Probe ("a 204 response", 204, False);
   Probe ("a 304 response", 304, False);

   --  205 is not excluded by Body_Allowed, so the proved policy accepts a
   --  body there; the discovery entry reports the client controller
   --  disagreeing.  Recorded for the report, not asserted here.
   declare
      State : constant Response_State := After_Final (205, False);
   begin
      Repro_Support.Note
        ("a 205 response: Body_Allowed " &
           Boolean'Image (State.Body_Allowed) &
           " (the policy permits a body on 205)");
   end;

   Repro_Support.Finish;
end Flyology.HTTP.HTTP_3_Message_Policy.Repro_H3_QPACK_11;
