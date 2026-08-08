with Flyology.QUIC.Initial_Packet_Policy;
with Flyology.QUIC.Transport_Parameter_Policy;

package body Flyology.QUIC.Test_Connections is
   package QUIC renames Flyology.QUIC.Connections;
   package Parameters renames Flyology.QUIC.Transport_Parameter_Policy;

   use type Parameters.Encode_Status;
   use type Initial_Packet_Policy.Parse_Status;
   use type QUIC.Operation_Status;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function ID (Data : Ada.Streams.Stream_Element_Array)
      return QUIC.Connection_ID
   is
      Result : QUIC.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Parameter
     (Value : QUIC.Connection_ID) return Parameters.Connection_ID_Parameter
   is
      Result : Parameters.Connection_ID_Parameter;
   begin
      Result.Present := True;
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Parameter;

   Certificate : constant Ada.Streams.Stream_Element_Array :=
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
   Private_Key : constant QUIC.Ed25519_Private_Key :=
     QUIC.Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Ada.Streams.Stream_Element_Array := Hex ("6833");
   Original_ID : constant Ada.Streams.Stream_Element_Array :=
     Hex ("8394c8f03e515708");
   Client_ID : constant QUIC.Connection_ID :=
     ID (Hex ("aabbccdd01020304"));
   Server_ID : constant QUIC.Connection_ID :=
     ID (Hex ("1020304050607080"));

   procedure Initialize_Client (Client : in out QUIC.Connection) is
      Client_Parameters : Parameters.Transport_Parameters;
      Client_Encoded    : Parameters.Encode_Result;
   begin
      Client_Parameters.Initial_Source_Connection_ID := Parameter (Client_ID);
      Client_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Client_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);
      Client_Encoded := Parameters.Encode
        (Client_Parameters, Parameters.Client);
      if Client_Encoded.Status /= Parameters.Encoded then
         raise Program_Error with "failed to encode QUIC client parameters";
      end if;
      QUIC.Initialize_Client
        (Client, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate, Original_ID, ID (Original_ID), Client_ID);
   end Initialize_Client;

   procedure Initialize_Server_From_Initial
     (Server : in out QUIC.Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Status : out Server_Initialize_Status)
   is
      Envelope : constant Initial_Packet_Policy.Parse_Result :=
        Initial_Packet_Policy.Parse (Packet);
      Server_Parameters : Parameters.Transport_Parameters;
      Server_Encoded    : Parameters.Encode_Result;
      Original          : QUIC.Connection_ID;
      Client_Source     : QUIC.Connection_ID;
   begin
      if Envelope.Status /= Initial_Packet_Policy.Parsed then
         Status := Not_A_V1_Initial;
         return;
      end if;

      Original.Length := Envelope.Header.Destination.Length;
      Client_Source.Length := Envelope.Header.Source.Length;
      if Original.Length > 0 then
         Original.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Original.Length)) :=
             Envelope.Header.Destination.Data
               (1 .. Ada.Streams.Stream_Element_Offset (Original.Length));
      end if;
      if Client_Source.Length > 0 then
         Client_Source.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Source.Length)) :=
             Envelope.Header.Source.Data
               (1 .. Ada.Streams.Stream_Element_Offset
                       (Client_Source.Length));
      end if;

      Server_Parameters.Original_Destination_Connection_ID :=
        Parameter (Original);
      Server_Parameters.Initial_Source_Connection_ID :=
        Parameter (Server_ID);
      Server_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Server_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);
      Server_Encoded := Parameters.Encode
        (Server_Parameters, Parameters.Server);
      if Server_Encoded.Status /= Parameters.Encoded then
         Status := Parameter_Error;
         return;
      end if;

      QUIC.Initialize_Server
        (Server, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key,
         Original.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Original.Length)),
         Client_Source, Server_ID);
      Status := Initialized;
   end Initialize_Server_From_Initial;

   procedure Connect
     (Client : in out QUIC.Connection;
      Server : in out QUIC.Connection)
   is
      Server_Parameters : Parameters.Transport_Parameters;
      Server_Encoded : Parameters.Encode_Result;
      Client_Output, Server_Output, Finish : QUIC.Datagram_Batch;
      Client_Status, Server_Status : QUIC.Operation_Status;
   begin
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
      Server_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Server_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);

      Server_Encoded := Parameters.Encode (Server_Parameters, Parameters.Server);
      if Server_Encoded.Status /= Parameters.Encoded then
         raise Program_Error with "failed to encode QUIC test parameters";
      end if;

      Initialize_Client (Client);
      QUIC.Initialize_Server
        (Server, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key, Original_ID, Client_ID, Server_ID);

      QUIC.Start_Client (Client, Client_Output, Client_Status);
      if Client_Status /= QUIC.Succeeded or else Client_Output.Count /= 1 then
         raise Program_Error with "failed to start QUIC test client";
      end if;
      QUIC.Process_Datagram
        (Server,
         Client_Output.Items (1).Data
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Client_Output.Items (1).Length)),
         Server_Output, Server_Status);
      if Server_Status /= QUIC.Succeeded or else Server_Output.Count < 2 then
         raise Program_Error with "failed to process client Initial";
      end if;

      Finish := (others => <>);
      for Index in 1 .. Server_Output.Count loop
         QUIC.Process_Datagram
           (Client,
            Server_Output.Items (Index).Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Server_Output.Items (Index).Length)),
            Client_Output, Client_Status);
         if Client_Output.Count > 0 then
            Finish := Client_Output;
         end if;
      end loop;
      if not QUIC.Is_Connected (Client) or else Finish.Count /= 1 then
         raise Program_Error with "failed to connect QUIC test client";
      end if;
      QUIC.Process_Datagram
        (Server,
         Finish.Items (1).Data
           (1 .. Ada.Streams.Stream_Element_Offset (Finish.Items (1).Length)),
         Server_Output, Server_Status);
      if not QUIC.Is_Connected (Server) then
         raise Program_Error with "failed to connect QUIC test server";
      end if;
   end Connect;

   procedure Deliver
     (Packet : QUIC.Datagram;
      Target : in out QUIC.Connection)
   is
      Output : QUIC.Datagram_Batch;
      Status : QUIC.Operation_Status;
   begin
      QUIC.Process_Datagram
        (Target,
         Packet.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Output, Status);
      if Status /= QUIC.Succeeded then
         raise Program_Error with "failed to deliver QUIC test datagram";
      end if;
   end Deliver;
end Flyology.QUIC.Test_Connections;
