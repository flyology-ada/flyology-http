with Ada.Streams;
with Interfaces;

procedure Flyology.HTTP.HTTP_2_Payloads.Smoke is
   use type Interfaces.Unsigned_32;
   View   : Fragment_View;
   Result : Fragment_Result;
begin
   Data_Fragment
     (0, Ada.Streams.Stream_Element_Array'(1 => 1, 2 => 2, 3 => 3),
      View, Result);
   pragma Assert
     (Result = Valid_Fragment and then View = (False, 1, 3));
   Data_Fragment
     (Frames.Padded_Flag,
      Ada.Streams.Stream_Element_Array'(1 => 2, 2 => 9, 3 => 0, 4 => 0),
      View, Result);
   pragma Assert
     (Result = Valid_Fragment and then View = (False, 2, 2));
   Data_Fragment
     (Frames.Padded_Flag,
      Ada.Streams.Stream_Element_Array'(1 => 4, 2 => 1, 3 => 2),
      View, Result);
   pragma Assert (Result = Invalid_Padding);

   Header_Fragment
     (3, Frames.Priority_Flag,
      Ada.Streams.Stream_Element_Array'
        (1 => 0, 2 => 0, 3 => 0, 4 => 1, 5 => 15, 6 => 16#82#),
      View, Result);
   pragma Assert
     (Result = Valid_Fragment and then View = (False, 6, 6));
   Header_Fragment
     (3, Frames.Priority_Flag,
      Ada.Streams.Stream_Element_Array'
        (1 => 0, 2 => 0, 3 => 0, 4 => 3, 5 => 15),
      View, Result);
   pragma Assert (Result = Invalid_Priority);

   pragma Assert
     (Unsigned_32
        (Ada.Streams.Stream_Element_Array'
           (1 => 1, 2 => 2, 3 => 3, 4 => 4)) = 16#0102_0304#);
   pragma Assert
     (Stream_ID
        (Ada.Streams.Stream_Element_Array'
           (1 => 16#80#, 2 => 0, 3 => 0, 4 => 3)) = 3);
   pragma Assert
     (Window_Increment
        (Ada.Streams.Stream_Element_Array'
           (1 => 16#80#, 2 => 0, 3 => 0, 4 => 1)) = 1);
   pragma Assert
     (Window_Increment
        (Ada.Streams.Stream_Element_Array'
           (1 => 0, 2 => 0, 3 => 0, 4 => 0)) = 0);
end Flyology.HTTP.HTTP_2_Payloads.Smoke;
