--  H1-CLIENT-6.  Validate_Response's chunked branch
--  (http_1_internals.adb:585-587) tests
--
--     if Length (Data.Pending) < Size + CRLF'Length then
--
--  with Size : Natural.  Chunk_Size (:780-797) admits any value up to
--  Natural'Last, so for Size in Natural'Last - 1 .. Natural'Last -- chunk
--  sizes 7FFFFFFE and 7FFFFFFF, both legal 1*HEXDIG under RFC 9112 7.1 --
--  Size + CRLF'Length overflows Integer and the overflow check raises
--  Constraint_Error.
--
--  tests/http-client-conformance.md:100-104 designates
--  Flyology.HTTP.Client.Testing.Fuzz_Response as the crash arbiter:
--  "Documented protocol and size rejections are normal outcomes; assertion
--  failures, runtime checks, hangs, and other exceptions remain crashes."
--
--  This program asserts that the arbiter consumes these inputs as the
--  documented rejections they are, and confirms the scope claim by driving
--  the same bytes through the production decoder on a live transport.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_H1_Client_6 is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   function Wire (Size_Text : String) return String is
     ("HTTP/1.1 200 OK" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & Size_Text & CRLF);

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   --  Call the documented fuzz arbiter exactly as a campaign does.
   function Arbiter (Size_Text : String) return String is
      Text  : constant String := Wire (Size_Text);
      Input : HC.Testing.Fuzz_Bytes := (others => 0);
   begin
      for Offset in 0 .. Text'Length - 1 loop
         Input (Input'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Text (Text'First + Offset)));
      end loop;
      HC.Testing.Fuzz_Response (Input, Text'Length);
      return "consumed";
   exception
      when Error : others =>
         return Ada.Exceptions.Exception_Name (Error) & ": "
           & Ada.Exceptions.Exception_Message (Error);
   end Arbiter;

   --  Live scope check ------------------------------------------------------

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
      Seen     : Unbounded_String;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Sockets.Accept_Socket
        (Listener, Peer, Address, Timeout => 10.0, Status => Status);
      if Status /= Sockets.Completed then
         raise Program_Error with "raw peer accept did not complete";
      end if;
      loop
         Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
         exit when Last < Buffer'First;
         for Index in Buffer'First .. Last loop
            Append (Seen, Character'Val (Buffer (Index)));
         end loop;
         exit when Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF)
           /= 0;
      end loop;
      Sockets.Send_All (Peer, B (Wire ("7FFFFFFF")), Timeout => 5.0);
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

   function Live return String is
      Port    : Sockets.Port;
      Item    : aliased HC.Client (Capacity => 1);
      Request : HC.Request;
      Answer  : Unbounded_String;
   begin
      Coordination.Wait_Ready (Port);
      HC.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Long_Long_Integer (Port))));
      HC.Set_Target (Request, "/huge-chunk");
      declare
         Reply   : HC.Response := HC.Execute (Item, Request, Timeout => 10.0);
         Content : Flyology.Bytes.Unbounded_Bytes;
      begin
         HC.Read_All (Reply, Content);
         Answer := To_Unbounded_String ("no exception");
      exception
         when Error : others =>
            Answer := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error));
      end;
      HC.Shutdown (Item);
      return To_String (Answer);
   exception
      when Occurrence : others =>
         HC.Shutdown (Item);
         return Ada.Exceptions.Exception_Name (Occurrence);
   end Live;

begin
   Note ("Natural'Last is" & Natural'Image (Natural'Last)
         & " = 16#7FFFFFFF#");
   Note ("arbiter 7FFFFFF0 -> " & Arbiter ("7FFFFFF0"));
   Note ("arbiter 7FFFFFFE -> " & Arbiter ("7FFFFFFE"));
   Note ("arbiter 7FFFFFFF -> " & Arbiter ("7FFFFFFF"));
   Note ("arbiter 80000000 -> " & Arbiter ("80000000"));

   Check (Arbiter ("7FFFFFF0") = "consumed",
          "control: chunk size 7FFFFFF0 is a documented rejection");
   Check (Arbiter ("80000000") = "consumed",
          "control: chunk size 80000000 is a documented size rejection");
   Check (Arbiter ("7FFFFFFE") = "consumed",
          "chunk size 7FFFFFFE is a documented rejection, not a crash");
   Check (Arbiter ("7FFFFFFF") = "consumed",
          "chunk size 7FFFFFFF is a documented rejection, not a crash");

   --  Scope: the production decoder must be, and is, unaffected.
   declare
      From_Wire : constant String := Live;
   begin
      Note ("live production decoder on the same bytes -> " & From_Wire);
      Check (From_Wire = "FLYOLOGY.HTTP.PROTOCOL_ERROR",
             "scope: the production decoder rejects the same bytes with a"
             & " typed Protocol_Error");
   end;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_H1_Client_6;
