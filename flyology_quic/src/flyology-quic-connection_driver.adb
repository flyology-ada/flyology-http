with Flyology.QUIC.Crypto_Reassembly_Policy;
with Flyology.QUIC.Debug;
with Flyology.QUIC.Handshake_Packet_Policy;
with Flyology.QUIC.Initial_Connection;
with Flyology.QUIC.Initial_Packet_Policy;
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
   use type Handshake_Packet_Policy.Parse_Status;
   use type Initial_Space.Build_Status;
   use type Initial_Space.Process_Status;
   use type Initial_Packet_Policy.Parse_Status;
   use type Recovery_Policy.Duration;
   use type TLS_Session.Operation_Status;

   function State (Item : Connection) return Connection_State is
     (Item.Current);

   function Is_Connected (Item : Connection) return Boolean is
     (Item.Current = Connected);

   function Handshake_Confirmed (Item : Connection) return Boolean is
     (Item.Is_Handshake_Confirmed);

   function Peer_Close_Is_Application (Item : Connection) return Boolean is
     (Item.Close_Is_Application);

   function Peer_Close_Error
     (Item : Connection) return Varint_Policy.Value_Type is
     (Item.Close_Error);

   function Has_Recovery_Timeout (Item : Connection) return Boolean is
     (Item.Current = Connected
      and then Application_Space.Has_Recovery_Timeout (Item.Application));

   function Recovery_Deadline
     (Item : Connection) return Application_Space.Timestamp
   is (Application_Space.Recovery_Deadline
         (Item.Application, Item.Peer_Max_ACK_Delay));

   function Has_Stream
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   is (Application_Space.Has_Stream (Item.Application, Stream_ID));

   function Is_Stream_Retired
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   is (Application_Space.Is_Stream_Retired (Item.Application, Stream_ID));

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

   procedure Release_Stream
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type) is
   begin
      Application_Space.Release_Stream (Item.Application, Stream_ID);
   end Release_Stream;

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

   procedure Build_Stream_Abort_Datagram
     (Item              : in out Connection;
      Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type;
      Now               : Application_Space.Timestamp;
      Packet            : out Datagram;
      Status            : out Application_Space.Send_Status)
   is
      Built : Application_Space.Send_Result;
   begin
      Packet := (others => <>);
      Application_Space.Build_Stream_Abort_Packet
        (Item.Application, Stream_ID, Application_Error, Final_Size, Now,
         Packet.Data, Built);
      Status := Built.Status;
      if Built.Status = Application_Space.Sent then
         Packet.Length := Built.Packet_Length;
      end if;
   end Build_Stream_Abort_Datagram;

   procedure Build_Max_Streams_Datagram
     (Item          : in out Connection;
      Bidirectional : Boolean;
      Maximum       : Varint_Policy.Value_Type;
      Now           : Application_Space.Timestamp;
      Packet        : out Datagram;
      Status        : out Application_Space.Send_Status)
   is
      Built : Application_Space.Send_Result;
   begin
      Packet := (others => <>);
      Application_Space.Build_Max_Streams_Packet
        (Item.Application, Bidirectional, Maximum, Now, Packet.Data, Built);
      Status := Built.Status;
      if Built.Status = Application_Space.Sent then
         Packet.Length := Built.Packet_Length;
      end if;
   end Build_Max_Streams_Datagram;

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

   procedure Build_Application_Close_Datagram
     (Item   : in out Connection;
      Application_Error : Varint_Policy.Value_Type;
      Packet : out Datagram;
      Status : out Application_Space.Send_Status)
   is
      Built : Application_Space.Send_Result;
   begin
      Packet := (others => <>);
      Application_Space.Build_Application_Close_Packet
        (Item.Application, Application_Error, Packet.Data, Built);
      Status := Built.Status;
      if Built.Status = Application_Space.Sent then
         Packet.Length := Built.Packet_Length;
      end if;
   end Build_Application_Close_Datagram;

   function Append
     (Output : in out Datagram_Batch;
      Packet : Ada.Streams.Stream_Element_Array;
      Length : Natural) return Boolean;

   procedure Clear (Output : out Datagram_Batch) is
   begin
      Output := (others => <>);
   end Clear;

   procedure Fail_Initial_With_Close
     (Item       : in out Connection;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Output     : in out Datagram_Batch;
      Result     : in out Operation_Result)
   is
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Built  : Initial_Space.Build_Result;
   begin
      Initial_Space.Build_Transport_Close_Packet
        (Item.Initial, Error_Code, Frame_Type, Packet, Built);
      Item.Current := Failed;
      if Built.Status = Initial_Space.Built
        and then Append (Output, Packet, Built.Packet_Length)
      then
         Result.Status := Succeeded;
      elsif Built.Status = Initial_Space.Built then
         Result.Status := Output_Capacity_Exceeded;
      else
         Result.Status := Packet_Error;
      end if;
   end Fail_Initial_With_Close;

   function Transport_Error_For
     (Status : Initial_Space.Process_Status)
      return Varint_Policy.Value_Type
   is
     (case Status is
         when Initial_Space.Invalid_Reserved_Bits
            | Initial_Space.Frame_Not_Allowed
            | Initial_Space.Conflicting_Crypto_Data => 16#0A#,
         when Initial_Space.Frame_Truncated
            | Initial_Space.Frame_Value_Too_Large
            | Initial_Space.Invalid_ACK_Range => 16#07#,
         when Initial_Space.Crypto_Data_Too_Large => 16#0D#,
         when Initial_Space.Processed
            | Initial_Space.Duplicate_Packet
            | Initial_Space.Packet_Too_Old
            | Initial_Space.Envelope_Rejected
            | Initial_Space.Authentication_Failed => 16#01#);

   function Transport_Error_For
     (Status : Handshake_Space.Process_Status)
      return Varint_Policy.Value_Type
   is
     (case Status is
         when Handshake_Space.Invalid_Reserved_Bits
            | Handshake_Space.Frame_Not_Allowed
            | Handshake_Space.Conflicting_Crypto_Data => 16#0A#,
         when Handshake_Space.Frame_Truncated
            | Handshake_Space.Frame_Value_Too_Large
            | Handshake_Space.Invalid_ACK_Range => 16#07#,
         when Handshake_Space.Crypto_Data_Too_Large => 16#0D#,
         when Handshake_Space.Processed
            | Handshake_Space.Duplicate_Packet
            | Handshake_Space.Packet_Too_Old
            | Handshake_Space.Envelope_Rejected
            | Handshake_Space.Authentication_Failed => 16#01#);

   procedure Fail_Handshake_With_Close
     (Item       : in out Connection;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Output     : in out Datagram_Batch;
      Result     : in out Operation_Result)
   is
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Built  : Handshake_Space.Build_Result;
   begin
      Handshake_Space.Build_Transport_Close_Packet
        (Item.Handshake, Error_Code, Frame_Type, Packet, Built);
      Item.Current := Failed;
      if Built.Status = Handshake_Space.Built
        and then Append (Output, Packet, Built.Packet_Length)
      then
         Result.Status := Succeeded;
      elsif Built.Status = Handshake_Space.Built then
         Result.Status := Output_Capacity_Exceeded;
      else
         Result.Status := Packet_Error;
      end if;
   end Fail_Handshake_With_Close;

   function Transport_Error_For
     (Status : Application_Space.Process_Status)
      return Varint_Policy.Value_Type
   is
     (case Status is
         when Application_Space.Flow_Control_Error => 16#03#,
         when Application_Space.Invalid_Stream_Limit => 16#04#,
         when Application_Space.Invalid_Stream_State => 16#05#,
         when Application_Space.Stream_Final_Size_Error
            | Application_Space.Stream_Reset_Conflict => 16#06#,
         when Application_Space.Frame_Truncated
            | Application_Space.Unknown_Frame_Type
            | Application_Space.Frame_Value_Too_Large
            | Application_Space.Invalid_ACK_Range => 16#07#,
         when Application_Space.Invalid_Reserved_Bits
            | Application_Space.Invalid_Connection_ID
            | Application_Space.Unexpected_Destination
            | Application_Space.Unexpected_Handshake_Done
            | Application_Space.Protocol_Violation
            | Application_Space.ACK_Range_Capacity_Exceeded
            | Application_Space.Acknowledges_Unsent_Packet
            | Application_Space.Conflicting_Stream_Data => 16#0A#,
         when Application_Space.Unsupported_Key_Phase => 16#0E#,
         when Application_Space.Unexpected_TLS_Message => 16#10A#,
         when Application_Space.Stream_Capacity_Exceeded
            | Application_Space.Stream_Data_Too_Large => 16#01#,
         when Application_Space.Processed
            | Application_Space.Duplicate
            | Application_Space.Too_Old
            | Application_Space.Envelope_Rejected
            | Application_Space.Authentication_Failed => 16#01#);

   procedure Fail_Application_With_Close
     (Item       : in out Connection;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Output     : in out Datagram_Batch;
      Result     : in out Operation_Result)
   is
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Built  : Application_Space.Send_Result;
   begin
      if Debug.Enabled then
         Debug.Log
           ("quic", "transport-close",
            "state=" & Connection_State'Image (Item.Current) &
            " error=" & Varint_Policy.Value_Type'Image (Error_Code) &
            " frame=" & Varint_Policy.Value_Type'Image (Frame_Type));
      end if;
      Application_Space.Build_Transport_Close_Packet
        (Item.Application, Error_Code, Frame_Type, Packet, Built);
      Item.Current := Failed;
      if Built.Status = Application_Space.Sent
        and then Append (Output, Packet, Built.Packet_Length)
      then
         Result.Status := Succeeded;
      elsif Built.Status = Application_Space.Sent then
         Result.Status := Output_Capacity_Exceeded;
      else
         Result.Status := Packet_Error;
      end if;
   end Fail_Application_With_Close;

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

   function Message_Length
     (Item : Handshake_Space.State; Offset : Natural) return Natural
   is
      Contiguous : constant Natural :=
        Natural (Handshake_Space.Contiguous_Length (Item));
      Available : constant Natural :=
        (if Offset <= Contiguous then Contiguous - Offset else 0);
      Body_Length : Natural;
   begin
      if Available < 4 then
         return 0;
      end if;
      Body_Length :=
        Natural (Handshake_Byte (Item, Offset + 1)) * 65_536
        + Natural (Handshake_Byte (Item, Offset + 2)) * 256
        + Natural (Handshake_Byte (Item, Offset + 3));
      if Body_Length > 65_531 or else Available < Body_Length + 4 then
         return 0;
      end if;
      return Body_Length + 4;
   end Message_Length;

   function Message_Length (Item : Handshake_Space.State) return Natural is
     (Message_Length (Item, 0));

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
         Item.Local_Parameters,
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
      Source                  : Long_Header_Policy.Connection_ID;
      Local_Parameters        :
        Transport_Parameter_Policy.Transport_Parameters) is
   begin
      TLS_Session.Initialize_Client
        (Item.TLS, ALPN, Transport_Parameters, Pinned_Certificate);
      Initial_Space.Initialize
        (Item.Initial, Initial_Connection.Client, Original_Destination_ID,
         Destination, Source);
      Item.Is_Client := True;
      Item.Is_Handshake_Confirmed := False;
      Item.Handshake_Consumed := 0;
      Item.Local_ID := Source;
      Item.Peer_ID := Destination;
      Item.Local_Parameters := Local_Parameters;
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
      Source                  : Long_Header_Policy.Connection_ID;
      Local_Parameters        :
        Transport_Parameter_Policy.Transport_Parameters) is
   begin
      TLS_Session.Initialize_Server
        (Item.TLS, ALPN, Transport_Parameters, Certificate_DER, Private_Key);
      Initial_Space.Initialize
        (Item.Initial, Initial_Connection.Server, Original_Destination_ID,
         Destination, Source);
      Item.Is_Client := False;
      Item.Is_Handshake_Confirmed := False;
      Item.Handshake_Consumed := 0;
      Item.Local_ID := Source;
      Item.Peer_ID := Destination;
      Item.Local_Parameters := Local_Parameters;
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
      if Processed.Status in
        Initial_Space.Duplicate_Packet | Initial_Space.Packet_Too_Old
          | Initial_Space.Envelope_Rejected
          | Initial_Space.Authentication_Failed
      then
         if Debug.Enabled
           and then Processed.Status in
             Initial_Space.Envelope_Rejected
               | Initial_Space.Authentication_Failed
         then
            Debug.Log
              ("quic", "initial-packet-discarded",
               "status=" & Initial_Space.Process_Status'Image
                 (Processed.Status));
         end if;
         --  Packets that cannot be authenticated are indistinguishable from
         --  off-path traffic and are discarded without closing the
         --  connection, as required for unauthenticated QUIC packets.
         Result.Status := Succeeded;
         return;
      elsif Processed.Status /= Initial_Space.Processed then
         Fail_Initial_With_Close
           (Item, Transport_Error_For (Processed.Status),
            Frame_Type => 16#06#, Output => Output, Result => Result);
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
               Fail_Initial_With_Close
                 (Item,
                  Error_Code =>
                    (case TLS_Result.Status is
                        when TLS_Session.Invalid_Transport_Parameters =>
                          16#08#,
                        when TLS_Session.ALPN_Mismatch => 16#178#,
                        when TLS_Session.Invalid_Extensions => 16#16D#,
                        when TLS_Session.Invalid_Message => 16#10A#,
                        when others => 16#150#),
                  Frame_Type => 16#06#,
                  Output => Output, Result => Result);
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
            Item.Handshake_Consumed := 0;
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
            Item.Handshake_Consumed := 0;
            Item.Current := Client_Handshake;
            Result.Status := Succeeded;
         end;
      elsif Item.Current in Client_Handshake | Server_Handshake | Connected then
         Result.Status := Succeeded;
      else
         Result.Status := Invalid_State;
      end if;
   end Process_Initial_Packet;

   procedure Process_Handshake_Packet
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : in out Datagram_Batch;
      Result : in out Operation_Result;
      Now    : Application_Space.Timestamp)
   is
      Processed : Handshake_Space.Process_Result;
      Length : Natural;
   begin
      if not Item.Handshake_Initialized then
         Result.Status := Invalid_State;
         return;
      end if;
      Handshake_Space.Process_Packet (Item.Handshake, Packet, Processed);
      if Processed.Status in
        Handshake_Space.Duplicate_Packet | Handshake_Space.Packet_Too_Old
          | Handshake_Space.Envelope_Rejected
          | Handshake_Space.Authentication_Failed
      then
         if Debug.Enabled
           and then Processed.Status in
             Handshake_Space.Envelope_Rejected
               | Handshake_Space.Authentication_Failed
         then
            Debug.Log
              ("quic", "handshake-packet-discarded",
               "status=" & Handshake_Space.Process_Status'Image
                 (Processed.Status));
         end if;
         Result.Status := Succeeded;
         return;
      elsif Processed.Status /= Handshake_Space.Processed then
         Fail_Handshake_With_Close
           (Item, Transport_Error_For (Processed.Status),
            Frame_Type => 16#06#, Output => Output, Result => Result);
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
               Fail_Handshake_With_Close
                 (Item,
                  Error_Code =>
                    (case TLS_Result.Status is
                        when TLS_Session.ALPN_Mismatch => 16#178#,
                        when TLS_Session.Invalid_Extensions => 16#16D#,
                        when TLS_Session.Invalid_Message => 16#10A#,
                        when others => 16#150#),
                  Frame_Type => 16#06#,
                  Output => Output, Result => Result);
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
            Item.Handshake_Consumed := Length;
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
            Packet_Out : Ada.Streams.Stream_Element_Array
              (1 .. Max_Datagram_Length);
            Built : Application_Space.Send_Result;
         begin
            Copy_Handshake (Item.Handshake, Length, Finished);
            TLS_Session.Accept_Client_Finished
              (Item.TLS, Finished, TLS_Result);
            Result.TLS_Status := TLS_Result.Status;
            if TLS_Result.Status /= TLS_Session.Succeeded then
               Fail_Handshake_With_Close
                 (Item,
                  Error_Code =>
                    (if TLS_Result.Status = TLS_Session.Invalid_Message
                     then 16#10A# else 16#150#),
                  Frame_Type => 16#06#,
                  Output => Output, Result => Result);
               return;
            end if;
            Initialize_Application (Item);
            Application_Space.Build_Handshake_Done_Packet
              (Item.Application, Now, Packet_Out, Built);
            if Built.Status /= Application_Space.Sent then
               Item.Current := Failed;
               Result.Status := Packet_Error;
               return;
            elsif not Append (Output, Packet_Out, Built.Packet_Length) then
               Item.Current := Failed;
               Result.Status := Output_Capacity_Exceeded;
               return;
            end if;
            Item.Is_Handshake_Confirmed := True;
            Item.Handshake_Consumed := Length;
            Item.Current := Connected;
            Result.Status := Succeeded;
         end;
      elsif Item.Current = Connected then
         Length := Message_Length (Item.Handshake, Item.Handshake_Consumed);
         if Length > 0 then
            Fail_Handshake_With_Close
              (Item, Error_Code => 16#10A#, Frame_Type => 16#06#,
               Output => Output, Result => Result);
         else
            Result.Status := Succeeded;
         end if;
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
      Cursor              : Natural := 0;
      Total               : constant Natural := Natural (Packet'Length);
      Accepted            : Boolean := False;
   begin
      Clear (Output);
      Result := (others => <>);
      if Packet'Length = 0 then
         Result.Status := Unsupported_Packet;
         return;
      end if;

      while Cursor < Total loop
         declare
            First : constant Ada.Streams.Stream_Element :=
              Packet
                (Packet'First + Ada.Streams.Stream_Element_Offset (Cursor));
         begin
            if (First and 16#80#) = 0 then
               if (First and 16#40#) = 0 then
                  if Accepted then
                     return;
                  end if;
                  Result.Status := Unsupported_Packet;
                  return;
               elsif Item.Current /= Connected then
                  if Accepted then
                     return;
                  end if;
                  Result.Status := Unsupported_Packet;
                  return;
               end if;
               Application_Space.Process_Packet
                 (Item.Application,
                  Packet
                    (Packet'First
                       + Ada.Streams.Stream_Element_Offset (Cursor)
                     .. Packet'Last),
                  Now, Item.Peer_ACK_Exponent, Item.Peer_Max_ACK_Delay,
                  Handshake_Confirmed => Item.Is_Handshake_Confirmed,
                  Result => Application_Result);
               if Application_Result.Status = Application_Space.Processed
                 and then Application_Result.Frame_Count = 0
               then
                  if Debug.Enabled then
                     Debug.Log
                       ("quic", "application-packet-rejected",
                        "status=" & Application_Space.Process_Status'Image
                          (Application_Result.Status) &
                        " frame=" & Varint_Policy.Value_Type'Image
                          (Application_Result.Triggering_Frame_Type) &
                        " packet=" & Application_Space.Packet_Number'Image
                          (Application_Result.Number));
                  end if;
                  Fail_Application_With_Close
                    (Item, Error_Code => 16#0A#, Frame_Type => 0,
                     Output => Output, Result => Result);
               elsif Application_Result.Status in
                 Application_Space.Envelope_Rejected
                   | Application_Space.Authentication_Failed
               then
                  if Debug.Enabled then
                     Debug.Log
                       ("quic", "application-packet-discarded",
                        "status=" & Application_Space.Process_Status'Image
                          (Application_Result.Status) &
                        " packet=" & Application_Space.Packet_Number'Image
                          (Application_Result.Number));
                  end if;
                  --  Invalid header protection or AEAD authentication is a
                  --  packet discard, not a transport error. Closing here
                  --  lets stray or corrupted UDP traffic tear down a live
                  --  connection and prevents normal retransmission.
                  Result.Status := Succeeded;
               elsif Application_Result.Status not in
                 Application_Space.Processed | Application_Space.Duplicate
                   | Application_Space.Too_Old
               then
                  if Debug.Enabled then
                     Debug.Log
                       ("quic", "application-packet-rejected",
                        "status=" & Application_Space.Process_Status'Image
                          (Application_Result.Status) &
                        " frame=" & Varint_Policy.Value_Type'Image
                          (Application_Result.Triggering_Frame_Type) &
                        " packet=" & Application_Space.Packet_Number'Image
                          (Application_Result.Number));
                  end if;
                  Fail_Application_With_Close
                    (Item,
                     Transport_Error_For (Application_Result.Status),
                     Application_Result.Triggering_Frame_Type,
                     Output, Result);
               elsif Application_Result.Status = Application_Space.Processed
               then
                  if Application_Result.Peer_Closed then
                     Item.Close_Is_Application :=
                       Application_Result.Application_Close;
                     Item.Close_Error := Application_Result.Close_Error;
                     Item.Current := Peer_Closed;
                     Result.Status := Connection_Closed;
                     return;
                  elsif Application_Result.Handshake_Done then
                     Item.Is_Handshake_Confirmed := True;
                  end if;
                  if Application_Result.ACK_Eliciting then
                     declare
                        ACK_Packet : Ada.Streams.Stream_Element_Array
                          (1 .. Max_Datagram_Length);
                        ACK_Result : Application_Space.Send_Result;
                     begin
                        Application_Space.Build_ACK_Packet
                          (Item.Application, ACK_Delay => 0, Now => Now,
                           Packet => ACK_Packet, Result => ACK_Result);
                        if ACK_Result.Status /= Application_Space.Sent then
                           Result.Status := Packet_Error;
                        elsif not Append
                          (Output, ACK_Packet, ACK_Result.Packet_Length)
                        then
                           Result.Status := Output_Capacity_Exceeded;
                        else
                           Result.Status := Succeeded;
                        end if;
                     end;
                  else
                     Result.Status := Succeeded;
                  end if;
               else
                  Result.Status := Succeeded;
               end if;
               return;
            elsif (First and 16#30#) = 16#00# then
               declare
                  Remaining : constant Ada.Streams.Stream_Element_Array :=
                    Packet
                      (Packet'First
                         + Ada.Streams.Stream_Element_Offset (Cursor)
                       .. Packet'Last);
                  Envelope : constant Initial_Packet_Policy.Parse_Result :=
                    Initial_Packet_Policy.Parse (Remaining);
               begin
                  if Envelope.Status /= Initial_Packet_Policy.Parsed then
                     Result.Status := Packet_Error;
                     return;
                  end if;
                  Process_Initial_Packet
                    (Item,
                     Remaining
                       (Remaining'First
                          .. Remaining'First
                               + Ada.Streams.Stream_Element_Offset
                                   (Envelope.Consumed - 1)),
                     Output, Result);
                  if Result.Status not in Succeeded | Waiting_For_More then
                     return;
                  end if;
                  Accepted := True;
                  Cursor := Cursor + Envelope.Consumed;
               end;
            elsif (First and 16#30#) = 16#20# then
               declare
                  Remaining : constant Ada.Streams.Stream_Element_Array :=
                    Packet
                      (Packet'First
                         + Ada.Streams.Stream_Element_Offset (Cursor)
                       .. Packet'Last);
                  Envelope : constant Handshake_Packet_Policy.Parse_Result :=
                    Handshake_Packet_Policy.Parse (Remaining);
               begin
                  if Envelope.Status /= Handshake_Packet_Policy.Parsed then
                     Result.Status := Packet_Error;
                     return;
                  end if;
                  Process_Handshake_Packet
                    (Item,
                     Remaining
                       (Remaining'First
                          .. Remaining'First
                               + Ada.Streams.Stream_Element_Offset
                                   (Envelope.Consumed - 1)),
                     Output, Result, Now);
                  if Result.Status not in Succeeded | Waiting_For_More then
                     return;
                  end if;
                  Accepted := True;
                  Cursor := Cursor + Envelope.Consumed;
               end;
            else
               if Accepted then
                  return;
               end if;
               Result.Status := Unsupported_Packet;
               return;
            end if;
         end;
      end loop;
   end Process_Datagram;

   procedure Process_Timeout
     (Item   : in out Connection;
      Now    : Application_Space.Timestamp;
      Output : out Datagram_Batch;
      Status : out Timeout_Status)
   is
      Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Built  : Application_Space.Send_Result;
   begin
      Clear (Output);
      if Item.Current /= Connected then
         Status := Timeout_Invalid_State;
         return;
      elsif not Application_Space.Has_Recovery_Timeout (Item.Application) then
         Status := No_Pending_Recovery;
         return;
      elsif Now < Application_Space.Recovery_Deadline
        (Item.Application, Item.Peer_Max_ACK_Delay)
      then
         Status := Not_Due;
         return;
      end if;

      for Probe in 1 .. 2 loop
         Application_Space.Build_Probe_Packet
           (Item.Application, Now, Packet, Built);
         if Built.Status = Application_Space.Sent then
            if not Append (Output, Packet, Built.Packet_Length) then
               Status := Timeout_Output_Capacity_Exceeded;
               return;
            end if;
         elsif Output.Count = 0 then
            Status := Timeout_Packet_Error;
            return;
         else
            exit;
         end if;
      end loop;
      Application_Space.On_Probe_Timeout (Item.Application);
      Status := Probes_Ready;
   end Process_Timeout;
end Flyology.QUIC.Connection_Driver;
