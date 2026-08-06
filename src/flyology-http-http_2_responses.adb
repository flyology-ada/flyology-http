with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Flyology.HTTP.HTTP_2_HPACK;

package body Flyology.HTTP.HTTP_2_Responses is

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

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
              "connection" | "keep-alive" | "proxy-connection" |
              "transfer-encoding" | "upgrade" | "content-length" |
              "content-type"
            then
               raise Constraint_Error with
                 "managed or connection-specific HTTP/2 response field";
            end if;
            HTTP_2_HPACK.Add_Field
              (Builder, Name,
               Flyology.HTTP.Headers.Value (Fields, Index),
               Never_Indexed => Name in "set-cookie" | "www-authenticate");
         end;
      end loop;
   end Add_Regular_Fields;

   function Encode_Head
     (Status             : Status_Code;
      Content_Type       : String;
      Fields             : Flyology.HTTP.Headers.List;
      Has_Content_Length : Boolean;
      Content_Length     : Natural) return Flyology.Bytes.Unbounded_Bytes
   is
      Builder : HTTP_2_HPACK.Builder;
   begin
      HTTP_2_HPACK.Add_Field (Builder, ":status", Decimal (Status));
      if Has_Content_Length then
         HTTP_2_HPACK.Add_Field
           (Builder, "content-length", Decimal (Content_Length));
      end if;
      if Content_Type /= "" then
         HTTP_2_HPACK.Add_Field (Builder, "content-type", Content_Type);
      end if;
      Add_Regular_Fields (Builder, Fields);
      return HTTP_2_HPACK.Bytes (Builder);
   end Encode_Head;

end Flyology.HTTP.HTTP_2_Responses;
