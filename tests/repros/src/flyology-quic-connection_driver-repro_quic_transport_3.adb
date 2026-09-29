with Ada.Streams;
with Flyology.QUIC.Initial_Connection;
with Flyology.QUIC.Initial_Frame_Policy;
with Repro_Support;

procedure Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_3 is
   --  QUIC-TRANSPORT-3 (the same defect as QUIC-TLS-1 in
   --  review/discovery-QUIC-TLS.md, found independently): Initial keys are
   --  never discarded, so an Initial packet forged from on-wire data ends an
   --  established connection in either role.
   --
   --  RFC 9001 s4.9.1: "a client MUST discard Initial keys when it first
   --  sends a Handshake packet and a server MUST discard Initial keys when
   --  it first successfully processes a Handshake packet.  Endpoints MUST
   --  NOT send Initial packets after this point."
   --
   --  Initial secrets derive from the original Destination Connection ID
   --  alone (RFC 9001 s5.2), which is plaintext in the client's first
   --  datagram, so anyone who saw the handshake can protect these packets.

   use Repro_Support;
   use type Application_Space.Timestamp;
   use type Initial_Connection.Build_Status;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

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

   Client, Server : Connection;
   Payload : constant Bytes (1 .. 1_100) := (others => 16#5A#);

   Now : Application_Space.Timestamp := 1_000;

   procedure Give
     (Packet : Datagram;
      Target : in out Connection;
      Reply  : out Datagram_Batch)
   is
      Result : Operation_Result;
   begin
      Process_Datagram
        (Target,
         Packet.Data (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Reply, Result, Now);
   end Give;

   procedure Handshake is
      Client_Output, Server_Output, Reply, Ignored : Datagram_Batch;
      Client_Result : Operation_Result;
   begin
      Start_Client (Client, Client_Output, Client_Result, Now);
      pragma Assert (Client_Output.Count = 1);
      Give (Client_Output.Items (1), Server, Server_Output);
      pragma Assert (Server_Output.Count >= 2);

      Reply := (others => <>);
      for Index in 1 .. Server_Output.Count loop
         Give (Server_Output.Items (Index), Client, Client_Output);
         if Client_Output.Count > 0 then
            Reply := Client_Output;
         end if;
      end loop;
      pragma Assert (Is_Connected (Client) and then Reply.Count = 1);

      Give (Reply.Items (1), Server, Server_Output);
      pragma Assert (Is_Connected (Server));
      Reply := (others => <>);
      for Index in 1 .. Server_Output.Count loop
         Give (Server_Output.Items (Index), Client, Client_Output);
         if Client_Output.Count > 0 then
            Reply := Client_Output;
         end if;
      end loop;
      if Reply.Count = 1 then
         Give (Reply.Items (1), Server, Ignored);
      end if;
      pragma Assert (Handshake_Confirmed (Client));
   end Handshake;

   use type Connection_State;
   use type Operation_Status;

   --  Forge one Initial packet carrying a transport CONNECTION_CLOSE,
   --  protected with the publicly derivable Initial keys.
   procedure Forge_Close
     (Role        : Initial_Connection.Endpoint_Role;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID;
      Skip        : Natural;
      Packet      : out Bytes;
      Length      : out Natural)
   is
      Codec : Initial_Connection.Connection;
      Close : constant Initial_Frame_Policy.Transport_Close_Encode_Result :=
        Initial_Frame_Policy.Encode_Transport_Close
          (Error_Code => 16#0A#, Frame_Type => 16#06#);
      Scratch : Bytes (1 .. Max_Datagram_Length);
      Built : Initial_Connection.Build_Result;
   begin
      Packet := (others => 0);
      Length := 0;
      Initial_Connection.Initialize
        (Codec, Role, Original_ID, Destination, Source);
      --  Advance past the packet numbers the real handshake already used, so
      --  the receiver's replay window cannot be the thing that rejects this.
      for Index in 1 .. Skip loop
         Initial_Connection.Build_Initial_At_Least
           (Codec, (1 .. 0 => 0), (1 => 16#01#), 1_200, Scratch, Built);
         pragma Assert (Built.Status = Initial_Connection.Built);
      end loop;
      Initial_Connection.Build_Initial_At_Least
        (Codec, (1 .. 0 => 0),
         Close.Data (1 .. Ada.Streams.Stream_Element_Offset (Close.Length)),
         1_200, Packet, Built);
      pragma Assert (Built.Status = Initial_Connection.Built);
      Length := Built.Packet_Length;
   end Forge_Close;

   Forged : Bytes (1 .. Max_Datagram_Length);
   Forged_Length : Natural;
   Output : Datagram_Batch;
   Result : Operation_Result;

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

   Initialize_Client
     (Client, ALPN,
      Client_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
      Certificate, Original_ID, ID (Original_ID), Client_ID,
      Client_Parameters);
   Initialize_Server
     (Server, ALPN,
      Server_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
      Certificate, Private_Key, Original_ID, Client_ID, Server_ID,
      Server_Parameters);

   Handshake;
   Check (Is_Connected (Server) and then Handshake_Confirmed (Server),
          "precondition: the server handshake completed");
   Check (Is_Connected (Client) and then Handshake_Confirmed (Client),
          "precondition: the client handshake completed");

   --  Against the server: DCID is the server connection ID, which the
   --  HTTP/3 listener registry resolves to the live slot
   --  (src/flyology-http-server-http_3.adb:112-123).
   Forge_Close (Initial_Connection.Client, Server_ID, Client_ID, 8,
                Forged, Forged_Length);
   Note ("forged Initial for the server:" & Forged_Length'Image & " bytes");
   Process_Datagram
     (Server, Forged (1 .. Ada.Streams.Stream_Element_Offset (Forged_Length)),
      Output, Result, Now);
   Note ("server reports " & Operation_Status'Image (Result.Status)
         & ", state " & Connection_State'Image (State (Server)));
   Check (State (Server) = Connected,
          "an established server discards an Initial packet protected with"
          & " the publicly derivable Initial keys (RFC 9001 s4.9.1)");

   --  Against the client: DCID is the client connection ID.
   Forge_Close (Initial_Connection.Server, Client_ID, Server_ID, 8,
                Forged, Forged_Length);
   Note ("forged Initial for the client:" & Forged_Length'Image & " bytes");
   Process_Datagram
     (Client, Forged (1 .. Ada.Streams.Stream_Element_Offset (Forged_Length)),
      Output, Result, Now);
   Note ("client reports " & Operation_Status'Image (Result.Status)
         & ", state " & Connection_State'Image (State (Client)));
   Check (State (Client) = Connected,
          "an established client discards an Initial packet protected with"
          & " the publicly derivable Initial keys (RFC 9001 s4.9.1)");

   Finish;
end Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_3;
