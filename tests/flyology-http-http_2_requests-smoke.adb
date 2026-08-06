with Ada.Streams;
with Flyology.HTTP.HTTP_2_HPACK;

procedure Flyology.HTTP.HTTP_2_Requests.Smoke is
   Decoder    : HTTP_2_HPACK.Decoder;
   Input      : Flyology.HTTP.Headers.List;
   Decoded    : Flyology.HTTP.Headers.List;
   Status     : Status_Code;
   Has_Status : Boolean;
begin
   Flyology.HTTP.Headers.Add (Input, "User-Agent", "flyology-test");
   Flyology.HTTP.Headers.Add (Input, "Cookie", "private");
   declare
      Block : constant Ada.Streams.Stream_Element_Array :=
        Flyology.Bytes.To_Array
          (Encode_Head
             ("POST", "https", "example.com", "/submit", Input,
              True, 7, True));
      Failed_As_Response : Boolean := False;
   begin
      --  The block contains request pseudo-fields and therefore must not pass
      --  the stricter response decoder; this still exercises its complete
      --  HPACK representation and lowercase-name parsing.
      begin
         HTTP_2_HPACK.Decode_Response
           (Decoder, Block, False, Decoded, Status, Has_Status);
      exception
         when Protocol_Error =>
            Failed_As_Response := True;
      end;
      pragma Assert (Failed_As_Response);
      pragma Assert (Block'Length > 0);
   end;

   Flyology.HTTP.Headers.Clear (Input);
   Flyology.HTTP.Headers.Add (Input, "X-Checksum", "abc");
   pragma Assert
     (Flyology.Bytes.Length (Encode_Trailers (Input)) > 0);
end Flyology.HTTP.HTTP_2_Requests.Smoke;
