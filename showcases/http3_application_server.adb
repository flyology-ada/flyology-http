with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.ALPN;
with Flyology.IO.TLS.OpenSSL;
with Flyology.QUIC.Connections;

procedure HTTP3_Application_Server is
   package App renames Flyology.HTTP.Server.Applications;
   package Files renames Ada.Streams.Stream_IO;
   package ALPN renames Flyology.IO.TLS.ALPN;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package QUIC renames Flyology.QUIC.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Ada.Streams.Stream_Element_Offset;
   use type Files.Count;

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

   type Context is limited null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Hello (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "hello " & X.Parameter ("name"));
   end Hello;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Sockets.Port'Value (Ada.Command_Line.Argument (5))
      else 4_433);
   Routes : aliased Routing.Router
     (Capacity => 1, Slashes => Routing.Strict_Slashes);
   State : aliased Context;
   Backend : aliased OpenSSL.OpenSSL_Provider;
   Stop : aliased Flyology.Cancellation.Token;
begin
   if Ada.Command_Line.Argument_Count not in 4 .. 5 then
      Ada.Text_IO.Put_Line
        ("usage: http3_application_server TLS_CERT.pem TLS_KEY.pem " &
         "QUIC_CERT.der QUIC_KEY.raw [PORT]");
      return;
   end if;

   OpenSSL.Initialize_Server
     (Backend,
      Certificate_File => Ada.Command_Line.Argument (1),
      Private_Key_File => Ada.Command_Line.Argument (2),
      Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));

   declare
      Certificate : constant Ada.Streams.Stream_Element_Array :=
        Read_File (Ada.Command_Line.Argument (3), 4_096);
      Key_Data : constant Ada.Streams.Stream_Element_Array :=
        Read_File (Ada.Command_Line.Argument (4), 32);
      Private_Key : constant QUIC.Ed25519_Private_Key :=
        QUIC.Ed25519_Private_Key'(Key_Data);
   begin
      Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
      Ada.Text_IO.Put_Line
        ("HTTP/1.1, HTTP/2, and HTTP/3 route ready on port " &
         Ada.Strings.Fixed.Trim (Sockets.Port'Image (Port), Ada.Strings.Both));

      Routes.Serve
        (State,
         Sockets.Network_Endpoint (Sockets.Any_IPv4, Port),
         Backend,
         Certificate_DER => Certificate,
         Private_Key => Private_Key,
         Max_Connection_Age => -1.0,
         Token => Stop'Access);
   end;
end HTTP3_Application_Server;
