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
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Priority_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Ping_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Window_Update_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Continuation_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);

   Process_Frame
     (Item, HTTP_3_Frame_Policy.Goaway_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Error and then not Has_Peer_Goaway (Item));
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Goaway_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 1), Status);
   pragma Assert (Status = ID_Error and then not Has_Peer_Goaway (Item));
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Goaway_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 4), Status);
   pragma Assert
     (Status = Accepted
      and then Has_Peer_Goaway (Item)
      and then Peer_Goaway_ID (Item) = 4);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Goaway_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 0), Status);
   pragma Assert (Status = Accepted and then Peer_Goaway_ID (Item) = 0);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Goaway_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 4), Status);
   pragma Assert (Status = ID_Error and then Peer_Goaway_ID (Item) = 0);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Max_Push_ID_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 0), Status);
   pragma Assert (Status = Frame_Unexpected);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Cancel_Push_Frame,
      Ada.Streams.Stream_Element_Array'(1 => 0), Status);
   pragma Assert (Status = ID_Error);
   Process_Frame
     (Item, HTTP_3_Frame_Policy.Cancel_Push_Frame,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert (Status = Frame_Error);

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

   declare
      Server : Control_State;
   begin
      Register_Peer_Control
        (Server, 2, HTTP_3_Stream_Policy.Server, Status);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Settings_Frame,
         Ada.Streams.Stream_Element_Array'(1, 0, 7, 0), Status);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Goaway_Frame,
         Ada.Streams.Stream_Element_Array'(1 => 3), Status);
      pragma Assert
        (Status = Accepted and then Peer_Goaway_ID (Server) = 3);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Max_Push_ID_Frame,
         Ada.Streams.Stream_Element_Array'(1 => 5), Status);
      pragma Assert (Status = Accepted);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Max_Push_ID_Frame,
         Ada.Streams.Stream_Element_Array'(1 => 7), Status);
      pragma Assert (Status = Accepted);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Max_Push_ID_Frame,
         Ada.Streams.Stream_Element_Array'(1 => 6), Status);
      pragma Assert (Status = ID_Error);
      Process_Frame
        (Server, HTTP_3_Frame_Policy.Cancel_Push_Frame,
         Ada.Streams.Stream_Element_Array'(1 => 0), Status);
      pragma Assert (Status = ID_Error);
   end;
end Flyology.HTTP.HTTP_3_Control_Policy.Smoke;
