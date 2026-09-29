--  QUIC-TLS-4: the server matches only the first ALPN entry of a ClientHello
--  instead of selecting a supported protocol from the list.
--
--  The ClientHello produced by Start_Client is patched so that its ALPN
--  extension carries two entries, "h3-29" then "h3", and is handed to a
--  server configured for "h3".  RFC 7301 3.2 has the server "select a
--  protocol from this list", so the correct outcome is a successful
--  ClientHello acceptance.

with Ada.Streams;
with Flyology.QUIC.Transport_Parameter_Policy;
with Repro_Support;

procedure Flyology.QUIC.TLS_Session.Repro_Quic_Tls_4 is
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

   --  alpn(0x0010) ext_len=5 list_len=3 name_len=2 "h3"
   Single : constant Bytes :=
     (16#00#, 16#10#, 16#00#, 16#05#, 16#00#, 16#03#, 16#02#,
      16#68#, 16#33#);
   --  alpn ext_len=11 list_len=9 "h3-29" then "h3"
   Pair : constant Bytes :=
     (16#00#, 16#10#, 16#00#, 16#0B#, 16#00#, 16#09#,
      16#05#, 16#68#, 16#33#, 16#2D#, 16#32#, 16#39#,
      16#02#, 16#68#, 16#33#);

   Client_Parameters, Server_Parameters :
     Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded, Server_Encoded :
     Transport_Parameter_Policy.Encode_Result;

begin
   Repro_Support.Note
     ("QUIC-TLS-4: ALPN selection from a multi-entry ClientHello list");

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

   declare
      Client_Session : Session;
      Server_Session : Session;
      Hello          : Bytes (1 .. 1_200);
      Patched        : Bytes (1 .. 1_206) := (others => 0);
      Server_Hello   : Bytes (1 .. 1_200);
      Authentication : Bytes (1 .. 18_000);
      Client_Result  : Operation_Result;
      Server_Result  : Server_Flight_Result;
      Length         : Ada.Streams.Stream_Element_Offset;
      New_Length     : Ada.Streams.Stream_Element_Offset;
      At_ALPN        : Ada.Streams.Stream_Element_Offset := 0;
      Extensions     : Natural;
      Body_Length    : Natural;
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
      Start_Client (Client_Session, Hello, Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Length :=
        Ada.Streams.Stream_Element_Offset (Client_Result.Output_Length);

      for Start in 1 .. Length - Single'Length + 1 loop
         if Hello (Start .. Start + Single'Length - 1) = Single then
            At_ALPN := Start;
            exit;
         end if;
      end loop;
      pragma Assert (At_ALPN > 0);

      New_Length := Length + Pair'Length - Single'Length;
      Patched (1 .. At_ALPN - 1) := Hello (1 .. At_ALPN - 1);
      Patched (At_ALPN .. At_ALPN + Pair'Length - 1) := Pair;
      Patched (At_ALPN + Pair'Length .. New_Length) :=
        Hello (At_ALPN + Single'Length .. Length);

      --  Grow the extensions-block length (bytes 46 .. 47) and the
      --  handshake message length (bytes 2 .. 4) by the same amount.
      Extensions :=
        Natural (Patched (46)) * 256 + Natural (Patched (47))
        + Natural (Pair'Length - Single'Length);
      Patched (46) := Ada.Streams.Stream_Element (Extensions / 256);
      Patched (47) := Ada.Streams.Stream_Element (Extensions mod 256);
      Body_Length := Natural (New_Length) - 4;
      Patched (2) := Ada.Streams.Stream_Element (Body_Length / 65_536);
      Patched (3) :=
        Ada.Streams.Stream_Element ((Body_Length / 256) mod 256);
      Patched (4) := Ada.Streams.Stream_Element (Body_Length mod 256);

      Repro_Support.Note
        ("patched ClientHello ALPN list = 05 'h3-29' 02 'h3'; server ALPN"
         & " = h3");
      Accept_Client_Hello
        (Server_Session, Patched (1 .. New_Length),
         Server_Hello, Authentication, Server_Result);
      Repro_Support.Note
        ("Accept_Client_Hello status = "
         & Operation_Status'Image (Server_Result.Status));
      Repro_Support.Check
        (Server_Result.Status = Succeeded,
         "the server selects h3 from the offered ALPN list");
   end;

   --  Control: the same server accepts the single-entry list unchanged.
   declare
      Client_Session : Session;
      Server_Session : Session;
      Hello          : Bytes (1 .. 1_200);
      Server_Hello   : Bytes (1 .. 1_200);
      Authentication : Bytes (1 .. 18_000);
      Client_Result  : Operation_Result;
      Server_Result  : Server_Flight_Result;
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
      Start_Client (Client_Session, Hello, Client_Result);
      Accept_Client_Hello
        (Server_Session,
         Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Client_Result.Output_Length)),
         Server_Hello, Authentication, Server_Result);
      Repro_Support.Check
        (Server_Result.Status = Succeeded,
         "control: the single-entry list h3 is accepted");
   end;

   Repro_Support.Finish;
end Flyology.QUIC.TLS_Session.Repro_Quic_Tls_4;
