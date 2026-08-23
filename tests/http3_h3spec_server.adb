with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.Execution_Groups;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_H3Spec_Server is
   use type Ada.Streams.Stream_Element_Offset;

   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count = 0 then 4_437
      else Sockets.Port'Value (Ada.Command_Line.Argument (1)));
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 2 then 32
      else Positive'Value (Ada.Command_Line.Argument (2)));
   Expected_Loops : constant Flyology.Execution_Groups.Loop_Pool_Size :=
     (if Ada.Command_Line.Argument_Count < 3 then 1
      else Flyology.Execution_Groups.Loop_Pool_Size'Value
        (Ada.Command_Line.Argument (3)));
   Max_Connection_Age : constant Duration :=
     (if Ada.Command_Line.Argument_Count < 4 then 15.0
      else Duration'Value (Ada.Command_Line.Argument (4)));
   Max_Requests : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 5 then 5
      else Positive'Value (Ada.Command_Line.Argument (5)));

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Root (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "h3spec");
   end Root;

   procedure Hello (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "hello");
   end Hello;

   procedure Upload (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
      Data : Ada.Streams.Stream_Element_Array (1 .. 1_024);
      Last : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
      Total : Natural := 0;
   begin
      loop
         X.Read_Body (Data, Last, Finished);
         if Last >= Data'First then
            Total := Total + Natural (Last - Data'First + 1);
         end if;
         exit when Finished;
      end loop;
      X.Text (200, (if Total = 12 then "uploaded" else "bad-upload"));
   end Upload;

   procedure Slow_Upload (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
      Data : Ada.Streams.Stream_Element_Array (1 .. 1_024);
      Last : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
      loop
         X.Read_Body (Data, Last, Finished);
         exit when Finished;
      end loop;
      delay 1.0;
      X.Text (200, "too-late");
   end Slow_Upload;

   procedure Early_Upload (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (413, "");
   end Early_Upload;

   procedure Slow_Get (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "slow");
   end Slow_Get;

   procedure Large_Get (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
      Chunk : constant String (1 .. 4_096) := (others => 'L');
   begin
      X.Begin_Stream
        (Status => 200, Content_Type => "application/octet-stream",
         Content_Length => 32_768);
      for Part in 1 .. 8 loop
         X.Write_Chunk (Chunk);
      end loop;
      X.End_Stream;
   end Large_Get;

   Routes : aliased Routing.Router
     (Capacity => 7, Slashes => Routing.Strict_Slashes);
   State  : aliased Context;
   Socket : aliased Sockets.Socket_Type;
   Stop   : aliased Flyology.Cancellation.Token;
begin
   if Flyology.Execution_Groups.Configured_Pool_Size /= Expected_Loops then
      raise Program_Error with
        "HTTP/3 stress server linked an unexpected loop-pool size";
   end if;
   Routes.Get ("/", Root'Access, Name => "root");
   Routes.Get ("/hello", Hello'Access, Name => "hello");
   Routes.Get ("/slow", Slow_Get'Access, Name => "slow");
   Routes.Get ("/large", Large_Get'Access, Name => "large");
   Routes.Put
     ("/upload", Upload'Access, Name => "upload",
      Policy =>
        (Body_Handling => App.Stream_Body,
         others => <>));
   Routes.Put
     ("/slow-upload", Slow_Upload'Access, Name => "slow-upload",
      Policy =>
        (Body_Handling => App.Stream_Body,
         others => <>));
   Routes.Put
     ("/early-upload", Early_Upload'Access, Name => "early-upload",
      Policy =>
        (Body_Handling => App.Stream_Body,
         others => <>));
   Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   declare
      Bound : constant Sockets.Endpoint := Sockets.Get_Socket_Name (Socket);
   begin
      Ada.Text_IO.Put_Line
        ("Ada HTTP/3 h3spec server listening on 127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Sockets.Port'Image (Bound.Port), Ada.Strings.Both));
   end;
   Ada.Text_IO.Flush;

   Routes.Serve_HTTP_3_Listener
     (State, Socket,
      Fixtures.Server_Certificate,
      Fixtures.Server_Private_Key,
      Capacity => Capacity,
      Timeout => 15.0,
      Handshake_Timeout => 5.0,
      Max_Connection_Age => Max_Connection_Age,
      Max_Requests => Max_Requests,
      Token => Stop'Access);
end HTTP3_H3Spec_Server;
