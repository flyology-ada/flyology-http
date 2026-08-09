with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;

package body Flyology.HTTP.Server.Development_Certificates is
   package OS renames GNAT.OS_Lib;
   package Files renames Ada.Streams.Stream_IO;
   package QUIC renames Flyology.QUIC.Connections;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Files.Count;
   use type OS.String_Access;

   protected Unique_Names is
      procedure Next (Value : out Natural);
   private
      Counter : Natural := 0;
   end Unique_Names;

   protected body Unique_Names is
      procedure Next (Value : out Natural) is
      begin
         Counter := (if Counter = Natural'Last then 1 else Counter + 1);
         Value := Counter;
      end Next;
   end Unique_Names;

   function Read_File
     (Path : String; Maximum : Positive)
      return Ada.Streams.Stream_Element_Array
   is
      Length : constant Files.Count :=
        Files.Count (Ada.Directories.Size (Path));
   begin
      if Length = 0 or else Length > Files.Count (Maximum) then
         raise Constraint_Error with "invalid generated identity file";
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
            raise Files.End_Error with "short generated identity file";
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

   procedure Free (Arguments : in out OS.Argument_List) is
   begin
      for Argument of Arguments loop
         OS.Free (Argument);
      end loop;
   end Free;

   procedure Run
     (Program     : String;
      Arguments   : in out OS.Argument_List;
      Output_File : String)
   is
      Success     : Boolean;
      Return_Code : Integer;
   begin
      begin
         OS.Spawn
           (Program, Arguments, Output_File, Success, Return_Code,
            Err_To_Out => True);
      exception
         when others =>
            Free (Arguments);
            raise;
      end;
      Free (Arguments);
      if not Success or else Return_Code /= 0 then
         raise Program_Error with "OpenSSL identity generation failed";
      end if;
   end Run;

   procedure Write_Configuration (Path : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put_Line (File, "[req]");
      Ada.Text_IO.Put_Line (File, "distinguished_name=subject");
      Ada.Text_IO.Put_Line (File, "x509_extensions=extensions");
      Ada.Text_IO.Put_Line (File, "prompt=no");
      Ada.Text_IO.Put_Line (File, "[subject]");
      Ada.Text_IO.Put_Line (File, "CN=localhost");
      Ada.Text_IO.Put_Line (File, "[extensions]");
      Ada.Text_IO.Put_Line (File, "basicConstraints=critical,CA:FALSE");
      Ada.Text_IO.Put_Line (File, "keyUsage=critical,digitalSignature");
      Ada.Text_IO.Put_Line (File, "extendedKeyUsage=serverAuth");
      Ada.Text_IO.Put_Line
        (File, "subjectAltName=DNS:localhost,IP:127.0.0.1");
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Write_Configuration;

   function Locate_OpenSSL (Command : String) return OS.String_Access is
   begin
      if Command'Length > 0 then
         return new String'(Command);
      elsif Ada.Environment_Variables.Exists ("FLYOLOGY_HTTP_OPENSSL") then
         return new String'
           (Ada.Environment_Variables.Value ("FLYOLOGY_HTTP_OPENSSL"));
      end if;

      --  The system /usr/bin/openssl on older macOS releases is LibreSSL and
      --  cannot generate the Ed25519 key required by the QUIC profile. Prefer
      --  conventional OpenSSL 3 installation paths before searching PATH.
      if Ada.Directories.Exists
        ("/opt/homebrew/opt/openssl@3/bin/openssl")
      then
         return new String'("/opt/homebrew/opt/openssl@3/bin/openssl");
      elsif Ada.Directories.Exists
        ("/usr/local/opt/openssl@3/bin/openssl")
      then
         return new String'("/usr/local/opt/openssl@3/bin/openssl");
      elsif Ada.Directories.Exists
        ("/opt/local/libexec/openssl3/bin/openssl")
      then
         return new String'("/opt/local/libexec/openssl3/bin/openssl");
      else
         return OS.Locate_Exec_On_Path ("openssl");
      end if;
   end Locate_OpenSSL;

   procedure Create_Temporary_Directory
     (Directory : out Unbounded.Unbounded_String)
   is
      Environment_Root : constant String :=
        (if Ada.Environment_Variables.Exists ("TMPDIR")
         then Ada.Environment_Variables.Value ("TMPDIR")
         else "");
      Temporary_Root : constant String :=
        (if Environment_Root'Length > 0 then Environment_Root else "/tmp");
      Separator : constant String :=
        (if Temporary_Root (Temporary_Root'Last) = '/' then "" else "/");
      Process : constant String :=
        Ada.Strings.Fixed.Trim
          (Integer'Image (OS.Pid_To_Integer (OS.Current_Process_Id)),
           Ada.Strings.Both);
   begin
      loop
         declare
            Sequence : Natural;
         begin
            Unique_Names.Next (Sequence);
            declare
               Candidate : constant String :=
                 Temporary_Root & Separator & "flyology-http-credentials-" &
                 Process & "-" &
                 Ada.Strings.Fixed.Trim
                   (Natural'Image (Sequence), Ada.Strings.Both);
            begin
               Ada.Directories.Create_Directory (Candidate);
               Directory := Unbounded.To_Unbounded_String (Candidate);
               return;
            exception
               when Ada.Directories.Use_Error =>
                  if not Ada.Directories.Exists (Candidate) then
                     raise;
                  end if;
            end;
         end;
      end loop;
   end Create_Temporary_Directory;

   overriding procedure Finalize (Item : in out Identity) is
   begin
      Discard (Item);
   exception
      when others =>
         null;
   end Finalize;

   procedure Discard (Item : in out Identity) is
      Directory : constant String := Unbounded.To_String (Item.Directory);
   begin
      if Directory'Length > 0 and then Ada.Directories.Exists (Directory) then
         Ada.Directories.Delete_Tree (Directory);
      end if;
      Item.Directory := Unbounded.Null_Unbounded_String;
      Item.TLS_Certificate_Path := Unbounded.Null_Unbounded_String;
      Item.TLS_Private_Key_Path := Unbounded.Null_Unbounded_String;
      Item.QUIC_Certificate_Path := Unbounded.Null_Unbounded_String;
      Item.QUIC_Private_Key_Path := Unbounded.Null_Unbounded_String;
   end Discard;

   procedure Generate
     (Item            : in out Identity;
      OpenSSL_Command : String := "")
   is
      OpenSSL : OS.String_Access := null;
   begin
      Discard (Item);
      OpenSSL := Locate_OpenSSL (OpenSSL_Command);
      if OpenSSL = null then
         raise Program_Error with
           "openssl with Ed25519 support is required for development " &
           "certificate generation";
      end if;

      Create_Temporary_Directory (Item.Directory);
      declare
         Directory : constant String := Unbounded.To_String (Item.Directory);
         Configuration : constant String := Directory & "/openssl.cnf";
         TLS_Certificate : constant String := Directory & "/tls-cert.pem";
         TLS_Private_Key : constant String := Directory & "/tls-key.pem";
         QUIC_Certificate : constant String := Directory & "/quic-cert.pem";
         QUIC_Private_Key : constant String := Directory & "/quic-key.pem";
         Certificate_DER : constant String := Directory & "/quic-cert.der";
         Private_Key_DER : constant String := Directory & "/quic-key.der";
         Output_Log : constant String := Directory & "/openssl-output.log";
      begin
         Item.TLS_Certificate_Path :=
           Unbounded.To_Unbounded_String (TLS_Certificate);
         Item.TLS_Private_Key_Path :=
           Unbounded.To_Unbounded_String (TLS_Private_Key);
         Item.QUIC_Certificate_Path :=
           Unbounded.To_Unbounded_String (Certificate_DER);
         Item.QUIC_Private_Key_Path :=
           Unbounded.To_Unbounded_String (Private_Key_DER);
         Write_Configuration (Configuration);

         declare
            Arguments : OS.Argument_List (1 .. 7) :=
              (new String'("genpkey"), new String'("-algorithm"),
               new String'("RSA"), new String'("-pkeyopt"),
               new String'("rsa_keygen_bits:2048"), new String'("-out"),
               new String'(TLS_Private_Key));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         declare
            Arguments : OS.Argument_List (1 .. 11) :=
              (new String'("req"), new String'("-new"), new String'("-x509"),
               new String'("-key"), new String'(TLS_Private_Key),
               new String'("-out"), new String'(TLS_Certificate),
               new String'("-days"), new String'("1"),
               new String'("-config"), new String'(Configuration));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         declare
            Arguments : OS.Argument_List (1 .. 5) :=
              (new String'("genpkey"), new String'("-algorithm"),
               new String'("ED25519"), new String'("-out"),
               new String'(QUIC_Private_Key));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         declare
            Arguments : OS.Argument_List (1 .. 11) :=
              (new String'("req"), new String'("-new"), new String'("-x509"),
               new String'("-key"), new String'(QUIC_Private_Key),
               new String'("-out"), new String'(QUIC_Certificate),
               new String'("-days"), new String'("1"),
               new String'("-config"), new String'(Configuration));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         declare
            Arguments : OS.Argument_List (1 .. 7) :=
              (new String'("x509"), new String'("-in"),
               new String'(QUIC_Certificate), new String'("-outform"),
               new String'("DER"), new String'("-out"),
               new String'(Certificate_DER));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         declare
            Arguments : OS.Argument_List (1 .. 7) :=
              (new String'("pkey"), new String'("-in"),
               new String'(QUIC_Private_Key), new String'("-outform"),
               new String'("DER"), new String'("-out"),
               new String'(Private_Key_DER));
         begin
            Run (OpenSSL.all, Arguments, Output_Log);
         end;
         Ada.Directories.Delete_File (Output_Log);
      end;
      OS.Free (OpenSSL);
   exception
      when others =>
         OS.Free (OpenSSL);
         Discard (Item);
         raise;
   end Generate;

   function Is_Generated (Item : Identity) return Boolean is
     (Unbounded.Length (Item.Directory) > 0);

   function TLS_Certificate_File (Item : Identity) return String is
     (Unbounded.To_String (Item.TLS_Certificate_Path));

   function TLS_Private_Key_File (Item : Identity) return String is
     (Unbounded.To_String (Item.TLS_Private_Key_Path));

   function QUIC_Certificate_DER
     (Item : Identity) return Ada.Streams.Stream_Element_Array
   is
     (Read_File
        (Unbounded.To_String (Item.QUIC_Certificate_Path), Maximum => 4_096));

   function QUIC_Private_Key
     (Item : Identity) return QUIC.Ed25519_Private_Key
   is
      Data : constant Ada.Streams.Stream_Element_Array :=
        Read_File
          (Unbounded.To_String (Item.QUIC_Private_Key_Path), Maximum => 256);
      Result : QUIC.Ed25519_Private_Key;
   begin
      if Data'Length < 34
        or else Data (Data'Last - 33) /= 16#04#
        or else Data (Data'Last - 32) /= 16#20#
      then
         raise Constraint_Error with
           "OpenSSL returned an unexpected Ed25519 private-key encoding";
      end if;
      for Offset in 0 .. 31 loop
         Result (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Data (Data'Last - 31 + Ada.Streams.Stream_Element_Offset (Offset));
      end loop;
      return Result;
   end QUIC_Private_Key;
end Flyology.HTTP.Server.Development_Certificates;
