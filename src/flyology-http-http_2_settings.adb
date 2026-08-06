package body Flyology.HTTP.HTTP_2_Settings is
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_32;

   Header_Table_Size_Id       : constant := 1;
   Enable_Push_Id             : constant := 2;
   Maximum_Streams_Id         : constant := 3;
   Initial_Window_Size_Id     : constant := 4;
   Maximum_Frame_Size_Id      : constant := 5;
   Maximum_Header_List_Size_Id : constant := 6;

   function Value_At
     (Payload : Ada.Streams.Stream_Element_Array;
      Cursor  : Ada.Streams.Stream_Element_Offset) return Setting_Value
   is
     (Interfaces.Shift_Left (Setting_Value (Payload (Cursor + 2)), 24)
        or Interfaces.Shift_Left
          (Setting_Value (Payload (Cursor + 3)), 16)
        or Interfaces.Shift_Left
          (Setting_Value (Payload (Cursor + 4)), 8)
        or Setting_Value (Payload (Cursor + 5)));

   procedure Apply
     (Item    : in out State;
      Payload : Ada.Streams.Stream_Element_Array;
      Result  : out Apply_Result;
      Peer_Is_Server : Boolean := True)
   is
      Cursor : Ada.Streams.Stream_Element_Offset := Payload'First;
   begin
      if Payload'Length mod 6 /= 0 then
         Result := Settings_Protocol_Error;
         return;
      end if;
      while Cursor in Payload'Range loop
         declare
            Identifier : constant Natural :=
              Natural (Payload (Cursor)) * 256
                + Natural (Payload (Cursor + 1));
            Value : constant Setting_Value := Value_At (Payload, Cursor);
         begin
            case Identifier is
               when Header_Table_Size_Id =>
                  Item.Header_Table_Size := Value;
               when Enable_Push_Id =>
                  if Peer_Is_Server or else Value > 1 then
                     --  RFC 9113 prohibits SETTINGS_ENABLE_PUSH from a server.
                     Result := Settings_Protocol_Error;
                     return;
                  end if;
                  Item.Enable_Push := Value = 1;
               when Maximum_Streams_Id =>
                  Item.Maximum_Streams := Value;
               when Initial_Window_Size_Id =>
                  if Value > 16#7FFF_FFFF# then
                     Result := Settings_Flow_Control_Error;
                     return;
                  end if;
                  Item.Initial_Window_Size := Value;
               when Maximum_Frame_Size_Id =>
                  if Value < Setting_Value (Frames.Default_Maximum_Frame_Size)
                    or else Value > Setting_Value (Frames.Largest_Frame_Size)
                  then
                     Result := Settings_Protocol_Error;
                     return;
                  end if;
                  Item.Maximum_Frame_Size := Frames.Maximum_Frame_Size (Value);
               when Maximum_Header_List_Size_Id =>
                  Item.Maximum_Header_List_Size := Value;
               when others =>
                  null;
            end case;
         end;
         Cursor := Cursor + 6;
      end loop;
      Result := Settings_Accepted;
   end Apply;

   function Initial_Payload return Ada.Streams.Stream_Element_Array is
      --  SETTINGS_ENABLE_PUSH = 0, the retained response-list bound, and a
      --  per-stream window that reserves connection credit for other streams.
      use Ada.Streams;
   begin
      return
        (1 => 0, 2 => Enable_Push_Id, 3 => 0, 4 => 0, 5 => 0, 6 => 0,
         7 => 0, 8 => Maximum_Header_List_Size_Id,
         9 => 0,
         10 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Header_List_Size, 16)),
         11 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Header_List_Size, 8)
              and 16#FF#),
         12 => Stream_Element (Advertised_Header_List_Size and 16#FF#),
         13 => 0, 14 => Initial_Window_Size_Id,
         15 => 0,
         16 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Initial_Window_Size, 16)),
         17 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Initial_Window_Size, 8)
              and 16#FF#),
         18 => Stream_Element
           (Advertised_Initial_Window_Size and 16#FF#));
   end Initial_Payload;

   function Server_Initial_Payload
     (Maximum_Streams : Positive) return Ada.Streams.Stream_Element_Array
   is
      use Ada.Streams;
      Streams : constant Setting_Value := Setting_Value (Maximum_Streams);
   begin
      return
        (1 => 0, 2 => Maximum_Streams_Id,
         3 => Stream_Element (Interfaces.Shift_Right (Streams, 24)),
         4 => Stream_Element
           (Interfaces.Shift_Right (Streams, 16) and 16#FF#),
         5 => Stream_Element
           (Interfaces.Shift_Right (Streams, 8) and 16#FF#),
         6 => Stream_Element (Streams and 16#FF#),
         7 => 0, 8 => Maximum_Header_List_Size_Id,
         9 => 0,
         10 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Header_List_Size, 16)),
         11 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Header_List_Size, 8)
              and 16#FF#),
         12 => Stream_Element (Advertised_Header_List_Size and 16#FF#),
         13 => 0, 14 => Initial_Window_Size_Id,
         15 => 0,
         16 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Initial_Window_Size, 16)),
         17 => Stream_Element
           (Interfaces.Shift_Right (Advertised_Initial_Window_Size, 8)
              and 16#FF#),
         18 => Stream_Element
           (Advertised_Initial_Window_Size and 16#FF#));
   end Server_Initial_Payload;

end Flyology.HTTP.HTTP_2_Settings;
