--  H1-CLIENT-2 (= CLIENT-POOL-3: one defect, found twice).
--
--  client.ads:217-226 promises of Set_Expect_Continue's Wait_Timeout that
--  "A positive wait expiry with no partial response sends the body; a
--  negative value waits within the whole exchange deadline and zero sends
--  immediately after the head."
--
--  client.adb:3767-3782 arms the continue wait with
--  Flyology.Operations.Drivers.Arm_Deadline, whose pinned contract
--  (flyology_6f91b1af/src/flyology-operations-drivers.ads:58-63) says "A
--  nonpositive interval is due on the next completion-set drive", and whose
--  body (.adb:80-91) sets the deadline to Clock when Interval <= 0.0.  A
--  negative Continue_Wait therefore behaves exactly like zero.
--
--  This program asserts the documented behaviour: with Wait_Timeout => -1.0
--  no request body byte reaches the peer before the peer sends 100 Continue.
--  The Wait_Timeout => 1.0 case is the control: it must show the same, and it
--  proves the peer's measurement is meaningful.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_H1_Client_2 is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   Payload : constant String (1 .. 4_096) := (others => 'x');

   --  How long the peer holds back its 100 Continue while it watches for an
   --  early body.  Well under the 10 s exchange deadline the client uses.
   Peer_Delay : constant Duration := 0.4;

   type Case_Index is (Positive_Wait, Negative_Wait);
   type Early_Counts is array (Case_Index) of Integer;

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Record_Early (Which : Case_Index; Bytes : Natural);
      function Early (Which : Case_Index) return Integer;
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Seen       : Early_Counts := (others => -1);
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

      procedure Record_Early (Which : Case_Index; Bytes : Natural) is
      begin
         Seen (Which) := Bytes;
      end Record_Early;

      function Early (Which : Case_Index) return Integer is (Seen (Which));

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
         Buffer  : Stream_Element_Array (1 .. 8_192);
         Last    : Stream_Element_Offset;
         Seen    : Unbounded_String;
         Mark    : Natural := 0;
         Early   : Natural := 0;
         Body_Seen : Natural := 0;
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 10.0, Status => Status);
         if Status /= Sockets.Completed then
            raise Program_Error with "raw peer accept did not complete";
         end if;
         --  Read until the request head is complete.  Any byte past the
         --  head's CRLF CRLF is already request body.
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               Append (Seen, Character'Val (Buffer (Index)));
            end loop;
            Mark := Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF);
            exit when Mark /= 0;
         end loop;
         Early := Length (Seen) - (Mark + 2 * CRLF'Length - 1);
         --  Watch for an early body for Peer_Delay before answering.
         if Early = 0 then
            begin
               Sockets.Receive (Peer, Buffer, Last, Timeout => Peer_Delay);
               if Last >= Buffer'First then
                  Early := Natural (Last - Buffer'First + 1);
               end if;
            exception
               when Flyology.IO.Timeout_Error =>
                  Early := 0;
            end;
         end if;
         Coordination.Record_Early (Which, Early);
         Body_Seen := Early;
         Sockets.Send_All
           (Peer, B ("HTTP/1.1 100 Continue" & CRLF & CRLF), Timeout => 5.0);
         while Body_Seen < Payload'Length loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
            exit when Last < Buffer'First;
            Body_Seen := Body_Seen + Natural (Last - Buffer'First + 1);
         end loop;
         Sockets.Send_All
           (Peer,
            B ("HTTP/1.1 200 OK" & CRLF
               & "Content-Length: 2" & CRLF
               & "Connection: close" & CRLF & CRLF & "ok"),
            Timeout => 5.0);
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
            exit when Last < Buffer'First;
         end loop;
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
      Serve (Positive_Wait);
      Serve (Negative_Wait);
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Server_Failed
           (Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
   end Raw_Server;

   procedure Run_Client is
      Port : Sockets.Port;
      Item : aliased HC.Client (Capacity => 1);

      procedure One (Which : Case_Index; Wait : Duration; Target : String) is
         Request : HC.Request;
      begin
         HC.Set_Method (Request, Flyology.HTTP.Methods.POST);
         HC.Set_Target (Request, Target);
         HC.Set_Expect_Continue (Request, Wait_Timeout => Wait);
         HC.Set_Body (Request, Payload);
         declare
            Reply : constant HC.Response :=
              HC.Execute (Item, Request, Timeout => 10.0);
         begin
            Check (HC.Status (Reply) = 200,
                   Case_Index'Image (Which) & ": the exchange completes");
         end;
      exception
         when Occurrence : others =>
            Check (False,
                   Case_Index'Image (Which) & ": the exchange completes, got "
                   & Ada.Exceptions.Exception_Name (Occurrence) & ": "
                   & Ada.Exceptions.Exception_Message (Occurrence));
      end One;
   begin
      Coordination.Wait_Ready (Port);
      HC.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Long_Long_Integer (Port))));
      One (Positive_Wait, 1.0, "/positive-wait");
      One (Negative_Wait, -1.0, "/negative-wait");
      HC.Shutdown (Item);
   end Run_Client;

begin
   Note ("request body is" & Natural'Image (Payload'Length) & " bytes;"
         & " the peer withholds 100 Continue for"
         & Duration'Image (Peer_Delay) & " s;"
         & " the exchange deadline is 10.0 s");
   Run_Client;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;
   Note ("body bytes seen before 100 Continue, Wait_Timeout =>  1.0:"
         & Integer'Image (Coordination.Early (Positive_Wait)));
   Note ("body bytes seen before 100 Continue, Wait_Timeout => -1.0:"
         & Integer'Image (Coordination.Early (Negative_Wait)));
   Check (Coordination.Early (Positive_Wait) = 0,
          "control: a positive wait sends no body before 100 Continue");
   Check (Coordination.Early (Negative_Wait) = 0,
          "a negative wait sends no body before 100 Continue, because it"
          & " waits within the whole exchange deadline");
   Finish;
end Repro_H1_Client_2;
