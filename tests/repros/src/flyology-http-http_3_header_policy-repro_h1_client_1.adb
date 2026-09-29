--  H1-CLIENT-1.  flyology-http.ads:103-106 declares Body_Size as the crate's
--  shared "64-bit-safe" message length type "so message lengths do not depend
--  on the implementation range of Natural".  The HTTP/1 response head parser
--  does depend on it: http_1_internals.adb:151-168 Parse_Natural returns
--  Natural and client.adb:307 stores Remaining_Body as Natural, so a
--  syntactically valid Content-Length of 2**31 or more is rejected with
--  "invalid or overflowing HTTP decimal value".
--
--  This program asserts the correct behaviour: a Content-Length that
--  Body_Size can represent parses as a valid head on HTTP/1, exactly as the
--  HTTP/3 response header validator already accepts it.  It is a child of the
--  private HTTP/3 policy package only so that the HTTP/3 comparison is a
--  direct call rather than an assertion about unreachable code.
--
--  Part A  parser oracle (Flyology.HTTP.Client.Testing.Validate_Response)
--  Part B  live loopback transport with a raw peer
--  Part C  the HTTP/3 response header validator on the same field value
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Header_Policy.Repro_H1_Client_1
  with SPARK_Mode => Off
is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;
   use type Sockets.Port;
   use type Flyology.QUIC.Varint_Policy.Value_Type;

   --  The value this crate's own HTTP/1 server puts on the wire: see
   --  tests/http_smoke.adb:285-296, which asserts "Content-Length: 5368709129"
   --  in the bytes Begin_Response_Stream produced.
   Server_Emitted : constant String := "5368709129";

   Head_Complete : constant String :=
     "peer closed before Content-Length was received";

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Diagnosis (Length_Text : String) return String is
      Wire : constant String :=
        "HTTP/1.1 200 OK" & CRLF
        & "Content-Length: " & Length_Text & CRLF & CRLF;
   begin
      HC.Testing.Validate_Response (B (Wire));
      return "<accepted with no body>";
   exception
      when Error : Protocol_Error | HC.Response_Too_Large =>
         return Ada.Exceptions.Exception_Name (Error) & ": "
           & Ada.Exceptions.Exception_Message (Error);
      when Error : others =>
         return "UNEXPECTED " & Ada.Exceptions.Exception_Name (Error) & ": "
           & Ada.Exceptions.Exception_Message (Error);
   end Diagnosis;

   --  True when the response HEAD parsed and framing was selected: the only
   --  remaining complaint is that the declared body is absent.
   function Head_Accepted (Length_Text : String) return Boolean is
     (Diagnosis (Length_Text) = "FLYOLOGY.HTTP.PROTOCOL_ERROR: "
      & Head_Complete);

   --  Part B ---------------------------------------------------------------

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
         Coordination.Server_Failed ("accept did not complete");
         Sockets.Close_Socket (Listener);
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
      --  A valid head announcing a 5 GiB body, then four body bytes.  The
      --  client is expected to return the head to its caller; the body is
      --  never read, so the peer simply waits for the client to go away.
      Sockets.Send_All
        (Peer,
         B ("HTTP/1.1 200 OK" & CRLF
            & "Content-Length: " & Server_Emitted & CRLF
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
         Parse_Origin ("http://127.0.0.1:" & Decimal (Long_Long_Integer
                                                        (Port))));
      HC.Set_Target (Request, "/large-object");
      declare
         Reply : HC.Response := HC.Execute (Item, Request, Timeout => 5.0);
      begin
         Check (HC.Status (Reply) = 200,
                "live HTTP/1.1 path: Execute returns the 200 head");
         Expect_Equal
           (HC.Header (Reply, "Content-Length"), Server_Emitted,
            "live HTTP/1.1 path: the declared length is readable");
      end;
      HC.Shutdown (Item);
   exception
      when Occurrence : others =>
         Check (False,
                "live HTTP/1.1 path: Execute returns the 200 head, got "
                & Ada.Exceptions.Exception_Name (Occurrence) & ": "
                & Ada.Exceptions.Exception_Message (Occurrence));
         HC.Shutdown (Item);
   end Run_Live_Exchange;

begin
   Note ("Natural'Last is" & Natural'Image (Natural'Last)
         & "; Body_Size'Last is " & Decimal (Body_Size'Last));

   --  Part A: the parser oracle, which runs the production head parser.
   Note ("2147483599 -> " & Diagnosis ("2147483599"));
   Note ("2147483647 -> " & Diagnosis ("2147483647"));
   Note ("2147483648 -> " & Diagnosis ("2147483648"));
   Note (Server_Emitted & " -> " & Diagnosis (Server_Emitted));

   Check (Head_Accepted ("2147483599"),
          "control: Content-Length 2147483599 is a valid head");
   Check (Head_Accepted ("2147483648"),
          "Content-Length 2147483648 is a valid head");
   Check (Head_Accepted (Server_Emitted),
          "Content-Length " & Server_Emitted
          & ", which this crate's own HTTP/1 server emits, is a valid head");
   Check (Head_Accepted (Decimal (Body_Size'Last)),
          "Content-Length " & Decimal (Body_Size'Last)
          & " (Body_Size'Last) is a valid head");

   --  Locate the exact threshold rather than assuming it.
   declare
      Low  : Long_Long_Integer := 1;
      High : Long_Long_Integer := Body_Size'Last;
      Mid  : Long_Long_Integer;
   begin
      if Head_Accepted (Decimal (High)) then
         Note ("no threshold: every representable length is accepted");
      else
         while High - Low > 1 loop
            Mid := Low + (High - Low) / 2;
            if Head_Accepted (Decimal (Mid)) then
               Low := Mid;
            else
               High := Mid;
            end if;
         end loop;
         Note ("largest accepted Content-Length is " & Decimal (Low));
         Note ("smallest rejected Content-Length is " & Decimal (High));
         Note ("Natural'Last is" & Natural'Image (Natural'Last)
               & ", so the bound is "
               & (if Low = Long_Long_Integer (Natural'Last)
                  then "exactly Natural'Last"
                  else "not Natural'Last"));
      end if;
   end;

   --  Part C: the HTTP/3 response header validator on the same value.
   declare
      use QPACK_Field_Section_Policy;
      Block   : Header_Block;
      Outcome : Validation_Result;
   begin
      Block.Count := 2;
      Block.Fields (1) := Make_Field (":status", "200");
      Block.Fields (2) := Make_Field ("content-length", Server_Emitted);
      Outcome := Validate_Response (Block);
      Note ("HTTP/3 Validate_Response status is "
            & Validation_Status'Image (Outcome.Status));
      Check (Outcome.Status = Valid,
             "control: the HTTP/3 response validator accepts Content-Length "
             & Server_Emitted);
      Check (Outcome.Has_Content_Length
               and then Outcome.Content_Length = 5_368_709_129,
             "control: the HTTP/3 validator keeps the 64-bit value");
   end;

   --  Part B: the live transport path.
   Run_Live_Exchange;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;

   Finish;
end Flyology.HTTP.HTTP_3_Header_Policy.Repro_H1_Client_1;
