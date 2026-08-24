package body Flyology.HTTP.Client.Testing is
   use type Ada.Streams.Stream_Element_Offset;

   procedure Set_HTTP_2_Settlement_Grace
     (Item : in out Client; Grace : Duration) is
   begin
      if Grace < 0.0 or else Grace > 1.0 then
         raise Program_Error with
           "HTTP/2 settlement grace must be between zero and one second";
      end if;
      Set_HTTP_2_Settlement_Grace_For_Testing (Item, Grace);
   end Set_HTTP_2_Settlement_Grace;

   function Serialized_Host (Value : Origin) return String is
     (Host_Field (Value));

   procedure Validate_Response
     (Value : Ada.Streams.Stream_Element_Array) is
   begin
      Validate_Response_Bytes_For_Testing (Value);
   end Validate_Response;

   procedure Fuzz_Response (Value : Fuzz_Bytes; Length : Fuzz_Length) is
   begin
      Validate_Response
        (Value
           (Value'First ..
              Value'First + Ada.Streams.Stream_Element_Offset (Length) - 1));
   exception
      when Protocol_Error | Response_Too_Large =>
         null;
   end Fuzz_Response;

end Flyology.HTTP.Client.Testing;
