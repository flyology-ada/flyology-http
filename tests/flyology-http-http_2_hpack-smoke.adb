with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;

procedure Flyology.HTTP.HTTP_2_HPACK.Smoke is
   use type Ada.Streams.Stream_Element_Offset;

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));

      function Digit (Item : Character) return Natural is
        (if Item in '0' .. '9' then Character'Pos (Item) - Character'Pos ('0')
         elsif Item in 'a' .. 'f'
         then Character'Pos (Item) - Character'Pos ('a') + 10
         elsif Item in 'A' .. 'F'
         then Character'Pos (Item) - Character'Pos ('A') + 10
         else raise Constraint_Error with "invalid test hexadecimal");
   begin
      if Value'Length mod 2 /= 0 then
         raise Constraint_Error with "odd test hexadecimal length";
      end if;
      for Index in Result'Range loop
         declare
            Offset : constant Natural :=
              Natural (Index - Result'First) * 2;
         begin
            Result (Index) := Ada.Streams.Stream_Element
              (Digit (Value (Value'First + Offset)) * 16
                 + Digit (Value (Value'First + Offset + 1)));
         end;
      end loop;
      return Result;
   end Hex;

   procedure Reject (Value : String; Trailers : Boolean := False) is
      Item       : Decoder;
      Fields     : Flyology.HTTP.Headers.List;
      Status     : Status_Code;
      Has_Status : Boolean;
      Failed     : Boolean := False;
   begin
      begin
         Decode_Response
           (Item, Hex (Value), Trailers, Fields, Status, Has_Status);
      exception
         when Protocol_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
   end Reject;

begin
   --  RFC 7541 C.6 response sequence exercises Huffman strings and dynamic
   --  references across three field sections on one connection.
   declare
      Item       : Decoder;
      Fields     : Flyology.HTTP.Headers.List;
      Status     : Status_Code;
      Has_Status : Boolean;
   begin
      Decode_Response
        (Item,
         Hex
           ("488264025885aec3771a4b6196d07abe941054d444a8200595040b8166" &
            "e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3"),
         False, Fields, Status, Has_Status);
      pragma Assert (Has_Status and then Status = 302);
      pragma Assert (Flyology.HTTP.Headers.Count (Fields) = 3);
      pragma Assert
        (Flyology.HTTP.Headers.Value (Fields, "location") =
         "https://www.example.com");

      Decode_Response
        (Item, Hex ("4883640effc1c0bf"), False,
         Fields, Status, Has_Status);
      pragma Assert (Has_Status and then Status = 307);
      pragma Assert
        (Flyology.HTTP.Headers.Value (Fields, "cache-control") = "private");

      Decode_Response
        (Item,
         Hex
           ("88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a83" &
            "9bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672" &
            "c1ab270fb5291f9587316065c003ed4ee5b1063d5007"),
         False, Fields, Status, Has_Status);
      pragma Assert (Has_Status and then Status = 200);
      pragma Assert (Flyology.HTTP.Headers.Count (Fields) = 5);
      pragma Assert
        (Flyology.HTTP.Headers.Value (Fields, "content-encoding") = "gzip");

      Reset (Item);
      pragma Assert (Item.Count = 0 and then Item.Size = 0);
   end;

   declare
      Item : Builder;
      Encoded : Flyology.Bytes.Unbounded_Bytes;
   begin
      Add_Indexed (Item, 2);
      Add_Indexed (Item, 7);
      Add_Field (Item, ":path", "/resource");
      Add_Field (Item, ":authority", "example.com");
      Add_Field (Item, "authorization", "secret", Never_Indexed => True);
      Add_Field (Item, "x-test", "ok");
      Encoded := Bytes (Item);
      pragma Assert (Flyology.Bytes.Length (Encoded) > 0);
      Clear (Item);
      pragma Assert (Flyology.Bytes.Length (Bytes (Item)) = 0);
   end;

   declare
      Encoder : Builder;
      Item : Decoder;
      Fields : Flyology.HTTP.Headers.List;
      Method, Scheme, Authority, Path :
        Ada.Strings.Unbounded.Unbounded_String;
   begin
      Add_Field (Encoder, ":method", "POST");
      Add_Field (Encoder, ":scheme", "https");
      Add_Field (Encoder, ":authority", "example.com");
      Add_Field (Encoder, ":path", "/upload?part=1");
      Add_Field (Encoder, "content-type", "application/octet-stream");
      Decode_Request
        (Item, Flyology.Bytes.To_Array (Bytes (Encoder)), False, Fields,
         Method, Scheme, Authority, Path);
      pragma Assert (Ada.Strings.Unbounded.To_String (Method) = "POST");
      pragma Assert (Ada.Strings.Unbounded.To_String (Scheme) = "https");
      pragma Assert
        (Ada.Strings.Unbounded.To_String (Authority) = "example.com");
      pragma Assert
        (Ada.Strings.Unbounded.To_String (Path) = "/upload?part=1");
      pragma Assert
        (Flyology.HTTP.Headers.Value (Fields, "content-type") =
           "application/octet-stream");
   end;

   Reject ("");
   Reject ("8820");
   Reject ("88be");
   Reject ("88" & "000A436F6E6E656374696F6E00");
   Reject ("88", Trailers => True);
end Flyology.HTTP.HTTP_2_HPACK.Smoke;
