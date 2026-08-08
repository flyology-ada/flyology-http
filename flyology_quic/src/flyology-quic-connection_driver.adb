with Flyology.QUIC.Crypto_Reassembly_Policy;
with Flyology.QUIC.Initial_Connection;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Transport_Parameter_Policy;
with Flyology.QUIC.Varint_Policy;

package body Flyology.QUIC.Connection_Driver is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Application_Space.Process_Status;
   use type Application_Space.Send_Status;
   use type Handshake_Space.Build_Status;
   use type Handshake_Space.Process_Status;
   use type Initial_Space.Build_Status;
   use type Initial_Space.Process_Status;
   use type Recovery_Policy.Duration;
   use type TLS_Session.Operation_Status;

   function State (Item : Connection) return Connection_State is
     (Item.Current);

   function Is_Connected (Item : Connection) return Boolean is
     (Item.Current = Connected);

   function Has_Stream
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   is (Application_Space.Has_Stream (Item.Application, Stream_ID));

   function Stream_Count (Item : Connection) return Natural is
     (Natural (Application_Space.Stream_Count (Item.Application)));

   function Stream_At
     (Item : Connection; Index : Positive) return Varint_Policy.Value_Type
   is (Application_Space.Stream_At (Item.Application, Index));

   function Available_Length
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type)
      return Application_Space.Stream_Offset
   is (Application_Space.Available_Length (Item.Application, Stream_ID));

   function Is_Complete
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   is (Application_Space.Is_Complete (Item.Application, Stream_ID));

   function Was_Reset
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   is (Application_Space.Was_Reset (Item.Application, Stream_ID));

   function Reset_Error
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type)
      return Varint_Policy.Value_Type
   is (Application_Space.Reset_Error (Item.Application, Stream_ID));

   function Stream_Element
     (Item      : Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Application_Space.Stream_Index)
      return Ada.Streams.Stream_Element
   is (Application_Space.Stream_Element
         (Item.Application, Stream_ID, Offset));

   procedure Consume
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Application_Space.Stream_Offset) is
   begin
      Application_Space.Consume (Item.Application, Stream_ID, Length);
   end Consume;

   procedure Open_Stream
     (Item      : in out Connection;
      Direction : Stream_ID_Policy.Stream_Direction;
      ID        : out Varint_Policy.Value_Type;
      Status    : out Application_Space.Open_Status) is
   begin
      Application_Space.Open_Stream
        (Item.Application, Direction, ID, Status);
   end Open_Stream;

   procedure Build_Stream_Datagram
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : Application_Space.Timestamp;
      Packet    : out Datagram;
      Status    : out Application_Space.Send_Status)
   is
      Built : Application_Space.Send_Result;
   begin
      Packet := (others => <>);
      Application_Space.Build_Stream_Packet
        (Item.Application, Stream_ID, Offset, Fin, Data, Now,
         Packet.Data, Built);
      Status := Built.Status;
      if Built.Status = Application_Space.Sent then
         Packet.Length := Built.Packet_Length;
      end if;
   end Build_Stream_Datagram;

   procedure Build_ACK_Datagram
     (Item      : in out Connection;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Application_Space.Timestamp;
      Packet    : out Datagram;
      Status    : out Application_Space.Send_Status)
   is
      Built : Application_Space.Send_Result;
   begin
      Packet := (others => <>);
      Application_Space.Build_ACK_Packet
        (Item.Application, ACK_Delay, Now, Packet.Data, Built);
      Status := Built.Status;
      if Built.Status = Application_Space.Sent then
         Packet.Length := Built.Packet_Length;
      end if;
   end Build_ACK_Datagram;

   procedure Clear (Output : out Datagram_Batch) is
   begin
      Output := (others => <>);
   end Clear;

   function Append
     (Output : in out Datagram_Batch;
      Packet : Ada.Streams.Stream_Element_Array;
      Length : Natural) return Boolean
   is
      Index : Datagram_Index;
   begin
      if Output.Count = Max_Output_Datagrams
        or else Length > Max_Datagram_Length
      then
         return False;
      end if;
      Output.Count := Output.Count + 1;
      Index := Datagram_Index (Output.Count);
      Output.Items (Index).Length := Length;
      if Length > 0 then
         Output.Items (Index).Data
           (1 .. Ada.Streams.Stream_Element_Offset (Length)) :=
             Packet
               (Packet'First
                  .. Packet'First
                       + Ada.Streams.Stream_Element_Offset (Length - 1));
      end if;
      return True;
   end Append;

   function Initial_Byte
     (Item : Initial_Space.State; Offset : Natural)
      return Ada.Streams.Stream_Element is
     (Initial_Space.Crypto_Element
        (Item, Crypto_Reassembly_Policy.Stream_Index (Offset)));

   function Handshake_Byte
     (Item : Handshake_Space.State; Offset : Natural)
      return Ada.Streams.Stream_Element is
     (Handshake_Space.Crypto_Element
        (Item, Crypto_Reassembly_Policy.Stream_Index (Offset)));

   function Message_Length (Item : Initial_Space.State) return Natural is
      Available : constant Natural :=
        Natural (Initial_Space.Contiguous_Length (Item));
      Body_Length : Natural;
   begin
      if Available < 4 then
         return 0;
      end if;
      Body_Length :=
        Natural (Initial_Byte (Item, 1)) * 65_536
        + Natural (Initial_Byte (Item, 2)) * 256
        + Natural (Initial_Byte (Item, 3));
      if Body_Length > 65_531 or else Available < Body_Length + 4 then
         return 0;
      end if;
      return Body_Length + 4;
   end Message_Length;

   function Message_Length (Item : Handshake_Space.State) return Natural is
      Available : constant Natural :=
        Natural (Handshake_Space.Contiguous_Length (Item));
      Body_Length : Natural;
   begin
      if Available < 4 then
         return 0;
      end if;
      Body_Length :=
        Natural (Handshake_Byte (Item, 1)) * 65_536
        + Natural (Handshake_Byte (Item, 2)) * 256
        + Natural (Handshake_Byte (Item, 3));
      if Body_Length > 65_531 or else Available < Body_Length + 4 then
         return 0;
      end if;
      return Body_Length + 4;
   end Message_Length;

   function Authentication_Length
     (Item : Handshake_Space.State) return Natural
   is
      Available : constant Natural :=
        Natural (Handshake_Space.Contiguous_Length (Item));
      Cursor : Natural := 0;
      Body_Length : Natural;
      Ending : Natural;
      Kind : Ada.Streams.Stream_Element;
   begin
      while Cursor + 4 <= Available loop
         Kind := Handshake_Byte (Item, Cursor);
         Body_Length :=
           Natural (Handshake_Byte (Item, Cursor + 1)) * 65_536
           + Natural (Handshake_Byte (Item, Cursor + 2)) * 256
           + Natural (Handshake_Byte (Item, Cursor + 3));
         if Body_Length > 65_531 - Cursor then
            return 0;
         end if;
         Ending := Cursor + 4 + Body_Length;
         if Ending > Available then
            return 0;
         elsif Kind = 20 then
            return Ending;
         end if;
         Cursor := Ending;
      end loop;
      return 0;
   end Authentication_Length;

   procedure Copy_Initial
     (Item   : Initial_Space.State;
      Length : Natural;
      Data   : out Ada.Streams.Stream_Element_Array) is
   begin
      Data := (others => 0);
      for Offset in 0 .. Length - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Initial_Byte (Item, Offset);
      end loop;
   end Copy_Initial;

   procedure Copy_Handshake
     (Item   : Handshake_Space.State;
      Length : Natural;
      Data   : out Ada.Streams.Stream_Element_Array) is
   begin
      Data := (others => 0);
      for Offset in 0 .. Length - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Handshake_Byte (Item, Offset);
      end loop;
   end Copy_Handshake;

   procedure Initialize_Application (Item : in out Connection) is
      Sending, Receiving : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Peer : Transport_Parameter_Policy.Transport_Parameters;
   begin
      TLS_Session.Get_Application_Keys (Item.TLS, Sending, Receiving);
      Peer := TLS_Session.Peer_Parameters (Item.TLS);
      Application_Space.Initialize
        (Item.Application, Sending, Receiving, Item.Peer_ID, Item.Local_ID,
         (if Item.Is_Client then Stream_ID_Policy.Client
          else Stream_ID_Policy.Server),
         Peer);
      Item.Peer_ACK_Exponent :=
        (if Peer.ACK_Delay_Exponent.Present
         then Application_Space.ACK_Delay_Exponent
           (Peer.ACK_Delay_Exponent.Value)
         else 3);
      Item.Peer_Max_ACK_Delay :=
        (if Peer.Max_ACK_Delay.Present
         then Recovery_Policy.Duration (Peer.Max_ACK_Delay.Value) * 1_000
         else Recovery_Policy.Duration'(25_000));
      Item.Application_Initialized := True;
   end Initialize_Application;

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID) is
   begin
      TLS_Session.Initialize_Client
        (Item.TLS, ALPN, Transport_Parameters, Pinned_Certificate);
      Initial_Space.Initialize
        (Item.Initial, Initial_Connection.Client, Original_Destination_ID,
         Destination, Source);
      Item.Is_Client := True;
      Item.Local_ID := Source;
      Item.Peer_ID := Destination;
      Item.Current := Client_Initial;
   end Initialize_Client;

   procedure Initialize_Server
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Certificate_DER         : Ada.Streams.Stream_Element_Array;
      Private_Key             : Crypto_OpenSSL.Ed25519_Private_Key;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID) is
   begin
      TLS_Session.Initialize_Server
        (Item.TLS, ALPN, Transport_Parameters, Certificate_DER, Private_Key);
      Initial_Space.Initialize
        (Item.Initial, Initial_Connection.Server, Original_Destination_ID,
         Destination, Source);
      Item.Is_Client := False;
      Item.Local_ID := Source;
      Item.Peer_ID := Destination;
      Item.Current := Server_Initial;
   end Initialize_Server;

   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Result : out Operation_Result)
   is
      Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      TLS_Result : TLS_Session.Operation_Result;
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Built : Initial_Space.Build_Result;
   begin
      Clear (Output);
      Result := (others => <>);
      if Item.Current /= Client_Initial then
         return;
      end if;
      TLS_Session.Start_Client (Item.TLS, Hello, TLS_Result);
      Result.TLS_Status := TLS_Result.Status;
      if TLS_Result.Status /= TLS_Session.Succeeded then
         Item.Current := Failed;
         Result.Status := TLS_Error;
         return;
      end if;
      Initial_Space.Build_Crypto_Packet
        (Item.Initial, (1 .. 0 => 0), 0,
         Hello (1 .. Ada.Streams.Stream_Element_Offset
                       (TLS_Result.Output_Length)),
         Packet, Built);
      if Built.Status /= Initial_Space.Built
        or else not Append (Output, Packet, Built.Packet_Length)
      then
         Item.Current := Failed;
         Result.Status := Packet_Error;
         return;
      end if;
      Result.Status := Succeeded;
   end Start_Client;

   procedure Process_Initial_Packet
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : in out Datagram_Batch;
      Result : in out Operation_Result)
   is
      Processed : Initial_Space.Process_Result;
      Length : Natural;
   begin
      Initial_Space.Process_Packet (Item.Initial, Packet, Processed);
      if Processed.Status /= Initial_Space.Processed then
         Result.Status := Packet_Error;
         return;
      end if;
      Length := Message_Length (Item.Initial);
      if Length = 0 then
         Result.Status := Waiting_For_More;
         return;
      end if;

      if Item.Current = Server_Initial then
         declare
            Hello : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length));
            Server_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
            Authentication : Ada.Streams.Stream_Element_Array (1 .. 18_000);
            TLS_Result : TLS_Session.Server_Flight_Result;
            Packet_Out : Ada.Streams.Stream_Element_Array
              (1 .. Max_Datagram_Length);
            Initial_Built : Initial_Space.Build_Result;
            Handshake_Built : Handshake_Space.Build_Result;
            Sending, Receiving : TLS_Key_Schedule.QUIC_Traffic_Keys;
            Offset : Natural := 0;
            Chunk  : Natural;
         begin
            Copy_Initial (Item.Initial, Length, Hello);
            TLS_Session.Accept_Client_Hello
              (Item.TLS, Hello, Server_Hello, Authentication, TLS_Result);
            Result.TLS_Status := TLS_Result.Status;
            if TLS_Result.Status /= TLS_Session.Succeeded then
               Item.Current := Failed;
               Result.Status := TLS_Error;
               return;
            end if;
            Initial_Space.Build_Crypto_Packet
              (Item.Initial, (1 .. 0 => 0), 0,
               Server_Hello
                 (1 .. Ada.Streams.Stream_Element_Offset
                         (TLS_Result.Server_Hello_Length)),
               Packet_Out, Initial_Built);
            if Initial_Built.Status /= Initial_Space.Built
              or else not Append
                (Output, Packet_Out, Initial_Built.Packet_Length)
            then
               Item.Current := Failed;
               Result.Status := Packet_Error;
               return;
            end if;
            TLS_Session.Get_Handshake_Keys (Item.TLS, Sending, Receiving);
            Handshake_Space.Initialize
              (Item.Handshake, Sending, Receiving, Item.Peer_ID,
               Item.Local_ID);
            Item.Handshake_Initialized := True;
            while Offset < TLS_Result.Authentication_Length loop
               Chunk := Natural'Min
                 (Handshake_Space.Max_Crypto_Payload,
                  TLS_Result.Authentication_Length - Offset);
               Handshake_Space.Build_Crypto_Packet
                 (Item.Handshake, Varint_Policy.Value_Type (Offset),
                  Authentication
                    (Ada.Streams.Stream_Element_Offset (Offset + 1)
                       .. Ada.Streams.Stream_Element_Offset (Offset + Chunk)),
                  Packet_Out, Handshake_Built);
               if Handshake_Built.Status /= Handshake_Space.Built
                 or else not Append
                   (Output, Packet_Out, Handshake_Built.Packet_Length)
               then
                  Item.Current := Failed;
                  Result.Status := Output_Capacity_Exceeded;
                  return;
               end if;
               Offset := Offset + Chunk;
            end loop;
            Item.Current := Server_Handshake;
            Result.Status := Succeeded;
         end;
      elsif Item.Current = Client_Initial then
         declare
            Hello : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length));
            TLS_Result : TLS_Session.Operation_Result;
            Sending, Receiving : TLS_Key_Schedule.QUIC_Traffic_Keys;
         begin
            Item.Peer_ID := Processed.Peer_Source;
            Copy_Initial (Item.Initial, Length, Hello);
            TLS_Session.Accept_Server_Hello (Item.TLS, Hello, TLS_Result);
            Result.TLS_Status := TLS_Result.Status;
            if TLS_Result.Status /= TLS_Session.Succeeded then
               Item.Current := Failed;
               Result.Status := TLS_Error;
               return;
            end if;
            TLS_Session.Get_Handshake_Keys (Item.TLS, Sending, Receiving);
            Handshake_Space.Initialize
              (Item.Handshake, Sending, Receiving, Item.Peer_ID,
               Item.Local_ID);
            Item.Handshake_Initialized := True;
            Item.Current := Client_Handshake;
            Result.Status := Succeeded;
         end;
      else
         Result.Status := Invalid_State;
      end if;
   end Process_Initial_Packet;

   procedure Process_Handshake_Packet
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : in out Datagram_Batch;
      Result : in out Operation_Result)
   is
      Processed : Handshake_Space.Process_Result;
      Length : Natural;
   begin
      if not Item.Handshake_Initialized then
         Result.Status := Invalid_State;
         return;
      end if;
      Handshake_Space.Process_Packet (Item.Handshake, Packet, Processed);
      if Processed.Status /= Handshake_Space.Processed then
         Result.Status := Packet_Error;
         return;
      end if;

      if Item.Current = Client_Handshake then
         Length := Authentication_Length (Item.Handshake);
         if Length = 0 then
            Result.Status := Waiting_For_More;
            return;
         end if;
         declare
            Authentication : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length));
            Finished : Ada.Streams.Stream_Element_Array (1 .. 36);
            TLS_Result : TLS_Session.Operation_Result;
            Packet_Out : Ada.Streams.Stream_Element_Array
              (1 .. Max_Datagram_Length);
            Built : Handshake_Space.Build_Result;
         begin
            Copy_Handshake (Item.Handshake, Length, Authentication);
            TLS_Session.Accept_Server_Authentication
              (Item.TLS, Authentication, Finished, TLS_Result);
            Result.TLS_Status := TLS_Result.Status;
            if TLS_Result.Status /= TLS_Session.Succeeded then
               Item.Current := Failed;
               Result.Status := TLS_Error;
               return;
            end if;
            Handshake_Space.Build_Crypto_Packet
              (Item.Handshake, 0,
               Finished
                 (1 .. Ada.Streams.Stream_Element_Offset
                         (TLS_Result.Output_Length)),
               Packet_Out, Built);
            if Built.Status /= Handshake_Space.Built
              or else not Append (Output, Packet_Out, Built.Packet_Length)
            then
               Item.Current := Failed;
               Result.Status := Packet_Error;
               return;
            end if;
            Initialize_Application (Item);
            Item.Current := Connected;
            Result.Status := Succeeded;
         end;
      elsif Item.Current = Server_Handshake then
         Length := Message_Length (Item.Handshake);
         if Length = 0 then
            Result.Status := Waiting_For_More;
            return;
         end if;
         declare
            Finished : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length));
            TLS_Result : TLS_Session.Operation_Result;
         begin
            Copy_Handshake (Item.Handshake, Length, Finished);
            TLS_Session.Accept_Client_Finished
              (Item.TLS, Finished, TLS_Result);
            Result.TLS_Status := TLS_Result.Status;
            if TLS_Result.Status /= TLS_Session.Succeeded then
               Item.Current := Failed;
               Result.Status := TLS_Error;
               return;
            end if;
            Initialize_Application (Item);
            Item.Current := Connected;
            Result.Status := Succeeded;
         end;
      else
         Result.Status := Invalid_State;
      end if;
   end Process_Handshake_Packet;

   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Result : out Operation_Result;
      Now    : Application_Space.Timestamp := 0)
   is
      Application_Result : Application_Space.Process_Result;
   begin
      Clear (Output);
      Result := (others => <>);
      if Packet'Length = 0 then
         Result.Status := Unsupported_Packet;
      elsif (Packet (Packet'First) and 16#80#) = 0 then
         if Item.Current /= Connected then
            Result.Status := Unsupported_Packet;
            return;
         end if;
         Application_Space.Process_Packet
           (Item.Application, Packet, Now, Item.Peer_ACK_Exponent,
            Item.Peer_Max_ACK_Delay, Handshake_Confirmed => True,
            Result => Application_Result);
         Result.Status :=
           (if Application_Result.Status in Application_Space.Processed
              | Application_Space.Duplicate | Application_Space.Too_Old
            then Succeeded else Packet_Error);
      elsif (Packet (Packet'First) and 16#30#) = 16#00# then
         Process_Initial_Packet (Item, Packet, Output, Result);
      elsif (Packet (Packet'First) and 16#30#) = 16#20# then
         Process_Handshake_Packet (Item, Packet, Output, Result);
      else
         Result.Status := Unsupported_Packet;
      end if;
   end Process_Datagram;
end Flyology.QUIC.Connection_Driver;
