with Ada.Unchecked_Deallocation;
with Flyology.QUIC.Application_Space;
with Flyology.QUIC.Connection_Driver;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Stream_ID_Policy;
with System.Address_To_Access_Conversions;

package body Flyology.QUIC.Connections is
   use type System.Address;

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

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID) is
   begin
      Ensure_Impl (Item);
      Connection_Driver.Initialize_Client
        (Impl (Item).Driver, ALPN, Transport_Parameters, Pinned_Certificate,
         Original_Destination_ID, Internal_ID (Destination),
         Internal_ID (Source));
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
   begin
      Ensure_Impl (Item);
      Connection_Driver.Initialize_Server
        (Impl (Item).Driver, ALPN, Transport_Parameters, Certificate_DER,
         Crypto_OpenSSL.Ed25519_Private_Key (Private_Key),
         Original_Destination_ID, Internal_ID (Destination),
         Internal_ID (Source));
   end Initialize_Server;

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
