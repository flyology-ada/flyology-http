with Ada.Unchecked_Deallocation;
with Flyology.HTTP.HTTP_3_Connection;
with Flyology.HTTP.HTTP_3_Settings_Policy;
with Flyology.HTTP.QPACK_Field_Section_Policy;
with System.Address_To_Access_Conversions;

package body Flyology.HTTP.HTTP_3 is
   use type System.Address;

   package Internal renames Flyology.HTTP.HTTP_3_Connection;
   package Internal_Fields renames
     Flyology.HTTP.QPACK_Field_Section_Policy;
   package Internal_Settings renames
     Flyology.HTTP.HTTP_3_Settings_Policy;
   use type Internal.Event_Kind;

   type Session_Impl is limited record
      Value      : Internal.Connection;
      Last_Event : Internal.Event;
      Send_Headers : Internal_Fields.Header_Block;
   end record;

   package Impl_Conversions is new System.Address_To_Access_Conversions
     (Session_Impl);

   procedure Release is new Ada.Unchecked_Deallocation
     (Session_Impl, Impl_Conversions.Object_Pointer);

   function Impl (Item : Session) return Impl_Conversions.Object_Pointer is
     (Impl_Conversions.To_Pointer (Item.Backend));

   procedure Ensure_Impl (Item : in out Session) is
   begin
      if Item.Backend = System.Null_Address then
         declare
            Value : constant Impl_Conversions.Object_Pointer :=
              new Session_Impl;
         begin
            Item.Backend := Impl_Conversions.To_Address (Value);
         end;
      end if;
   end Ensure_Impl;

   overriding procedure Finalize (Item : in out Session) is
      Value : Impl_Conversions.Object_Pointer;
   begin
      if Item.Backend /= System.Null_Address then
         Value := Impl (Item);
         Release (Value);
         Item.Backend := System.Null_Address;
      end if;
   end Finalize;

   function Make_Field (Name, Value : String) return Header_Field is
      Result : Header_Field;
   begin
      Result.Name_Size := Name'Length;
      Result.Name (1 .. Name'Length) := Name;
      Result.Value_Size := Value'Length;
      if Value'Length > 0 then
         Result.Value (1 .. Value'Length) := Value;
      end if;
      return Result;
   end Make_Field;

   function Field_Name (Item : Header_Field) return String is
     (Item.Name (1 .. Item.Name_Size));

   function Field_Value (Item : Header_Field) return String is
     (if Item.Value_Size = 0 then ""
      else Item.Value (1 .. Item.Value_Size));

   procedure Append (Item : in out Header_Block; Value : Header_Field) is
   begin
      Item.Count := Item.Count + 1;
      Item.Fields (Item.Count) := Value;
   end Append;

   procedure Clear (Item : in out Header_Block) is
   begin
      Item.Count := 0;
   end Clear;

   function Header_Count (Item : Header_Block) return Natural is
     (Item.Count);

   function Field_At
     (Item : Header_Block; Index : Positive) return Header_Field is
     (Item.Fields (Index));

   function Is_Initialized (Item : Session) return Boolean is
     (Item.Backend /= System.Null_Address);

   function To_Internal
     (Value : Settings) return Internal_Settings.Settings is
     ((QPACK_Table_Capacity => 0,
       QPACK_Blocked        => 0,
       Has_Max_Field_Size   => Value.Has_Max_Field_Size,
       Max_Field_Size       => Value.Max_Field_Size));

   procedure To_Internal_Into
     (Value  : Header_Block;
      Result : in out Internal_Fields.Header_Block)
   is
   begin
      Result.Count := Value.Count;
      for Index in 1 .. Value.Count loop
         Result.Fields (Index) := Internal_Fields.Make_Field
           (Field_Name (Value.Fields (Index)),
            Field_Value (Value.Fields (Index)));
      end loop;
   end To_Internal_Into;

   procedure To_Public_Into
     (Value  : Internal_Fields.Header_Block;
      Result : in out Header_Block)
   is
   begin
      Result.Count := Value.Count;
      for Index in 1 .. Value.Count loop
         Result.Fields (Index) := Make_Field
           (Internal_Fields.Field_Name (Value.Fields (Index)),
            Internal_Fields.Field_Value (Value.Fields (Index)));
      end loop;
   end To_Public_Into;

   function Public_Status
     (Value : Internal.Operation_Status) return Operation_Status
   is
     (case Value is
         when Internal.Succeeded => Succeeded,
         when Internal.No_Event => No_Event,
         when Internal.Not_Connected => Not_Connected,
         when Internal.Not_Started => Not_Started,
         when Internal.Already_Started => Already_Started,
         when Internal.Connection_Draining => Connection_Draining,
         when Internal.Wrong_Role => Wrong_Role,
         when Internal.Stream_Limit_Reached => Stream_Limit_Reached,
         when Internal.Transport_Blocked => Transport_Blocked,
         when Internal.Transport_Error => Transport_Error,
         when Internal.Frame_Too_Large => Frame_Too_Large,
         when Internal.Stream_Capacity_Exceeded => Stream_Capacity_Exceeded,
         when Internal.Stream_Creation_Error => Stream_Creation_Error,
         when Internal.Closed_Critical_Stream => Closed_Critical_Stream,
         when Internal.Missing_Settings => Missing_Settings,
         when Internal.Frame_Unexpected => Frame_Unexpected,
         when Internal.Settings_Error => Settings_Error,
         when Internal.Frame_Error => Frame_Error,
         when Internal.ID_Error => ID_Error,
         when Internal.QPACK_Decompression_Failed =>
           QPACK_Decompression_Failed,
         when Internal.QPACK_Encoder_Stream_Error =>
           QPACK_Encoder_Stream_Error,
         when Internal.QPACK_Decoder_Stream_Error =>
           QPACK_Decoder_Stream_Error,
         when Internal.Peer_Field_Section_Too_Large =>
           Peer_Field_Section_Too_Large,
         when Internal.Message_Error => Message_Error,
         when Internal.Header_Error => Header_Error);

   procedure Initialize
     (Item           : in out Session;
      Role           : Endpoint_Role;
      Local_Settings : Settings := (others => <>)) is
   begin
      Ensure_Impl (Item);
      Internal.Initialize
        (Impl (Item).Value,
         (case Role is
             when Client => Internal.Client,
             when Server => Internal.Server),
         To_Internal (Local_Settings));
   end Initialize;

   procedure Start
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      Packet := (others => <>);
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Start (Impl (Item).Value, Transport, Now, Packet, Result);
      Status := Public_Status (Result);
   end Start;

   function Public_Kind (Value : Internal.Event_Kind) return Event_Kind is
     (case Value is
         when Internal.No_Event => No_Event,
         when Internal.Settings_Received => Settings_Received,
         when Internal.Goaway_Received => Goaway_Received,
         when Internal.Headers_Received => Headers_Received,
         when Internal.Data_Received => Data_Received,
         when Internal.Stream_Reset => Stream_Reset,
         when Internal.Stream_Ended => Stream_Ended);

   procedure Poll
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Output    : out Event;
      Status    : out Operation_Status)
   is
      Internal_Status : Internal.Operation_Status;
   begin
      Output.Kind := No_Event;
      Output.Stream := 0;
      Output.Identifier := 0;
      Output.Headers.Count := 0;
      Output.Data_Length := 0;
      Output.Application_Error := 0;
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Poll
        (Impl (Item).Value, Transport, Impl (Item).Last_Event,
         Internal_Status);
      Status := Public_Status (Internal_Status);
      Output.Kind := Public_Kind (Impl (Item).Last_Event.Kind);
      Output.Stream := Impl (Item).Last_Event.Stream;
      Output.Identifier := Impl (Item).Last_Event.Identifier;
      if Impl (Item).Last_Event.Kind = Internal.Headers_Received then
         To_Public_Into
           (Impl (Item).Last_Event.Headers, Output.Headers);
      end if;
      Output.Data_Length := Impl (Item).Last_Event.Data_Length;
      Output.Application_Error := Impl (Item).Last_Event.Application_Error;
      if Impl (Item).Last_Event.Data_Length > 0 then
         Output.Data
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Impl (Item).Last_Event.Data_Length)) :=
             Impl (Item).Last_Event.Data
               (1 .. Ada.Streams.Stream_Element_Offset
                       (Impl (Item).Last_Event.Data_Length));
      end if;
   end Poll;

   procedure Release_Request
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Release_Request
        (Impl (Item).Value, Transport, Stream, Result);
      Status := Public_Status (Result);
   end Release_Request;

   procedure Open_Request
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : out QUIC.Stream_ID;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      Stream := 0;
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Open_Request (Impl (Item).Value, Transport, Stream, Result);
      Status := Public_Status (Result);
   end Open_Request;

   procedure Cancel_Request
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Reason    : Request_Cancellation_Reason := Cancel_Processing;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
      Error  : constant Application_Error_Code :=
        (case Reason is
            when Reject_Unprocessed => H3_Request_Rejected,
            when Cancel_Processing => H3_Request_Cancelled);
   begin
      Packet := (others => <>);
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Build_Request_Cancellation
        (Impl (Item).Value, Transport, Stream, Error, Now, Packet, Result);
      Status := Public_Status (Result);
   end Cancel_Request;

   procedure Send_Goaway
     (Item       : in out Session;
      Transport  : in out QUIC.Connection;
      Identifier : QUIC.Stream_Offset;
      Now        : QUIC.Timestamp;
      Packet     : out QUIC.Datagram;
      Status     : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      Packet := (others => <>);
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Build_Goaway
        (Impl (Item).Value, Transport, Identifier, Now, Packet, Result);
      Status := Public_Status (Result);
   end Send_Goaway;

   procedure Send_Headers
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : Header_Block;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      Packet := (others => <>);
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      To_Internal_Into (Headers, Impl (Item).Send_Headers);
      Internal.Build_Headers
        (Impl (Item).Value, Transport, Stream, Impl (Item).Send_Headers, Fin,
         Now, Packet, Result);
      Status := Public_Status (Result);
   end Send_Headers;

   procedure Send_Response
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : Header_Block;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status;
      ACK_Included : out Boolean)
   is
      Result : Internal.Operation_Status;
   begin
      Packet := (others => <>);
      ACK_Included := False;
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      To_Internal_Into (Headers, Impl (Item).Send_Headers);
      Internal.Build_Response
        (Impl (Item).Value, Transport, Stream, Impl (Item).Send_Headers, Data,
         Now, Packet, Result, ACK_Included);
      Status := Public_Status (Result);
   end Send_Response;

   procedure Send_Data
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Data      : Ada.Streams.Stream_Element_Array;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Result : Internal.Operation_Status;
   begin
      Packet := (others => <>);
      if not Is_Initialized (Item) then
         Status := Uninitialized;
         return;
      end if;
      Internal.Build_Data
        (Impl (Item).Value, Transport, Stream, Data, Fin, Now, Packet, Result);
      Status := Public_Status (Result);
   end Send_Data;

   function Has_Peer_Settings (Item : Session) return Boolean is
     (Is_Initialized (Item)
      and then Internal.Has_Peer_Settings (Impl (Item).Value));

   function Peer_Settings (Item : Session) return Settings is
      Value : constant Internal_Settings.Settings :=
        Internal.Peer_Settings (Impl (Item).Value);
   begin
      return
        (Has_Max_Field_Size => Value.Has_Max_Field_Size,
         Max_Field_Size     => Value.Max_Field_Size);
   end Peer_Settings;

   function Has_Peer_Goaway (Item : Session) return Boolean is
     (Is_Initialized (Item)
      and then Internal.Has_Peer_Goaway (Impl (Item).Value));

   function Peer_Goaway_ID (Item : Session) return QUIC.Stream_Offset is
     (Internal.Peer_Goaway_ID (Impl (Item).Value));
end Flyology.HTTP.HTTP_3;
