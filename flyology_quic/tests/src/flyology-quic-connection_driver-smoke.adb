with Flyology.IO.Sockets;
with Flyology.QUIC.Connection_IO;
with Flyology.QUIC.Transport_Parameter_Policy;

procedure Flyology.QUIC.Connection_Driver.Smoke is
   use type Application_Space.Open_Status;
   use type Application_Space.Send_Status;
   use type Ada.Streams.Stream_Element;
   use type Transport_Parameter_Policy.Encode_Status;
   use type Varint_Policy.Value_Type;

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
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function ID
     (Data : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
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
   Private_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Ada.Streams.Stream_Element_Array := Hex ("6833");
   Original_ID : constant Ada.Streams.Stream_Element_Array :=
     Hex ("8394c8f03e515708");
   Original_Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("aabbccdd01020304"));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("1020304050607080"));

   Client_Parameters, Server_Parameters :
     Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded, Server_Encoded :
     Transport_Parameter_Policy.Encode_Result;
   Client, Server : Connection;
   Client_Output, Server_Output, Reply : Datagram_Batch;
   Client_Result, Server_Result : Operation_Result;
   Client_Socket, Server_Socket : Flyology.IO.Sockets.Socket_Type;
   Client_Endpoint, Server_Endpoint : Flyology.IO.Sockets.Endpoint;
begin
   Client_Parameters.Initial_Source_Connection_ID :=
     Parameter (Client_ID);
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

   Server_Parameters.Original_Destination_Connection_ID :=
     Parameter (Original_Destination);
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
      Certificate, Original_ID, Original_Destination, Client_ID);
   Initialize_Server
     (Server, ALPN,
      Server_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
      Certificate, Private_Key, Original_ID, Client_ID, Server_ID);

   Flyology.IO.Sockets.Create_Socket
     (Client_Socket, Flyology.IO.Sockets.IPv4,
      Flyology.IO.Sockets.Socket_Datagram);
   Flyology.IO.Sockets.Create_Socket
     (Server_Socket, Flyology.IO.Sockets.IPv4,
      Flyology.IO.Sockets.Socket_Datagram);
   Flyology.IO.Sockets.Bind_Socket
     (Client_Socket,
      Flyology.IO.Sockets.Network_Endpoint
        (Flyology.IO.Sockets.Loopback_IPv4,
         Flyology.IO.Sockets.Any_Port));
   Flyology.IO.Sockets.Bind_Socket
     (Server_Socket,
      Flyology.IO.Sockets.Network_Endpoint
        (Flyology.IO.Sockets.Loopback_IPv4,
         Flyology.IO.Sockets.Any_Port));
   Client_Endpoint := Flyology.IO.Sockets.Get_Socket_Name (Client_Socket);
   Server_Endpoint := Flyology.IO.Sockets.Get_Socket_Name (Server_Socket);
   Flyology.IO.Sockets.Connect_Socket (Client_Socket, Server_Endpoint);
   Flyology.IO.Sockets.Connect_Socket (Server_Socket, Client_Endpoint);

   Start_Client (Client, Client_Output, Client_Result);
   pragma Assert
     (Client_Result.Status = Succeeded and then Client_Output.Count = 1
      and then Client_Output.Items (1).Length = Max_Datagram_Length);
   Connection_IO.Send (Client_Socket, Client_Output, Timeout => 1.0);
   Connection_IO.Receive
     (Server_Socket, Server, Server_Output, Server_Result, Timeout => 1.0);
   pragma Assert
     (Server_Result.Status = Succeeded and then Server_Output.Count >= 2
      and then State (Server) = Server_Handshake);

   Reply := (others => <>);
   Connection_IO.Send (Server_Socket, Server_Output, Timeout => 1.0);
   for Index in 1 .. Server_Output.Count loop
      Connection_IO.Receive
        (Client_Socket, Client, Client_Output, Client_Result,
         Timeout => 1.0);
      if Client_Output.Count > 0 then
         Reply := Client_Output;
      end if;
   end loop;
   pragma Assert
     (Is_Connected (Client) and then Reply.Count = 1
      and then Client_Result.Status = Succeeded);

   Connection_IO.Send (Client_Socket, Reply, Timeout => 1.0);
   Connection_IO.Receive
     (Server_Socket, Server, Server_Output, Server_Result, Timeout => 1.0);
   pragma Assert
     (Server_Result.Status = Succeeded and then Is_Connected (Server)
      and then Server_Output.Count = 0);

   declare
      Stream_ID : Varint_Policy.Value_Type;
      Opened    : Application_Space.Open_Status;
      Sent      : Application_Space.Send_Status;
      Stream_Packet, ACK_Packet : Datagram;
   begin
      Open_Stream
        (Client, Stream_ID_Policy.Bidirectional, Stream_ID, Opened);
      pragma Assert
        (Opened = Stream_ID_Policy.Opened and then Stream_ID = 0);
      Build_Stream_Datagram
        (Client, Stream_ID, 0, Fin => True,
         Data => (16#68#, 16#33#), Now => 100,
         Packet => Stream_Packet, Status => Sent);
      pragma Assert (Sent = Application_Space.Sent);
      Connection_IO.Send (Client_Socket, Stream_Packet, Timeout => 1.0);
      Connection_IO.Receive
        (Server_Socket, Server, Server_Output, Server_Result,
         Now => 150, Timeout => 1.0);
      pragma Assert
        (Server_Result.Status = Succeeded
         and then Has_Stream (Server, Stream_ID)
         and then Available_Length (Server, Stream_ID) = 2
         and then Stream_Element (Server, Stream_ID, 0) = 16#68#
         and then Stream_Element (Server, Stream_ID, 1) = 16#33#);
      Build_ACK_Datagram
        (Server, ACK_Delay => 0, Now => 160,
         Packet => ACK_Packet, Status => Sent);
      pragma Assert (Sent = Application_Space.Sent);
      Connection_IO.Send (Server_Socket, ACK_Packet, Timeout => 1.0);
      Connection_IO.Receive
        (Client_Socket, Client, Client_Output, Client_Result,
         Now => 200, Timeout => 1.0);
      pragma Assert (Client_Result.Status = Succeeded);
   end;

   Flyology.IO.Sockets.Close_Socket (Client_Socket);
   Flyology.IO.Sockets.Close_Socket (Server_Socket);
end Flyology.QUIC.Connection_Driver.Smoke;
