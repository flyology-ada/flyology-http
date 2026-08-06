with Ada.Streams;
with Interfaces;

procedure Flyology.HTTP.HTTP_2_Settings.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Interfaces.Unsigned_32;

   Item   : State;
   Result : Apply_Result;
begin
   Apply
     (Item,
      (0, 1, 0, 0, 0, 0,
       0, 3, 0, 0, 0, 10,
       0, 4, 0, 1, 0, 0,
       0, 5, 0, 0, 128, 0,
       0, 6, 0, 0, 32, 0,
       16#FE#, 16#ED#, 1, 2, 3, 4),
      Result);
   pragma Assert (Result = Settings_Accepted);
   pragma Assert (Item.Header_Table_Size = 0);
   pragma Assert (Item.Maximum_Streams = 10);
   pragma Assert (Item.Initial_Window_Size = 65_536);
   pragma Assert (Item.Maximum_Frame_Size = 32_768);
   pragma Assert (Item.Maximum_Header_List_Size = 8_192);

   Apply (Item, (0, 2, 0, 0, 0, 0), Result);
   pragma Assert (Result = Settings_Protocol_Error);
   Apply (Item, (0, 4, 16#80#, 0, 0, 0), Result);
   pragma Assert (Result = Settings_Flow_Control_Error);
   Apply (Item, (0, 5, 0, 0, 16, 0), Result);
   pragma Assert (Result = Settings_Protocol_Error);
   Apply (Item, (1, 2, 3), Result);
   pragma Assert (Result = Settings_Protocol_Error);

   declare
      Payload : constant Ada.Streams.Stream_Element_Array := Initial_Payload;
   begin
      pragma Assert
        (Payload = (0, 2, 0, 0, 0, 0, 0, 6, 0, 0, 64, 0));
   end;
end Flyology.HTTP.HTTP_2_Settings.Smoke;
