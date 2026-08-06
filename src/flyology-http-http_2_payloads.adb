package body Flyology.HTTP.HTTP_2_Payloads is
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   function Unsigned_32
     (Payload : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_32
   is
      First : constant Ada.Streams.Stream_Element_Offset := Payload'First;
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_32 (Payload (First)), 24)
          or Interfaces.Shift_Left
            (Interfaces.Unsigned_32 (Payload (First + 1)), 16)
          or Interfaces.Shift_Left
            (Interfaces.Unsigned_32 (Payload (First + 2)), 8)
          or Interfaces.Unsigned_32 (Payload (First + 3));
   end Unsigned_32;

   function Stream_ID
     (Payload : Ada.Streams.Stream_Element_Array)
      return Frames.Stream_Identifier
   is
     (Frames.Stream_Identifier (Unsigned_32 (Payload) and 16#7FFF_FFFF#));

   function Window_Increment
     (Payload : Ada.Streams.Stream_Element_Array) return Natural
   is
     (Natural (Unsigned_32 (Payload) and 16#7FFF_FFFF#));

   procedure Locate
     (Flags         : Frames.Frame_Flags;
      Has_Priority  : Boolean;
      Stream        : Frames.Stream_Identifier;
      Payload       : Ada.Streams.Stream_Element_Array;
      View          : out Fragment_View;
      Result        : out Fragment_Result)
   is
      Cursor  : Ada.Streams.Stream_Element_Offset := Payload'First;
      Padding : Natural := 0;
   begin
      View :=
        (Empty => True, First => Payload'First, Last => Payload'First);
      if (Flags and Frames.Padded_Flag) /= 0 then
         if Payload'Length = 0 then
            Result := Invalid_Padding;
            return;
         end if;
         Padding := Natural (Payload (Cursor));
         Cursor := Cursor + 1;
      end if;
      if Has_Priority then
         if Natural (Payload'Last - Cursor + 1) < 5 then
            Result := Invalid_Priority;
            return;
         elsif Stream_ID (Payload (Cursor .. Cursor + 3)) = Stream then
            Result := Invalid_Priority;
            return;
         end if;
         Cursor := Cursor + 5;
      end if;
      if Payload'Length = 0 then
         Result := Valid_Fragment;
         return;
      end if;
      if Padding > Natural (Payload'Last - Cursor + 1) then
         Result := Invalid_Padding;
         return;
      end if;
      View :=
        (Empty =>
           Cursor >
             Payload'Last - Ada.Streams.Stream_Element_Offset (Padding),
         First => Cursor,
         Last  => Payload'Last - Ada.Streams.Stream_Element_Offset (Padding));
      Result := Valid_Fragment;
   end Locate;

   procedure Data_Fragment
     (Flags   : Frames.Frame_Flags;
      Payload : Ada.Streams.Stream_Element_Array;
      View    : out Fragment_View;
      Result  : out Fragment_Result) is
   begin
      Locate (Flags, False, 0, Payload, View, Result);
   end Data_Fragment;

   procedure Header_Fragment
     (Stream_ID : Frames.Stream_Identifier;
      Flags     : Frames.Frame_Flags;
      Payload   : Ada.Streams.Stream_Element_Array;
      View      : out Fragment_View;
      Result    : out Fragment_Result) is
   begin
      Locate
        (Flags, (Flags and Frames.Priority_Flag) /= 0,
         Stream_ID, Payload, View, Result);
   end Header_Fragment;

end Flyology.HTTP.HTTP_2_Payloads;
