package body Flyology.HTTP.HTTP_2_Frames is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   function Decode (Value : Wire_Header) return Header is
      Length : constant Frame_Size :=
        Frame_Size (Value (1)) * 65_536
          + Frame_Size (Value (2)) * 256
          + Frame_Size (Value (3));
      Raw_Stream : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Left (Interfaces.Unsigned_32 (Value (6)), 24)
          or Interfaces.Shift_Left
            (Interfaces.Unsigned_32 (Value (7)), 16)
          or Interfaces.Shift_Left
            (Interfaces.Unsigned_32 (Value (8)), 8)
          or Interfaces.Unsigned_32 (Value (9));
   begin
      return
        (Length    => Length,
         Kind      => Frame_Code (Value (4)),
         Flags     => Frame_Flags (Value (5)),
         Stream_ID => Stream_Identifier (Raw_Stream and 16#7FFF_FFFF#));
   end Decode;

   function Encode (Value : Header) return Wire_Header is
      Length : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value.Length);
      Stream : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value.Stream_ID);
   begin
      return
        (1 => Ada.Streams.Stream_Element
                (Interfaces.Shift_Right (Length, 16) and 16#FF#),
         2 => Ada.Streams.Stream_Element
                (Interfaces.Shift_Right (Length, 8) and 16#FF#),
         3 => Ada.Streams.Stream_Element (Length and 16#FF#),
         4 => Ada.Streams.Stream_Element (Value.Kind),
         5 => Ada.Streams.Stream_Element (Value.Flags),
         6 => Ada.Streams.Stream_Element
                (Interfaces.Shift_Right (Stream, 24) and 16#7F#),
         7 => Ada.Streams.Stream_Element
                (Interfaces.Shift_Right (Stream, 16) and 16#FF#),
         8 => Ada.Streams.Stream_Element
                (Interfaces.Shift_Right (Stream, 8) and 16#FF#),
         9 => Ada.Streams.Stream_Element (Stream and 16#FF#));
   end Encode;

   function Validate
     (Value : Header;
      Maximum : Maximum_Frame_Size := Default_Maximum_Frame_Size)
      return Header_Validity
   is
      Connection_Frame : constant Boolean :=
        Value.Kind in Settings_Frame | Ping_Frame | Goaway_Frame;
      Stream_Frame : constant Boolean :=
        Value.Kind in Data_Frame | Headers_Frame | Priority_Frame |
          Reset_Stream_Frame | Push_Promise_Frame | Continuation_Frame;
   begin
      if Value.Length > Maximum then
         return Frame_Too_Large;
      elsif (Connection_Frame and then Value.Stream_ID /= 0)
        or else (Stream_Frame and then Value.Stream_ID = 0)
      then
         return Invalid_Stream;
      end if;

      case Value.Kind is
         when Priority_Frame =>
            return
              (if Value.Length = 5 then Valid_Header else Invalid_Length);
         when Reset_Stream_Frame | Window_Update_Frame =>
            return
              (if Value.Length = 4 then Valid_Header else Invalid_Length);
         when Settings_Frame =>
            if (Value.Flags and Ack_Flag) /= 0 then
               return
                 (if Value.Length = 0 then Valid_Header else Invalid_Length);
            end if;
            return
              (if Value.Length mod 6 = 0
               then Valid_Header else Invalid_Length);
         when Ping_Frame =>
            return
              (if Value.Length = 8 then Valid_Header else Invalid_Length);
         when Goaway_Frame =>
            return
              (if Value.Length >= 8 then Valid_Header else Invalid_Length);
         when others =>
            return Valid_Header;
      end case;
   end Validate;

end Flyology.HTTP.HTTP_2_Frames;
