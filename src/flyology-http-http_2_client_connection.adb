with Ada.Unchecked_Deallocation;
with Flyology.HTTP.HTTP_2_Frames;
with Flyology.HTTP.HTTP_2_HPACK;
with Flyology.HTTP.HTTP_2_Payloads;
with Flyology.HTTP.HTTP_2_Policy;
with Flyology.HTTP.HTTP_2_Settings;
with Flyology.Wake_Sources;
with Interfaces;

package body Flyology.HTTP.HTTP_2_Client_Connection is
   use Ada.Streams;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Flyology.IO.Descriptor;
   package Bytes renames Flyology.Bytes;
   package Drivers renames Flyology.IO.Connections.Drivers;
   package Frames renames Flyology.HTTP.HTTP_2_Frames;
   package HPACK renames Flyology.HTTP.HTTP_2_HPACK;
   package Payloads renames Flyology.HTTP.HTTP_2_Payloads;
   package Policy renames Flyology.HTTP.HTTP_2_Policy;
   package Settings renames Flyology.HTTP.HTTP_2_Settings;
   use type Frames.Header_Validity;
   use type Payloads.Fragment_Result;
   use type Settings.Apply_Result;

   Client_Preface : constant String := "PRI * HTTP/2.0" &
     Character'Val (13) & Character'Val (10) &
     Character'Val (13) & Character'Val (10) &
     "SM" & Character'Val (13) & Character'Val (10) &
     Character'Val (13) & Character'Val (10);
   Maximum_Header_Block : constant Positive := 64 * 1_024;
   Maximum_Buffered_Data : constant Positive := 65_535;
   Maximum_Control_Backlog : constant Positive := 32 * 1_024;
   Window_Update_Threshold : constant Positive := 8 * 1_024;

   type Request_Buffer_Access is access Bytes.Unbounded_Bytes;
   procedure Free_Request_Buffer is new Ada.Unchecked_Deallocation
     (Bytes.Unbounded_Bytes, Request_Buffer_Access);

   Response_Buffer_Capacity : constant Positive :=
     Positive (Settings.Advertised_Initial_Window_Size);
   Request_Stream_Buffer_Capacity : constant Positive :=
     Positive (Settings.Advertised_Initial_Window_Size);
   type Response_Storage is array (Positive range 1 ..
     Response_Buffer_Capacity) of Stream_Element;
   type Request_Stream_Storage is array (Positive range 1 ..
     Request_Stream_Buffer_Capacity) of Stream_Element;

   type Stream_Phase is (Free, Open, Complete, Failed);
   type Failure_Kind is
     (No_Failure, Connection_Failure, Refused_Failure,
      Goaway_Unprocessed_Failure, Response_Protocol_Failure,
      Other_Stream_Failure);
   type Publish_Result is
     (Publish_Accepted, Publish_Stream_Rejected,
      Publish_Connection_Rejected);

   type Stream_Record is limited record
      Phase          : Stream_Phase := Free;
      ID             : Frames.Stream_Identifier := 0;
      Head_Request   : Boolean := False;
      Head_Available : Boolean := False;
      Head_Delivered : Boolean := False;
      Status         : Status_Code := 200;
      Fields         : Flyology.HTTP.Headers.List;
      Trailers       : Flyology.HTTP.Headers.List;
      Response_Buffer : Response_Storage;
      Response_First  : Positive := 1;
      Response_Count  : Natural range 0 .. Response_Buffer_Capacity := 0;
      Remote_End     : Boolean := False;
      Body_Forbidden : Boolean := False;
      Has_Expected_Length : Boolean := False;
      Expected_Length : Long_Long_Integer := 0;
      Received_Length : Long_Long_Integer := 0;
      Response_Observed : Boolean := False;
      Failure        : Failure_Kind := No_Failure;
      Request_Head   : Bytes.Unbounded_Bytes;
      Head_Cursor    : Natural := 1;
      Request_Body   : Request_Buffer_Access := null;
      Body_Send_Cursor : Natural := 1;
      Streaming_Body : Boolean := False;
      Upload_Buffer  : Request_Stream_Storage;
      Upload_First   : Positive := 1;
      Upload_Count   : Natural range 0 .. Request_Stream_Buffer_Capacity := 0;
      Upload_Finished : Boolean := False;
      Request_Trailers : Bytes.Unbounded_Bytes;
      Trailer_Cursor : Natural := 1;
      Local_End      : Boolean := False;
      Send_Window    : Policy.Window_Size := 65_535;
      Receive_Window : Policy.Window_Size :=
        Policy.Window_Size (Settings.Advertised_Initial_Window_Size);
      Pending_Receive_Credit : Natural := 0;
      Wake           : Flyology.Wake_Sources.Source;
      Wake_Signalled : Boolean := False;
   end record;

   type Stream_Array is
     array (Positive range 1 .. Maximum_Concurrent_Streams) of Stream_Record;

   type Closed_Stream_Record is record
      ID        : Frames.Stream_Identifier := 0;
      Head_Seen : Boolean := False;
   end record;
   Maximum_Remembered_Closed_Streams : constant Positive := 256;
   type Closed_Stream_Array is
     array (Positive range 1 .. Maximum_Remembered_Closed_Streams)
       of Closed_Stream_Record;

   type Window_Update_Result is
     (Window_Accepted,
      Window_Stream_Rejected,
      Window_Connection_Protocol_Error,
      Window_Connection_Flow_Control_Error);

   protected type Controller is
      procedure Open
        (Header_Block  : Stream_Element_Array;
         Retained_Body : in out Request_Buffer_Access;
         Streaming     : Boolean;
         Head_Request  : Boolean;
         Handle        : out Stream_Handle;
         Accepted      : out Boolean);
      procedure Write_Request_Data
        (Handle        : Stream_Handle;
         Data          : Stream_Element_Array;
         Finished      : Boolean;
         Trailer_Block : Stream_Element_Array;
         Result        : out Upload_Result;
         Wake_Pump     : out Boolean);
      procedure Pull_Output
        (Data      : out Stream_Element_Array;
         Last      : out Stream_Element_Offset;
         Available : out Boolean);
      procedure Apply_Peer_Settings
        (Value  : Settings.State;
         Result : out Boolean);
      procedure Queue_Settings_Ack;
      procedure Queue_Ping_Ack (Payload : Stream_Element_Array);
      procedure Queue_Goaway (Error : Frames.Error_Code);
      procedure Publish_Headers
        (Stream_ID  : Frames.Stream_Identifier;
         Fields     : Flyology.HTTP.Headers.List;
         Status     : Status_Code;
         Has_Status : Boolean;
         End_Stream : Boolean;
         Result     : out Publish_Result);
      procedure Publish_Data
        (Stream_ID  : Frames.Stream_Identifier;
         Payload    : Stream_Element_Array;
         Flow_Length : Natural;
         End_Stream : Boolean;
         Result     : out Publish_Result);
      procedure Reject_Stream (Index : Positive);
      procedure Observe_Stream (Stream_ID : Frames.Stream_Identifier);
      function Has_Response_Observation
        (Handle : Stream_Handle) return Boolean;
      procedure Window_Update
        (Stream_ID : Frames.Stream_Identifier;
         Increment : Natural;
         Result    : out Window_Update_Result);
      procedure Reset_Stream
        (Stream_ID : Frames.Stream_Identifier;
         Error     : Frames.Error_Code);
      procedure Receive_Goaway
        (Last_Stream : Frames.Stream_Identifier);
      procedure Fail_All;
      function Is_Usable return Boolean;
      function Can_Open return Boolean;
      function Control_Backlogged return Boolean;
      function Is_Trailers
        (Stream_ID : Frames.Stream_Identifier) return Boolean;
      procedure Poll_Head
        (Handle   : Stream_Handle;
         Result   : out Head_Result;
         Status   : out Status_Code;
         Fields   : in out Flyology.HTTP.Headers.List;
         Finished : out Boolean);
      procedure Read
        (Handle   : Stream_Handle;
         Data     : out Stream_Element_Array;
         Last     : out Stream_Element_Offset;
         Finished : out Boolean;
         Result   : out Body_Result;
         Trailers : in out Flyology.HTTP.Headers.List;
         Wake_Pump : out Boolean);
      procedure Wait_Source
        (Handle    : Stream_Handle;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean);
      procedure Upload_Wait_Source
        (Handle    : Stream_Handle;
         Required  : Natural;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean);
      procedure Cancel_Stream
        (Handle : Stream_Handle; Wake_Pump : out Boolean);
      procedure Release_Stream
        (Handle : Stream_Handle; Wake_Pump : out Boolean);
      procedure Try_Claim_Pump
        (Handle : Stream_Handle; Claimed : out Boolean);
      function Owns_Pump (Handle : Stream_Handle) return Boolean;
      procedure Release_Pump (Handle : Stream_Handle);
      procedure Pump_Wait_Source
        (Handle    : Stream_Handle;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean);
   private
      Streams          : Stream_Array;
      Next_Stream_ID   : Frames.Stream_Identifier := 1;
      Peer             : Settings.State;
      Connection_Send_Window : Policy.Window_Size := 65_535;
      Connection_Receive_Window : Policy.Window_Size := 65_535;
      Pending_Connection_Credit : Natural := 0;
      Buffered_Data    : Natural := 0;
      Preface_Pending  : Boolean := True;
      Settings_Pending : Boolean := True;
      Control_Output   : Bytes.Unbounded_Bytes;
      Control_Cursor   : Natural := 1;
      Output_Cursor    : Positive := 1;
      Continuation_Slot : Natural := 0;
      Closed_Streams   : Closed_Stream_Array;
      Closed_Cursor    : Positive := Closed_Streams'First;
      Draining         : Boolean := False;
      Broken           : Boolean := False;
      Pump_Owner       : Natural := 0;
   end Controller;

   subtype Pump_Output_Index is Stream_Element_Offset range
     1 .. Stream_Element_Offset
       (Frames.Default_Maximum_Frame_Size + Frames.Frame_Header_Size);
   subtype Pump_Input_Index is Stream_Element_Offset range
     1 .. Stream_Element_Offset
       (2 * (Frames.Default_Maximum_Frame_Size + Frames.Frame_Header_Size));

   type Owner_Pump_Driver is limited record
      Output              : Stream_Element_Array (Pump_Output_Index) :=
        (others => 0);
      Output_Last         : Stream_Element_Offset :=
        Pump_Output_Index'First - 1;
      Output_Cursor       : Stream_Element_Offset :=
        Pump_Output_Index'First;
      Have_Output         : Boolean := False;
      Input               : Stream_Element_Array (Pump_Input_Index) :=
        (others => 0);
      Input_Head          : Natural := 0;
      Input_Count         : Natural := 0;
      Decoder             : HPACK.Decoder;
      Peer_Settings       : Settings.State;
      Header_Block        : Bytes.Unbounded_Bytes;
      Header_Stream       : Frames.Stream_Identifier := 0;
      Header_End_Stream   : Boolean := False;
      Expect_Continuation : Boolean := False;
      Peer_Preface_Seen   : Boolean := False;
      Broken              : Boolean := False;
      Closing             : Boolean := False;
   end record;

   type Session_State is limited record
      Streams  : Controller;
      Outbound : aliased Drivers.Outbound_Wakeup;
      Driver   : Owner_Pump_Driver;
   end record;

   procedure Append_Frame
     (Target    : in out Bytes.Unbounded_Bytes;
      Kind      : Frames.Frame_Code;
      Flags     : Frames.Frame_Flags;
      Stream_ID : Frames.Stream_Identifier;
      Payload   : Stream_Element_Array)
   is
      Header : constant Frames.Wire_Header := Frames.Encode
        ((Length => Payload'Length,
          Kind => Kind,
          Flags => Flags,
          Stream_ID => Stream_ID));
   begin
      Bytes.Append (Target, Header);
      Bytes.Append (Target, Payload);
   end Append_Frame;

   function U31_Payload (Value : Natural) return Stream_Element_Array is
      Number : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value);
   begin
      return
        (1 => Stream_Element (Interfaces.Shift_Right (Number, 24) and 16#7F#),
         2 => Stream_Element (Interfaces.Shift_Right (Number, 16) and 16#FF#),
         3 => Stream_Element (Interfaces.Shift_Right (Number, 8) and 16#FF#),
         4 => Stream_Element (Number and 16#FF#));
   end U31_Payload;

   procedure Parse_Content_Length
     (Fields  : Flyology.HTTP.Headers.List;
      Present : out Boolean;
      Value   : out Long_Long_Integer;
      Valid   : out Boolean)
   is
      Count : constant Natural :=
        Flyology.HTTP.Headers.Count (Fields, "content-length");
   begin
      Present := Count > 0;
      Value := 0;
      Valid := Count <= 1;
      if not Present or else not Valid then
         return;
      end if;
      declare
         Text : constant String :=
           Flyology.HTTP.Headers.Value (Fields, "content-length");
      begin
         if Text'Length = 0 then
            Valid := False;
            return;
         end if;
         for Character_Value of Text loop
            if Character_Value not in '0' .. '9'
              or else Value >
                (Long_Long_Integer'Last -
                   Long_Long_Integer
                     (Character'Pos (Character_Value) - Character'Pos ('0'))) /
                  10
            then
               Valid := False;
               return;
            end if;
            Value := Value * 10 + Long_Long_Integer
              (Character'Pos (Character_Value) - Character'Pos ('0'));
         end loop;
      end;
   end Parse_Content_Length;

   protected body Controller is
      function Valid (Handle : Stream_Handle) return Boolean is
        (Handle.Slot in Streams'Range
           and then Streams (Handle.Slot).Phase /= Free
           and then Natural (Streams (Handle.Slot).ID) = Handle.ID);

      procedure Notify (Index : Positive) is
      begin
         if not Streams (Index).Wake_Signalled then
            Flyology.Wake_Sources.Signal (Streams (Index).Wake);
            Streams (Index).Wake_Signalled := True;
         end if;
      end Notify;

      function Ready (Index : Positive) return Boolean is
        ((Streams (Index).Head_Available
            and then not Streams (Index).Head_Delivered)
           or else Streams (Index).Response_Count > 0
           or else Streams (Index).Remote_End
           or else Streams (Index).Failure /= No_Failure
           or else
             (Streams (Index).Streaming_Body
                and then not Streams (Index).Upload_Finished
                and then Streams (Index).Upload_Count <
                  Request_Stream_Buffer_Capacity));

      procedure Remember_Closed (Index : Positive) is
      begin
         if Streams (Index).ID /= 0 then
            Closed_Streams (Closed_Cursor) :=
              (ID        => Streams (Index).ID,
               Head_Seen => Streams (Index).Head_Available);
            Closed_Cursor := Closed_Cursor mod Closed_Streams'Length + 1;
         end if;
      end Remember_Closed;

      function Closed_Head_Seen
        (Stream_ID : Frames.Stream_Identifier) return Boolean
      is
      begin
         for Item of Closed_Streams loop
            if Item.ID = Stream_ID then
               return Item.Head_Seen;
            end if;
         end loop;
         return False;
      end Closed_Head_Seen;

      function Is_Closed
        (Stream_ID : Frames.Stream_Identifier) return Boolean
      is
      begin
         if Stream_ID = 0 then
            return False;
         end if;
         for Item of Closed_Streams loop
            if Item.ID = Stream_ID then
               return True;
            end if;
         end loop;
         return Natural (Stream_ID) mod 2 = 1
           and then Stream_ID < Next_Stream_ID;
      end Is_Closed;

      procedure Queue_Control_Frame
        (Kind      : Frames.Frame_Code;
         Flags     : Frames.Frame_Flags;
         Stream_ID : Frames.Stream_Identifier;
         Payload   : Stream_Element_Array)
      is
      begin
         if Control_Cursor > 1 then
            declare
               Replacement : Bytes.Unbounded_Bytes;
               Remaining : constant Natural :=
                 (if Control_Cursor <= Bytes.Length (Control_Output)
                  then Bytes.Length (Control_Output) - Control_Cursor + 1
                  else 0);
            begin
               Bytes.Reserve_Capacity (Replacement, Remaining);
               if Remaining > 0 then
                  for Index in Control_Cursor .. Bytes.Length (Control_Output)
                  loop
                     Bytes.Append
                       (Replacement, Bytes.Element (Control_Output, Index));
                  end loop;
               end if;
               Bytes.Move (Control_Output, Replacement);
               Control_Cursor := 1;
            end;
         end if;
         Append_Frame
           (Control_Output, Kind, Flags, Stream_ID, Payload);
      end Queue_Control_Frame;

      procedure Flush_Connection_Credit (Force : Boolean := False) is
      begin
         if Pending_Connection_Credit > 0
           and then
             (Force
                or else Pending_Connection_Credit >= Window_Update_Threshold)
         then
            Connection_Receive_Window := Connection_Receive_Window +
              Policy.Window_Size (Pending_Connection_Credit);
            Queue_Control_Frame
              (Frames.Window_Update_Frame, 0, 0,
               U31_Payload (Pending_Connection_Credit));
            Pending_Connection_Credit := 0;
         end if;
      end Flush_Connection_Credit;

      procedure Return_Connection_Credit
        (Count : Natural; Force : Boolean := False) is
      begin
         if Count > 0 then
            Pending_Connection_Credit :=
              Pending_Connection_Credit + Count;
            Flush_Connection_Credit (Force);
         end if;
      end Return_Connection_Credit;

      procedure Return_Stream_Credit
        (Index : Positive; Count : Natural; Force : Boolean := False) is
      begin
         if Count > 0 then
            Streams (Index).Pending_Receive_Credit :=
              Streams (Index).Pending_Receive_Credit + Count;
            if Force
              or else Streams (Index).Pending_Receive_Credit >=
                Window_Update_Threshold
            then
               Streams (Index).Receive_Window :=
                 Streams (Index).Receive_Window + Policy.Window_Size
                   (Streams (Index).Pending_Receive_Credit);
               Queue_Control_Frame
                 (Frames.Window_Update_Frame, 0,
                  Streams (Index).ID,
                  U31_Payload (Streams (Index).Pending_Receive_Credit));
               Streams (Index).Pending_Receive_Credit := 0;
            end if;
         end if;
      end Return_Stream_Credit;

      procedure Abandon_Local_Half (Index : Positive) is
      begin
         if not Streams (Index).Local_End then
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0,
               Streams (Index).ID,
               U31_Payload (Natural (Frames.Cancel)));
            Streams (Index).Local_End := True;
            if Continuation_Slot = Index then
               Continuation_Slot := 0;
            end if;
            Bytes.Clear (Streams (Index).Request_Head);
            Streams (Index).Head_Cursor := 1;
            if Streams (Index).Request_Body /= null then
               Free_Request_Buffer (Streams (Index).Request_Body);
            end if;
            Streams (Index).Body_Send_Cursor := 1;
         end if;
      end Abandon_Local_Half;

      procedure Clear_Stream (Index : Positive) is
      begin
         Remember_Closed (Index);
         if Continuation_Slot = Index then
            Continuation_Slot := 0;
         end if;
         Streams (Index).Phase := Free;
         Streams (Index).ID := 0;
         Streams (Index).Head_Request := False;
         Streams (Index).Head_Available := False;
         Streams (Index).Head_Delivered := False;
         Streams (Index).Status := 200;
         Flyology.HTTP.Headers.Clear (Streams (Index).Fields);
         Flyology.HTTP.Headers.Clear (Streams (Index).Trailers);
         Streams (Index).Response_First := 1;
         Streams (Index).Response_Count := 0;
         Streams (Index).Remote_End := False;
         Streams (Index).Body_Forbidden := False;
         Streams (Index).Has_Expected_Length := False;
         Streams (Index).Expected_Length := 0;
         Streams (Index).Received_Length := 0;
         Streams (Index).Response_Observed := False;
         Streams (Index).Failure := No_Failure;
         Bytes.Clear (Streams (Index).Request_Head);
         Streams (Index).Head_Cursor := 1;
         if Streams (Index).Request_Body /= null then
            Free_Request_Buffer (Streams (Index).Request_Body);
         end if;
         Streams (Index).Body_Send_Cursor := 1;
         Streams (Index).Streaming_Body := False;
         Streams (Index).Upload_First := 1;
         Streams (Index).Upload_Count := 0;
         Streams (Index).Upload_Finished := False;
         Bytes.Clear (Streams (Index).Request_Trailers);
         Streams (Index).Trailer_Cursor := 1;
         Streams (Index).Local_End := False;
         Streams (Index).Send_Window :=
           Policy.Window_Size (Peer.Initial_Window_Size);
         Streams (Index).Receive_Window := Policy.Window_Size
           (Settings.Advertised_Initial_Window_Size);
         Streams (Index).Pending_Receive_Credit := 0;
         if Flyology.Wake_Sources.Descriptor (Streams (Index).Wake) >= 0 then
            Flyology.Wake_Sources.Release (Streams (Index).Wake);
         end if;
         Streams (Index).Wake_Signalled := False;
      end Clear_Stream;

      procedure Open
        (Header_Block  : Stream_Element_Array;
         Retained_Body : in out Request_Buffer_Access;
         Streaming     : Boolean;
         Head_Request  : Boolean;
         Handle        : out Stream_Handle;
         Accepted      : out Boolean)
      is
         Active : Natural := 0;
         Index  : Natural := 0;
      begin
         Handle := No_Stream;
         Accepted := False;
         if Broken or else Draining or else Next_Stream_ID > 16#7FFF_FFFD# then
            return;
         end if;
         for Position in Streams'Range loop
            if Streams (Position).Phase = Free then
               if Index = 0 then
                  Index := Position;
               end if;
            else
               Active := Active + Boolean'Pos
                 (Streams (Position).Phase /= Free);
            end if;
         end loop;
         if Index = 0
           or else Interfaces.Unsigned_32 (Active) >= Peer.Maximum_Streams
         then
            return;
         end if;
         Flyology.Wake_Sources.Ensure (Streams (Index).Wake);
         Streams (Index).Phase := Open;
         Streams (Index).ID := Next_Stream_ID;
         Streams (Index).Head_Request := Head_Request;
         Streams (Index).Request_Head :=
           Bytes.To_Unbounded_Bytes (Header_Block);
         Streams (Index).Request_Body := Retained_Body;
         Retained_Body := null;
         Streams (Index).Streaming_Body := Streaming;
         Streams (Index).Upload_First := 1;
         Streams (Index).Upload_Count := 0;
         Streams (Index).Upload_Finished := False;
         Bytes.Clear (Streams (Index).Request_Trailers);
         Streams (Index).Trailer_Cursor := 1;
         Streams (Index).Send_Window :=
           Policy.Window_Size (Peer.Initial_Window_Size);
         Handle := (Slot => Index, ID => Natural (Next_Stream_ID));
         Next_Stream_ID := Next_Stream_ID + 2;
         Accepted := True;
      end Open;

      procedure Write_Request_Data
        (Handle        : Stream_Handle;
         Data          : Stream_Element_Array;
         Finished      : Boolean;
         Trailer_Block : Stream_Element_Array;
         Result        : out Upload_Result;
         Wake_Pump     : out Boolean)
      is
      begin
         Wake_Pump := False;
         if not Valid (Handle) then
            Result := Upload_Failed;
            return;
         end if;
         declare
            Item : Stream_Record renames Streams (Handle.Slot);
         begin
            if Item.Phase /= Open or else Item.Failure /= No_Failure
              or else not Item.Streaming_Body
              or else Item.Upload_Finished
            then
               Result := Upload_Failed;
            elsif Data'Length >
              Request_Stream_Buffer_Capacity - Item.Upload_Count
            then
               Result := Upload_Would_Block;
            else
               if Data'Length > 0 then
                  for Offset in 0 .. Natural (Data'Length) - 1 loop
                     Item.Upload_Buffer
                       (((Item.Upload_First - 1 + Item.Upload_Count + Offset)
                          mod Request_Stream_Buffer_Capacity) + 1) :=
                       Data (Data'First + Stream_Element_Offset (Offset));
                  end loop;
                  Item.Upload_Count := Item.Upload_Count + Data'Length;
               end if;
               if Finished then
                  Item.Upload_Finished := True;
                  Item.Request_Trailers :=
                    Bytes.To_Unbounded_Bytes (Trailer_Block);
                  Item.Trailer_Cursor := 1;
               end if;
               Result := Upload_Accepted;
               Wake_Pump := True;
            end if;
         end;
      end Write_Request_Data;

      procedure Copy_Bytes
        (Value  : Bytes.Unbounded_Bytes;
         Cursor : in out Natural;
         Data   : out Stream_Element_Array;
         Last   : out Stream_Element_Offset)
      is
         Count : constant Natural := Natural'Min
           (Data'Length, Bytes.Length (Value) - Cursor + 1);
      begin
         Last := Data'First - 1;
         if Count > 0 then
            for Offset in 0 .. Count - 1 loop
               Data (Data'First + Stream_Element_Offset (Offset)) :=
                 Bytes.Element (Value, Cursor + Offset);
               Last := Data'First + Stream_Element_Offset (Offset);
            end loop;
         end if;
         Cursor := Cursor + Count;
      end Copy_Bytes;

      procedure Pull_Output
        (Data      : out Stream_Element_Array;
         Last      : out Stream_Element_Offset;
         Available : out Boolean)
      is
         Empty_Payload : Stream_Element_Array (1 .. 0);
         Required_Header_Slot : Natural := Continuation_Slot;
      begin
         Last := Data'First - 1;
         Available := False;
         if Preface_Pending then
            declare
               Value : constant Stream_Element_Array :=
                 Bytes.To_Array (Bytes.From_Byte_String (Client_Preface));
               Cursor : Natural := 1;
            begin
               Copy_Bytes
                 (Bytes.To_Unbounded_Bytes (Value), Cursor, Data, Last);
            end;
            Preface_Pending := False;
            Available := True;
            return;
         elsif Settings_Pending then
            declare
               Payload : constant Stream_Element_Array :=
                 Settings.Initial_Payload;
               Header  : constant Frames.Wire_Header := Frames.Encode
                 ((Length => Payload'Length,
                   Kind => Frames.Settings_Frame,
                   Flags => 0,
                   Stream_ID => 0));
               Cursor : Stream_Element_Offset := Data'First;
            begin
               for Value of Header loop
                  Data (Cursor) := Value;
                  Cursor := Cursor + 1;
               end loop;
               for Value of Payload loop
                  Data (Cursor) := Value;
                  Cursor := Cursor + 1;
               end loop;
               Last := Cursor - 1;
            end;
            Settings_Pending := False;
            Available := True;
            return;
         elsif Continuation_Slot = 0
           and then Control_Cursor <= Bytes.Length (Control_Output)
         then
            Copy_Bytes (Control_Output, Control_Cursor, Data, Last);
            if Control_Cursor > Bytes.Length (Control_Output) then
               Bytes.Clear (Control_Output);
               Control_Cursor := 1;
            end if;
            Available := True;
            return;
         end if;

         --  A peer treats receipt of stream N as implicitly closing every
         --  lower, still-idle client stream. Concurrent callers can occupy
         --  stream-table slots in a different order from their allocated
         --  identifiers, so start new field sections by stream ID rather than
         --  by the round-robin slot cursor.
         if Required_Header_Slot = 0 then
            for Index in Streams'Range loop
               if Streams (Index).Phase = Open
                 and then Streams (Index).Head_Cursor = 1
                 and then Bytes.Length (Streams (Index).Request_Head) > 0
                 and then
                   (Required_Header_Slot = 0
                      or else Streams (Index).ID <
                        Streams (Required_Header_Slot).ID)
               then
                  Required_Header_Slot := Index;
               end if;
            end loop;
         end if;

         for Attempt in 1 ..
           (if Required_Header_Slot = 0 then Streams'Length else 1)
         loop
            declare
               Index : constant Positive :=
                 (if Required_Header_Slot /= 0
                  then Positive (Required_Header_Slot)
                  else ((Output_Cursor + Attempt - 2) mod Streams'Length) + 1);
               Item : Stream_Record renames Streams (Index);
            begin
               if Item.Phase = Open
                 and then Item.Head_Cursor > Bytes.Length (Item.Request_Head)
                 and then Item.Streaming_Body
                 and then Item.Upload_Finished
                 and then Item.Upload_Count = 0
                 and then Item.Trailer_Cursor <=
                   Bytes.Length (Item.Request_Trailers)
               then
                  declare
                     Remaining : constant Natural :=
                       Bytes.Length (Item.Request_Trailers) -
                         Item.Trailer_Cursor + 1;
                     Count : constant Natural := Natural'Min
                       (Remaining, Frames.Default_Maximum_Frame_Size);
                     First_Fragment : constant Boolean :=
                       Item.Trailer_Cursor = 1;
                     Final_Fragment : constant Boolean := Count = Remaining;
                     Flags : constant Frames.Frame_Flags :=
                       (if Final_Fragment
                        then Frames.End_Headers_Flag or Frames.End_Stream_Flag
                        else 0);
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => Count,
                         Kind => (if First_Fragment then Frames.Headers_Frame
                                  else Frames.Continuation_Frame),
                         Flags => Flags,
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Bytes.Element
                          (Item.Request_Trailers,
                           Item.Trailer_Cursor + Offset);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Trailer_Cursor := Item.Trailer_Cursor + Count;
                     if Final_Fragment then
                        Continuation_Slot := 0;
                        Item.Local_End := True;
                        Bytes.Clear (Item.Request_Trailers);
                     else
                        Continuation_Slot := Index;
                     end if;
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               elsif Item.Phase = Open
                 and then Item.Head_Cursor <= Bytes.Length (Item.Request_Head)
               then
                  declare
                     Remaining : constant Natural :=
                       Bytes.Length (Item.Request_Head) - Item.Head_Cursor + 1;
                     Count : constant Natural := Natural'Min
                       (Remaining, Frames.Default_Maximum_Frame_Size);
                     First_Fragment : constant Boolean := Item.Head_Cursor = 1;
                     Final_Fragment : constant Boolean := Count = Remaining;
                     Flags : Frames.Frame_Flags :=
                       (if Final_Fragment then Frames.End_Headers_Flag else 0);
                     Header : Frames.Wire_Header;
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     if Final_Fragment
                       and then Item.Request_Body = null
                       and then not Item.Streaming_Body
                     then
                        Flags := Flags or Frames.End_Stream_Flag;
                        Item.Local_End := True;
                     end if;
                     Header := Frames.Encode
                       ((Length => Count,
                         Kind => (if First_Fragment then Frames.Headers_Frame
                                  else Frames.Continuation_Frame),
                         Flags => Flags,
                         Stream_ID => Item.ID));
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Bytes.Element
                          (Item.Request_Head, Item.Head_Cursor + Offset);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Head_Cursor := Item.Head_Cursor + Count;
                     if Final_Fragment then
                        Continuation_Slot := 0;
                     else
                        Continuation_Slot := Index;
                     end if;
                     Last := Cursor - 1;
                     Available := True;
                     if Final_Fragment then
                        Output_Cursor := Index mod Streams'Length + 1;
                     end if;
                     return;
                  end;
               elsif Item.Phase = Open
                 and then Item.Head_Cursor > Bytes.Length (Item.Request_Head)
                 and then Item.Request_Body /= null
                 and then Item.Body_Send_Cursor <=
                   Bytes.Length (Item.Request_Body.all)
                 and then Connection_Send_Window > 0
                 and then Item.Send_Window > 0
               then
                  declare
                     Remaining : constant Natural :=
                       Bytes.Length (Item.Request_Body.all) -
                         Item.Body_Send_Cursor + 1;
                     Count : constant Natural := Natural'Min
                       (Natural'Min
                          (Remaining, Frames.Default_Maximum_Frame_Size),
                        Natural'Min
                          (Natural (Connection_Send_Window),
                           Natural (Item.Send_Window)));
                     Final_Fragment : constant Boolean := Count = Remaining;
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => Count,
                         Kind => Frames.Data_Frame,
                         Flags => (if Final_Fragment
                                   then Frames.End_Stream_Flag else 0),
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Bytes.Element
                          (Item.Request_Body.all,
                           Item.Body_Send_Cursor + Offset);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Body_Send_Cursor := Item.Body_Send_Cursor + Count;
                     Connection_Send_Window := Connection_Send_Window -
                       Policy.Window_Size (Count);
                     Item.Send_Window := Item.Send_Window -
                       Policy.Window_Size (Count);
                     if Final_Fragment then
                        Item.Local_End := True;
                        Free_Request_Buffer (Item.Request_Body);
                     end if;
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               elsif Item.Phase = Open
                 and then Item.Head_Cursor > Bytes.Length (Item.Request_Head)
                 and then Item.Streaming_Body
                 and then Item.Upload_Count > 0
                 and then Connection_Send_Window > 0
                 and then Item.Send_Window > 0
               then
                  declare
                     Count : constant Natural := Natural'Min
                       (Natural'Min
                          (Item.Upload_Count,
                           Frames.Default_Maximum_Frame_Size),
                        Natural'Min
                          (Natural (Connection_Send_Window),
                           Natural (Item.Send_Window)));
                     Final_Fragment : constant Boolean :=
                       Count = Item.Upload_Count
                         and then Item.Upload_Finished
                         and then
                           Bytes.Length (Item.Request_Trailers) = 0;
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => Count,
                         Kind => Frames.Data_Frame,
                         Flags => (if Final_Fragment
                                   then Frames.End_Stream_Flag else 0),
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Item.Upload_Buffer
                          (((Item.Upload_First - 1 + Offset) mod
                             Request_Stream_Buffer_Capacity) + 1);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Upload_First :=
                       ((Item.Upload_First - 1 + Count) mod
                          Request_Stream_Buffer_Capacity) + 1;
                     Item.Upload_Count := Item.Upload_Count - Count;
                     Connection_Send_Window := Connection_Send_Window -
                       Policy.Window_Size (Count);
                     Item.Send_Window := Item.Send_Window -
                       Policy.Window_Size (Count);
                     if Final_Fragment then
                        Item.Local_End := True;
                     end if;
                     Notify (Index);
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               elsif Item.Phase = Open
                 and then Item.Head_Cursor > Bytes.Length (Item.Request_Head)
                 and then Item.Streaming_Body
                 and then Item.Upload_Finished
                 and then Item.Upload_Count = 0
                 and then Bytes.Length (Item.Request_Trailers) = 0
                 and then not Item.Local_End
               then
                  declare
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => 0,
                         Kind => Frames.Data_Frame,
                         Flags => Frames.End_Stream_Flag,
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Local_End := True;
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               end if;
            end;
         end loop;
         pragma Unreferenced (Empty_Payload);
      end Pull_Output;

      procedure Apply_Peer_Settings
        (Value  : Settings.State;
         Result : out Boolean)
      is
         Change : constant Policy.Window_Size :=
           Policy.Window_Size (Value.Initial_Window_Size) -
             Policy.Window_Size (Peer.Initial_Window_Size);
      begin
         Result := True;
         for Item of Streams loop
            if Item.Phase /= Free then
               declare
                  Adjusted : constant Policy.Window_Result :=
                    Policy.Adjust_Initial_Window (Item.Send_Window, Change);
               begin
                  if not Adjusted.Accepted then
                     Result := False;
                     return;
                  end if;
                  Item.Send_Window := Adjusted.Window;
               end;
            end if;
         end loop;
         Peer := Value;
      end Apply_Peer_Settings;

      procedure Queue_Settings_Ack is
         Empty : Stream_Element_Array (1 .. 0);
      begin
         Queue_Control_Frame
           (Frames.Settings_Frame, Frames.Ack_Flag, 0, Empty);
      end Queue_Settings_Ack;

      procedure Queue_Ping_Ack (Payload : Stream_Element_Array) is
      begin
         Queue_Control_Frame
           (Frames.Ping_Frame, Frames.Ack_Flag, 0, Payload);
      end Queue_Ping_Ack;

      procedure Queue_Goaway (Error : Frames.Error_Code) is
         Payload : Stream_Element_Array (1 .. 8);
         Last_Stream : constant Stream_Element_Array := U31_Payload (0);
         Error_Value : constant Stream_Element_Array :=
           U31_Payload (Natural (Error));
      begin
         Payload (1 .. 4) := Last_Stream;
         Payload (5 .. 8) := Error_Value;
         Queue_Control_Frame
           (Frames.Goaway_Frame, 0, 0, Payload);
         Draining := True;
      end Queue_Goaway;

      function Find
        (Stream_ID : Frames.Stream_Identifier) return Natural is
      begin
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free
              and then Streams (Index).ID = Stream_ID
            then
               return Index;
            end if;
         end loop;
         return 0;
      end Find;

      procedure Reject_Stream (Index : Positive) is
      begin
         if Streams (Index).Phase in Free | Failed then
            return;
         end if;
         --  A response framing error is a stream error even when the request
         --  half has already ended. Local_End only describes the request
         --  direction, so it cannot suppress the required RST_STREAM.
         Queue_Control_Frame
           (Frames.Reset_Stream_Frame, 0, Streams (Index).ID,
            U31_Payload (Natural (Frames.Protocol_Error_Code)));
         Streams (Index).Local_End := True;
         Streams (Index).Failure := Response_Protocol_Failure;
         Streams (Index).Phase := Failed;
         Notify (Index);
      end Reject_Stream;

      procedure Observe_Stream (Stream_ID : Frames.Stream_Identifier) is
         Index : constant Natural := Find (Stream_ID);
      begin
         if Index /= 0 then
            Streams (Index).Response_Observed := True;
         end if;
      end Observe_Stream;

      function Has_Response_Observation
        (Handle : Stream_Handle) return Boolean is
        (Valid (Handle)
           and then Streams (Handle.Slot).Response_Observed);

      procedure Publish_Headers
        (Stream_ID  : Frames.Stream_Identifier;
         Fields     : Flyology.HTTP.Headers.List;
         Status     : Status_Code;
         Has_Status : Boolean;
         End_Stream : Boolean;
         Result     : out Publish_Result)
      is
         Index : constant Natural := Find (Stream_ID);
         Length_Accepted : Boolean;
      begin
         Result :=
           (if Index /= 0 or else Is_Closed (Stream_ID)
            then Publish_Accepted else Publish_Connection_Rejected);
         if Index = 0 then
            return;
         else
            Streams (Index).Response_Observed := True;
         end if;
         if Streams (Index).Remote_End then
            Result := Publish_Stream_Rejected;
            Reject_Stream (Positive (Index));
            return;
         elsif Has_Status then
            if Streams (Index).Head_Available then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            elsif Natural (Status) in 100 .. 199 then
               if Status = 101 or else End_Stream then
                  Result := Publish_Stream_Rejected;
                  Reject_Stream (Positive (Index));
               end if;
               return;
            end if;
            Streams (Index).Status := Status;
            Streams (Index).Fields := Fields;
            Streams (Index).Head_Available := True;
            Streams (Index).Body_Forbidden :=
              Streams (Index).Head_Request
                or else Status in 204 | 205 | 304;
            Parse_Content_Length
              (Fields,
               Streams (Index).Has_Expected_Length,
               Streams (Index).Expected_Length,
               Length_Accepted);
            if not Length_Accepted
              or else
                (Status = 204
                   and then Streams (Index).Has_Expected_Length)
            then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            end if;
         else
            if not Streams (Index).Head_Available then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            elsif not End_Stream then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            end if;
            Streams (Index).Trailers := Fields;
         end if;
         if End_Stream then
            if Streams (Index).Has_Expected_Length
              and then not Streams (Index).Body_Forbidden
              and then Streams (Index).Received_Length /=
                Streams (Index).Expected_Length
            then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            end if;
            Abandon_Local_Half (Positive (Index));
            Streams (Index).Remote_End := True;
            Streams (Index).Phase := Complete;
         end if;
         Notify (Positive (Index));
      end Publish_Headers;

      procedure Publish_Data
        (Stream_ID  : Frames.Stream_Identifier;
         Payload    : Stream_Element_Array;
         Flow_Length : Natural;
         End_Stream : Boolean;
         Result     : out Publish_Result)
      is
         Index : constant Natural := Find (Stream_ID);
         Connection_Result : Policy.Window_Result;
         Stream_Result : Policy.Window_Result;
      begin
         Result :=
           (if Index /= 0 or else Is_Closed (Stream_ID)
            then Publish_Accepted else Publish_Connection_Rejected);
         if Index = 0 then
            if Result = Publish_Accepted then
               Connection_Result := Policy.Consume
                 (Connection_Receive_Window,
                  Policy.Data_Length (Flow_Length));
               if not Connection_Result.Accepted then
                  Result := Publish_Connection_Rejected;
                  return;
               end if;
               Connection_Receive_Window := Connection_Result.Window;
               Return_Connection_Credit (Flow_Length);
            end if;
            return;
         end if;

         Streams (Index).Response_Observed := True;

         Connection_Result := Policy.Consume
           (Connection_Receive_Window, Policy.Data_Length (Flow_Length));
         if not Connection_Result.Accepted then
            Result := Publish_Connection_Rejected;
            return;
         end if;
         Connection_Receive_Window := Connection_Result.Window;
         Stream_Result := Policy.Consume
           (Streams (Index).Receive_Window,
            Policy.Data_Length (Flow_Length));
         if not Stream_Result.Accepted then
            Return_Connection_Credit (Flow_Length);
            Result := Publish_Stream_Rejected;
            Reject_Stream (Positive (Index));
            return;
         end if;
         Streams (Index).Receive_Window := Stream_Result.Window;

         if not Streams (Index).Head_Available
           or else Streams (Index).Remote_End
           or else
             (Streams (Index).Body_Forbidden and then Payload'Length > 0)
           or else Buffered_Data + Payload'Length > Maximum_Buffered_Data
           or else Streams (Index).Response_Count + Payload'Length >
             Response_Buffer_Capacity
         then
            Return_Connection_Credit (Flow_Length);
            Result := Publish_Stream_Rejected;
            Reject_Stream (Positive (Index));
            return;
         end if;
         Streams (Index).Received_Length :=
           Streams (Index).Received_Length + Payload'Length;
         if Streams (Index).Has_Expected_Length
           and then Streams (Index).Received_Length >
             Streams (Index).Expected_Length
         then
            Streams (Index).Received_Length :=
              Streams (Index).Received_Length - Payload'Length;
            Return_Connection_Credit (Flow_Length);
            Result := Publish_Stream_Rejected;
            Reject_Stream (Positive (Index));
            return;
         end if;
         if Payload'Length > 0 then
            for Offset in 0 .. Payload'Length - 1 loop
               declare
                  Position : constant Positive :=
                    ((Streams (Index).Response_First - 1 +
                        Streams (Index).Response_Count + Offset)
                       mod Response_Buffer_Capacity) + 1;
               begin
                  Streams (Index).Response_Buffer (Position) :=
                    Payload
                      (Payload'First + Stream_Element_Offset (Offset));
               end;
            end loop;
            Streams (Index).Response_Count :=
              Streams (Index).Response_Count + Payload'Length;
         end if;
         Buffered_Data := Buffered_Data + Payload'Length;
         if Flow_Length > Payload'Length then
            declare
               Padding : constant Natural := Flow_Length - Payload'Length;
            begin
               Return_Connection_Credit (Padding);
               Return_Stream_Credit (Positive (Index), Padding);
            end;
         end if;
         if End_Stream then
            if Streams (Index).Has_Expected_Length
              and then not Streams (Index).Body_Forbidden
              and then Streams (Index).Received_Length /=
                Streams (Index).Expected_Length
            then
               Result := Publish_Stream_Rejected;
               Reject_Stream (Positive (Index));
               return;
            end if;
            Abandon_Local_Half (Positive (Index));
            Streams (Index).Remote_End := True;
            Streams (Index).Phase := Complete;
         end if;
         Notify (Positive (Index));
      end Publish_Data;

      procedure Window_Update
        (Stream_ID : Frames.Stream_Identifier;
         Increment : Natural;
         Result    : out Window_Update_Result)
      is
         procedure Reject
           (Index : Positive; Error : Frames.Error_Code) is
         begin
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Streams (Index).ID,
               U31_Payload (Natural (Error)));
            Streams (Index).Failure := Other_Stream_Failure;
            Streams (Index).Phase := Failed;
            Notify (Index);
         end Reject;
      begin
         Result := Window_Accepted;
         if Increment = 0 then
            if Stream_ID = 0 then
               Result := Window_Connection_Protocol_Error;
            else
               declare
                  Index : constant Natural := Find (Stream_ID);
               begin
                  if Index /= 0 then
                     Reject
                       (Positive (Index), Frames.Protocol_Error_Code);
                     Result := Window_Stream_Rejected;
                  end if;
               end;
            end if;
            return;
         elsif Stream_ID = 0 then
            declare
               Updated : constant Policy.Window_Result := Policy.Increase
                 (Connection_Send_Window, Policy.Window_Increment (Increment));
            begin
               if Updated.Accepted then
                  Connection_Send_Window := Updated.Window;
               else
                  Result := Window_Connection_Flow_Control_Error;
               end if;
            end;
         else
            declare
               Index : constant Natural := Find (Stream_ID);
            begin
               if Index = 0 then
                  return;
               end if;
               declare
                  Updated : constant Policy.Window_Result := Policy.Increase
                    (Streams (Index).Send_Window,
                     Policy.Window_Increment (Increment));
               begin
                  if Updated.Accepted then
                     Streams (Index).Send_Window := Updated.Window;
                  else
                     Reject
                       (Positive (Index), Frames.Flow_Control_Error);
                     Result := Window_Stream_Rejected;
                  end if;
               end;
            end;
         end if;
      exception
         when Constraint_Error =>
            Result :=
              (if Stream_ID = 0
               then Window_Connection_Flow_Control_Error
               else Window_Stream_Rejected);
      end Window_Update;

      procedure Reset_Stream
        (Stream_ID : Frames.Stream_Identifier;
         Error     : Frames.Error_Code)
      is
         Index : constant Natural := Find (Stream_ID);
      begin
         if Index = 0 then
            return;
         end if;
         Streams (Index).Response_Observed := True;
         Streams (Index).Failure :=
           (if Error = Frames.Refused_Stream
              and then not Streams (Index).Head_Available
            then Refused_Failure
            else Other_Stream_Failure);
         Streams (Index).Phase := Failed;
         Notify (Positive (Index));
      end Reset_Stream;

      procedure Receive_Goaway
        (Last_Stream : Frames.Stream_Identifier) is
      begin
         Draining := True;
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free
              and then Streams (Index).ID > Last_Stream
              and then not Streams (Index).Head_Available
            then
               Streams (Index).Failure := Goaway_Unprocessed_Failure;
               Streams (Index).Phase := Failed;
               Notify (Index);
            end if;
         end loop;
      end Receive_Goaway;

      procedure Fail_All is
      begin
         Broken := True;
         Draining := True;
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free
              and then not Streams (Index).Remote_End
              and then Streams (Index).Failure = No_Failure
            then
               Streams (Index).Failure := Connection_Failure;
               Streams (Index).Phase := Failed;
               Notify (Index);
            end if;
         end loop;
      end Fail_All;

      function Is_Usable return Boolean is
        (not Broken and then not Draining
           and then Next_Stream_ID <= 16#7FFF_FFFD#);

      function Can_Open return Boolean is
         Active   : Natural := 0;
         Has_Free : Boolean := False;
      begin
         if not Is_Usable then
            return False;
         end if;
         for Item of Streams loop
            if Item.Phase = Free then
               Has_Free := True;
            else
               Active := Active + 1;
            end if;
         end loop;
         return Has_Free
           and then Interfaces.Unsigned_32 (Active) < Peer.Maximum_Streams;
      end Can_Open;

      function Control_Backlogged return Boolean is
        (Control_Cursor <= Bytes.Length (Control_Output)
           and then Bytes.Length (Control_Output) - Control_Cursor + 1 >=
             Maximum_Control_Backlog);

      function Is_Trailers
        (Stream_ID : Frames.Stream_Identifier) return Boolean
      is
         Index : constant Natural := Find (Stream_ID);
      begin
         return
           (if Index /= 0 then Streams (Index).Head_Available
            else Closed_Head_Seen (Stream_ID));
      end Is_Trailers;

      procedure Poll_Head
        (Handle   : Stream_Handle;
         Result   : out Head_Result;
         Status   : out Status_Code;
         Fields   : in out Flyology.HTTP.Headers.List;
         Finished : out Boolean) is
      begin
         Status := 200;
         Flyology.HTTP.Headers.Clear (Fields);
         Finished := False;
         if not Valid (Handle) then
            Result := Head_Connection_Failed;
            return;
         end if;
         declare
            Item : Stream_Record renames Streams (Handle.Slot);
         begin
            if Item.Head_Available then
               Status := Item.Status;
               Fields := Item.Fields;
               Item.Head_Delivered := True;
               Finished := Item.Remote_End
                 and then
                   Item.Response_Count = 0;
               Result := Head_Ready;
               return;
            end if;
            case Item.Failure is
               when Connection_Failure | Other_Stream_Failure =>
                  Result := Head_Connection_Failed;
               when Response_Protocol_Failure =>
                  Result := Head_Protocol_Failed;
               when Refused_Failure =>
                  Result := Head_Refused;
               when Goaway_Unprocessed_Failure =>
                  Result := Head_Goaway_Unprocessed;
               when No_Failure =>
                  Result := Head_Would_Block;
            end case;
         end;
      end Poll_Head;

      procedure Read
        (Handle   : Stream_Handle;
         Data     : out Stream_Element_Array;
         Last     : out Stream_Element_Offset;
         Finished : out Boolean;
         Result   : out Body_Result;
         Trailers : in out Flyology.HTTP.Headers.List;
         Wake_Pump : out Boolean)
      is
         Count : Natural := 0;
      begin
         Last := Data'First - 1;
         Finished := False;
         Wake_Pump := False;
         Flyology.HTTP.Headers.Clear (Trailers);
         if not Valid (Handle) then
            Result := Body_Connection_Failed;
            return;
         end if;
         declare
            Item : Stream_Record renames Streams (Handle.Slot);
         begin
            if Item.Failure = Connection_Failure then
               Result := Body_Connection_Failed;
               return;
            elsif Item.Failure = Response_Protocol_Failure then
               Result := Body_Protocol_Failed;
               return;
            elsif Item.Failure /= No_Failure then
               Result := Body_Stream_Failed;
               return;
            elsif Item.Response_Count > 0 then
               Count := Natural'Min
                 (Data'Length, Item.Response_Count);
               if Count > 0 then
                  for Offset in 0 .. Count - 1 loop
                     Data (Data'First + Stream_Element_Offset (Offset)) :=
                       Item.Response_Buffer
                         (((Item.Response_First - 1 + Offset)
                            mod Response_Buffer_Capacity) + 1);
                  end loop;
                  Last := Data'First + Stream_Element_Offset (Count) - 1;
               end if;
               if Count = 0 then
                  Result := Body_Progress;
                  return;
               end if;
               Item.Response_First :=
                 ((Item.Response_First - 1 + Count)
                    mod Response_Buffer_Capacity) + 1;
               Item.Response_Count := Item.Response_Count - Count;
               Buffered_Data := Buffered_Data - Count;
               Finished := Item.Remote_End
                 and then Item.Response_Count = 0;
               Return_Connection_Credit (Count, Force => Finished);
               Return_Stream_Credit
                 (Handle.Slot, Count, Force => Finished);
               Wake_Pump := Pending_Connection_Credit = 0
                 or else Item.Pending_Receive_Credit = 0;
               if Finished then
                  Trailers := Item.Trailers;
               end if;
               Result := Body_Progress;
            elsif Item.Remote_End then
               Finished := True;
               Trailers := Item.Trailers;
               Result := Body_Finished;
            else
               Result := Body_Would_Block;
            end if;
         end;
      end Read;

      procedure Wait_Source
        (Handle    : Stream_Handle;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean) is
      begin
         if not Valid (Handle) then
            FD := Flyology.IO.Invalid_Descriptor;
            Ready_Now := True;
            return;
         end if;
         Ready_Now := Ready (Handle.Slot);
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Flyology.Wake_Sources.Ensure (Streams (Handle.Slot).Wake);
            FD := Flyology.Wake_Sources.Descriptor
              (Streams (Handle.Slot).Wake);
         end if;
      end Wait_Source;

      procedure Upload_Wait_Source
        (Handle    : Stream_Handle;
         Required  : Natural;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean) is
      begin
         if not Valid (Handle) then
            FD := Flyology.IO.Invalid_Descriptor;
            Ready_Now := True;
            return;
         end if;
         Ready_Now := Streams (Handle.Slot).Failure /= No_Failure
           or else Streams (Handle.Slot).Remote_End
           or else Required <= Request_Stream_Buffer_Capacity -
             Streams (Handle.Slot).Upload_Count;
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Flyology.Wake_Sources.Ensure (Streams (Handle.Slot).Wake);
            FD := Flyology.Wake_Sources.Descriptor
              (Streams (Handle.Slot).Wake);
         end if;
      end Upload_Wait_Source;

      procedure Cancel_Stream
        (Handle : Stream_Handle; Wake_Pump : out Boolean) is
      begin
         Wake_Pump := False;
         if Valid (Handle) then
            --  A stream whose request field section has not entered the pump
            --  is still idle at the peer. Sending RST_STREAM for that stream
            --  would itself be a connection-level protocol error. Once any
            --  header bytes have been pulled, continuation ordering ensures
            --  the reset follows the complete field section on the wire.
            if Streams (Handle.Slot).Head_Cursor > 1 then
               Queue_Control_Frame
                 (Frames.Reset_Stream_Frame, 0,
                  Streams (Handle.Slot).ID,
                  U31_Payload (Natural (Frames.Cancel)));
               Wake_Pump := True;
            end if;
            Streams (Handle.Slot).Remote_End := True;
            Streams (Handle.Slot).Phase := Complete;
            if Pump_Owner = Handle.ID then
               Pump_Owner := 0;
               for Index in Streams'Range loop
                  if Streams (Index).Phase /= Free
                    and then Index /= Handle.Slot
                  then
                     Notify (Index);
                  end if;
               end loop;
            end if;
         end if;
      end Cancel_Stream;

      procedure Release_Stream
        (Handle : Stream_Handle; Wake_Pump : out Boolean)
      is
         Unread : Natural := 0;
      begin
         Wake_Pump := False;
         if Valid (Handle) then
            if Pump_Owner = Handle.ID then
               Pump_Owner := 0;
               for Index in Streams'Range loop
                  if Streams (Index).Phase /= Free
                    and then Index /= Handle.Slot
                  then
                     Notify (Index);
                  end if;
               end loop;
            end if;
            if Streams (Handle.Slot).Response_Count > 0 then
               Unread := Streams (Handle.Slot).Response_Count;
               Buffered_Data := Buffered_Data - Unread;
               Return_Connection_Credit (Unread, Force => True);
               Wake_Pump := True;
            end if;
            Clear_Stream (Handle.Slot);
         end if;
      end Release_Stream;

      procedure Try_Claim_Pump
        (Handle : Stream_Handle; Claimed : out Boolean) is
      begin
         Claimed := Valid (Handle)
           and then (Pump_Owner = 0 or else Pump_Owner = Handle.ID);
         if Claimed then
            Pump_Owner := Handle.ID;
         end if;
      end Try_Claim_Pump;

      function Owns_Pump (Handle : Stream_Handle) return Boolean is
        (Valid (Handle) and then Pump_Owner = Handle.ID);

      procedure Release_Pump (Handle : Stream_Handle) is
      begin
         if Pump_Owner = Handle.ID then
            Pump_Owner := 0;
            for Index in Streams'Range loop
               if Streams (Index).Phase /= Free then
                  Notify (Index);
               end if;
            end loop;
         end if;
      end Release_Pump;

      procedure Pump_Wait_Source
        (Handle    : Stream_Handle;
         FD        : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean) is
      begin
         if not Valid (Handle) then
            FD := Flyology.IO.Invalid_Descriptor;
            Ready_Now := True;
            return;
         end if;
         Ready_Now := Pump_Owner = 0
           or else Pump_Owner = Handle.ID
           or else Streams (Handle.Slot).Failure /= No_Failure;
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Flyology.Wake_Sources.Ensure (Streams (Handle.Slot).Wake);
            FD := Flyology.Wake_Sources.Descriptor
              (Streams (Handle.Slot).Wake);
         end if;
      end Pump_Wait_Source;
   end Controller;

   procedure Drive_Owner_Pump
     (State : in out Session_State;
      IO    : in out Drivers.Capability;
      Step  : out Pump_Step)
   is
      Stop : exception;

      procedure Protocol_Failure
        (Error : Frames.Error_Code := Frames.Protocol_Error_Code) is
      begin
         if not State.Driver.Closing then
            State.Streams.Queue_Goaway (Error);
            State.Streams.Fail_All;
            State.Driver.Closing := True;
         end if;
         raise Stop;
      end Protocol_Failure;

      procedure Process_Header_Block is
         Fields     : Flyology.HTTP.Headers.List;
         Status     : Status_Code := 200;
         Has_Status : Boolean := False;
         Publication : Publish_Result;
         Trailers   : constant Boolean :=
           State.Streams.Is_Trailers (State.Driver.Header_Stream);
      begin
         State.Streams.Observe_Stream (State.Driver.Header_Stream);
         HPACK.Decode_Response
           (State.Driver.Decoder,
            Bytes.To_Array (State.Driver.Header_Block), Trailers,
            Fields, Status, Has_Status);
         State.Streams.Publish_Headers
           (State.Driver.Header_Stream, Fields, Status, Has_Status,
            State.Driver.Header_End_Stream, Publication);
         Bytes.Clear (State.Driver.Header_Block);
         State.Driver.Header_Stream := 0;
         State.Driver.Header_End_Stream := False;
         State.Driver.Expect_Continuation := False;
         if Publication = Publish_Connection_Rejected then
            Protocol_Failure;
         end if;
      exception
         when HPACK.Header_List_Too_Large | Protocol_Error |
              Constraint_Error =>
            Protocol_Failure;
      end Process_Header_Block;

      procedure Process_Frame
        (Header  : Frames.Header;
         Payload : Stream_Element_Array)
      is
         Accepted : Boolean;
         Publication : Publish_Result;
         Window_Result : Window_Update_Result;
      begin
         if not State.Driver.Peer_Preface_Seen then
            if Header.Kind /= Frames.Settings_Frame
              or else (Header.Flags and Frames.Ack_Flag) /= 0
            then
               Protocol_Failure;
            end if;
            State.Driver.Peer_Preface_Seen := True;
         end if;
         if State.Driver.Expect_Continuation
           and then
             (Header.Kind /= Frames.Continuation_Frame
                or else Header.Stream_ID /= State.Driver.Header_Stream)
         then
            Protocol_Failure;
         elsif Header.Kind = Frames.Settings_Frame then
            if (Header.Flags and Frames.Ack_Flag) = 0 then
               declare
                  Applied : Settings.Apply_Result;
               begin
                  Settings.Apply
                    (State.Driver.Peer_Settings, Payload, Applied);
                  if Applied /= Settings.Settings_Accepted then
                     Protocol_Failure;
                  end if;
                  State.Streams.Apply_Peer_Settings
                    (State.Driver.Peer_Settings, Accepted);
                  if not Accepted then
                     Protocol_Failure;
                  end if;
                  State.Streams.Queue_Settings_Ack;
               end;
            end if;
         elsif Header.Kind = Frames.Ping_Frame then
            if (Header.Flags and Frames.Ack_Flag) = 0 then
               State.Streams.Queue_Ping_Ack (Payload);
            end if;
         elsif Header.Kind = Frames.Headers_Frame then
            declare
               View   : Payloads.Fragment_View;
               Result : Payloads.Fragment_Result;
            begin
               Payloads.Header_Fragment
                 (Header.Stream_ID, Header.Flags, Payload, View, Result);
               if Result /= Payloads.Valid_Fragment then
                  Protocol_Failure;
               end if;
               State.Driver.Header_Stream := Header.Stream_ID;
               State.Driver.Header_End_Stream :=
                 (Header.Flags and Frames.End_Stream_Flag) /= 0;
               if not View.Empty then
                  Bytes.Append
                    (State.Driver.Header_Block,
                     Payload (View.First .. View.Last));
               end if;
               if Bytes.Length (State.Driver.Header_Block) >
                 Maximum_Header_Block
               then
                  Protocol_Failure;
               elsif (Header.Flags and Frames.End_Headers_Flag) /= 0 then
                  Process_Header_Block;
               else
                  State.Driver.Expect_Continuation := True;
               end if;
            end;
         elsif Header.Kind = Frames.Continuation_Frame then
            if not State.Driver.Expect_Continuation then
               Protocol_Failure;
            end if;
            Bytes.Append (State.Driver.Header_Block, Payload);
            if Bytes.Length (State.Driver.Header_Block) >
              Maximum_Header_Block
            then
               Protocol_Failure;
            elsif (Header.Flags and Frames.End_Headers_Flag) /= 0 then
               Process_Header_Block;
            end if;
         elsif Header.Kind = Frames.Data_Frame then
            declare
               View   : Payloads.Fragment_View;
               Result : Payloads.Fragment_Result;
               Empty  : Stream_Element_Array (1 .. 0);
            begin
               State.Streams.Observe_Stream (Header.Stream_ID);
               Payloads.Data_Fragment
                 (Header.Flags, Payload, View, Result);
               if Result /= Payloads.Valid_Fragment then
                  Protocol_Failure;
               elsif View.Empty then
                  State.Streams.Publish_Data
                    (Header.Stream_ID, Empty, Payload'Length,
                     (Header.Flags and Frames.End_Stream_Flag) /= 0,
                     Publication);
               else
                  State.Streams.Publish_Data
                    (Header.Stream_ID, Payload (View.First .. View.Last),
                     Payload'Length,
                     (Header.Flags and Frames.End_Stream_Flag) /= 0,
                     Publication);
               end if;
               if Publication = Publish_Connection_Rejected then
                  Protocol_Failure;
               end if;
            end;
         elsif Header.Kind = Frames.Window_Update_Frame then
            State.Streams.Window_Update
              (Header.Stream_ID, Payloads.Window_Increment (Payload),
               Window_Result);
            case Window_Result is
               when Window_Accepted | Window_Stream_Rejected => null;
               when Window_Connection_Protocol_Error =>
                  Protocol_Failure (Frames.Protocol_Error_Code);
               when Window_Connection_Flow_Control_Error =>
                  Protocol_Failure (Frames.Flow_Control_Error);
            end case;
         elsif Header.Kind = Frames.Reset_Stream_Frame then
            State.Streams.Reset_Stream
              (Header.Stream_ID, Payloads.Unsigned_32 (Payload));
         elsif Header.Kind = Frames.Goaway_Frame then
            State.Streams.Receive_Goaway
              (Payloads.Stream_ID (Payload));
         elsif Header.Kind = Frames.Push_Promise_Frame then
            Protocol_Failure;
         end if;
      end Process_Frame;

      procedure Parse_One (Progress : out Boolean) is
         procedure Consume_Input (Count : Natural) is
         begin
            State.Driver.Input_Head := State.Driver.Input_Head + Count;
            State.Driver.Input_Count := State.Driver.Input_Count - Count;
            if State.Driver.Input_Count = 0 then
               State.Driver.Input_Head := 0;
            end if;
         end Consume_Input;
      begin
         Progress := False;
         if State.Driver.Input_Count < Frames.Frame_Header_Size then
            return;
         end if;
         declare
            Wire : Frames.Wire_Header;
         begin
            for Index in Wire'Range loop
               Wire (Index) := State.Driver.Input
                 (State.Driver.Input'First
                    + Stream_Element_Offset (State.Driver.Input_Head)
                    + Index - Wire'First);
            end loop;
            declare
               Header : constant Frames.Header := Frames.Decode (Wire);
               Total  : constant Natural :=
                 Frames.Frame_Header_Size + Header.Length;
               Validity : constant Frames.Header_Validity :=
                 Frames.Validate (Header);
            begin
               if Validity /= Frames.Valid_Header then
                  --  For a malformed frame that fits the bounded input
                  --  buffer, wait for and consume its declared payload.
                  --  Closing a Linux socket while those bytes remain
                  --  unread can replace the queued GOAWAY with TCP RST.
                  if Total <= State.Driver.Input'Length
                    and then State.Driver.Input_Count < Total
                  then
                     return;
                  elsif State.Driver.Input_Count >= Total then
                     Consume_Input (Total);
                  end if;
                  Protocol_Failure
                    ((if Validity in
                         Frames.Frame_Too_Large | Frames.Invalid_Length
                      then Frames.Frame_Size_Error
                      else Frames.Protocol_Error_Code));
               elsif State.Driver.Input_Count < Total then
                  return;
               end if;
               declare
                  Payload : Stream_Element_Array
                    (1 .. Stream_Element_Offset (Header.Length));
               begin
                  if Header.Length > 0 then
                     for Offset in 0 .. Header.Length - 1 loop
                        Payload
                          (Payload'First + Stream_Element_Offset (Offset)) :=
                          State.Driver.Input
                            (State.Driver.Input'First
                               + Stream_Element_Offset
                                 (State.Driver.Input_Head)
                               + Stream_Element_Offset
                                 (Frames.Frame_Header_Size + Offset));
                     end loop;
                  end if;
                  Process_Frame (Header, Payload);
               end;
               Consume_Input (Total);
               Progress := True;
            end;
         end;
      end Parse_One;

      procedure Compact_Input is
      begin
         if State.Driver.Input_Head > 0
           and then State.Driver.Input_Count > 0
         then
            for Offset in 0 .. State.Driver.Input_Count - 1 loop
               State.Driver.Input
                 (State.Driver.Input'First
                    + Stream_Element_Offset (Offset)) :=
                 State.Driver.Input
                   (State.Driver.Input'First
                      + Stream_Element_Offset
                        (State.Driver.Input_Head + Offset));
            end loop;
            State.Driver.Input_Head := 0;
         elsif State.Driver.Input_Count = 0 then
            State.Driver.Input_Head := 0;
         end if;
      end Compact_Input;

      Last       : Stream_Element_Offset;
      IO_Result  : Drivers.Step_Result;
      Parsed     : Boolean;
      Backlogged : Boolean;
      First      : Stream_Element_Offset;
   begin
      Step := (others => <>);
      if State.Driver.Broken then
         Step.Result := Pump_Protocol_Failed;
         return;
      end if;

      Backlogged := State.Streams.Control_Backlogged;
      if not Backlogged and then not State.Driver.Closing then
         Parse_One (Parsed);
         if Parsed then
            Step.Result := Pump_Progress;
            return;
         end if;
      end if;

      if not State.Driver.Have_Output then
         State.Streams.Pull_Output
           (State.Driver.Output, State.Driver.Output_Last,
            State.Driver.Have_Output);
         State.Driver.Output_Cursor := State.Driver.Output'First;
      end if;
      if State.Driver.Have_Output then
         Drivers.Send
           (IO,
            State.Driver.Output
              (State.Driver.Output_Cursor .. State.Driver.Output_Last),
            Last, IO_Result);
         case IO_Result is
            when Drivers.Made_Progress =>
               if Last >= State.Driver.Output_Cursor then
                  State.Driver.Output_Cursor := Last + 1;
                  Step.Sent_Bytes := True;
               end if;
               if State.Driver.Output_Cursor > State.Driver.Output_Last then
                  State.Driver.Have_Output := False;
               end if;
               Step.Result := Pump_Progress;
            when Drivers.Need_Read =>
               Step.Result := Pump_Need_Read;
            when Drivers.Need_Write =>
               Step.Result := Pump_Need_Write;
            when Drivers.Peer_Closed =>
               Step.Result := Pump_Peer_Closed;
         end case;
         Step.Outbound_Pending := State.Driver.Have_Output;
         return;
      end if;

      if State.Driver.Closing then
         State.Driver.Broken := True;
         Step.Result := Pump_Protocol_Failed;
         return;
      end if;

      if State.Driver.Input_Head + State.Driver.Input_Count =
        State.Driver.Input'Length
        and then State.Driver.Input_Head > 0
      then
         Compact_Input;
      end if;
      if State.Driver.Input_Head + State.Driver.Input_Count >=
        State.Driver.Input'Length
      then
         Protocol_Failure;
      end if;
      First := State.Driver.Input'First
        + Stream_Element_Offset
          (State.Driver.Input_Head + State.Driver.Input_Count);
      Drivers.Receive
        (IO, State.Driver.Input (First .. State.Driver.Input'Last),
         Last, IO_Result);
      case IO_Result is
         when Drivers.Made_Progress =>
            if Last >= First then
               State.Driver.Input_Count := State.Driver.Input_Count
                 + Natural (Last - First + 1);
               Step.Received_Bytes := True;
            end if;
            Step.Result := Pump_Progress;
         when Drivers.Need_Read =>
            Step.Result := Pump_Need_Read;
         when Drivers.Need_Write =>
            Step.Result := Pump_Need_Write;
         when Drivers.Peer_Closed =>
            Step.Result := Pump_Peer_Closed;
      end case;
   exception
      when Stop =>
         Step :=
           (Result => Pump_Progress,
            Outbound_Pending => True,
            others => False);
      when others =>
         State.Driver.Broken := True;
         State.Streams.Fail_All;
         Step := (Result => Pump_Protocol_Failed, others => False);
   end Drive_Owner_Pump;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Session_State, Session_State_Access);
   procedure Free_Session is new Ada.Unchecked_Deallocation
     (Session, Session_Access);

   procedure Create (Item : out Session_Access) is
   begin
      Item := new Session;
      Item.State := new Session_State;
   exception
      when others =>
         if Item /= null then
            if Item.State /= null then
               Free_State (Item.State);
            end if;
            Free_Session (Item);
         end if;
         raise;
   end Create;

   procedure Destroy (Item : in out Session_Access) is
   begin
      if Item = null then
         return;
      end if;
      Free_State (Item.State);
      Free_Session (Item);
   end Destroy;

   procedure Try_Claim_Pump
     (Item    : in out Session;
      Handle  : Stream_Handle;
      Claimed : out Boolean) is
   begin
      Item.State.Streams.Try_Claim_Pump (Handle, Claimed);
   end Try_Claim_Pump;

   function Owns_Pump
     (Item : Session; Handle : Stream_Handle) return Boolean is
     (Item.State /= null and then Item.State.Streams.Owns_Pump (Handle));

   procedure Release_Pump
     (Item : in out Session; Handle : Stream_Handle) is
   begin
      Item.State.Streams.Release_Pump (Handle);
   end Release_Pump;

   procedure Pump_Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean) is
   begin
      Item.State.Streams.Pump_Wait_Source (Handle, FD, Ready_Now);
   end Pump_Wait_Source;

   function Has_Response_Observation
     (Item : Session; Handle : Stream_Handle) return Boolean is
     (Item.State /= null
        and then Item.State.Streams.Has_Response_Observation (Handle));

   procedure Drive_Pump
     (Item   : in out Session;
      Handle : Stream_Handle;
      IO     : in out Drivers.Capability;
      Step   : out Pump_Step) is
   begin
      if not Owns_Pump (Item, Handle) then
         raise Program_Error with
           "HTTP/2 stream does not own the session pump";
      end if;
      Drive_Owner_Pump (Item.State.all, IO, Step);
   end Drive_Pump;

   function Outbound
     (Item : aliased in out Session)
      return not null access Drivers.Outbound_Wakeup is
     (Item.State.Outbound'Access);

   function Is_Usable (Item : Session) return Boolean is
     (Item.State /= null and then Item.State.Streams.Is_Usable);

   function Can_Open (Item : Session) return Boolean is
     (Item.State /= null and then Item.State.Streams.Can_Open);

   function Identifier (Handle : Stream_Handle) return Natural is
     (Handle.ID);

   procedure Open
     (Item          : in out Session;
      Header_Block  : Stream_Element_Array;
      Retained_Body : Bytes.Unbounded_Bytes;
      Streaming     : Boolean;
      Head_Request  : Boolean;
      Handle        : out Stream_Handle;
      Accepted      : out Boolean) is
      Owned_Body : Request_Buffer_Access :=
        (if Bytes.Length (Retained_Body) = 0
         then null else new Bytes.Unbounded_Bytes'(Retained_Body));
   begin
      Item.State.Streams.Open
        (Header_Block, Owned_Body, Streaming, Head_Request, Handle, Accepted);
      if Accepted then
         Drivers.Signal (Item.State.Outbound);
      elsif Owned_Body /= null then
         Free_Request_Buffer (Owned_Body);
      end if;
   exception
      when others =>
         if Owned_Body /= null then
            Free_Request_Buffer (Owned_Body);
         end if;
         raise;
   end Open;

   procedure Write_Request_Data
     (Item          : in out Session;
      Handle        : Stream_Handle;
      Data          : Stream_Element_Array;
      Finished      : Boolean;
      Trailer_Block : Stream_Element_Array;
      Result        : out Upload_Result)
   is
      Wake_Pump : Boolean;
   begin
      Item.State.Streams.Write_Request_Data
        (Handle, Data, Finished, Trailer_Block, Result, Wake_Pump);
      if Wake_Pump then
         Drivers.Signal (Item.State.Outbound);
      end if;
   end Write_Request_Data;

   procedure Poll_Head
     (Item    : in out Session;
      Handle  : Stream_Handle;
      Result  : out Head_Result;
      Status  : out Status_Code;
      Fields  : in out Flyology.HTTP.Headers.List;
      Finished : out Boolean) is
   begin
      Item.State.Streams.Poll_Head
        (Handle, Result, Status, Fields, Finished);
      if Result = Head_Connection_Failed and then Item.State.Driver.Closing
      then
         Result := Head_Protocol_Failed;
      end if;
   end Poll_Head;

   procedure Read
     (Item     : in out Session;
      Handle   : Stream_Handle;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Result   : out Body_Result;
      Trailers : in out Flyology.HTTP.Headers.List)
   is
      Wake_Pump : Boolean;
   begin
      Item.State.Streams.Read
        (Handle, Data, Last, Finished, Result, Trailers, Wake_Pump);
      if Result = Body_Connection_Failed and then Item.State.Driver.Closing
      then
         Result := Body_Protocol_Failed;
      end if;
      if Wake_Pump then
         Drivers.Signal (Item.State.Outbound);
      end if;
   end Read;

   procedure Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean) is
   begin
      Item.State.Streams.Wait_Source (Handle, FD, Ready_Now);
   end Wait_Source;

   procedure Upload_Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      Required  : Natural;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean) is
   begin
      Item.State.Streams.Upload_Wait_Source
        (Handle, Required, FD, Ready_Now);
   end Upload_Wait_Source;

   procedure Cancel_Stream (Item : in out Session; Handle : Stream_Handle) is
      Wake_Pump : Boolean;
   begin
      Item.State.Streams.Cancel_Stream (Handle, Wake_Pump);
      if Wake_Pump then
         Drivers.Signal (Item.State.Outbound);
      end if;
   end Cancel_Stream;

   procedure Release_Stream (Item : in out Session; Handle : Stream_Handle) is
      Wake_Pump : Boolean;
   begin
      Item.State.Streams.Release_Stream (Handle, Wake_Pump);
      if Wake_Pump then
         Drivers.Signal (Item.State.Outbound);
      end if;
   end Release_Stream;

end Flyology.HTTP.HTTP_2_Client_Connection;
