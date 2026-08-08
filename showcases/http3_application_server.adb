with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.HTTP;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections;

procedure HTTP3_Application_Server is
   package App renames Flyology.HTTP.Server.Applications;
   package Files renames Ada.Streams.Stream_IO;
   package QUIC renames Flyology.QUIC.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Ada.Streams.Stream_Element_Offset;
   use type Files.Count;
   use type Flyology.HTTP.Protocol;

   function Read_File
     (Path : String; Maximum : Positive)
      return Ada.Streams.Stream_Element_Array
   is
      Length : constant Files.Count :=
        Files.Count (Ada.Directories.Size (Path));
   begin
      if Length = 0 or else Length > Files.Count (Maximum) then
         raise Constraint_Error with "invalid identity file size: " & Path;
      end if;

      declare
         File : Files.File_Type;
         Data : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Length));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Open (File, Files.In_File, Path);
         Files.Read (File, Data, Last);
         Files.Close (File);
         if Last /= Data'Last then
            raise Files.End_Error with "short identity file: " & Path;
         end if;
         return Data;
      exception
         when others =>
            if Files.Is_Open (File) then
               Files.Close (File);
            end if;
            raise;
      end;
   end Read_File;

   type Context is limited record
      Requests : Natural := 0;
   end record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Hello (State : in out Context; X : in out App.Exchange) is
   begin
      pragma Assert (X.Request_Protocol = Flyology.HTTP.HTTP_3_Protocol);
      State.Requests := State.Requests + 1;
      X.Text (200, "hello " & X.Parameter ("name"));
   end Hello;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Sockets.Port'Value (Ada.Command_Line.Argument (3))
      else 4_433);
   Routes : Routing.Router
     (Capacity => 1, Slashes => Routing.Strict_Slashes);
   State : Context;
   Socket : aliased Sockets.Socket_Type;
begin
   if Ada.Command_Line.Argument_Count not in 2 .. 3 then
      Ada.Text_IO.Put_Line
        ("usage: http3_application_server CERTIFICATE.der PRIVATE_KEY.raw" &
         " [PORT]");
      return;
   end if;

   declare
      Certificate : constant Ada.Streams.Stream_Element_Array :=
        Read_File (Ada.Command_Line.Argument (1), 4_096);
      Key_Data : constant Ada.Streams.Stream_Element_Array :=
        Read_File (Ada.Command_Line.Argument (2), 32);
      Private_Key : constant QUIC.Ed25519_Private_Key :=
        QUIC.Ed25519_Private_Key'(Key_Data);
   begin
      Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
      Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Socket, Sockets.Network_Endpoint (Sockets.Any_IPv4, Port));
      Ada.Text_IO.Put_Line
        ("HTTP/3 route ready on UDP port " &
         Ada.Strings.Fixed.Trim (Sockets.Port'Image (Port), Ada.Strings.Both));

      Routes.Serve_HTTP_3
        (State, Socket, Certificate, Private_Key,
         Max_Connection_Age => -1.0);
      Sockets.Close_Socket (Socket);
   end;
exception
   when others =>
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
      raise;
end HTTP3_Application_Server;
