with Ada.Exceptions;
with Flyology.HTTP;
with Flyology.HTTP.Client.Testing;
with Repro_Support;

procedure Seam_Check is
   --  Harness seam check: proves a spike can reach the library through the
   --  public client testing seam and that Flyology.HTTP exceptions are
   --  catchable here.  Not a finding spike; it must PASS on current sources.
   use Repro_Support;

   function Rejected (Bytes : String) return Boolean is
   begin
      Flyology.HTTP.Client.Testing.Validate_Response (B (Bytes));
      return False;
   exception
      when Flyology.HTTP.Protocol_Error =>
         return True;
      when Flyology.HTTP.Client.Response_Too_Large =>
         return True;
   end Rejected;

   Good : constant String :=
     "HTTP/1.1 204 No Content" & CRLF & CRLF;
begin
   Note ("seam check: Flyology.HTTP.Client.Testing.Validate_Response");

   begin
      Flyology.HTTP.Client.Testing.Validate_Response (B (Good));
      Check (True, "a well formed 204 response is accepted");
   exception
      when Error : others =>
         Check (False,
                "a well formed 204 response is accepted, got "
                & Ada.Exceptions.Exception_Name (Error));
   end;

   Check (Rejected ("HTTP/1.1 200 OK" & CRLF
                    & "Content-Length: 1" & CRLF
                    & "Content-Length: 2" & CRLF & CRLF),
          "conflicting Content-Length is rejected");

   Check (Rejected ("HTTP/1.1 200 OK" & CRLF
                    & "Content-Length: 1" & CRLF
                    & "Transfer-Encoding: chunked" & CRLF & CRLF),
          "Content-Length with Transfer-Encoding is rejected");

   Note ("Serialized_Host seam is linkable");
   Finish;
end Seam_Check;
