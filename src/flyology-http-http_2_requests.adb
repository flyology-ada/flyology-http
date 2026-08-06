with Ada.Characters.Handling;
with Flyology.HTTP.HTTP_2_HPACK;

package body Flyology.HTTP.HTTP_2_Requests is

   function Decimal (Value : Long_Long_Integer) return String is
      Result : constant String := Long_Long_Integer'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Decimal;

   procedure Add_Regular_Fields
     (Builder : in out HTTP_2_HPACK.Builder;
      Fields  : Flyology.HTTP.Headers.List) is
   begin
      for Index in 1 .. Flyology.HTTP.Headers.Count (Fields) loop
         declare
            Name : constant String := Ada.Characters.Handling.To_Lower
              (Flyology.HTTP.Headers.Name (Fields, Index));
         begin
            if Name in
              "connection" | "host" | "keep-alive" |
              "proxy-connection" | "transfer-encoding" | "upgrade"
            then
               raise Constraint_Error with
                 "connection-specific field cannot be encoded for HTTP/2";
            end if;
            HTTP_2_HPACK.Add_Field
              (Builder, Name,
               Flyology.HTTP.Headers.Value (Fields, Index),
               Never_Indexed =>
                 Name in "authorization" | "cookie" | "proxy-authorization");
         end;
      end loop;
   end Add_Regular_Fields;

   function Encode_Head
     (Method_Text       : String;
      Scheme_Text       : String;
      Authority         : String;
      Target            : String;
      Fields            : Flyology.HTTP.Headers.List;
      Has_Content_Length : Boolean;
      Content_Length    : Long_Long_Integer;
      Expect_Continue   : Boolean) return Flyology.Bytes.Unbounded_Bytes
   is
      Builder : HTTP_2_HPACK.Builder;
   begin
      HTTP_2_HPACK.Add_Field (Builder, ":method", Method_Text);
      HTTP_2_HPACK.Add_Field (Builder, ":scheme", Scheme_Text);
      HTTP_2_HPACK.Add_Field (Builder, ":authority", Authority);
      HTTP_2_HPACK.Add_Field (Builder, ":path", Target);
      Add_Regular_Fields (Builder, Fields);
      if Expect_Continue then
         HTTP_2_HPACK.Add_Field (Builder, "expect", "100-continue");
      end if;
      if Has_Content_Length then
         HTTP_2_HPACK.Add_Field
           (Builder, "content-length", Decimal (Content_Length));
      end if;
      return HTTP_2_HPACK.Bytes (Builder);
   end Encode_Head;

   function Encode_Trailers
     (Fields : Flyology.HTTP.Headers.List)
      return Flyology.Bytes.Unbounded_Bytes
   is
      Builder : HTTP_2_HPACK.Builder;
   begin
      Add_Regular_Fields (Builder, Fields);
      return HTTP_2_HPACK.Bytes (Builder);
   end Encode_Trailers;

end Flyology.HTTP.HTTP_2_Requests;
