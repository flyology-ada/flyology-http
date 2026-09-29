--  H1-CLIENT-4.  Parse_Available_Final_Head
--  (http_1_internals.adb:363-381) applies two different bounds to the same
--  16 KiB limit:
--
--     if Mark = 0 then
--        if Text'Length >= Flyology.HTTP.Headers.Default_Max_Bytes then
--           raise Response_Too_Large;
--     ...
--        if Head_Last - Text'First + 1 >
--          Flyology.HTTP.Headers.Default_Max_Bytes
--        then
--           raise Response_Too_Large;
--
--  The second accepts a head of exactly Default_Max_Bytes; the first refuses
--  as soon as Default_Max_Bytes bytes are buffered without the terminating
--  CRLF CRLF yet present.  tests/http_client_parser_matrix.adb:117-122,201-203
--  builds a head of exactly Default_Max_Bytes and validates it through the
--  oracle, so the conformance ledger records a boundary the live transport
--  does not honour.
--
--  This program asserts that the head the parser matrix accepts is also
--  accepted on the live transport.  The peer writes the response head in two
--  pieces around the client's 8 KiB receive buffer
--  (client.adb:65 Receive_Buffer_Size := 8 * 1_024), which is what an ordinary
--  kernel delivery does.  The H = 16382 case is the control.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.HTTP.Headers;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_H1_Client_4 is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   Bound : constant Natural := Flyology.HTTP.Headers.Default_Max_Bytes;

   --  The parser matrix's construction, verbatim.
   Head_Prefix : constant String := "HTTP/1.1 200 OK" & CRLF & "X: ";
   Head_Suffix : constant String := CRLF;
   Exact_Value_Length : constant Natural :=
     Bound - Head_Prefix'Length - Head_Suffix'Length;

   --  Wire bytes for a head whose length through the CRLF that ends the last
   --  field line is Bound - Shrink.
   function Wire (Shrink : Natural) return String is
     (Head_Prefix & String'(1 .. Exact_Value_Length - Shrink => 'a')
      & Head_Suffix & CRLF);

   type Case_Index is (H_16382, H_16383, H_16384);
   Shrink_Of : constant array (Case_Index) of Natural :=
     (H_16382 => 2, H_16383 => 1, H_16384 => 0);

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Oracle (Which : Case_Index) return String is
   begin
      HC.Testing.Validate_Response (B (Wire (Shrink_Of (Which))));
      return "accepted";
   exception
      when Error : others =>
         return Ada.Exceptions.Exception_Name (Error);
   end Oracle;

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

      procedure Serve (Which : Case_Index) is
         Peer    : Sockets.Socket_Type;
         Address : Sockets.Endpoint;
         Status  : Sockets.Selector_Status;
         Buffer  : Stream_Element_Array (1 .. 4_096);
         Last    : Stream_Element_Offset;
         Seen    : Unbounded_String;
         Payload : constant String := Wire (Shrink_Of (Which));
         Cut     : constant Natural := Payload'First + 8_192 - 1;
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 15.0, Status => Status);
         if Status /= Sockets.Completed then
            raise Program_Error with "raw peer accept did not complete";
         end if;
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 15.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               Append (Seen, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF)
              /= 0;
         end loop;
         --  Two deliveries around the client's 8 KiB receive buffer.
         Sockets.Send_All
           (Peer, B (Payload (Payload'First .. Cut)), Timeout => 5.0);
         delay 0.15;
         Sockets.Send_All
           (Peer, B (Payload (Cut + 1 .. Payload'Last)), Timeout => 5.0);
         --  No Content-Length and no Transfer-Encoding: the body is
         --  close-delimited and empty.
         Sockets.Close_Socket (Peer);
      exception
         when Occurrence : others =>
            Coordination.Server_Failed
              (Case_Index'Image (Which) & ": "
               & Ada.Exceptions.Exception_Information (Occurrence));
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
      end Serve;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      for Which in Case_Index loop
         Serve (Which);
      end loop;
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Server_Failed
           (Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
   end Raw_Server;

   function Live (Which : Case_Index; Port : Sockets.Port) return String is
      Item    : aliased HC.Client (Capacity => 1);
      Request : HC.Request;
      Answer  : Unbounded_String;
   begin
      HC.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Long_Long_Integer (Port))));
      HC.Set_Target (Request, "/boundary");
      declare
         Reply : constant HC.Response :=
           HC.Execute (Item, Request, Timeout => 15.0);
      begin
         Answer := To_Unbounded_String
           ("status" & Flyology.HTTP.Status_Code'Image (HC.Status (Reply)));
      end;
      HC.Shutdown (Item);
      return To_String (Answer);
   exception
      when Occurrence : others =>
         HC.Shutdown (Item);
         return Ada.Exceptions.Exception_Name (Occurrence);
   end Live;

   Port : Sockets.Port;
begin
   Note ("Default_Max_Bytes is" & Natural'Image (Bound));
   for Which in Case_Index loop
      Note (Case_Index'Image (Which) & ": head length"
            & Natural'Image (Bound - Shrink_Of (Which))
            & ", wire bytes"
            & Natural'Image (Wire (Shrink_Of (Which))'Length));
   end loop;

   Coordination.Wait_Ready (Port);
   for Which in Case_Index loop
      declare
         From_Oracle : constant String := Oracle (Which);
         From_Wire   : constant String := Live (Which, Port);
      begin
         Note (Case_Index'Image (Which) & ": oracle " & From_Oracle
               & ", live " & From_Wire);
         Check (From_Oracle = "accepted",
                Case_Index'Image (Which)
                & ": the parser oracle accepts the head");
         Check (From_Wire = "status 200",
                Case_Index'Image (Which)
                & ": the live transport accepts the same head");
      end;
   end loop;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_H1_Client_4;
