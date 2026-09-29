--  QUIC-TLS-3: handshake, master, finished and exporter secrets survive a
--  successful handshake and survive the release of the connection object.
--
--  Part 1 inspects the private Session after the handshake reaches Connected
--  and asserts the correct behaviour: every secret with no remaining use is
--  zero.  Part 2 allocates the Session on the heap, records its master
--  secret, releases it the way Connections.Finalize releases the connection
--  implementation (Unchecked_Deallocation, which finalizes but does not
--  overwrite), and then reads a freshly allocated block of the same size.
--  Reading a block the allocator has handed back is an ordinary read of
--  uninitialized storage, not a read of freed memory.

with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Flyology.QUIC.Transport_Parameter_Policy;
with Repro_Support;

procedure Flyology.QUIC.TLS_Session.Repro_Quic_Tls_3 is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Bytes is
      Result : Bytes (1 .. Ada.Streams.Stream_Element_Offset
                             (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function Is_Zero (Item : TLS_Key_Schedule.Secret) return Boolean is
     (Item = TLS_Key_Schedule.Secret'(others => 0));

   Certificate : constant Bytes :=
     Hex
       ("3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" &
        "ea17411e64300506032b657030143112301006035504030c096c6f6361" &
        "6c686f7374301e170d3236303830373230323830385a170d3336303830" &
        "343230323830385a30143112301006035504030c096c6f63616c686f73" &
        "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" &
        "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" &
        "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" &
        "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" &
        "3551d130101ff040530030101ff300506032b657003410024075a33b818" &
        "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" &
        "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f");
   Private_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Bytes := Hex ("6833");

   Client_Parameters, Server_Parameters :
     Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded, Server_Encoded :
     Transport_Parameter_Policy.Encode_Result;

   type Session_Access is access Session;
   procedure Free is new Ada.Unchecked_Deallocation
     (Session, Session_Access);

   Session_Bytes : constant Ada.Streams.Stream_Element_Offset :=
     Ada.Streams.Stream_Element_Offset
       (Session'Max_Size_In_Storage_Elements);
   type Block is new Bytes (1 .. Session_Bytes);
   type Block_Access is access Block;

   procedure Handshake
     (Client_Session : in out Session;
      Server_Session : in out Session)
   is
      Client_Hello    : Bytes (1 .. 1_200);
      Server_Hello    : Bytes (1 .. 1_200);
      Authentication  : Bytes (1 .. 18_000);
      Client_Finished : Bytes (1 .. 36);
      Client_Result   : Operation_Result;
      Server_Result   : Server_Flight_Result;
   begin
      Initialize_Client
        (Client_Session, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate);
      Initialize_Server
        (Server_Session, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key);
      Start_Client (Client_Session, Client_Hello, Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Accept_Client_Hello
        (Server_Session,
         Client_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Client_Result.Output_Length)),
         Server_Hello, Authentication, Server_Result);
      pragma Assert (Server_Result.Status = Succeeded);
      Accept_Server_Hello
        (Client_Session,
         Server_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Server_Result.Server_Hello_Length)),
         Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Accept_Server_Authentication
        (Client_Session,
         Authentication
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Server_Result.Authentication_Length)),
         Client_Finished, Client_Result);
      pragma Assert
        (Client_Result.Status = Succeeded
         and then Is_Connected (Client_Session));
      Accept_Client_Finished
        (Server_Session,
         Client_Finished
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Client_Result.Output_Length)),
         Client_Result);
      pragma Assert
        (Client_Result.Status = Succeeded
         and then Is_Connected (Server_Session));
   end Handshake;

   procedure Report (Name : String; Item : Session) is
   begin
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Handshake),
         Name & ": handshake secret cleared at Connected");
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Master),
         Name & ": master secret cleared at Connected");
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Client_Traffic),
         Name & ": client handshake traffic secret cleared");
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Server_Traffic),
         Name & ": server handshake traffic secret cleared");
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Client_Finished),
         Name & ": client finished key cleared");
      Repro_Support.Check
        (Is_Zero (Item.Handshake_Secrets.Server_Finished),
         Name & ": server finished key cleared");
      Repro_Support.Check
        (Is_Zero (Item.Application_Secrets.Exporter),
         Name & ": exporter secret cleared (never used by this crate)");
   end Report;

begin
   Client_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 16#AA#, 2 => 16#BB#, 3 => 16#CC#, 4 => 16#DD#,
               5 => 1, 6 => 2, 7 => 3, 8 => 4, others => 0),
      Length => 8);
   Server_Parameters.Original_Destination_Connection_ID :=
     Client_Parameters.Initial_Source_Connection_ID;
   Server_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 1, 2 => 2, 3 => 3, 4 => 4,
               5 => 5, 6 => 6, 7 => 7, 8 => 8, others => 0),
      Length => 8);
   Client_Encoded := Transport_Parameter_Policy.Encode
     (Client_Parameters, Transport_Parameter_Policy.Client);
   Server_Encoded := Transport_Parameter_Policy.Encode
     (Server_Parameters, Transport_Parameter_Policy.Server);
   pragma Assert
     (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
      and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

   --  Part 1: what the connected Session still holds.
   declare
      Client_Session : Session;
      Server_Session : Session;
   begin
      Handshake (Client_Session, Server_Session);
      Report ("client", Client_Session);
      Report ("server", Server_Session);
      Repro_Support.Note
        ("client master secret at Connected = "
         & Repro_Support.Hex (Client_Session.Handshake_Secrets.Master));
   end;

   --  Part 2: what survives the release of the heap object.
   declare
      Client_Session : Session_Access := new Session;
      Server_Session : Session_Access := new Session;
      Master  : TLS_Key_Schedule.Secret;
      Reused  : Block_Access;
      Found   : Boolean := False;
      Matches : Natural := 0;
   begin
      Handshake (Client_Session.all, Server_Session.all);
      Master := Client_Session.Handshake_Secrets.Master;
      Repro_Support.Note
        ("heap Session size ="
         & Ada.Streams.Stream_Element_Offset'Image (Session_Bytes)
         & " bytes; master secret = " & Repro_Support.Hex (Master));
      Free (Client_Session);
      Free (Server_Session);
      --  The allocator commonly hands the same storage back.  Reading it
      --  through a fresh allocation is a read of uninitialized storage the
      --  program owns, not a read of freed memory.
      for Attempt in 1 .. 4 loop
         Reused := new Block;
         for Start in Reused'First .. Reused'Last - 31 loop
            if Bytes (Reused (Start .. Start + 31)) = Bytes (Master) then
               Found := True;
               Matches := Matches + 1;
            end if;
         end loop;
         exit when Found;
      end loop;
      Repro_Support.Note
        ("master secret copies found in reused heap storage ="
         & Natural'Image (Matches));
      Repro_Support.Check
        (not Found,
         "the master secret is not recoverable from reused heap storage "
         & "after the session is released");
   end;

   Repro_Support.Finish;
end Flyology.QUIC.TLS_Session.Repro_Quic_Tls_3;
