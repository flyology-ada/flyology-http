with Ada.Streams;
with Ada.Text_IO;
with Flyology.HTTP.Headers;
with Flyology.HTTP.HTTP_3;

procedure Flyology.HTTP.HTTP_3_Client_Connection.Smoke is
   package H3 renames Flyology.HTTP.HTTP_3;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element_Array;

   Item : Session;
   Bad  : Stream_Handle;
   Good : Stream_Handle;
   Accepted : Boolean;
   Published : Boolean;
   Event : H3.Event;
   Fields : Flyology.HTTP.Headers.List;
   Trailers : Flyology.HTTP.Headers.List;
   Status : Status_Code;
   Head : Head_Result;
   Body_State : Body_Result;
   Finished : Boolean;
   Data : Ada.Streams.Stream_Element_Array (1 .. 8);
   Last : Ada.Streams.Stream_Element_Offset;
begin
   Open (Item, 0, Bad, Accepted);
   pragma Assert (Accepted);
   Open (Item, 4, Good, Accepted);
   pragma Assert (Accepted);

   --  DATA before a final head is local to stream zero. In particular,
   --  Publish must not report a connection failure that an arbitrary pump
   --  owner could accidentally attribute to stream four.
   Event.Kind := H3.Data_Received;
   Event.Stream := 0;
   Event.Data (1) := Ada.Streams.Stream_Element (Character'Pos ('x'));
   Event.Data_Length := 1;
   Publish (Item, Event, Published);
   pragma Assert (Published);

   H3.Clear (Event.Headers);
   H3.Append (Event.Headers, H3.Make_Field (":status", "200"));
   H3.Append (Event.Headers, H3.Make_Field ("content-length", "4"));
   Event.Kind := H3.Headers_Received;
   Event.Stream := 4;
   Event.Data_Length := 0;
   Publish (Item, Event, Published);
   pragma Assert (Published);

   Event := (Kind => H3.Data_Received, Stream => 4, others => <>);
   Event.Data (1) := Ada.Streams.Stream_Element (Character'Pos ('g'));
   Event.Data (2) := Ada.Streams.Stream_Element (Character'Pos ('o'));
   Event.Data (3) := Ada.Streams.Stream_Element (Character'Pos ('o'));
   Event.Data (4) := Ada.Streams.Stream_Element (Character'Pos ('d'));
   Event.Data_Length := 4;
   Publish (Item, Event, Published);
   pragma Assert (Published);
   Event := (Kind => H3.Stream_Ended, Stream => 4, others => <>);
   Publish (Item, Event, Published);
   pragma Assert (Published);

   Poll_Head (Item, Bad, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Stream_Failed);
   Poll_Head (Item, Good, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Ready and then Status = 200);
   Read (Item, Good, Data, Last, Finished, Body_State, Trailers);
   pragma Assert (Body_State = Body_Finished and then Finished);
   pragma Assert (Last = Data'First + 3);
   pragma Assert
     (Data (1 .. 4) =
        [Ada.Streams.Stream_Element (Character'Pos ('g')),
         Ada.Streams.Stream_Element (Character'Pos ('o')),
         Ada.Streams.Stream_Element (Character'Pos ('o')),
         Ada.Streams.Stream_Element (Character'Pos ('d'))]);

   Release_Stream (Item, Bad);
   Release_Stream (Item, Good);

   --  RFC 9114 applies the same response field-section rules as HTTP/2:
   --  101 is unavailable, pseudo-fields precede regular fields, field names
   --  are lowercase, and connection-specific fields are forbidden.  Each
   --  violation is stream-local.
   Open (Item, 8, Bad, Accepted);
   pragma Assert (Accepted);
   H3.Clear (Event.Headers);
   H3.Append (Event.Headers, H3.Make_Field (":status", "101"));
   Event.Kind := H3.Headers_Received;
   Event.Stream := 8;
   Publish (Item, Event, Published);
   pragma Assert (Published);
   Poll_Head (Item, Bad, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Stream_Failed);
   Release_Stream (Item, Bad);

   Open (Item, 12, Bad, Accepted);
   pragma Assert (Accepted);
   H3.Clear (Event.Headers);
   H3.Append (Event.Headers, H3.Make_Field ("server", "fixture"));
   H3.Append (Event.Headers, H3.Make_Field (":status", "200"));
   Event.Stream := 12;
   Publish (Item, Event, Published);
   pragma Assert (Published);
   Poll_Head (Item, Bad, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Stream_Failed);
   Release_Stream (Item, Bad);

   Open (Item, 16, Bad, Accepted);
   pragma Assert (Accepted);
   H3.Clear (Event.Headers);
   H3.Append (Event.Headers, H3.Make_Field (":status", "200"));
   H3.Append (Event.Headers, H3.Make_Field ("Connection", "close"));
   Event.Stream := 16;
   Publish (Item, Event, Published);
   pragma Assert (Published);
   Poll_Head (Item, Bad, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Stream_Failed);
   Release_Stream (Item, Bad);

   Open (Item, 20, Bad, Accepted);
   pragma Assert (Accepted);
   H3.Clear (Event.Headers);
   H3.Append (Event.Headers, H3.Make_Field (":status", "200"));
   H3.Append (Event.Headers, H3.Make_Field ("te", "trailers"));
   Event.Stream := 20;
   Publish (Item, Event, Published);
   pragma Assert (Published);
   Poll_Head (Item, Bad, Head, Status, Fields, Finished);
   pragma Assert (Head = Head_Stream_Failed);
   Release_Stream (Item, Bad);
   Ada.Text_IO.Put_Line ("HTTP/3 client stream isolation passed");
end Flyology.HTTP.HTTP_3_Client_Connection.Smoke;
