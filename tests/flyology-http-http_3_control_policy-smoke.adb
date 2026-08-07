with Flyology.HTTP.HTTP_3_Frame_Policy;

procedure Flyology.HTTP.HTTP_3_Control_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type HTTP_3_Settings_Policy.Settings;

   Item   : Control_State;
   Status : Operation_Status;
begin
   Register_Peer_Control (Item, 2, HTTP_3_Stream_Policy.Client, Status);
   pragma Assert (Status = Stream_Creation_Error);
   Register_Peer_Control (Item, 3, HTTP_3_Stream_Policy.Client, Status);
   pragma Assert (Status = Accepted and then Has_Peer_Control (Item));
   Register_Peer_Control (Item, 7, HTTP_3_Stream_Policy.Client, Status);
   pragma Assert (Status = Stream_Creation_Error);

   Process_Frame
     (Item, HTTP_3_Frame_Policy.Data_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Missing_Settings);

   Process_Frame
     (Item, HTTP_3_Frame_Policy.Settings_Frame,
      Ada.Streams.Stream_Element_Array'(1, 0, 7, 0), Status);
   pragma Assert
     (Status = Accepted
      and then Has_Peer_Settings (Item)
      and then Peer_Settings (Item) = (others => <>));

   Process_Frame
     (Item, HTTP_3_Frame_Policy.Settings_Frame,
      Ada.Streams.Stream_Element_Array'(1, 0, 7, 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Headers_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, 16#21#, Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Accepted);

   Peer_Stream_Closed (Item, 3, Status);
   pragma Assert (Status = Critical_Stream_Closed);

   declare
      Preface : constant Preface_Result :=
        Build_Local_Preface ((others => <>));
   begin
      pragma Assert
        (Preface.Length = 7
         and then Preface.Data (1 .. 7) = (0, 4, 4, 1, 0, 7, 0));
   end;

   declare
      Broken : Control_State;
   begin
      Register_Peer_Control
        (Broken, 3, HTTP_3_Stream_Policy.Client, Status);
      Process_Frame
        (Broken, HTTP_3_Frame_Policy.Settings_Frame,
         Ada.Streams.Stream_Element_Array'(1, 0, 1, 1), Status);
      pragma Assert (Status = Settings_Error);
   end;
end Flyology.HTTP.HTTP_3_Control_Policy.Smoke;
