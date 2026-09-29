with Ada.Streams;
with Flyology.QUIC.Crypto_Frame_Policy;
with Flyology.QUIC.Initial_Connection;
with Repro_Support;

procedure Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_1 is
   --  QUIC-TRANSPORT-1: RFC 9000 section 8.1 anti-amplification and the
   --  section 14.1 minimum on a received client Initial.
   --
   --  RFC 9000 s8.1: "a server MUST limit the amount of data it sends to an
   --  unvalidated address to three times the amount of data received from
   --  that address."
   --
   --  RFC 9000 s14.1: "A server MUST discard an Initial packet that is
   --  carried in a UDP datagram with a payload that is smaller than the
   --  smallest allowed maximum datagram size of 1200 bytes."
   --
   --  Four measurements, each starting a fresh server from one client
   --  Initial and never sending anything else from that address:
   --    A  1200-byte Initial, pinned 320-byte Ed25519 test certificate
   --    B  1200-byte Initial, 4096-byte certificate (the largest the HTTP/3
   --       server accepts, src/flyology-http-server-http_3.ads:75)
   --    C  minimal Initial (no 1200-byte padding), test certificate
   --    D  minimal Initial, 4096-byte certificate
   --
   --  The spike measures the ratio.  It asserts nothing about its size in
   --  advance.

   use Repro_Support;
   use type Application_Space.Timestamp;
   use type Initial_Connection.Build_Status;
   use type TLS_Session.Operation_Status;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   --  The listener reclaims a slot that makes no progress after
   --  Default_Handshake_Idle_Timeout = 3.0 s
   --  (src/flyology-http-server-http_3.ads:32).  Microseconds here.
   Idle_Budget : constant Application_Space.Timestamp := 3_000_000;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex_Bytes (Value : String) return Bytes is
      Result : Bytes (1 .. Ada.Streams.Stream_Element_Offset
                             (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex_Bytes;

   function ID (Data : Bytes) return Long_Header_Policy.Connection_ID is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Parameter
     (Value : Long_Header_Policy.Connection_ID)
      return Transport_Parameter_Policy.Connection_ID_Parameter
   is
      Result : Transport_Parameter_Policy.Connection_ID_Parameter;
   begin
      Result.Present := True;
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Parameter;

   --  Same pinned material as tests/flyology-quic-test_connections.adb.
   Certificate : constant Bytes :=
     Hex_Bytes
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
       (Hex_Bytes ("f491306c81165ffd97822f3ef58de891" &
                   "8779314457f5501e42d3f68504cd3aa8"));

   --  The TLS session copies Certificate_DER into the Certificate message
   --  without parsing it (flyology-quic-tls_session.adb:155-156), so an
   --  opaque array of the maximum size the HTTP/3 server accepts measures
   --  the flight a real 4 KB certificate would produce.
   Large_Certificate : constant Bytes (1 .. 4_096) := (others => 16#41#);
   --  A CA-issued leaf with SANs, AIA, CRL and SCT extensions is routinely
   --  around a kilobyte even with an Ed25519 key.
   Typical_Certificate : constant Bytes (1 .. 1_024) := (others => 16#41#);

   ALPN        : constant Bytes := Hex_Bytes ("6833");
   Original_ID : constant Bytes := Hex_Bytes ("8394c8f03e515708");
   Client_ID   : constant Long_Header_Policy.Connection_ID :=
     ID (Hex_Bytes ("aabbccdd01020304"));
   Server_ID   : constant Long_Header_Policy.Connection_ID :=
     ID (Hex_Bytes ("1020304050607080"));

   Client_Parameters, Server_Parameters :
     Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded, Server_Encoded :
     Transport_Parameter_Policy.Encode_Result;

   function Batch_Bytes (Batch : Datagram_Batch) return Natural is
      Total : Natural := 0;
   begin
      for Index in 1 .. Batch.Count loop
         Total := Total + Batch.Items (Index).Length;
      end loop;
      return Total;
   end Batch_Bytes;

   function Ratio_Image (Numerator, Denominator : Natural) return String is
      Scaled : constant Natural :=
        (if Denominator = 0 then 0 else (Numerator * 100) / Denominator);
      Whole  : constant String := Natural'Image (Scaled / 100);
      Frac   : constant String := Natural'Image (Scaled mod 100);
   begin
      return Whole (Whole'First + 1 .. Whole'Last) & "."
        & (if Scaled mod 100 < 10 then "0" else "")
        & Frac (Frac'First + 1 .. Frac'Last);
   end Ratio_Image;

   --  Build one client Initial.  Minimum = 1_200 reproduces what the driver
   --  emits; Minimum = 0 is the undersized datagram s14.1 covers.
   procedure Build_Client_Initial
     (Minimum : Natural;
      Packet  : out Bytes;
      Length  : out Natural)
   is
      TLS   : TLS_Session.Session;
      Hello : Bytes (1 .. 1_200);
      TLS_Result : TLS_Session.Operation_Result;
      Codec : Initial_Connection.Connection;
      Frame : Crypto_Frame_Policy.Encode_Result;
      Built : Initial_Connection.Build_Result;
   begin
      Packet := (others => 0);
      Length := 0;
      TLS_Session.Initialize_Client
        (TLS, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate);
      TLS_Session.Start_Client (TLS, Hello, TLS_Result);
      pragma Assert (TLS_Result.Status = TLS_Session.Succeeded);
      Frame := Crypto_Frame_Policy.Encode
        (0,
         Hello (1 .. Ada.Streams.Stream_Element_Offset
                       (TLS_Result.Output_Length)));
      Initial_Connection.Initialize
        (Codec, Initial_Connection.Client, Original_ID, ID (Original_ID),
         Client_ID);
      Initial_Connection.Build_Initial_At_Least
        (Codec, (1 .. 0 => 0),
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Minimum, Packet, Built);
      pragma Assert (Built.Status = Initial_Connection.Built);
      Length := Built.Packet_Length;
   end Build_Client_Initial;

   procedure Measure
     (Label            : String;
      Server_Cert      : Bytes;
      Initial_Datagram : Bytes;
      Accepted         : out Boolean;
      Emitted          : out Natural;
      Flights          : out Natural)
   is
      Server : Connection;
      Output : Datagram_Batch;
      Result : Operation_Result;
      Timeout_Result : Timeout_Status;
      Now : Application_Space.Timestamp := 0;
   begin
      Emitted := 0;
      Flights := 0;
      Initialize_Server
        (Server, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Server_Cert, Private_Key, Original_ID, Client_ID, Server_ID,
         Server_Parameters);
      Process_Datagram (Server, Initial_Datagram, Output, Result, Now);
      Accepted := Result.Status = Succeeded and then Output.Count > 0;
      Emitted := Batch_Bytes (Output);
      if Output.Count > 0 then
         Flights := 1;
         Note ("   flight 1 at" & Now'Image & " us:" & Output.Count'Image
               & " datagrams," & Emitted'Image & " bytes");
      end if;
      while Has_Recovery_Timeout (Server) loop
         Now := Recovery_Deadline (Server);
         exit when Now > Idle_Budget;
         Process_Timeout (Server, Now, Output, Timeout_Result);
         exit when Timeout_Result /= Probes_Ready;
         Flights := Flights + 1;
         Emitted := Emitted + Batch_Bytes (Output);
         Note ("   flight" & Flights'Image & " at" & Now'Image & " us:"
               & Output.Count'Image & " datagrams,"
               & Natural'Image (Batch_Bytes (Output)) & " bytes");
      end loop;
      Note (Label & ": status " & Operation_Status'Image (Result.Status)
            & ", flights" & Flights'Image
            & ", sent" & Emitted'Image & " bytes, received"
            & Natural'Image (Natural (Initial_Datagram'Length)) & " bytes");
   end Measure;

   Padded_Packet, Short_Packet : Bytes (1 .. Max_Datagram_Length);
   Padded_Length, Short_Length : Natural;

begin
   Client_Parameters.Initial_Source_Connection_ID := Parameter (Client_ID);
   Client_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 16_384);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 16_384);
   Client_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 16_384);
   Client_Parameters.Initial_Max_Streams_Bidi := (Present => True, Value => 8);
   Client_Parameters.Initial_Max_Streams_Uni := (Present => True, Value => 8);

   Server_Parameters.Original_Destination_Connection_ID :=
     Parameter (ID (Original_ID));
   Server_Parameters.Initial_Source_Connection_ID := Parameter (Server_ID);
   Server_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 16_384);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 16_384);
   Server_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 16_384);
   Server_Parameters.Initial_Max_Streams_Bidi := (Present => True, Value => 8);
   Server_Parameters.Initial_Max_Streams_Uni := (Present => True, Value => 8);

   Client_Encoded := Transport_Parameter_Policy.Encode
     (Client_Parameters, Transport_Parameter_Policy.Client);
   Server_Encoded := Transport_Parameter_Policy.Encode
     (Server_Parameters, Transport_Parameter_Policy.Server);
   pragma Assert
     (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
      and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

   Build_Client_Initial (1_200, Padded_Packet, Padded_Length);
   Build_Client_Initial (0, Short_Packet, Short_Length);
   Note ("padded client Initial:" & Padded_Length'Image & " bytes");
   Note ("minimal client Initial:" & Short_Length'Image & " bytes");

   declare
      Accepted : Boolean;
      Emitted, Flights : Natural;
   begin
      Measure ("A 1200-byte Initial, 320-byte certificate", Certificate,
               Padded_Packet (1 .. Ada.Streams.Stream_Element_Offset
                                     (Padded_Length)),
               Accepted, Emitted, Flights);
      Note ("   amplification " & Ratio_Image (Emitted, Padded_Length) & "x");
      Check (Emitted <= 3 * Padded_Length,
             "A: at most 3x the bytes received (RFC 9000 s8.1)");

      Measure ("B 1200-byte Initial, 4096-byte certificate",
               Large_Certificate,
               Padded_Packet (1 .. Ada.Streams.Stream_Element_Offset
                                     (Padded_Length)),
               Accepted, Emitted, Flights);
      Note ("   amplification " & Ratio_Image (Emitted, Padded_Length) & "x");
      Check (Emitted <= 3 * Padded_Length,
             "B: at most 3x the bytes received (RFC 9000 s8.1)");

      Measure ("E 1200-byte Initial, 1024-byte certificate",
               Typical_Certificate,
               Padded_Packet (1 .. Ada.Streams.Stream_Element_Offset
                                     (Padded_Length)),
               Accepted, Emitted, Flights);
      Note ("   amplification " & Ratio_Image (Emitted, Padded_Length) & "x");
      Check (Emitted <= 3 * Padded_Length,
             "E: at most 3x the bytes received (RFC 9000 s8.1)");

      Measure ("C minimal Initial, 320-byte certificate", Certificate,
               Short_Packet (1 .. Ada.Streams.Stream_Element_Offset
                                    (Short_Length)),
               Accepted, Emitted, Flights);
      Check (not Accepted,
             "C: a server discards a client Initial in a datagram under"
             & " 1200 bytes (RFC 9000 s14.1)");
      Note ("   amplification " & Ratio_Image (Emitted, Short_Length) & "x");
      Check (Emitted <= 3 * Short_Length,
             "C: at most 3x the bytes received (RFC 9000 s8.1)");

      Measure ("D minimal Initial, 4096-byte certificate", Large_Certificate,
               Short_Packet (1 .. Ada.Streams.Stream_Element_Offset
                                    (Short_Length)),
               Accepted, Emitted, Flights);
      Note ("   amplification " & Ratio_Image (Emitted, Short_Length) & "x");
      Check (Emitted <= 3 * Short_Length,
             "D: at most 3x the bytes received (RFC 9000 s8.1)");
   end;

   Finish;
end Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_1;
