with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Development_Certificates;
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
   package Development_Certificates renames
     Flyology.HTTP.Server.Development_Certificates;
   use type Ada.Streams.Stream_Element_Offset;
   use type Files.Count;
   use type Sockets.Port;

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
   Generated : aliased Development_Certificates.Identity;

   procedure Serve
     (Certificate_PEM : String;
      Private_Key_PEM : String;
      Certificate_DER : Ada.Streams.Stream_Element_Array;
      Private_Key     : QUIC.Ed25519_Private_Key;
      HTTPS_Port      : Sockets.Port;
      HTTP_Port       : Sockets.Port;
      Temporary_Identity : access Development_Certificates.Identity := null)
   is
      HTTPS_Port_Text : constant String :=
        Ada.Strings.Fixed.Trim
          (Sockets.Port'Image (HTTPS_Port), Ada.Strings.Both);
      HTTP_Port_Text : constant String :=
        Ada.Strings.Fixed.Trim
          (Sockets.Port'Image (HTTP_Port), Ada.Strings.Both);
   begin
      if HTTPS_Port = Sockets.Any_Port
        or else HTTP_Port = Sockets.Any_Port
        or else HTTPS_Port = HTTP_Port
      then
         raise Constraint_Error with
           "HTTP and HTTPS ports must be distinct and nonzero";
      end if;
      OpenSSL.Initialize_Server
        (Backend,
         Certificate_File => Certificate_PEM,
         Private_Key_File => Private_Key_PEM,
         Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
      if Temporary_Identity /= null then
         Development_Certificates.Discard (Temporary_Identity.all);
      end if;
      Ada.Text_IO.Put_Line
        ("HTTP/1.1, HTTP/2, and HTTP/3 route ready on secure port " &
         HTTPS_Port_Text);
      Ada.Text_IO.Put_Line
        ("HTTP redirect: curl -i http://127.0.0.1:" & HTTP_Port_Text &
         "/hello/test");
      Ada.Text_IO.Put_Line
        ("TLS test: curl -k https://127.0.0.1:" & HTTPS_Port_Text &
         "/hello/test");
      Ada.Text_IO.Put_Line
        ("H3 test: curl -k --http3-only https://127.0.0.1:" &
         HTTPS_Port_Text &
         "/hello/test");

      Routes.Serve
        (State,
         HTTP_Endpoint =>
           Sockets.Network_Endpoint (Sockets.Any_IPv4, HTTP_Port),
         HTTPS_Endpoint =>
           Sockets.Network_Endpoint (Sockets.Any_IPv4, HTTPS_Port),
         HTTPS_Origin => Flyology.HTTP.Parse_Origin
           ("https://127.0.0.1:" & HTTPS_Port_Text),
         TLS_Backend => Backend,
         Certificate_DER => Certificate_DER,
         Private_Key => Private_Key,
         Max_Connection_Age => -1.0,
         Token => Stop'Access);
   end Serve;
begin
   if Ada.Command_Line.Argument_Count not in 0 .. 2 | 4 .. 6 then
      Ada.Text_IO.Put_Line
        ("usage: http3_application_server [HTTPS_PORT [HTTP_PORT]]");
      Ada.Text_IO.Put_Line
        ("   or: http3_application_server TLS_CERT.pem TLS_KEY.pem " &
         "QUIC_CERT.der QUIC_KEY.raw [HTTPS_PORT [HTTP_PORT]]");
      return;
   end if;

   Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
   if Ada.Command_Line.Argument_Count <= 2 then
      Development_Certificates.Generate (Generated);
      Ada.Text_IO.Put_Line
        ("Generated temporary self-signed localhost identities " &
         "for TLS and QUIC");
      Serve
        (Development_Certificates.TLS_Certificate_File (Generated),
         Development_Certificates.TLS_Private_Key_File (Generated),
         Development_Certificates.QUIC_Certificate_DER (Generated),
         Development_Certificates.QUIC_Private_Key (Generated),
         (if Ada.Command_Line.Argument_Count >= 1
          then Sockets.Port'Value (Ada.Command_Line.Argument (1))
          else 4_433),
         (if Ada.Command_Line.Argument_Count = 2
          then Sockets.Port'Value (Ada.Command_Line.Argument (2))
          else 4_080),
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
            (if Ada.Command_Line.Argument_Count >= 5
             then Sockets.Port'Value (Ada.Command_Line.Argument (5))
             else 4_433),
            (if Ada.Command_Line.Argument_Count = 6
             then Sockets.Port'Value (Ada.Command_Line.Argument (6))
             else 4_080));
      end;
   end if;
end HTTP3_Application_Server;
