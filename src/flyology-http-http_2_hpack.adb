with Ada.Characters.Handling;
with Flyology.HTTP.HTTP_2_Huffman;

package body Flyology.HTTP.HTTP_2_HPACK is
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   Static_Count : constant Positive := 61;
   Maximum_Integer : constant Natural := 2_147_483_647;

   function Static_Name (Index : Positive) return String is
     (case Index is
        when 1 => ":authority",
        when 2 | 3 => ":method",
        when 4 | 5 => ":path",
        when 6 | 7 => ":scheme",
        when 8 .. 14 => ":status",
        when 15 => "accept-charset",
        when 16 => "accept-encoding",
        when 17 => "accept-language",
        when 18 => "accept-ranges",
        when 19 => "accept",
        when 20 => "access-control-allow-origin",
        when 21 => "age",
        when 22 => "allow",
        when 23 => "authorization",
        when 24 => "cache-control",
        when 25 => "content-disposition",
        when 26 => "content-encoding",
        when 27 => "content-language",
        when 28 => "content-length",
        when 29 => "content-location",
        when 30 => "content-range",
        when 31 => "content-type",
        when 32 => "cookie",
        when 33 => "date",
        when 34 => "etag",
        when 35 => "expect",
        when 36 => "expires",
        when 37 => "from",
        when 38 => "host",
        when 39 => "if-match",
        when 40 => "if-modified-since",
        when 41 => "if-none-match",
        when 42 => "if-range",
        when 43 => "if-unmodified-since",
        when 44 => "last-modified",
        when 45 => "link",
        when 46 => "location",
        when 47 => "max-forwards",
        when 48 => "proxy-authenticate",
        when 49 => "proxy-authorization",
        when 50 => "range",
        when 51 => "referer",
        when 52 => "refresh",
        when 53 => "retry-after",
        when 54 => "server",
        when 55 => "set-cookie",
        when 56 => "strict-transport-security",
        when 57 => "transfer-encoding",
        when 58 => "user-agent",
        when 59 => "vary",
        when 60 => "via",
        when 61 => "www-authenticate",
        when others => raise Protocol_Error with "invalid HPACK static index");

   function Static_Value (Index : Positive) return String is
     (case Index is
        when 2 => "GET",
        when 3 => "POST",
        when 4 => "/",
        when 5 => "/index.html",
        when 6 => "http",
        when 7 => "https",
        when 8 => "200",
        when 9 => "204",
        when 10 => "206",
        when 11 => "304",
        when 12 => "400",
        when 13 => "404",
        when 14 => "500",
        when 16 => "gzip, deflate",
        when 1 | 15 | 17 .. 61 => "",
        when others => raise Protocol_Error with "invalid HPACK static index");

   procedure Lookup
     (Item  : Decoder;
      Index : Natural;
      Name  : out Unbounded_String;
      Value : out Unbounded_String)
   is
      Dynamic_Index : Natural;
   begin
      if Index = 0 then
         raise Protocol_Error with "zero HPACK table index";
      elsif Index <= Static_Count then
         Name := To_Unbounded_String (Static_Name (Index));
         Value := To_Unbounded_String (Static_Value (Index));
      else
         Dynamic_Index := Index - Static_Count;
         if Dynamic_Index > Item.Count then
            raise Protocol_Error with "HPACK table index exceeds context";
         end if;
         Name := Item.Entries (Dynamic_Index).Name;
         Value := Item.Entries (Dynamic_Index).Value;
      end if;
   end Lookup;

   procedure Evict_Last (Item : in out Decoder) is
   begin
      if Item.Count = 0 then
         return;
      end if;
      Item.Size := Item.Size - Item.Entries (Item.Count).Size;
      Item.Entries (Item.Count) := (others => <>);
      Item.Count := Item.Count - 1;
   end Evict_Last;

   procedure Set_Maximum (Item : in out Decoder; Value : Natural) is
   begin
      if Value > Default_Table_Size then
         raise Protocol_Error with
           "HPACK dynamic table update exceeds advertised maximum";
      end if;
      Item.Maximum := Value;
      while Item.Size > Item.Maximum loop
         Evict_Last (Item);
      end loop;
   end Set_Maximum;

   procedure Insert
     (Item : in out Decoder; Name : String; Value : String)
   is
      Entry_Size : constant Natural := Name'Length + Value'Length + 32;
   begin
      if Entry_Size > Item.Maximum then
         while Item.Count > 0 loop
            Evict_Last (Item);
         end loop;
         return;
      end if;
      while Item.Count > 0
        and then Item.Size > Item.Maximum - Entry_Size
      loop
         Evict_Last (Item);
      end loop;
      if Item.Count = Maximum_Dynamic_Entries then
         Evict_Last (Item);
      end if;
      if Item.Count > 0 then
         for Index in reverse 2 .. Item.Count + 1 loop
            Item.Entries (Index) := Item.Entries (Index - 1);
         end loop;
      end if;
      Item.Entries (1) :=
        (Name  => To_Unbounded_String (Name),
         Value => To_Unbounded_String (Value),
         Size  => Entry_Size);
      Item.Count := Item.Count + 1;
      Item.Size := Item.Size + Entry_Size;
   end Insert;

   procedure Decode_Integer
     (Data        : Ada.Streams.Stream_Element_Array;
      Cursor      : in out Ada.Streams.Stream_Element_Offset;
      Prefix_Bits : Positive;
      Value       : out Natural)
   is
      Prefix_Max : constant Natural := 2 ** Prefix_Bits - 1;
      Byte       : Natural;
      Shift      : Natural := 0;
      Count      : Natural := 0;
   begin
      if Prefix_Bits > 8 or else Cursor not in Data'Range then
         raise Protocol_Error with "truncated HPACK integer";
      end if;
      Value := Natural (Data (Cursor)) mod (Prefix_Max + 1);
      Cursor := Cursor + 1;
      if Value < Prefix_Max then
         return;
      end if;
      loop
         if Cursor not in Data'Range or else Count = 5 then
            raise Protocol_Error with "invalid HPACK integer";
         end if;
         Byte := Natural (Data (Cursor));
         Cursor := Cursor + 1;
         if Shift >= 31
           or else (Byte mod 128) > (Maximum_Integer - Value) / (2 ** Shift)
         then
            raise Protocol_Error with "overflowing HPACK integer";
         end if;
         Value := Value + (Byte mod 128) * (2 ** Shift);
         Count := Count + 1;
         exit when Byte < 128;
         Shift := Shift + 7;
      end loop;
   end Decode_Integer;

   function Decode_String
     (Data    : Ada.Streams.Stream_Element_Array;
      Cursor  : in out Ada.Streams.Stream_Element_Offset;
      Maximum : Natural) return String
   is
      Huffman : Boolean;
      Size    : Natural;
   begin
      if Cursor not in Data'Range then
         raise Protocol_Error with "truncated HPACK string";
      end if;
      Huffman := (Data (Cursor) and 16#80#) /= 0;
      Decode_Integer (Data, Cursor, 7, Size);
      if Size > Maximum
        or else Size > Natural (Data'Last - Cursor + 1)
      then
         raise Protocol_Error with "HPACK string exceeds field bound";
      elsif Size = 0 then
         return "";
      end if;
      declare
         Last : constant Ada.Streams.Stream_Element_Offset :=
           Cursor + Ada.Streams.Stream_Element_Offset (Size) - 1;
         Result : Unbounded_String;
      begin
         if Huffman then
            declare
               Decoded : constant String := HTTP_2_Huffman.Decode
                 (Data (Cursor .. Last), Maximum);
            begin
               Cursor := Last + 1;
               return Decoded;
            end;
         end if;
         for Index in Cursor .. Last loop
            Append (Result, Character'Val (Data (Index)));
         end loop;
         Cursor := Last + 1;
         return To_String (Result);
      end;
   end Decode_String;

   procedure Decode_Response
     (Item        : in out Decoder;
      Block       : Ada.Streams.Stream_Element_Array;
      Is_Trailers : Boolean;
      Fields      : in out Flyology.HTTP.Headers.List;
      Status      : out Status_Code;
      Has_Status  : out Boolean)
   is
      Cursor      : Ada.Streams.Stream_Element_Offset := Block'First;
      Saw_Field   : Boolean := False;
      Saw_Regular : Boolean := False;
      List_Size   : Natural := 0;
   begin
      Flyology.HTTP.Headers.Clear (Fields);
      Status := 200;
      Has_Status := False;
      while Cursor in Block'Range loop
         declare
            First       : constant Ada.Streams.Stream_Element :=
              Block (Cursor);
            Index       : Natural;
            Name_Value  : Unbounded_String;
            Field_Value : Unbounded_String;
            Incremental : Boolean := False;
            Table_Update : Boolean := False;
         begin
            if (First and 16#80#) /= 0 then
               Decode_Integer (Block, Cursor, 7, Index);
               Lookup (Item, Index, Name_Value, Field_Value);
            elsif (First and 16#40#) /= 0 then
               Incremental := True;
               Decode_Integer (Block, Cursor, 6, Index);
               if Index = 0 then
                  Name_Value := To_Unbounded_String
                    (Decode_String
                       (Block, Cursor,
                        Flyology.HTTP.Headers.Default_Max_Bytes));
               else
                  declare
                     Ignored : Unbounded_String;
                  begin
                     Lookup (Item, Index, Name_Value, Ignored);
                  end;
               end if;
               Field_Value := To_Unbounded_String
                 (Decode_String
                    (Block, Cursor,
                     Flyology.HTTP.Headers.Default_Max_Bytes));
            elsif (First and 16#E0#) = 16#20# then
               if Saw_Field then
                  raise Protocol_Error with
                    "HPACK table update follows a field representation";
               end if;
               Decode_Integer (Block, Cursor, 5, Index);
               Set_Maximum (Item, Index);
               Table_Update := True;
            else
               Decode_Integer (Block, Cursor, 4, Index);
               if Index = 0 then
                  Name_Value := To_Unbounded_String
                    (Decode_String
                       (Block, Cursor,
                        Flyology.HTTP.Headers.Default_Max_Bytes));
               else
                  declare
                     Ignored : Unbounded_String;
                  begin
                     Lookup (Item, Index, Name_Value, Ignored);
                  end;
               end if;
               Field_Value := To_Unbounded_String
                 (Decode_String
                    (Block, Cursor,
                     Flyology.HTTP.Headers.Default_Max_Bytes));
            end if;

            if not Table_Update then
               Saw_Field := True;
               declare
                  Name  : constant String := To_String (Name_Value);
                  Value : constant String := To_String (Field_Value);
                  Lower : constant String :=
                    Ada.Characters.Handling.To_Lower (Name);
                  Added : constant Natural :=
                    Name'Length + Value'Length + 32;
               begin
                  if Added > Flyology.HTTP.Headers.Default_Max_Bytes
                    or else List_Size >
                      Flyology.HTTP.Headers.Default_Max_Bytes - Added
                  then
                     raise Header_List_Too_Large;
                  elsif Name = ""
                    or else Name /= Lower
                  then
                     raise Protocol_Error with "invalid HTTP/2 field name";
                  elsif Name (Name'First) = ':' then
                     if Is_Trailers or else Saw_Regular
                       or else Name /= ":status" or else Has_Status
                       or else Value'Length /= 3
                       or else
                         (for some Character_Value of Value =>
                            Character_Value not in '0' .. '9')
                     then
                        raise Protocol_Error with
                          "invalid HTTP/2 response pseudo-field";
                     end if;
                     declare
                        Parsed : constant Natural := Natural'Value (Value);
                     begin
                        if Parsed not in Status_Code
                          or else Parsed = 101
                        then
                           raise Protocol_Error with
                             "invalid HTTP/2 response status";
                        end if;
                        Status := Status_Code (Parsed);
                        Has_Status := True;
                     end;
                  else
                     Saw_Regular := True;
                     if Lower in
                       "connection" | "keep-alive" | "proxy-connection" |
                       "te" | "transfer-encoding" | "upgrade"
                     then
                        raise Protocol_Error with
                          "connection-specific HTTP/2 response field";
                     end if;
                     begin
                        Flyology.HTTP.Headers.Add (Fields, Name, Value);
                     exception
                        when Flyology.HTTP.Headers.Headers_Too_Large =>
                           raise Header_List_Too_Large;
                        when Constraint_Error =>
                           raise Protocol_Error with
                             "invalid HTTP/2 response field value";
                     end;
                  end if;
                  List_Size := List_Size + Added;
                  if Incremental then
                     Insert (Item, Name, Value);
                  end if;
               end;
            end if;
         end;
      end loop;
      if Is_Trailers = Has_Status then
         raise Protocol_Error with
           (if Is_Trailers then "status pseudo-field in HTTP/2 trailers"
            else "missing HTTP/2 response status");
      end if;
   end Decode_Response;

   procedure Reset (Item : in out Decoder) is
   begin
      for Table_Entry of Item.Entries loop
         Table_Entry := (others => <>);
      end loop;
      Item.Count := 0;
      Item.Size := 0;
      Item.Maximum := Default_Table_Size;
   end Reset;

   procedure Append_Byte
     (Item : in out Builder; Value : Natural) is
   begin
      Flyology.Bytes.Append
        (Item.Data, Ada.Streams.Stream_Element (Value));
   end Append_Byte;

   procedure Encode_Integer
     (Item        : in out Builder;
      Value       : Natural;
      Prefix_Bits : Positive;
      Pattern     : Natural)
   is
      Prefix_Max : constant Natural := 2 ** Prefix_Bits - 1;
      Rest       : Natural := Value;
   begin
      if Prefix_Bits > 8 or else Pattern > 255 - Prefix_Max then
         raise Constraint_Error with "invalid HPACK integer prefix";
      elsif Rest < Prefix_Max then
         Append_Byte (Item, Pattern + Rest);
         return;
      end if;
      Append_Byte (Item, Pattern + Prefix_Max);
      Rest := Rest - Prefix_Max;
      while Rest >= 128 loop
         Append_Byte (Item, Rest mod 128 + 128);
         Rest := Rest / 128;
      end loop;
      Append_Byte (Item, Rest);
   end Encode_Integer;

   procedure Encode_String (Item : in out Builder; Value : String) is
   begin
      Encode_Integer (Item, Value'Length, 7, 0);
      Flyology.Bytes.Append_Byte_String (Item.Data, Value);
   end Encode_String;

   function Static_Index
     (Name : String; Value : String; Exact : Boolean) return Natural is
   begin
      for Index in 1 .. Static_Count loop
         if Static_Name (Index) = Name
           and then (not Exact or else Static_Value (Index) = Value)
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Static_Index;

   procedure Clear (Item : in out Builder) is
   begin
      Flyology.Bytes.Clear (Item.Data);
   end Clear;

   procedure Add_Indexed (Item : in out Builder; Index : Positive) is
   begin
      Encode_Integer (Item, Index, 7, 16#80#);
   end Add_Indexed;

   procedure Add_Field
     (Item          : in out Builder;
      Name          : String;
      Value         : String;
      Never_Indexed : Boolean := False)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
      Exact : constant Natural := Static_Index (Lower, Value, True);
      Named : constant Natural := Static_Index (Lower, "", False);
   begin
      if Name = "" or else Name /= Lower then
         raise Constraint_Error with "HTTP/2 field names must be lowercase";
      elsif Exact > 0 and then not Never_Indexed then
         Add_Indexed (Item, Exact);
         return;
      end if;
      Encode_Integer
        (Item, Named, 4, (if Never_Indexed then 16#10# else 0));
      if Named = 0 then
         Encode_String (Item, Lower);
      end if;
      Encode_String (Item, Value);
   end Add_Field;

   function Bytes (Item : Builder) return Flyology.Bytes.Unbounded_Bytes is
     (Item.Data);

end Flyology.HTTP.HTTP_2_HPACK;
