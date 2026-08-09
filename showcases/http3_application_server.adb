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
with HTTP3_Development_Identity;

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

   Routes : aliased Routing.Router
     (Capacity => 1, Slashes => Routing.Strict_Slashes);
   State : aliased Context;
   Backend : aliased OpenSSL.OpenSSL_Provider;
   Stop : aliased Flyology.Cancellation.Token;
   Generated : aliased HTTP3_Development_Identity.Identity;

   procedure Serve
     (Certificate_PEM : String;
      Private_Key_PEM : String;
      Certificate_DER : Ada.Streams.Stream_Element_Array;
      Private_Key     : QUIC.Ed25519_Private_Key;
      Port            : Sockets.Port;
      Temporary_Identity : access HTTP3_Development_Identity.Identity := null)
   is
   begin
      OpenSSL.Initialize_Server
        (Backend,
         Certificate_File => Certificate_PEM,
         Private_Key_File => Private_Key_PEM,
         Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
      if Temporary_Identity /= null then
         HTTP3_Development_Identity.Discard (Temporary_Identity.all);
      end if;
      Ada.Text_IO.Put_Line
        ("HTTP/1.1, HTTP/2, and HTTP/3 route ready on port " &
         Ada.Strings.Fixed.Trim (Sockets.Port'Image (Port), Ada.Strings.Both));

      Routes.Serve
        (State,
         Sockets.Network_Endpoint (Sockets.Any_IPv4, Port),
         Backend,
         Certificate_DER => Certificate_DER,
         Private_Key => Private_Key,
         Max_Connection_Age => -1.0,
         Token => Stop'Access);
   end Serve;
begin
   if Ada.Command_Line.Argument_Count not in 0 .. 1 | 4 .. 5 then
      Ada.Text_IO.Put_Line ("usage: http3_application_server [PORT]");
      Ada.Text_IO.Put_Line
        ("   or: http3_application_server TLS_CERT.pem TLS_KEY.pem " &
         "QUIC_CERT.der QUIC_KEY.raw [PORT]");
      return;
   end if;

   Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
   if Ada.Command_Line.Argument_Count <= 1 then
      HTTP3_Development_Identity.Generate (Generated);
      Ada.Text_IO.Put_Line
        ("Generated a temporary self-signed Ed25519 identity for localhost");
      Serve
        (HTTP3_Development_Identity.Certificate_PEM (Generated),
         HTTP3_Development_Identity.Private_Key_PEM (Generated),
         HTTP3_Development_Identity.Certificate_DER (Generated),
         HTTP3_Development_Identity.Private_Key (Generated),
         (if Ada.Command_Line.Argument_Count = 1
          then Sockets.Port'Value (Ada.Command_Line.Argument (1))
          else 4_433),
         Generated'Access);
   else
      declare
         Certificate : constant Ada.Streams.Stream_Element_Array :=
           Read_File (Ada.Command_Line.Argument (3), 4_096);
         Key_Data : constant Ada.Streams.Stream_Element_Array :=
           Read_File (Ada.Command_Line.Argument (4), 32);
      begin
         Serve
           (Ada.Command_Line.Argument (1), Ada.Command_Line.Argument (2),
            Certificate, QUIC.Ed25519_Private_Key'(Key_Data),
            (if Ada.Command_Line.Argument_Count = 5
             then Sockets.Port'Value (Ada.Command_Line.Argument (5))
             else 4_433));
      end;
   end if;
end HTTP3_Application_Server;
