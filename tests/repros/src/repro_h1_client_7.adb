--  H1-CLIENT-7 (new; found while verifying H1-CLIENT-1).
--
--  http_1_internals.adb:151-168 Parse_Natural guards its accumulator against
--  overflow with
--
--     Result > (Natural'Last - (Character'Pos (Item) - Character'Pos ('0')))
--                / 10
--
--  and then accumulates with
--
--     Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
--
--  The guard reasons about the DIGIT VALUE, but the statement adds
--  Character'Pos (Item), which is 48 larger, before subtracting 48.  The
--  intermediate Result * 10 + Character'Pos (Item) is an Integer expression,
--  so for a Content-Length in 2_147_483_600 .. 2_147_483_647 -- values that
--  Natural represents exactly and that the guard deliberately admits -- the
--  intermediate exceeds Integer'Last and the overflow check raises
--  Constraint_Error out of the production response head parser.
--
--  That is a different defect from H1-CLIENT-1 (which is about lengths above
--  Natural'Last being refused at all): here the length is inside Natural and
--  the parser is expected to accept it outright.  This program asserts that
--  a Content-Length of Natural'Last parses as a valid head, on the oracle and
--  on the live transport, and that no raw runtime check escapes.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_H1_Client_7 is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;
   use type Ada.Exceptions.Exception_Id;

   Head_Complete : constant String :=
     "peer closed before Content-Length was received";

   Live_Length : constant String := "2147483647";  --  Natural'Last

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   type Outcome_Kind is (Head_Valid, Typed_Rejection, Runtime_Check, Other);

   function Classify (Length_Text : String) return Outcome_Kind is
      Wire : constant String :=
        "HTTP/1.1 200 OK" & CRLF
        & "Content-Length: " & Length_Text & CRLF & CRLF;
   begin
      HC.Testing.Validate_Response (B (Wire));
      return Other;
   exception
      when Error : Flyology.HTTP.Protocol_Error =>
         return (if Ada.Exceptions.Exception_Message (Error) = Head_Complete
                 then Head_Valid else Typed_Rejection);
      when HC.Response_Too_Large =>
         return Typed_Rejection;
      when Constraint_Error | Program_Error | Storage_Error =>
         return Runtime_Check;
      when others =>
         return Other;
   end Classify;

   function Detail (Length_Text : String) return String is
      Wire : constant String :=
        "HTTP/1.1 200 OK" & CRLF
        & "Content-Length: " & Length_Text & CRLF & CRLF;
   begin
      HC.Testing.Validate_Response (B (Wire));
      return "<accepted with no body>";
   exception
      when Error : others =>
         return Ada.Exceptions.Exception_Name (Error) & ": "
           & Ada.Exceptions.Exception_Message (Error);
   end Detail;

   --  Live path -----------------------------------------------------------

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Message    : Unbounded_String;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      procedure Server_Failed (Text : String) is
      begin
         Message := To_Unbounded_String (Text);
      end Server_Failed;

      function Server_Note return String is (To_String (Message));
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
      Buffer   : Stream_Element_Array (1 .. 4_096);
      Last     : Stream_Element_Offset;
      Head     : Unbounded_String;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Sockets.Accept_Socket
        (Listener, Peer, Address, Timeout => 5.0, Status => Status);
      if Status /= Sockets.Completed then
         raise Program_Error with "raw peer accept did not complete";
      end if;
      loop
         Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
         exit when Last < Buffer'First;
         for Index in Buffer'First .. Last loop
            Append (Head, Character'Val (Buffer (Index)));
         end loop;
         exit when Ada.Strings.Fixed.Index (To_String (Head), CRLF & CRLF)
           /= 0;
      end loop;
      Sockets.Send_All
        (Peer,
         B ("HTTP/1.1 200 OK" & CRLF
            & "Content-Length: " & Live_Length & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Connection: close" & CRLF & CRLF
            & "abcd"),
         Timeout => 5.0);
      loop
         Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
         exit when Last < Buffer'First;
      end loop;
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Server_Failed
           (Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
   end Raw_Server;

   procedure Run_Live_Exchange is
      Port    : Sockets.Port;
      Item    : aliased HC.Client (Capacity => 1);
      Request : HC.Request;
   begin
      Coordination.Wait_Ready (Port);
      HC.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:"
            & Decimal (Long_Long_Integer (Port))));
      HC.Set_Target (Request, "/two-gib");
      declare
         Reply : HC.Response := HC.Execute (Item, Request, Timeout => 5.0);
      begin
         Check (HC.Status (Reply) = 200,
                "live HTTP/1.1 path: Content-Length " & Live_Length
                & " yields the 200 head");
         Expect_Equal
           (HC.Header (Reply, "Content-Length"), Live_Length,
            "live HTTP/1.1 path: the declared length is readable");
      end;
      HC.Shutdown (Item);
   exception
      when Occurrence : others =>
         Check (False,
                "live HTTP/1.1 path: Content-Length " & Live_Length
                & " yields the 200 head, got "
                & Ada.Exceptions.Exception_Name (Occurrence) & ": "
                & Ada.Exceptions.Exception_Message (Occurrence));
         Check (Ada.Exceptions.Exception_Identity (Occurrence)
                  /= Constraint_Error'Identity,
                "live HTTP/1.1 path: no raw Constraint_Error reaches the"
                & " caller");
         HC.Shutdown (Item);
   end Run_Live_Exchange;

   First_Check : Long_Long_Integer := 0;
   Last_Check  : Long_Long_Integer := 0;
   Count       : Natural := 0;
begin
   Note ("Natural'Last is" & Natural'Image (Natural'Last));
   Note ("2147483599 -> " & Detail ("2147483599"));
   Note ("2147483600 -> " & Detail ("2147483600"));
   Note ("2147483647 -> " & Detail ("2147483647"));
   Note ("2147483648 -> " & Detail ("2147483648"));

   --  Map the whole neighbourhood so the report states the exact set.
   for Value in Long_Long_Integer range 2_147_483_580 .. 2_147_483_660 loop
      if Classify (Decimal (Value)) = Runtime_Check then
         if Count = 0 then
            First_Check := Value;
         end if;
         Last_Check := Value;
         Count := Count + 1;
      end if;
   end loop;
   if Count = 0 then
      Note ("no Content-Length in 2147483580 .. 2147483660 raises a"
            & " runtime check");
   else
      Note ("Content-Length values raising a runtime check:"
            & Natural'Image (Count) & ", from " & Decimal (First_Check)
            & " to " & Decimal (Last_Check));
   end if;

   Check (Classify ("2147483599") = Head_Valid,
          "control: Content-Length 2147483599 is a valid head");
   Check (Classify ("2147483600") = Head_Valid,
          "Content-Length 2147483600, inside Natural, is a valid head");
   Check (Classify (Decimal (Long_Long_Integer (Natural'Last))) = Head_Valid,
          "Content-Length 2147483647 (Natural'Last) is a valid head");
   Check (Classify ("2147483600") /= Runtime_Check,
          "Content-Length 2147483600 does not escape as a runtime check");
   Check (Classify ("2147483648") /= Runtime_Check,
          "control: an out-of-range Content-Length is a typed rejection");

   Run_Live_Exchange;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;

   Finish;
end Repro_H1_Client_7;
