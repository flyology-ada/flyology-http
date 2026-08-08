with Ada.Unchecked_Deallocation;
with Flyology.QUIC.Application_Space;
with Flyology.QUIC.Connection_Driver;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Initial_Packet_Policy;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.Transport_Parameter_Policy;
with System.Address_To_Access_Conversions;

package body Flyology.QUIC.Connections is
   use type System.Address;
   use type Initial_Packet_Policy.Parse_Status;
   use type Transport_Parameter_Policy.Encode_Status;
   use type Transport_Parameter_Policy.Decode_Status;
   use type Transport_Parameter_Policy.Endpoint_Role;

   type Connection_Impl is limited record
      Driver : Connection_Driver.Connection;
   end record;

   package Impl_Conversions is new System.Address_To_Access_Conversions
     (Connection_Impl);

   procedure Release is new Ada.Unchecked_Deallocation
     (Connection_Impl, Impl_Conversions.Object_Pointer);

   function Impl
     (Item : Connection) return Impl_Conversions.Object_Pointer is
     (Impl_Conversions.To_Pointer (Item.Backend));

   procedure Ensure_Impl (Item : in out Connection) is
   begin
      if Item.Backend = System.Null_Address then
         declare
            Value : constant Impl_Conversions.Object_Pointer :=
              new Connection_Impl;
         begin
            Item.Backend := Impl_Conversions.To_Address (Value);
         end;
      end if;
   end Ensure_Impl;

   overriding procedure Finalize (Item : in out Connection) is
      Value : Impl_Conversions.Object_Pointer;
   begin
      if Item.Backend /= System.Null_Address then
         Value := Impl (Item);
         Release (Value);
         Item.Backend := System.Null_Address;
      end if;
   end Finalize;

   function Internal_ID
     (Value : Connection_ID) return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Internal_ID;

   function Public_ID
     (Value : Long_Header_Policy.Connection_ID) return Connection_ID
   is
      Result : Connection_ID;
   begin
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Public_ID;

   function Parameter
     (Value : Connection_ID)
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

   function Encode_Parameters
     (Settings        : Transport_Settings;
      Sender          : Transport_Parameter_Policy.Endpoint_Role;
      Initial_Source  : Connection_ID;
      Original        : Connection_ID := (others => <>))
      return Transport_Parameter_Policy.Encode_Result
   is
      Value : Transport_Parameter_Policy.Transport_Parameters;
   begin
      Value.Initial_Source_Connection_ID := Parameter (Initial_Source);
      if Sender = Transport_Parameter_Policy.Server then
         Value.Original_Destination_Connection_ID := Parameter (Original);
      end if;
      Value.Initial_Max_Data := (True, Settings.Max_Data);
      Value.Initial_Max_Stream_Data_Bidi_Local :=
        (True, Settings.Max_Stream_Data_Bidi_Local);
      Value.Initial_Max_Stream_Data_Bidi_Remote :=
        (True, Settings.Max_Stream_Data_Bidi_Remote);
      Value.Initial_Max_Stream_Data_Uni :=
        (True, Settings.Max_Stream_Data_Uni);
      Value.Initial_Max_Streams_Bidi := (True, Settings.Max_Streams_Bidi);
      Value.Initial_Max_Streams_Uni := (True, Settings.Max_Streams_Uni);
      return Transport_Parameter_Policy.Encode (Value, Sender);
   end Encode_Parameters;

   function Public_State
     (Value : Connection_Driver.Connection_State) return Connection_State
   is
     (case Value is
         when Connection_Driver.Uninitialized => Uninitialized,
         when Connection_Driver.Client_Initial => Client_Initial,
         when Connection_Driver.Client_Handshake => Client_Handshake,
         when Connection_Driver.Server_Initial => Server_Initial,
         when Connection_Driver.Server_Handshake => Server_Handshake,
         when Connection_Driver.Connected => Connected,
         when Connection_Driver.Failed => Failed);

   function State (Item : Connection) return Connection_State is
     (if Item.Backend = System.Null_Address then Uninitialized
      else Public_State (Connection_Driver.State (Impl (Item).Driver)));

   function Is_Connected (Item : Connection) return Boolean is
     (Item.Backend /= System.Null_Address
      and then Connection_Driver.Is_Connected (Impl (Item).Driver));

   function Handshake_Confirmed (Item : Connection) return Boolean is
     (Item.Backend /= System.Null_Address
      and then Connection_Driver.Handshake_Confirmed (Impl (Item).Driver));

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID) is
      Decoded : constant Transport_Parameter_Policy.Decode_Result :=
        Transport_Parameter_Policy.Decode
          (Transport_Parameters, Transport_Parameter_Policy.Client);
   begin
      if Decoded.Status /= Transport_Parameter_Policy.Decoded then
         raise Program_Error with "invalid QUIC client transport parameters";
      end if;
      Ensure_Impl (Item);
      Connection_Driver.Initialize_Client
        (Impl (Item).Driver, ALPN, Transport_Parameters, Pinned_Certificate,
         Original_Destination_ID, Internal_ID (Destination),
         Internal_ID (Source), Decoded.Parameters);
   end Initialize_Client;

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Settings                : Transport_Settings;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID)
   is
      Encoded : constant Transport_Parameter_Policy.Encode_Result :=
        Encode_Parameters
          (Settings, Transport_Parameter_Policy.Client,
           Initial_Source => Source);
   begin
      if Encoded.Status /= Transport_Parameter_Policy.Encoded then
         raise Program_Error with "invalid QUIC client transport settings";
      end if;
      Initialize_Client
        (Item, ALPN,
         Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
         Pinned_Certificate, Original_Destination_ID, Destination, Source);
   end Initialize_Client;

   procedure Initialize_Server
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Certificate_DER         : Ada.Streams.Stream_Element_Array;
      Private_Key             : Ed25519_Private_Key;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID) is
      Decoded : constant Transport_Parameter_Policy.Decode_Result :=
        Transport_Parameter_Policy.Decode
          (Transport_Parameters, Transport_Parameter_Policy.Server);
   begin
      if Decoded.Status /= Transport_Parameter_Policy.Decoded then
         raise Program_Error with "invalid QUIC server transport parameters";
      end if;
      Ensure_Impl (Item);
      Connection_Driver.Initialize_Server
        (Impl (Item).Driver, ALPN, Transport_Parameters, Certificate_DER,
         Crypto_OpenSSL.Ed25519_Private_Key (Private_Key),
         Original_Destination_ID, Internal_ID (Destination),
         Internal_ID (Source), Decoded.Parameters);
   end Initialize_Server;

   procedure Initialize_Server_From_Initial
     (Item            : in out Connection;
      ALPN            : Ada.Streams.Stream_Element_Array;
      Settings        : Transport_Settings;
      Certificate_DER : Ada.Streams.Stream_Element_Array;
      Private_Key     : Ed25519_Private_Key;
      Source          : Connection_ID;
      First_Datagram  : Ada.Streams.Stream_Element_Array;
      Status          : out Server_Initialize_Status)
   is
      Envelope : constant Initial_Packet_Policy.Parse_Result :=
        Initial_Packet_Policy.Parse (First_Datagram);
      Original, Peer : Connection_ID;
   begin
      if Envelope.Status /= Initial_Packet_Policy.Parsed then
         Status := Invalid_Initial;
         return;
      end if;
      Original := Public_ID (Envelope.Header.Destination);
      Peer := Public_ID (Envelope.Header.Source);
      declare
         Encoded : constant Transport_Parameter_Policy.Encode_Result :=
           Encode_Parameters
             (Settings, Transport_Parameter_Policy.Server,
              Initial_Source => Source, Original => Original);
      begin
         if Encoded.Status /= Transport_Parameter_Policy.Encoded then
            Status := Invalid_Transport_Settings;
            return;
         end if;
         Initialize_Server
           (Item, ALPN,
            Encoded.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
            Certificate_DER, Private_Key,
            Original.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Original.Length)),
            Peer, Source);
      end;
      Status := Initialized;
   end Initialize_Server_From_Initial;

   function Public_Status
     (Value : Connection_Driver.Operation_Status) return Operation_Status
   is
     (case Value is
         when Connection_Driver.Succeeded => Succeeded,
         when Connection_Driver.Waiting_For_More => Waiting_For_More,
         when Connection_Driver.Invalid_State => Invalid_State,
         when Connection_Driver.Unsupported_Packet => Unsupported_Packet,
         when Connection_Driver.Packet_Error => Packet_Error,
         when Connection_Driver.TLS_Error => TLS_Error,
         when Connection_Driver.Output_Capacity_Exceeded =>
           Output_Capacity_Exceeded);

   procedure Copy
     (Source : Connection_Driver.Datagram;
      Target : out Datagram) is
   begin
      Target := (others => <>);
      Target.Length := Source.Length;
      if Source.Length > 0 then
         Target.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Source.Length)) :=
             Source.Data
               (1 .. Ada.Streams.Stream_Element_Offset (Source.Length));
      end if;
   end Copy;

   procedure Copy
     (Source : Connection_Driver.Datagram_Batch;
      Target : out Datagram_Batch) is
   begin
      Target := (others => <>);
      Target.Count := Source.Count;
      for Index in 1 .. Source.Count loop
         Copy (Source.Items (Index), Target.Items (Index));
      end loop;
   end Copy;

   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Status : out Operation_Status)
   is
      Internal_Output : Connection_Driver.Datagram_Batch;
      Result          : Connection_Driver.Operation_Result;
   begin
      Connection_Driver.Start_Client
        (Impl (Item).Driver, Internal_Output, Result);
      Copy (Internal_Output, Output);
      Status := Public_Status (Result.Status);
   end Start_Client;

   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Status : out Operation_Status;
      Now    : Timestamp := 0)
   is
      Internal_Output : Connection_Driver.Datagram_Batch;
      Result          : Connection_Driver.Operation_Result;
   begin
      Connection_Driver.Process_Datagram
        (Impl (Item).Driver, Packet, Internal_Output, Result,
         Application_Space.Timestamp (Now));
      Copy (Internal_Output, Output);
      Status := Public_Status (Result.Status);
   end Process_Datagram;

   function Has_Recovery_Timeout (Item : Connection) return Boolean is
     (Item.Backend /= System.Null_Address
      and then Connection_Driver.Has_Recovery_Timeout (Impl (Item).Driver));

   function Recovery_Deadline (Item : Connection) return Timestamp is
     (Timestamp
        (Connection_Driver.Recovery_Deadline (Impl (Item).Driver)));

   procedure Process_Timeout
     (Item   : in out Connection;
      Now    : Timestamp;
      Output : out Datagram_Batch;
      Status : out Timeout_Status)
   is
      Internal_Output : Connection_Driver.Datagram_Batch;
      Internal_Status : Connection_Driver.Timeout_Status;
   begin
      Connection_Driver.Process_Timeout
        (Impl (Item).Driver, Application_Space.Timestamp (Now),
         Internal_Output, Internal_Status);
      Copy (Internal_Output, Output);
      Status :=
        (case Internal_Status is
            when Connection_Driver.Probes_Ready => Probes_Ready,
            when Connection_Driver.Not_Due => Not_Due,
            when Connection_Driver.No_Pending_Recovery =>
              No_Pending_Recovery,
            when Connection_Driver.Timeout_Invalid_State =>
              Invalid_Timeout_State,
            when Connection_Driver.Timeout_Packet_Error =>
              Timeout_Packet_Error,
            when Connection_Driver.Timeout_Output_Capacity_Exceeded =>
              Timeout_Output_Capacity_Exceeded);
   end Process_Timeout;

   procedure Open_Stream
     (Item      : in out Connection;
      Direction : Stream_Direction;
      ID        : out Stream_ID;
      Status    : out Open_Status)
   is
      Internal_Status : Application_Space.Open_Status;
   begin
      Connection_Driver.Open_Stream
        (Impl (Item).Driver,
         (case Direction is
             when Bidirectional => Stream_ID_Policy.Bidirectional,
             when Unidirectional => Stream_ID_Policy.Unidirectional),
         ID, Internal_Status);
      Status :=
        (case Internal_Status is
            when Stream_ID_Policy.Opened => Opened,
            when Stream_ID_Policy.Stream_Limit_Reached =>
              Stream_Limit_Reached,
            when Stream_ID_Policy.Invalid_Stream_Limit =>
              Invalid_Stream_Limit);
   end Open_Stream;

   function Public_Status
     (Value : Application_Space.Send_Status) return Send_Status
   is
     (case Value is
         when Application_Space.Sent => Sent,
         when Application_Space.Nothing_To_ACK => Nothing_To_ACK,
         when Application_Space.Congestion_Blocked => Congestion_Blocked,
         when Application_Space.Recovery_Capacity_Exceeded =>
           Recovery_Capacity_Exceeded,
         when Application_Space.Stream_Not_Sendable => Stream_Not_Sendable,
         when Application_Space.Stream_Capacity_Exceeded =>
           Stream_Capacity_Exceeded,
         when Application_Space.Stream_Flow_Blocked => Stream_Flow_Blocked,
         when Application_Space.Connection_Flow_Blocked =>
           Connection_Flow_Blocked,
         when Application_Space.Stream_Range_Too_Large =>
           Stream_Range_Too_Large,
         when Application_Space.Stream_Final_Size_Mismatch =>
           Stream_Final_Size_Mismatch,
         when Application_Space.Packet_Number_Exhausted =>
           Packet_Number_Exhausted,
         when Application_Space.Packet_Number_Unrepresentable =>
           Packet_Number_Unrepresentable,
         when Application_Space.Insufficient_Protected_Payload =>
           Insufficient_Protected_Payload,
         when Application_Space.Packet_Too_Large => Packet_Too_Large,
         when Application_Space.Output_Too_Small => Output_Too_Small,
         when Application_Space.Internal_State_Error => Internal_State_Error);

   procedure Build_Stream_Datagram
     (Item   : in out Connection;
      ID     : Stream_ID;
      Offset : Stream_Offset;
      Fin    : Boolean;
      Data   : Ada.Streams.Stream_Element_Array;
      Now    : Timestamp;
      Packet : out Datagram;
      Status : out Send_Status)
   is
      Internal_Packet : Connection_Driver.Datagram;
      Internal_Status : Application_Space.Send_Status;
   begin
      Connection_Driver.Build_Stream_Datagram
        (Impl (Item).Driver, ID, Offset, Fin, Data,
         Application_Space.Timestamp (Now), Internal_Packet, Internal_Status);
      Copy (Internal_Packet, Packet);
      Status := Public_Status (Internal_Status);
   end Build_Stream_Datagram;

   procedure Build_Stream_Abort_Datagram
     (Item              : in out Connection;
      ID                : Stream_ID;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Stream_Offset;
      Now               : Timestamp;
      Packet            : out Datagram;
      Status            : out Send_Status)
   is
      Internal_Packet : Connection_Driver.Datagram;
      Internal_Status : Application_Space.Send_Status;
   begin
      Connection_Driver.Build_Stream_Abort_Datagram
        (Impl (Item).Driver, ID, Application_Error, Final_Size,
         Application_Space.Timestamp (Now), Internal_Packet, Internal_Status);
      Copy (Internal_Packet, Packet);
      Status := Public_Status (Internal_Status);
   end Build_Stream_Abort_Datagram;

   procedure Build_ACK_Datagram
     (Item      : in out Connection;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Timestamp;
      Packet    : out Datagram;
      Status    : out Send_Status)
   is
      Internal_Packet : Connection_Driver.Datagram;
      Internal_Status : Application_Space.Send_Status;
   begin
      Connection_Driver.Build_ACK_Datagram
        (Impl (Item).Driver, ACK_Delay, Application_Space.Timestamp (Now),
         Internal_Packet, Internal_Status);
      Copy (Internal_Packet, Packet);
      Status := Public_Status (Internal_Status);
   end Build_ACK_Datagram;

   function Stream_Count (Item : Connection) return Natural is
     (Connection_Driver.Stream_Count (Impl (Item).Driver));

   function Stream_At (Item : Connection; Index : Positive) return Stream_ID is
     (Connection_Driver.Stream_At (Impl (Item).Driver, Index));

   function Has_Stream (Item : Connection; ID : Stream_ID) return Boolean is
     (Connection_Driver.Has_Stream (Impl (Item).Driver, ID));

   function Available_Length
     (Item : Connection; ID : Stream_ID) return Stream_Offset
   is
     (Stream_Offset
        (Connection_Driver.Available_Length (Impl (Item).Driver, ID)));

   function Is_Complete
     (Item : Connection; ID : Stream_ID) return Boolean
   is (Connection_Driver.Is_Complete (Impl (Item).Driver, ID));

   function Was_Reset (Item : Connection; ID : Stream_ID) return Boolean is
     (Connection_Driver.Was_Reset (Impl (Item).Driver, ID));

   function Reset_Error (Item : Connection; ID : Stream_ID) return Stream_ID is
     (Connection_Driver.Reset_Error (Impl (Item).Driver, ID));

   function Element
     (Item   : Connection;
      ID     : Stream_ID;
      Offset : Stream_Offset) return Ada.Streams.Stream_Element
   is
     (Connection_Driver.Stream_Element
        (Impl (Item).Driver, ID, Application_Space.Stream_Index (Offset)));

   procedure Consume
     (Item : in out Connection; ID : Stream_ID; Length : Stream_Offset) is
   begin
      Connection_Driver.Consume
        (Impl (Item).Driver, ID, Application_Space.Stream_Offset (Length));
   end Consume;
end Flyology.QUIC.Connections;
