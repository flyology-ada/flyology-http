with Ada.Streams;
with Interfaces;
with Flyology.HTTP.HTTP_2_Frames;

--  Validates and locates payload fields for HTTP/2 frames handled by the
--  connection pump. Returned views borrow the caller's payload indices.
private package Flyology.HTTP.HTTP_2_Payloads is

   package Frames renames Flyology.HTTP.HTTP_2_Frames;

   type Fragment_View is record
      Empty : Boolean := True;
      First : Ada.Streams.Stream_Element_Offset := 1;
      Last  : Ada.Streams.Stream_Element_Offset := 1;
   end record;

   type Fragment_Result is
     (Valid_Fragment, Invalid_Padding, Invalid_Priority);

   procedure Data_Fragment
     (Flags   : Frames.Frame_Flags;
      Payload : Ada.Streams.Stream_Element_Array;
      View    : out Fragment_View;
      Result  : out Fragment_Result);

   procedure Header_Fragment
     (Stream_ID : Frames.Stream_Identifier;
      Flags     : Frames.Frame_Flags;
      Payload   : Ada.Streams.Stream_Element_Array;
      View      : out Fragment_View;
      Result    : out Fragment_Result);

   function Unsigned_32
     (Payload : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_32
   with Pre => Payload'Length >= 4;

   function Stream_ID
     (Payload : Ada.Streams.Stream_Element_Array)
      return Frames.Stream_Identifier
   with Pre => Payload'Length >= 4;

   function Window_Increment
     (Payload : Ada.Streams.Stream_Element_Array) return Natural
   with Pre => Payload'Length >= 4;

end Flyology.HTTP.HTTP_2_Payloads;
