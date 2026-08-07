with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.Bytes;
with Flyology.HTTP.Headers;
with Flyology.HTTP.HTTP_2_Frames;
with Flyology.HTTP.HTTP_2_HPACK;
with Flyology.HTTP.HTTP_2_Payloads;
with Flyology.HTTP.HTTP_2_Policy;
with Flyology.HTTP.HTTP_2_Responses;
with Flyology.HTTP.HTTP_2_Settings;
with Flyology.HTTP.Server.Applications.Internals;
with Flyology.HTTP.Server.Exchange_Backends;
with Flyology.IO;
with Flyology.IO.Connections.Drivers;
with Flyology.Wake_Sources;
with Interfaces;

package body Flyology.HTTP.Server.HTTP_2 is
   use Ada.Streams;
   use type Ada.Real_Time.Time;
   use type Flyology.HTTP.Server.Applications.Response_State;
   use type Flyology.IO.Descriptor;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   package Bytes renames Flyology.Bytes;
   package Drivers renames Flyology.IO.Connections.Drivers;
   package Frames renames Flyology.HTTP.HTTP_2_Frames;
   package HPACK renames Flyology.HTTP.HTTP_2_HPACK;
   package Payloads renames Flyology.HTTP.HTTP_2_Payloads;
   package Policy renames Flyology.HTTP.HTTP_2_Policy;
   package Responses renames Flyology.HTTP.HTTP_2_Responses;
   package Settings renames Flyology.HTTP.HTTP_2_Settings;
   package Backends renames Flyology.HTTP.Server.Exchange_Backends;
   use type Frames.Header_Validity;
   use type Payloads.Fragment_Result;
   use type Settings.Apply_Result;

   Client_Preface : constant String := "PRI * HTTP/2.0" &
     Character'Val (13) & Character'Val (10) &
     Character'Val (13) & Character'Val (10) &
     "SM" & Character'Val (13) & Character'Val (10) &
     Character'Val (13) & Character'Val (10);
   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Maximum_Header_Block : constant Positive := 64 * 1_024;
   Stream_Buffer_Capacity : constant Positive :=
     Positive (Settings.Advertised_Initial_Window_Size);
   Maximum_Control_Backlog : constant Positive := 32 * 1_024;
   Window_Update_Threshold : constant Positive := 8 * 1_024;

   type Byte_Storage is
     array (Positive range 1 .. Stream_Buffer_Capacity) of Stream_Element;
   type Stream_Phase is (Free, Open, Complete);
   type Failure_Kind is
     (No_Failure, Reset_Failure, Body_Limit_Failure, Connection_Failure);
   type Read_Result is
     (Read_Progress, Read_Would_Block, Read_Finished, Read_Failed,
      Read_Body_Too_Large);
   type Queue_Result is (Queue_Accepted, Queue_Would_Block, Queue_Failed);
   type Header_Disposition is
     (Headers_Allowed, Headers_Stream_Closed, Headers_Connection_Closed,
      Headers_Invalid_Lower_ID);
   --  Closed stream state may be discarded eventually, but retaining a
   --  generous bounded history lets us distinguish recently closed streams
   --  from stream identifiers that were skipped by the client.
   Stream_History_Capacity : constant Positive := 4_096;
   type Stream_History_Array is array
     (Positive range 1 .. Stream_History_Capacity) of
       Frames.Stream_Identifier;

   type Stream_Record is limited record
      Phase          : Stream_Phase := Free;
      ID             : Frames.Stream_Identifier := 0;
      Remote_End     : Boolean := False;
      Local_End      : Boolean := False;
      Discarding     : Boolean := False;
      Handler_Done   : Boolean := False;
      Failure        : Failure_Kind := No_Failure;
      Body_Limit     : Natural := Max_Request_Body;
      Body_Bytes     : Natural := 0;
      Has_Length     : Boolean := False;
      Expected_Length : Long_Long_Integer := 0;
      Input          : Byte_Storage;
      Input_First    : Positive := 1;
      Input_Count    : Natural range 0 .. Stream_Buffer_Capacity := 0;
      Response_Started : Boolean := False;
      Response_Head  : Bytes.Unbounded_Bytes;
      Head_Cursor    : Natural := 1;
      Output         : Byte_Storage;
      Output_First   : Positive := 1;
      Output_Count   : Natural range 0 .. Stream_Buffer_Capacity := 0;
      End_Pending    : Boolean := False;
      Send_Window    : Policy.Window_Size := 65_535;
      Receive_Window : Policy.Window_Size :=
        Policy.Window_Size (Settings.Advertised_Initial_Window_Size);
      Pending_Receive_Credit : Natural := 0;
      Wake           : Flyology.Wake_Sources.Source;
      Wake_Signalled : Boolean := False;
   end record;

   type Stream_Array is array
     (Positive range 1 .. Maximum_Concurrent_Streams) of Stream_Record;

   protected type Controller is
      procedure Open_Request
        (Stream_ID       : Frames.Stream_Identifier;
         End_Stream      : Boolean;
         Has_Length      : Boolean;
         Expected_Length : Long_Long_Integer;
         Slot            : out Natural;
         Accepted        : out Boolean);
      function Find (Stream_ID : Frames.Stream_Identifier) return Natural;
      function Is_Trailers
        (Stream_ID : Frames.Stream_Identifier) return Boolean;
      function Header_State
        (Stream_ID : Frames.Stream_Identifier) return Header_Disposition;
      function Is_Idle
        (Stream_ID : Frames.Stream_Identifier) return Boolean;
      procedure Publish_Data
        (Stream_ID   : Frames.Stream_Identifier;
         Data        : Stream_Element_Array;
         Flow_Length : Natural;
         End_Stream  : Boolean;
         Accepted    : out Boolean);
      procedure Publish_Trailers
        (Stream_ID  : Frames.Stream_Identifier;
         End_Stream : Boolean;
         Accepted   : out Boolean);
      procedure Narrow_Body_Limit
        (Slot : Positive; Maximum : Natural; Accepted : out Boolean);
      procedure Read_Body
        (Slot     : Positive;
         Data     : out Stream_Element_Array;
         Last     : out Stream_Element_Offset;
         Finished : out Boolean;
         Result   : out Read_Result);
      procedure Start_Discard
        (Slot : Positive; Finished : out Boolean; Failed : out Boolean);
      function Body_Complete (Slot : Positive) return Boolean;
      function Body_Bytes (Slot : Positive) return Natural;
      procedure Queue_Response_Head
        (Slot   : Positive;
         Block  : Stream_Element_Array;
         Result : out Queue_Result);
      procedure Queue_Response_Data
        (Slot   : Positive;
         Data   : Stream_Element_Array;
         Result : out Queue_Result);
      procedure Finish_Response
        (Slot : Positive; Result : out Queue_Result);
      function Response_Started (Slot : Positive) return Boolean;
      procedure Mark_Failed (Slot : Positive);
      procedure Handler_Finished (Slot : Positive);
      procedure Wait_Source
        (Slot       : Positive;
         For_Output : Boolean;
         FD         : out Flyology.IO.Descriptor;
         Ready_Now  : out Boolean);
      procedure Pull_Output
        (Data      : out Stream_Element_Array;
         Last      : out Stream_Element_Offset;
         Available : out Boolean);
      procedure Apply_Peer_Settings
        (Value : Settings.State; Accepted : out Boolean);
      procedure Queue_Settings_Ack;
      procedure Queue_Ping_Ack (Payload : Stream_Element_Array);
      procedure Queue_Stream_Reset
        (Stream_ID : Frames.Stream_Identifier; Error : Frames.Error_Code);
      procedure Window_Update
        (Stream_ID : Frames.Stream_Identifier;
         Increment : Natural;
         Accepted  : out Boolean;
         Stream_Failure : out Boolean);
      procedure Reset_Stream
        (Stream_ID : Frames.Stream_Identifier; Slot : out Natural);
      procedure Reject_Stream
        (Stream_ID : Frames.Stream_Identifier;
         Error     : Frames.Error_Code;
         Slot      : out Natural;
         Accepted  : out Boolean);
      procedure Receive_Goaway;
      procedure Fail_All (Error : Frames.Error_Code);
      function Control_Backlogged return Boolean;
      function Can_Reap (Slot : Positive) return Boolean;
      procedure Release_Stream (Slot : Positive);
   private
      Streams       : Stream_Array;
      Peer          : Settings.State;
      Last_Client_Stream : Frames.Stream_Identifier := 0;
      Connection_Send_Window : Policy.Window_Size := 65_535;
      Connection_Receive_Window : Policy.Window_Size := 65_535;
      Pending_Connection_Credit : Natural := 0;
      Initial_Settings_Pending : Boolean := True;
      Control_Output : Bytes.Unbounded_Bytes;
      Control_Cursor : Natural := 1;
      Continuation_Slot : Natural := 0;
      Output_Cursor : Positive := 1;
      Draining : Boolean := False;
      Broken   : Boolean := False;
      Seen_Streams  : Stream_History_Array := (others => 0);
      Seen_Cursor   : Positive := 1;
      Reset_Streams : Stream_History_Array := (others => 0);
      Reset_Cursor  : Positive := 1;
   end Controller;

   type Session_State is limited record
      Streams  : Controller;
      Outbound : Drivers.Outbound_Wakeup;
   end record;
   type Session_State_Access is access all Session_State;

   type Stream_Backend is limited new Backends.Backend with record
      State         : Session_State_Access := null;
      Slot          : Natural := 0;
      Request_Value : aliased Request;
      Deadline      : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Head_Request  : Boolean := False;
      Token         : aliased Flyology.Cancellation.Token;
   end record;
   type Stream_Backend_Access is access all Stream_Backend;

   overriding function Response_Started
     (Item : Stream_Backend) return Boolean;
   overriding procedure Narrow_Deadline
     (Item : in out Stream_Backend; Deadline : Ada.Real_Time.Time);
   overriding function Body_Complete
     (Item : Stream_Backend) return Boolean;
   overriding function Body_Bytes (Item : Stream_Backend) return Natural;
   overriding procedure Narrow_Body_Limit
     (Item : in out Stream_Backend; Maximum : Natural);
   overriding procedure Read_Body
     (Item     : in out Stream_Backend;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token);
   overriding procedure Accept_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Buffer_Body
     (Item  : in out Stream_Backend;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Discard_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Respond
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token);
   overriding procedure Begin_Response_Stream
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token);
   overriding procedure Write_Response_Chunk
     (Item    : in out Stream_Backend;
      Data    : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   overriding procedure Write_Response_Chunk
     (Item    : in out Stream_Backend;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   overriding procedure End_Response_Stream
     (Item    : in out Stream_Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   overriding procedure Begin_SSE
     (Item          : in out Stream_Backend;
      Extra_Headers : String;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token);
   overriding procedure Send_Event
     (Item          : in out Stream_Backend;
      Data          : String;
      Event         : String;
      Id            : String;
      Retry         : Natural;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Include_Id    : Boolean;
      Include_Retry : Boolean);
   overriding procedure Send_SSE_Comment
     (Item    : in out Stream_Backend;
      Comment : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   overriding procedure End_SSE
     (Item    : in out Stream_Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);
   overriding procedure Mark_Failed (Item : in out Stream_Backend);

   procedure Append_Frame
     (Target    : in out Bytes.Unbounded_Bytes;
      Kind      : Frames.Frame_Code;
      Flags     : Frames.Frame_Flags;
      Stream_ID : Frames.Stream_Identifier;
      Payload   : Stream_Element_Array)
   is
      Header : constant Frames.Wire_Header := Frames.Encode
        ((Length => Payload'Length, Kind => Kind, Flags => Flags,
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

   protected body Controller is
      procedure Notify (Index : Positive) is
      begin
         if not Streams (Index).Wake_Signalled then
            Flyology.Wake_Sources.Signal (Streams (Index).Wake);
            Streams (Index).Wake_Signalled := True;
         end if;
      end Notify;

      function Find (Stream_ID : Frames.Stream_Identifier) return Natural is
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
               for Index in 1 .. Remaining loop
                  Bytes.Append
                    (Replacement,
                     Bytes.Element
                       (Control_Output, Control_Cursor + Index - 1));
               end loop;
               Bytes.Move (Control_Output, Replacement);
               Control_Cursor := 1;
            end;
         end if;
         Append_Frame (Control_Output, Kind, Flags, Stream_ID, Payload);
      end Queue_Control_Frame;

      procedure Maybe_Complete (Index : Positive) is
      begin
         if Streams (Index).Phase = Open
           and then Streams (Index).Remote_End
           and then Streams (Index).Local_End
           and then Streams (Index).Handler_Done
         then
            Streams (Index).Phase := Complete;
         end if;
      end Maybe_Complete;

      procedure Remember_Reset (Stream_ID : Frames.Stream_Identifier) is
      begin
         Reset_Streams (Reset_Cursor) := Stream_ID;
         Reset_Cursor := Reset_Cursor mod Reset_Streams'Length + 1;
      end Remember_Reset;

      procedure Remember_Seen (Stream_ID : Frames.Stream_Identifier) is
      begin
         Seen_Streams (Seen_Cursor) := Stream_ID;
         Seen_Cursor := Seen_Cursor mod Seen_Streams'Length + 1;
      end Remember_Seen;

      function Was_Reset
        (Stream_ID : Frames.Stream_Identifier) return Boolean
      is
      begin
         for Value of Reset_Streams loop
            if Value = Stream_ID then
               return True;
            end if;
         end loop;
         return False;
      end Was_Reset;

      function Was_Seen
        (Stream_ID : Frames.Stream_Identifier) return Boolean
      is
      begin
         for Value of Seen_Streams loop
            if Value = Stream_ID then
               return True;
            end if;
         end loop;
         return False;
      end Was_Seen;

      procedure Return_Connection_Credit (Count : Natural) is
      begin
         if Count = 0 then
            return;
         end if;
         Pending_Connection_Credit := Pending_Connection_Credit + Count;
         if Pending_Connection_Credit >= Window_Update_Threshold then
            Connection_Receive_Window := Connection_Receive_Window +
              Policy.Window_Size (Pending_Connection_Credit);
            Queue_Control_Frame
              (Frames.Window_Update_Frame, 0, 0,
               U31_Payload (Pending_Connection_Credit));
            Pending_Connection_Credit := 0;
         end if;
      end Return_Connection_Credit;

      procedure Return_Stream_Credit
        (Index : Positive; Count : Natural; Force : Boolean := False) is
      begin
         if Count = 0 then
            return;
         end if;
         Streams (Index).Pending_Receive_Credit :=
           Streams (Index).Pending_Receive_Credit + Count;
         if Force or else Streams (Index).Pending_Receive_Credit >=
           Window_Update_Threshold
         then
            Streams (Index).Receive_Window := Streams (Index).Receive_Window +
              Policy.Window_Size (Streams (Index).Pending_Receive_Credit);
            Queue_Control_Frame
              (Frames.Window_Update_Frame, 0, Streams (Index).ID,
               U31_Payload (Streams (Index).Pending_Receive_Credit));
            Streams (Index).Pending_Receive_Credit := 0;
         end if;
      end Return_Stream_Credit;

      --  A closed stream still consumes connection flow-control credit: the
      --  peer debited its connection send window before the stream closed.
      --  Charge those bytes and hand the credit straight back, otherwise the
      --  two sides diverge permanently and the peer stalls on every stream.
      procedure Charge_Closed_Stream
        (Flow_Length : Natural; Accepted : out Boolean)
      is
         Consumed : constant Policy.Window_Result := Policy.Consume
           (Connection_Receive_Window, Policy.Data_Length (Flow_Length));
      begin
         Accepted := Consumed.Accepted;
         if Accepted then
            Connection_Receive_Window := Consumed.Window;
            Return_Connection_Credit (Flow_Length);
         end if;
      end Charge_Closed_Stream;

      procedure Open_Request
        (Stream_ID       : Frames.Stream_Identifier;
         End_Stream      : Boolean;
         Has_Length      : Boolean;
         Expected_Length : Long_Long_Integer;
         Slot            : out Natural;
         Accepted        : out Boolean)
      is
         Active : Natural := 0;
      begin
         Slot := 0;
         Accepted := False;
         if Broken or else Draining or else Stream_ID = 0
           or else Natural (Stream_ID) mod 2 = 0
           or else Stream_ID <= Last_Client_Stream
         then
            return;
         end if;
         Last_Client_Stream := Stream_ID;
         Remember_Seen (Stream_ID);
         for Index in Streams'Range loop
            if Streams (Index).Phase = Free and then Slot = 0 then
               Slot := Index;
            elsif Streams (Index).Phase = Open then
               Active := Active + 1;
            end if;
         end loop;
         if Slot = 0 or else Active >= Maximum_Concurrent_Streams then
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Frames.Refused_Stream)));
            Remember_Reset (Stream_ID);
            Slot := 0;
            Accepted := True;
            return;
         end if;
         if End_Stream and then Has_Length and then Expected_Length /= 0 then
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Frames.Protocol_Error_Code)));
            Remember_Reset (Stream_ID);
            Slot := 0;
            Accepted := True;
            return;
         end if;
         Flyology.Wake_Sources.Ensure (Streams (Slot).Wake);
         Streams (Slot).Phase := Open;
         Streams (Slot).ID := Stream_ID;
         Streams (Slot).Remote_End := End_Stream;
         Streams (Slot).Has_Length := Has_Length;
         Streams (Slot).Expected_Length := Expected_Length;
         Streams (Slot).Send_Window :=
           Policy.Window_Size (Peer.Initial_Window_Size);
         Accepted := True;
      end Open_Request;

      function Is_Trailers
        (Stream_ID : Frames.Stream_Identifier) return Boolean is
      begin
         return Find (Stream_ID) /= 0;
      end Is_Trailers;

      function Header_State
        (Stream_ID : Frames.Stream_Identifier) return Header_Disposition
      is
         Index : constant Natural := Find (Stream_ID);
      begin
         return
           (if Index = 0 then
               (if Stream_ID > Last_Client_Stream then Headers_Allowed
               elsif Was_Reset (Stream_ID) then Headers_Stream_Closed
               elsif Was_Seen (Stream_ID) then Headers_Connection_Closed
               else Headers_Invalid_Lower_ID)
            elsif Streams (Index).Failure /= No_Failure then
              Headers_Stream_Closed
            elsif Streams (Index).Phase = Complete then
              Headers_Connection_Closed
            elsif Streams (Index).Remote_End then Headers_Stream_Closed
            else Headers_Allowed);
      end Header_State;

      function Is_Idle
        (Stream_ID : Frames.Stream_Identifier) return Boolean is
        (Natural (Stream_ID) mod 2 = 0 or else Stream_ID > Last_Client_Stream);

      procedure Publish_Data
        (Stream_ID   : Frames.Stream_Identifier;
         Data        : Stream_Element_Array;
         Flow_Length : Natural;
         End_Stream  : Boolean;
         Accepted    : out Boolean)
      is
         Index : constant Natural := Find (Stream_ID);
         Connection_Result : Policy.Window_Result;
         Stream_Result : Policy.Window_Result;
         Immediate_Credit : Natural := Flow_Length - Natural (Data'Length);
      begin
         Accepted := False;
         if Index = 0 then
            if Stream_ID /= 0 and then Stream_ID <= Last_Client_Stream then
               Queue_Control_Frame
                 (Frames.Reset_Stream_Frame, 0, Stream_ID,
                  U31_Payload (Natural (Frames.Stream_Closed_Error)));
               Charge_Closed_Stream (Flow_Length, Accepted);
            end if;
            return;
         elsif Streams (Index).Remote_End then
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Frames.Stream_Closed_Error)));
            Charge_Closed_Stream (Flow_Length, Accepted);
            return;
         end if;
         Connection_Result := Policy.Consume
           (Connection_Receive_Window, Policy.Data_Length (Flow_Length));
         Stream_Result := Policy.Consume
           (Streams (Index).Receive_Window,
            Policy.Data_Length (Flow_Length));
         if not Connection_Result.Accepted or else not Stream_Result.Accepted
         then
            return;
         end if;
         Connection_Receive_Window := Connection_Result.Window;
         Streams (Index).Receive_Window := Stream_Result.Window;
         Streams (Index).Body_Bytes := Streams (Index).Body_Bytes +
           Natural (Data'Length);
         if Streams (Index).Body_Bytes > Streams (Index).Body_Limit then
            Streams (Index).Failure := Body_Limit_Failure;
            Streams (Index).Discarding := True;
         end if;
         if Streams (Index).Discarding then
            Immediate_Credit := Immediate_Credit + Natural (Data'Length);
         elsif Streams (Index).Input_Count + Natural (Data'Length) >
           Stream_Buffer_Capacity
         then
            return;
         else
            if Data'Length > 0 then
               for Offset in 0 .. Natural (Data'Length) - 1 loop
                  Streams (Index).Input
                    (((Streams (Index).Input_First - 1 +
                       Streams (Index).Input_Count + Offset) mod
                       Stream_Buffer_Capacity) + 1) :=
                      Data (Data'First + Stream_Element_Offset (Offset));
               end loop;
            end if;
            Streams (Index).Input_Count := Streams (Index).Input_Count +
              Natural (Data'Length);
         end if;
         if Immediate_Credit > 0 then
            Return_Connection_Credit (Immediate_Credit);
            Return_Stream_Credit (Index, Immediate_Credit);
         end if;
         if End_Stream then
            Streams (Index).Remote_End := True;
            if Streams (Index).Has_Length and then
              Long_Long_Integer (Streams (Index).Body_Bytes) /=
                Streams (Index).Expected_Length
            then
               declare
                  Ignored : Natural;
                  Rejected : Boolean;
               begin
                  Reject_Stream
                    (Stream_ID, Frames.Protocol_Error_Code,
                     Ignored, Rejected);
               end;
            end if;
         end if;
         Notify (Index);
         Maybe_Complete (Index);
         Accepted := True;
      end Publish_Data;

      procedure Publish_Trailers
        (Stream_ID  : Frames.Stream_Identifier;
         End_Stream : Boolean;
         Accepted   : out Boolean)
      is
         Index : constant Natural := Find (Stream_ID);
      begin
         Accepted := Index /= 0 and then End_Stream
           and then not Streams (Index).Remote_End;
         if not Accepted then
            return;
         end if;
         Streams (Index).Remote_End := True;
         if Streams (Index).Has_Length and then
           Long_Long_Integer (Streams (Index).Body_Bytes) /=
             Streams (Index).Expected_Length
         then
            declare
               Ignored : Natural;
               Rejected : Boolean;
            begin
               Reject_Stream
                 (Stream_ID, Frames.Protocol_Error_Code, Ignored, Rejected);
            end;
         end if;
         Notify (Index);
         Maybe_Complete (Index);
      end Publish_Trailers;

      procedure Narrow_Body_Limit
        (Slot : Positive; Maximum : Natural; Accepted : out Boolean) is
      begin
         Accepted := Streams (Slot).Phase = Open
           and then Maximum <= Streams (Slot).Body_Limit
           and then Streams (Slot).Body_Bytes <= Maximum;
         if Accepted then
            Streams (Slot).Body_Limit := Maximum;
         end if;
      end Narrow_Body_Limit;

      procedure Read_Body
        (Slot     : Positive;
         Data     : out Stream_Element_Array;
         Last     : out Stream_Element_Offset;
         Finished : out Boolean;
         Result   : out Read_Result)
      is
         Count : Natural;
      begin
         Last := Data'First - 1;
         Finished := False;
         if Streams (Slot).Phase = Free
           or else Streams (Slot).Failure in
             Reset_Failure | Connection_Failure
         then
            Result := Read_Failed;
         elsif Streams (Slot).Failure = Body_Limit_Failure then
            Result := Read_Body_Too_Large;
         elsif Streams (Slot).Input_Count > 0 then
            Count := Natural'Min (Data'Length, Streams (Slot).Input_Count);
            if Count > 0 then
               for Offset in 0 .. Count - 1 loop
                  Data (Data'First + Stream_Element_Offset (Offset)) :=
                    Streams (Slot).Input
                      (((Streams (Slot).Input_First - 1 + Offset) mod
                         Stream_Buffer_Capacity) + 1);
               end loop;
               Last := Data'First + Stream_Element_Offset (Count) - 1;
            end if;
            Streams (Slot).Input_First :=
              ((Streams (Slot).Input_First - 1 + Count) mod
                 Stream_Buffer_Capacity) + 1;
            Streams (Slot).Input_Count := Streams (Slot).Input_Count - Count;
            Finished := Streams (Slot).Remote_End
              and then Streams (Slot).Input_Count = 0;
            Return_Connection_Credit (Count);
            Return_Stream_Credit (Slot, Count, Force => Finished);
            Result := Read_Progress;
         elsif Streams (Slot).Remote_End then
            Finished := True;
            Result := Read_Finished;
         else
            Result := Read_Would_Block;
         end if;
      end Read_Body;

      procedure Start_Discard
        (Slot : Positive; Finished : out Boolean; Failed : out Boolean)
      is
         Count : constant Natural := Streams (Slot).Input_Count;
      begin
         Failed := Streams (Slot).Phase = Free
           or else Streams (Slot).Failure in
             Reset_Failure | Connection_Failure;
         if not Failed then
            Streams (Slot).Discarding := True;
            Streams (Slot).Input_First := 1;
            Streams (Slot).Input_Count := 0;
            Return_Connection_Credit (Count);
            Return_Stream_Credit
              (Slot, Count, Force => Streams (Slot).Remote_End);
         end if;
         Finished := not Failed and then Streams (Slot).Remote_End;
      end Start_Discard;

      function Body_Complete (Slot : Positive) return Boolean is
        (Streams (Slot).Phase /= Free and then Streams (Slot).Remote_End
         and then Streams (Slot).Input_Count = 0);

      function Body_Bytes (Slot : Positive) return Natural is
        (Streams (Slot).Body_Bytes);

      procedure Queue_Response_Head
        (Slot   : Positive;
         Block  : Stream_Element_Array;
         Result : out Queue_Result) is
      begin
         if Streams (Slot).Phase = Free
           or else Streams (Slot).Failure /= No_Failure
           or else Streams (Slot).Response_Started
         then
            Result := Queue_Failed;
            return;
         end if;
         Streams (Slot).Response_Started := True;
         Streams (Slot).Response_Head := Bytes.To_Unbounded_Bytes (Block);
         Streams (Slot).Head_Cursor := 1;
         Result := Queue_Accepted;
      end Queue_Response_Head;

      procedure Queue_Response_Data
        (Slot   : Positive;
         Data   : Stream_Element_Array;
         Result : out Queue_Result) is
      begin
         if Streams (Slot).Phase = Free
           or else Streams (Slot).Failure /= No_Failure
           or else Streams (Slot).End_Pending
         then
            Result := Queue_Failed;
         elsif Natural (Data'Length) >
           Stream_Buffer_Capacity - Streams (Slot).Output_Count
         then
            Result := Queue_Would_Block;
         else
            if Data'Length > 0 then
               for Offset in 0 .. Natural (Data'Length) - 1 loop
                  Streams (Slot).Output
                    (((Streams (Slot).Output_First - 1 +
                       Streams (Slot).Output_Count + Offset) mod
                       Stream_Buffer_Capacity) + 1) :=
                      Data (Data'First + Stream_Element_Offset (Offset));
               end loop;
            end if;
            Streams (Slot).Output_Count := Streams (Slot).Output_Count +
              Natural (Data'Length);
            Result := Queue_Accepted;
         end if;
      end Queue_Response_Data;

      procedure Finish_Response
        (Slot : Positive; Result : out Queue_Result) is
      begin
         if Streams (Slot).Phase = Free
           or else Streams (Slot).Failure /= No_Failure
           or else not Streams (Slot).Response_Started
           or else Streams (Slot).End_Pending
         then
            Result := Queue_Failed;
         else
            Streams (Slot).End_Pending := True;
            Result := Queue_Accepted;
         end if;
      end Finish_Response;

      function Response_Started (Slot : Positive) return Boolean is
        (Streams (Slot).Phase /= Free
         and then Streams (Slot).Response_Started);

      procedure Mark_Failed (Slot : Positive) is
         Retained_Input : Natural;
      begin
         if Streams (Slot).Phase = Open then
            Retained_Input := Streams (Slot).Input_Count;
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Streams (Slot).ID,
               U31_Payload (Natural (Frames.Internal_Error)));
            Remember_Reset (Streams (Slot).ID);
            Streams (Slot).Failure := Reset_Failure;
            Streams (Slot).Remote_End := True;
            Streams (Slot).Local_End := True;
            Streams (Slot).Input_Count := 0;
            Streams (Slot).Output_Count := 0;
            --  A reset closes the stream window, but DATA already charged to
            --  the connection window still has to be returned. Otherwise a
            --  reset with a retained request body can stall unrelated later
            --  streams on the same connection.
            Return_Connection_Credit (Retained_Input);
            Notify (Slot);
            Maybe_Complete (Slot);
         end if;
      end Mark_Failed;

      procedure Handler_Finished (Slot : Positive) is
      begin
         if Streams (Slot).Phase /= Free then
            Streams (Slot).Handler_Done := True;
            Maybe_Complete (Slot);
         end if;
      end Handler_Finished;

      procedure Wait_Source
        (Slot       : Positive;
         For_Output : Boolean;
         FD         : out Flyology.IO.Descriptor;
         Ready_Now  : out Boolean) is
      begin
         Ready_Now := Streams (Slot).Phase = Free
           or else Streams (Slot).Failure /= No_Failure
           or else
             (if For_Output
              then Streams (Slot).Output_Count < Stream_Buffer_Capacity
              else Streams (Slot).Input_Count > 0
                or else Streams (Slot).Remote_End);
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
            return;
         end if;
         if Streams (Slot).Wake_Signalled then
            Flyology.Wake_Sources.Consume (Streams (Slot).Wake);
            Streams (Slot).Wake_Signalled := False;
         end if;
         Flyology.Wake_Sources.Ensure (Streams (Slot).Wake);
         FD := Flyology.Wake_Sources.Descriptor (Streams (Slot).Wake);
      end Wait_Source;

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
         Required : constant Natural := Continuation_Slot;
      begin
         Last := Data'First - 1;
         Available := False;
         if Initial_Settings_Pending then
            declare
               Payload : constant Stream_Element_Array :=
                 Settings.Server_Initial_Payload
                   (Maximum_Concurrent_Streams);
               Header : constant Frames.Wire_Header := Frames.Encode
                 ((Length => Payload'Length, Kind => Frames.Settings_Frame,
                   Flags => 0, Stream_ID => 0));
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
            Initial_Settings_Pending := False;
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

         for Attempt in 1 .. (if Required = 0 then Streams'Length else 1) loop
            declare
               Index : constant Positive :=
                 (if Required /= 0 then Positive (Required)
                  else ((Output_Cursor + Attempt - 2) mod Streams'Length) + 1);
               Item : Stream_Record renames Streams (Index);
            begin
               --  A stream that completes while its field section is still
               --  fragmented must keep emitting: CONTINUATION frames cannot
               --  be interleaved, so abandoning the block would leave the
               --  connection output pinned to a slot that never produces
               --  again.
               if (Item.Phase = Open or else Index = Required)
                 and then Item.Response_Started
                 and then Item.Head_Cursor <= Bytes.Length (Item.Response_Head)
               then
                  declare
                     Remaining : constant Natural :=
                       Bytes.Length (Item.Response_Head) -
                         Item.Head_Cursor + 1;
                     Count : constant Natural := Natural'Min
                       (Remaining, Frames.Default_Maximum_Frame_Size);
                     First : constant Boolean := Item.Head_Cursor = 1;
                     Final : constant Boolean := Count = Remaining;
                     Flags : Frames.Frame_Flags :=
                       (if Final then Frames.End_Headers_Flag else 0);
                     Header : Frames.Wire_Header;
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     if Final and then Item.End_Pending
                       and then Item.Output_Count = 0
                     then
                        Flags := Flags or Frames.End_Stream_Flag;
                        Item.Local_End := True;
                     end if;
                     Header := Frames.Encode
                       ((Length => Count,
                         Kind => (if First then Frames.Headers_Frame
                                  else Frames.Continuation_Frame),
                         Flags => Flags, Stream_ID => Item.ID));
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Bytes.Element
                          (Item.Response_Head, Item.Head_Cursor + Offset);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Head_Cursor := Item.Head_Cursor + Count;
                     Continuation_Slot := (if Final then 0 else Index);
                     Last := Cursor - 1;
                     Available := True;
                     if Final then
                        Output_Cursor := Index mod Streams'Length + 1;
                        Maybe_Complete (Index);
                     end if;
                     return;
                  end;
               elsif Item.Phase = Open and then Item.Response_Started
                 and then Item.Head_Cursor > Bytes.Length (Item.Response_Head)
                 and then Item.Output_Count > 0
                 and then Connection_Send_Window > 0
                 and then Item.Send_Window > 0
               then
                  declare
                     Count : constant Natural := Natural'Min
                       (Natural'Min
                          (Item.Output_Count,
                           Frames.Default_Maximum_Frame_Size),
                        Natural'Min
                          (Natural (Connection_Send_Window),
                           Natural (Item.Send_Window)));
                     Final : constant Boolean := Item.End_Pending
                       and then Count = Item.Output_Count;
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => Count, Kind => Frames.Data_Frame,
                         Flags =>
                           (if Final then Frames.End_Stream_Flag else 0),
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     for Offset in 0 .. Count - 1 loop
                        Data (Cursor) := Item.Output
                          (((Item.Output_First - 1 + Offset) mod
                             Stream_Buffer_Capacity) + 1);
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Output_First :=
                       ((Item.Output_First - 1 + Count) mod
                          Stream_Buffer_Capacity) + 1;
                     Item.Output_Count := Item.Output_Count - Count;
                     Connection_Send_Window := Connection_Send_Window -
                       Policy.Window_Size (Count);
                     Item.Send_Window := Item.Send_Window -
                       Policy.Window_Size (Count);
                     if Final then
                        Item.Local_End := True;
                     end if;
                     Notify (Index);
                     Maybe_Complete (Index);
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               elsif Item.Phase = Open and then Item.Response_Started
                 and then Item.Head_Cursor > Bytes.Length (Item.Response_Head)
                 and then Item.Output_Count = 0 and then Item.End_Pending
                 and then not Item.Local_End
               then
                  declare
                     Header : constant Frames.Wire_Header := Frames.Encode
                       ((Length => 0, Kind => Frames.Data_Frame,
                         Flags => Frames.End_Stream_Flag,
                         Stream_ID => Item.ID));
                     Cursor : Stream_Element_Offset := Data'First;
                  begin
                     for Value of Header loop
                        Data (Cursor) := Value;
                        Cursor := Cursor + 1;
                     end loop;
                     Item.Local_End := True;
                     Maybe_Complete (Index);
                     Last := Cursor - 1;
                     Available := True;
                     Output_Cursor := Index mod Streams'Length + 1;
                     return;
                  end;
               end if;
            end;
         end loop;
      end Pull_Output;

      procedure Apply_Peer_Settings
        (Value : Settings.State; Accepted : out Boolean)
      is
         Change : constant Policy.Window_Size :=
           Policy.Window_Size (Value.Initial_Window_Size) -
             Policy.Window_Size (Peer.Initial_Window_Size);
      begin
         Accepted := True;
         for Item of Streams loop
            if Item.Phase /= Free then
               declare
                  Adjusted : constant Policy.Window_Result :=
                    Policy.Adjust_Initial_Window (Item.Send_Window, Change);
               begin
                  if not Adjusted.Accepted then
                     Accepted := False;
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

      procedure Queue_Stream_Reset
        (Stream_ID : Frames.Stream_Identifier; Error : Frames.Error_Code) is
      begin
         Queue_Control_Frame
           (Frames.Reset_Stream_Frame, 0, Stream_ID,
            U31_Payload (Natural (Error)));
      end Queue_Stream_Reset;

      procedure Window_Update
        (Stream_ID : Frames.Stream_Identifier;
         Increment : Natural;
         Accepted  : out Boolean;
         Stream_Failure : out Boolean)
      is
         Index : constant Natural := Find (Stream_ID);
         Increased : Policy.Window_Result;
      begin
         Accepted := Increment > 0;
         Stream_Failure := False;
         if not Accepted then
            Stream_Failure := Stream_ID /= 0;
            return;
         elsif Stream_ID = 0 then
            Increased := Policy.Increase
              (Connection_Send_Window, Policy.Window_Increment (Increment));
            Accepted := Increased.Accepted;
            if Accepted then
               Connection_Send_Window := Increased.Window;
            end if;
         elsif Index = 0 then
            Accepted := Stream_ID <= Last_Client_Stream;
         else
            Increased := Policy.Increase
              (Streams (Index).Send_Window,
               Policy.Window_Increment (Increment));
            Accepted := Increased.Accepted;
            if Accepted then
               Streams (Index).Send_Window := Increased.Window;
               Notify (Index);
            else
               Stream_Failure := True;
            end if;
         end if;
      end Window_Update;

      procedure Reset_Stream
        (Stream_ID : Frames.Stream_Identifier; Slot : out Natural) is
         Retained_Input : Natural;
      begin
         Slot := Find (Stream_ID);
         if Slot /= 0 then
            Remember_Reset (Stream_ID);
            Retained_Input := Streams (Slot).Input_Count;
            Streams (Slot).Failure := Reset_Failure;
            Streams (Slot).Remote_End := True;
            Streams (Slot).Local_End := True;
            Streams (Slot).Input_Count := 0;
            Streams (Slot).Output_Count := 0;
            Return_Connection_Credit (Retained_Input);
            Notify (Slot);
            Maybe_Complete (Slot);
         end if;
      end Reset_Stream;

      procedure Reject_Stream
        (Stream_ID : Frames.Stream_Identifier;
         Error     : Frames.Error_Code;
         Slot      : out Natural;
         Accepted  : out Boolean)
      is
         Retained_Input : Natural;
      begin
         Slot := Find (Stream_ID);
         Accepted := not Broken and then Stream_ID /= 0
           and then Natural (Stream_ID) mod 2 = 1;
         if not Accepted then
            return;
         elsif Slot = 0 then
            if Stream_ID > Last_Client_Stream then
               Last_Client_Stream := Stream_ID;
               Remember_Seen (Stream_ID);
            end if;
            Remember_Reset (Stream_ID);
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Error)));
            return;
         end if;

         Retained_Input := Streams (Slot).Input_Count;
         Remember_Reset (Stream_ID);
         Queue_Control_Frame
           (Frames.Reset_Stream_Frame, 0, Stream_ID,
            U31_Payload (Natural (Error)));
         Streams (Slot).Failure := Reset_Failure;
         Streams (Slot).Remote_End := True;
         Streams (Slot).Local_End := True;
         Streams (Slot).Input_Count := 0;
         Streams (Slot).Output_Count := 0;
         Return_Connection_Credit (Retained_Input);
         Notify (Positive (Slot));
         Maybe_Complete (Positive (Slot));
      end Reject_Stream;

      procedure Receive_Goaway is
      begin
         Draining := True;
      end Receive_Goaway;

      procedure Fail_All (Error : Frames.Error_Code) is
      begin
         if not Broken then
            Queue_Control_Frame
              (Frames.Goaway_Frame, 0, 0,
               U31_Payload (Natural (Last_Client_Stream)) &
                 U31_Payload (Natural (Error)));
         end if;
         Broken := True;
         Draining := True;
         for Index in Streams'Range loop
            if Streams (Index).Phase = Open then
               Streams (Index).Failure := Connection_Failure;
               Streams (Index).Remote_End := True;
               Streams (Index).Local_End := True;
               Notify (Index);
               Maybe_Complete (Index);
            end if;
         end loop;
      end Fail_All;

      function Control_Backlogged return Boolean is
        (Control_Cursor <= Bytes.Length (Control_Output)
         and then Bytes.Length (Control_Output) - Control_Cursor + 1 >=
           Maximum_Control_Backlog);

      --  A slot pinned mid-field-section still owns the encoded head, so it
      --  cannot be released until its last fragment has been emitted.
      function Can_Reap (Slot : Positive) return Boolean is
        (Streams (Slot).Phase = Complete and then Streams (Slot).Handler_Done
         and then Continuation_Slot /= Slot);

      procedure Release_Stream (Slot : Positive) is
      begin
         if not Can_Reap (Slot) then
            return;
         end if;
         --  A slot reaped while its field section was still fragmented would
         --  otherwise keep the connection output pinned to it forever.
         if Continuation_Slot = Slot then
            Continuation_Slot := 0;
         end if;
         Streams (Slot).Phase := Free;
         Streams (Slot).ID := 0;
         Streams (Slot).Remote_End := False;
         Streams (Slot).Local_End := False;
         Streams (Slot).Discarding := False;
         Streams (Slot).Handler_Done := False;
         Streams (Slot).Failure := No_Failure;
         Streams (Slot).Body_Limit := Max_Request_Body;
         Streams (Slot).Body_Bytes := 0;
         Streams (Slot).Has_Length := False;
         Streams (Slot).Expected_Length := 0;
         Streams (Slot).Input_First := 1;
         Streams (Slot).Input_Count := 0;
         Streams (Slot).Response_Started := False;
         Bytes.Clear (Streams (Slot).Response_Head);
         Streams (Slot).Head_Cursor := 1;
         Streams (Slot).Output_First := 1;
         Streams (Slot).Output_Count := 0;
         Streams (Slot).End_Pending := False;
         --  A reused slot must start from the advertised initial window; the
         --  previous stream's residue would reject a legal DATA frame.
         Streams (Slot).Receive_Window :=
           Policy.Window_Size (Settings.Advertised_Initial_Window_Size);
         Streams (Slot).Pending_Receive_Credit := 0;
         if Flyology.Wake_Sources.Descriptor (Streams (Slot).Wake) >= 0 then
            Flyology.Wake_Sources.Release (Streams (Slot).Wake);
         end if;
         Streams (Slot).Wake_Signalled := False;
      end Release_Stream;
   end Controller;

   function Remaining (Item : Stream_Backend) return Duration is
   begin
      if Item.Deadline = Ada.Real_Time.Time_Last then
         return -1.0;
      elsif Ada.Real_Time.Clock >= Item.Deadline then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration
           (Item.Deadline - Ada.Real_Time.Clock);
      end if;
   end Remaining;

   procedure Wait_For_Stream
     (Item : in out Stream_Backend; For_Output : Boolean)
   is
      Stream_FD : Flyology.IO.Descriptor;
      Token_FD  : Flyology.IO.Descriptor;
      Ready     : Boolean;
      Cancelled : Boolean;
      Selected  : Natural;
   begin
      Item.State.Streams.Wait_Source
        (Item.Slot, For_Output, Stream_FD, Ready);
      if Ready then
         return;
      end if;
      Item.Token.Wait_Source (Token_FD, Cancelled);
      if Cancelled then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
      declare
         Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
      begin
         Sources (1) := (FD => Stream_FD, Condition => Flyology.IO.For_Read);
         Sources (2) := (FD => Token_FD, Condition => Flyology.IO.For_Read);
         Selected := Flyology.IO.Wait_Any (Sources, Remaining (Item));
      end;
      if Selected = 0 then
         raise Flyology.IO.Timeout_Error;
      elsif Selected = 2 then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Wait_For_Stream;

   overriding function Response_Started
     (Item : Stream_Backend) return Boolean is
     (Item.State.Streams.Response_Started (Item.Slot));

   overriding procedure Narrow_Deadline
     (Item : in out Stream_Backend; Deadline : Ada.Real_Time.Time) is
   begin
      Item.Deadline := Deadline;
   end Narrow_Deadline;

   overriding function Body_Complete
     (Item : Stream_Backend) return Boolean is
     (Item.State.Streams.Body_Complete (Item.Slot));

   overriding function Body_Bytes (Item : Stream_Backend) return Natural is
     (Item.State.Streams.Body_Bytes (Item.Slot));

   overriding procedure Narrow_Body_Limit
     (Item : in out Stream_Backend; Maximum : Natural)
   is
      Accepted : Boolean;
   begin
      Item.State.Streams.Narrow_Body_Limit
        (Item.Slot, Maximum, Accepted);
      if not Accepted then
         raise Payload_Too_Large;
      end if;
   end Narrow_Body_Limit;

   overriding procedure Read_Body
     (Item     : in out Stream_Backend;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Token);
      Result : Read_Result;
   begin
      loop
         Item.State.Streams.Read_Body
           (Item.Slot, Data, Last, Finished, Result);
         case Result is
            when Read_Progress | Read_Finished =>
               Drivers.Signal (Item.State.Outbound);
               return;
            when Read_Would_Block =>
               Wait_For_Stream (Item, For_Output => False);
            when Read_Body_Too_Large =>
               raise Payload_Too_Large;
            when Read_Failed =>
               raise Flyology.IO.Device_Error;
         end case;
      end loop;
   end Read_Body;

   overriding procedure Accept_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Item, Token);
   begin
      null;
   end Accept_Body;

   overriding procedure Buffer_Body
     (Item  : in out Stream_Backend;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token)
   is
      Buffer : Stream_Element_Array (1 .. 8 * 1_024);
      Last : Stream_Element_Offset;
      Finished : Boolean := False;
   begin
      Value.Body_Value := Null_Unbounded_String;
      while not Finished loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         for Index in Buffer'First .. Last loop
            Append (Value.Body_Value, Character'Val (Buffer (Index)));
         end loop;
      end loop;
   end Buffer_Body;

   overriding procedure Discard_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Token);
      Finished : Boolean;
      Failed : Boolean;
   begin
      loop
         Item.State.Streams.Start_Discard
           (Item.Slot, Finished, Failed);
         Drivers.Signal (Item.State.Outbound);
         if Failed then
            raise Flyology.IO.Device_Error;
         elsif Finished then
            return;
         end if;
         Wait_For_Stream (Item, For_Output => False);
      end loop;
   end Discard_Body;

   procedure Parse_Extra_Headers
     (Text : String; Fields : in out Flyology.HTTP.Headers.List)
   is
      Position : Natural := Text'First;
   begin
      Flyology.HTTP.Headers.Clear (Fields);
      while Position <= Text'Last loop
         declare
            Marker : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Position .. Text'Last), CRLF);
            Line_Last : constant Natural := Marker - 1;
            Colon : constant Natural := Ada.Strings.Fixed.Index
              (Text (Position .. Line_Last), ":");
         begin
            if Marker = 0 or else Colon <= Position then
               raise Program_Error with "malformed HTTP response header";
            end if;
            declare
               Name : constant String := Text (Position .. Colon - 1);
               First : Natural := Colon + 1;
            begin
               while First <= Line_Last and then Text (First) in ' ' |
                 Character'Val (9)
               loop
                  First := First + 1;
               end loop;
               Flyology.HTTP.Headers.Add
                 (Fields, Name,
                  (if First > Line_Last then ""
                   else Text (First .. Line_Last)));
            end;
            Position := Marker + 2;
         end;
      end loop;
   end Parse_Extra_Headers;

   procedure Queue_Head
     (Item               : in out Stream_Backend;
      Status             : Positive;
      Content_Type       : String;
      Extra_Headers      : String;
      Has_Content_Length : Boolean;
      Content_Length     : Natural)
   is
      Fields : Flyology.HTTP.Headers.List;
      Block  : Bytes.Unbounded_Bytes;
      Result : Queue_Result;
   begin
      if Status not in Status_Code then
         raise Constraint_Error with "invalid HTTP/2 response status";
      end if;
      Parse_Extra_Headers (Extra_Headers, Fields);
      Block := Responses.Encode_Head
        (Status_Code (Status), Content_Type, Fields,
         Has_Content_Length, Content_Length);
      Item.State.Streams.Queue_Response_Head
        (Item.Slot, Bytes.To_Array (Block), Result);
      if Result /= Queue_Accepted then
         raise Flyology.IO.Device_Error;
      end if;
      Drivers.Signal (Item.State.Outbound);
   end Queue_Head;

   procedure Queue_Data
     (Item : in out Stream_Backend; Data : Stream_Element_Array)
   is
      Cursor : Stream_Element_Offset := Data'First;
      Result : Queue_Result;
   begin
      while Cursor <= Data'Last loop
         declare
            Count : constant Natural := Natural'Min
              (Natural (Data'Last - Cursor + 1),
               Frames.Default_Maximum_Frame_Size);
            Last : constant Stream_Element_Offset :=
              Cursor + Stream_Element_Offset (Count) - 1;
         begin
            loop
               Item.State.Streams.Queue_Response_Data
                 (Item.Slot, Data (Cursor .. Last), Result);
               exit when Result = Queue_Accepted;
               if Result = Queue_Failed then
                  raise Flyology.IO.Device_Error;
               end if;
               Wait_For_Stream (Item, For_Output => True);
            end loop;
            Drivers.Signal (Item.State.Outbound);
            Cursor := Last + 1;
         end;
      end loop;
   end Queue_Data;

   procedure Finish (Item : in out Stream_Backend) is
      Result : Queue_Result;
   begin
      Item.State.Streams.Finish_Response (Item.Slot, Result);
      if Result /= Queue_Accepted then
         raise Flyology.IO.Device_Error;
      end if;
      Drivers.Signal (Item.State.Outbound);
   end Finish;

   overriding procedure Respond
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Close, Timeout, Token);
      Forbidden : constant Boolean := Status in 204 | 205 | 304;
   begin
      if Forbidden and then Payload /= "" then
         raise Program_Error with "HTTP status does not permit content";
      end if;
      Queue_Head
        (Item, Status, Content_Type, Extra_Headers,
         Has_Content_Length => Status not in 204 | 304,
         Content_Length => Payload'Length);
      if not Item.Head_Request and then not Forbidden and then Payload /= ""
      then
         Queue_Data (Item, Bytes.To_Array (Bytes.From_Byte_String (Payload)));
      end if;
      Finish (Item);
   end Respond;

   overriding procedure Begin_Response_Stream
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Close, Timeout, Token);
   begin
      if not Body_Complete (Item) then
         raise Program_Error with
           "streaming response requires a consumed request body";
      elsif Status in 204 | 205 | 304 then
         raise Program_Error with
           "HTTP status does not permit a streaming response";
      end if;
      Queue_Head
        (Item, Status, Content_Type, Extra_Headers,
         Has_Content_Length => False, Content_Length => 0);
   end Begin_Response_Stream;

   overriding procedure Write_Response_Chunk
     (Item    : in out Stream_Backend;
      Data    : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      if not Item.Head_Request and then Data /= "" then
         Queue_Data (Item, Bytes.To_Array (Bytes.From_Byte_String (Data)));
      end if;
   end Write_Response_Chunk;

   overriding procedure Write_Response_Chunk
     (Item    : in out Stream_Backend;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      if not Item.Head_Request and then Data'Length > 0 then
         Queue_Data (Item, Data);
      end if;
   end Write_Response_Chunk;

   overriding procedure End_Response_Stream
     (Item    : in out Stream_Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      Finish (Item);
   end End_Response_Stream;

   overriding procedure Begin_SSE
     (Item          : in out Stream_Backend;
      Extra_Headers : String;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Fields : constant String :=
        "Cache-Control: no-cache" & CRLF & Extra_Headers;
   begin
      if Item.Head_Request then
         raise Program_Error with "SSE is not available for HEAD";
      elsif not Body_Complete (Item) then
         raise Program_Error with "SSE request body has not been consumed";
      end if;
      Queue_Head
        (Item, 200, "text/event-stream", Fields,
         Has_Content_Length => False, Content_Length => 0);
   end Begin_SSE;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   overriding procedure Send_Event
     (Item          : in out Stream_Backend;
      Data          : String;
      Event         : String;
      Id            : String;
      Retry         : Natural;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Include_Id    : Boolean;
      Include_Retry : Boolean)
   is
      pragma Unreferenced (Timeout, Token);
      Payload : Unbounded_String;
      First : Integer := Data'First;
   begin
      if Event /= "" then
         Append (Payload, "event: " & Event & Character'Val (10));
      end if;
      if Id /= "" or else Include_Id then
         Append (Payload, "id: " & Id & Character'Val (10));
      end if;
      if Retry > 0 or else Include_Retry then
         Append
           (Payload, "retry: " & Decimal (Retry) & Character'Val (10));
      end if;
      if Data = "" then
         Append (Payload, "data:" & Character'Val (10));
      else
         while First <= Data'Last loop
            declare
               Break : Natural := 0;
               Last : Integer;
            begin
               for Index in First .. Data'Last loop
                  if Data (Index) in Character'Val (10) | Character'Val (13)
                  then
                     Break := Index;
                     exit;
                  end if;
               end loop;
               Last := (if Break = 0 then Data'Last else Break - 1);
               Append (Payload, "data:");
               if Last >= First then
                  Append (Payload, " " & Data (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when Break = 0;
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
         end loop;
      end if;
      Append (Payload, Character'Val (10));
      Queue_Data
        (Item, Bytes.To_Array
          (Bytes.From_Byte_String (To_String (Payload))));
   end Send_Event;

   overriding procedure Send_SSE_Comment
     (Item    : in out Stream_Backend;
      Comment : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      Queue_Data
        (Item, Bytes.To_Array
          (Bytes.From_Byte_String
             ((if Comment = "" then ":" else ": " & Comment)
              & Character'Val (10) & Character'Val (10))));
   end Send_SSE_Comment;

   overriding procedure End_SSE
     (Item    : in out Stream_Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      Finish (Item);
   end End_SSE;

   overriding procedure Mark_Failed (Item : in out Stream_Backend) is
   begin
      Item.State.Streams.Mark_Failed (Item.Slot);
      Drivers.Signal (Item.State.Outbound);
   end Mark_Failed;

   procedure Serve
     (Context            : in out App_Context;
      Channel            : in out Flyology.IO.Connections.Connection;
      Peer               : Flyology.IO.Sockets.Endpoint;
      Timeout            : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Token              : access Flyology.Cancellation.Token := null)
   is
      State : aliased Session_State;
      type Backend_Array is array
        (Positive range 1 .. Maximum_Concurrent_Streams) of
          Stream_Backend_Access;
      Backends_By_Slot : Backend_Array := (others => null);

      task type Handler_Task (Slot : Positive) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Handler_Task;
      type Handler_Access is access Handler_Task;
      type Handler_Array is array
        (Positive range 1 .. Maximum_Concurrent_Streams) of Handler_Access;
      Handlers : Handler_Array := (others => null);

      task body Handler_Task is
         Backend : Stream_Backend renames Backends_By_Slot (Slot).all;
         X : Applications.Exchange := Applications.Internals.Create
           (Backend.Request_Value, Backend'Access, Peer,
            Backend.Token'Access, Backend.Deadline);
      begin
         begin
            Handle (Context, X);
            if X.Response = Applications.Not_Started then
               X.No_Content;
            elsif X.Response in
              Applications.Streaming_Response | Applications.Streaming_SSE |
              Applications.Upgraded | Applications.Failed
            then
               X.Mark_Failed;
            end if;
         exception
            when others =>
               if not X.Wire_Response_Started then
                  begin
                     X.Problem
                       (500, "internal-server-error",
                        "Internal server error");
                  exception
                     when others => X.Mark_Failed;
                  end;
               else
                  X.Mark_Failed;
               end if;
         end;
         State.Streams.Handler_Finished (Slot);
         Drivers.Signal (State.Outbound);
      end Handler_Task;

      procedure Free_Handler is new Ada.Unchecked_Deallocation
        (Handler_Task, Handler_Access);
      procedure Free_Backend is new Ada.Unchecked_Deallocation
        (Stream_Backend, Stream_Backend_Access);

      procedure Reap is
      begin
         for Slot in Handlers'Range loop
            if Handlers (Slot) /= null and then Handlers (Slot).all'Terminated
              and then State.Streams.Can_Reap (Slot)
            then
               Free_Handler (Handlers (Slot));
               Free_Backend (Backends_By_Slot (Slot));
               State.Streams.Release_Stream (Slot);
            end if;
         end loop;
      end Reap;

      procedure Start_Handler
        (Slot      : Positive;
         Method    : String;
         Target    : String;
         Authority : String;
         Fields    : Flyology.HTTP.Headers.List)
      is
         Backend : constant Stream_Backend_Access := new Stream_Backend;
      begin
         Backend.State := State'Unchecked_Access;
         Backend.Slot := Slot;
         Backend.Deadline :=
           (if Timeout < 0.0 then Ada.Real_Time.Time_Last
            else Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout));
         Backend.Head_Request := Method = "HEAD";
         Backend.Request_Value.Method_Value := To_Unbounded_String (Method);
         Backend.Request_Value.Target_Value := To_Unbounded_String (Target);
         Backend.Request_Value.Version_Value := HTTP_1_1;
         Backend.Request_Value.Protocol_Value := HTTP_2_Protocol;
         Backend.Request_Value.Keep_Alive := True;
         for Index in 1 .. Flyology.HTTP.Headers.Count (Fields) loop
            Append
              (Backend.Request_Value.Header_Block,
               Flyology.HTTP.Headers.Name (Fields, Index) & ": " &
                 Flyology.HTTP.Headers.Value (Fields, Index) & CRLF);
         end loop;
         if Authority /= ""
           and then Flyology.HTTP.Headers.Count (Fields, "host") = 0
         then
            Append
              (Backend.Request_Value.Header_Block,
               "Host: " & Authority & CRLF);
         end if;
         Backends_By_Slot (Slot) := Backend;
         Handlers (Slot) := new Handler_Task (Slot);
      end Start_Handler;

      Output : Stream_Element_Array
        (1 .. Stream_Element_Offset
          (Frames.Default_Maximum_Frame_Size + Frames.Frame_Header_Size));
      Output_Last : Stream_Element_Offset := Output'First - 1;
      Output_Cursor : Stream_Element_Offset := Output'First;
      Have_Output : Boolean := False;
      Input : Stream_Element_Array
        (1 .. Stream_Element_Offset
          (2 *
             (Frames.Default_Maximum_Frame_Size + Frames.Frame_Header_Size)));
      Input_Head : Natural := 0;
      Input_Count : Natural := 0;
      Preface_Received : Boolean := False;
      Peer_Settings_Received : Boolean := False;
      Decoder : HPACK.Decoder;
      Peer_Settings : Settings.State;
      Header_Block : Bytes.Unbounded_Bytes;
      Header_Stream : Frames.Stream_Identifier := 0;
      Header_End_Stream : Boolean := False;
      Expect_Continuation : Boolean := False;
      Fatal : Boolean := False;
      Stop_Pump : exception;
      Stop_Parsing : exception;
      Request_Message_Error : exception;

      procedure Protocol_Failure
        (Error : Frames.Error_Code := Frames.Protocol_Error_Code) is
      begin
         if not Fatal then
            Fatal := True;
            State.Streams.Fail_All (Error);
         end if;
         raise Stop_Parsing;
      end Protocol_Failure;

      procedure Parse_Content_Length
        (Fields  : Flyology.HTTP.Headers.List;
         Present : out Boolean;
         Value   : out Long_Long_Integer)
      is
         Text : Unbounded_String;
      begin
         Present := Flyology.HTTP.Headers.Count (Fields, "content-length") > 0;
         Value := 0;
         if not Present then
            return;
         elsif Flyology.HTTP.Headers.Count (Fields, "content-length") /= 1
         then
            raise Request_Message_Error with
              "duplicate HTTP/2 content-length";
         end if;
         Text := To_Unbounded_String
           (Flyology.HTTP.Headers.Value (Fields, "content-length"));
         if Length (Text) = 0 then
            raise Request_Message_Error with "empty HTTP/2 content-length";
         end if;
         for Character_Value of To_String (Text) loop
            if Character_Value not in '0' .. '9'
              or else Value >
                (Long_Long_Integer'Last - Long_Long_Integer
                   (Character'Pos (Character_Value) -
                      Character'Pos ('0'))) / 10
            then
               raise Request_Message_Error with
                 "invalid HTTP/2 content-length";
            end if;
            Value := Value * 10 + Long_Long_Integer
              (Character'Pos (Character_Value) - Character'Pos ('0'));
         end loop;
      end Parse_Content_Length;

      procedure Clear_Header_Block is
      begin
         Bytes.Clear (Header_Block);
         Header_Stream := 0;
         Header_End_Stream := False;
         Expect_Continuation := False;
      end Clear_Header_Block;

      procedure Reject_Header_Block (Error : Frames.Error_Code) is
         Slot : Natural;
         Accepted : Boolean;
      begin
         State.Streams.Reject_Stream
           (Header_Stream, Error, Slot, Accepted);
         if Slot /= 0 and then Backends_By_Slot (Slot) /= null then
            Backends_By_Slot (Slot).Token.Request;
         end if;
         Clear_Header_Block;
         if not Accepted then
            Protocol_Failure;
         end if;
      end Reject_Header_Block;

      procedure Process_Header_Block is
         Fields : Flyology.HTTP.Headers.List;
         Method, Scheme, Authority, Path : Unbounded_String;
         Disposition : constant Header_Disposition :=
           State.Streams.Header_State (Header_Stream);
         Trailers : constant Boolean :=
           Disposition = Headers_Allowed
             and then State.Streams.Is_Trailers (Header_Stream);
         Accepted : Boolean;
         Slot : Natural;
         Has_Length : Boolean;
         Length_Value : Long_Long_Integer;
      begin
         HPACK.Decode_Request
           (Decoder, Bytes.To_Array (Header_Block), Trailers, Fields,
            Method, Scheme, Authority, Path);
         if Disposition = Headers_Stream_Closed then
            Reject_Header_Block (Frames.Stream_Closed_Error);
            return;
         elsif Disposition = Headers_Connection_Closed then
            Clear_Header_Block;
            Protocol_Failure (Frames.Stream_Closed_Error);
         elsif Disposition = Headers_Invalid_Lower_ID then
            Clear_Header_Block;
            Protocol_Failure (Frames.Protocol_Error_Code);
         elsif Trailers then
            State.Streams.Publish_Trailers
              (Header_Stream, Header_End_Stream, Accepted);
         else
            declare
               Method_Text : constant String := To_String (Method);
               Scheme_Text : constant String := To_String (Scheme);
               Authority_Text : constant String := To_String (Authority);
               Path_Text : constant String := To_String (Path);
               Validated : constant Flyology.HTTP.Method :=
                 Flyology.HTTP.To_Method (Method_Text);
               pragma Unreferenced (Validated);
            begin
               if Method_Text = "CONNECT" or else
                 Scheme_Text not in "http" | "https"
                 or else Path_Text = ""
                 or else Ada.Strings.Fixed.Index (Path_Text, "#") /= 0
                 or else (Path_Text = "*"
                   and then Method_Text /= "OPTIONS")
               then
                  raise Request_Message_Error with
                    "unsupported HTTP/2 request target";
               elsif Flyology.HTTP.Headers.Count (Fields, "host") > 1
                 or else (Authority_Text /= ""
                   and then Flyology.HTTP.Headers.Count (Fields, "host") = 1
                   and then Flyology.HTTP.Headers.Value (Fields, "host") /=
                     Authority_Text)
                 or else (Authority_Text = ""
                   and then Flyology.HTTP.Headers.Count (Fields, "host") = 0)
               then
                  raise Request_Message_Error with
                    "invalid HTTP/2 authority";
               end if;
               Parse_Content_Length (Fields, Has_Length, Length_Value);
               State.Streams.Open_Request
                 (Header_Stream, Header_End_Stream, Has_Length, Length_Value,
                  Slot, Accepted);
               if Accepted and then Slot /= 0 then
                  Start_Handler
                    (Positive (Slot), Method_Text, Path_Text,
                     (if Authority_Text /= "" then Authority_Text
                      else Flyology.HTTP.Headers.Value (Fields, "host")),
                     Fields);
               end if;
            end;
         end if;
         Clear_Header_Block;
         if not Accepted then
            Protocol_Failure;
         end if;
      exception
         when HPACK.Header_List_Too_Large =>
            Reject_Header_Block (Frames.Enhance_Your_Calm);
         when HPACK.Invalid_Request_Fields | Request_Message_Error |
           Constraint_Error =>
            case Disposition is
               when Headers_Stream_Closed =>
                  Reject_Header_Block (Frames.Stream_Closed_Error);
               when Headers_Connection_Closed =>
                  Clear_Header_Block;
                  Protocol_Failure (Frames.Stream_Closed_Error);
               when Headers_Invalid_Lower_ID =>
                  Clear_Header_Block;
                  Protocol_Failure (Frames.Protocol_Error_Code);
               when Headers_Allowed =>
                  Reject_Header_Block (Frames.Protocol_Error_Code);
            end case;
         when Protocol_Error =>
            Protocol_Failure (Frames.Compression_Error);
      end Process_Header_Block;

      procedure Process_Frame
        (Header : Frames.Header; Payload : Stream_Element_Array)
      is
         Accepted : Boolean;
      begin
         if not Peer_Settings_Received then
            if Header.Kind /= Frames.Settings_Frame
              or else (Header.Flags and Frames.Ack_Flag) /= 0
            then
               Protocol_Failure;
            end if;
            Peer_Settings_Received := True;
         end if;
         if Expect_Continuation and then
           (Header.Kind /= Frames.Continuation_Frame
            or else Header.Stream_ID /= Header_Stream)
         then
            Protocol_Failure;
         elsif Header.Kind = Frames.Settings_Frame then
            if (Header.Flags and Frames.Ack_Flag) = 0 then
               declare
                  Applied : Settings.Apply_Result;
               begin
                  Settings.Apply
                    (Peer_Settings, Payload, Applied,
                     Peer_Is_Server => False);
                  if Applied /= Settings.Settings_Accepted then
                     Protocol_Failure;
                  end if;
                  State.Streams.Apply_Peer_Settings
                    (Peer_Settings, Accepted);
                  if not Accepted then
                     Protocol_Failure (Frames.Flow_Control_Error);
                  end if;
                  State.Streams.Queue_Settings_Ack;
               end;
            end if;
         elsif Header.Kind = Frames.Ping_Frame then
            if (Header.Flags and Frames.Ack_Flag) = 0 then
               State.Streams.Queue_Ping_Ack (Payload);
            end if;
         elsif Header.Kind = Frames.Priority_Frame then
            declare
               Dependency : constant Natural :=
                 Natural (Payload (Payload'First) and 16#7F#) * 16#1000000#
                 + Natural (Payload (Payload'First + 1)) * 16#10000#
                 + Natural (Payload (Payload'First + 2)) * 16#100#
                 + Natural (Payload (Payload'First + 3));
            begin
               if Dependency = Natural (Header.Stream_ID) then
                  State.Streams.Queue_Stream_Reset
                    (Header.Stream_ID, Frames.Protocol_Error_Code);
               end if;
            end;
         elsif Header.Kind = Frames.Headers_Frame then
            declare
               View : Payloads.Fragment_View;
               Result : Payloads.Fragment_Result;
            begin
               Payloads.Header_Fragment
                 (Header.Stream_ID, Header.Flags, Payload, View, Result);
               if Result /= Payloads.Valid_Fragment then
                  Protocol_Failure;
               end if;
               Header_Stream := Header.Stream_ID;
               Header_End_Stream :=
                 (Header.Flags and Frames.End_Stream_Flag) /= 0;
               if not View.Empty then
                  Bytes.Append
                    (Header_Block, Payload (View.First .. View.Last));
               end if;
               if Bytes.Length (Header_Block) > Maximum_Header_Block then
                  Protocol_Failure (Frames.Enhance_Your_Calm);
               elsif (Header.Flags and Frames.End_Headers_Flag) /= 0 then
                  Process_Header_Block;
               else
                  Expect_Continuation := True;
               end if;
            end;
         elsif Header.Kind = Frames.Continuation_Frame then
            Bytes.Append (Header_Block, Payload);
            if Bytes.Length (Header_Block) > Maximum_Header_Block then
               Protocol_Failure (Frames.Enhance_Your_Calm);
            elsif (Header.Flags and Frames.End_Headers_Flag) /= 0 then
               Process_Header_Block;
            end if;
         elsif Header.Kind = Frames.Data_Frame then
            declare
               View : Payloads.Fragment_View;
               Result : Payloads.Fragment_Result;
               Empty : Stream_Element_Array (1 .. 0);
            begin
               Payloads.Data_Fragment (Header.Flags, Payload, View, Result);
               if Result /= Payloads.Valid_Fragment then
                  Protocol_Failure;
               elsif View.Empty then
                  State.Streams.Publish_Data
                    (Header.Stream_ID, Empty, Payload'Length,
                     (Header.Flags and Frames.End_Stream_Flag) /= 0,
                     Accepted);
               else
                  State.Streams.Publish_Data
                    (Header.Stream_ID, Payload (View.First .. View.Last),
                     Payload'Length,
                     (Header.Flags and Frames.End_Stream_Flag) /= 0,
                     Accepted);
               end if;
               if not Accepted then
                  --  RFC 9113 5.1: a frame other than HEADERS or PRIORITY on
                  --  an idle stream is a connection PROTOCOL_ERROR. Only a
                  --  genuinely exhausted window is FLOW_CONTROL_ERROR.
                  Protocol_Failure
                    ((if State.Streams.Is_Idle (Header.Stream_ID)
                      then Frames.Protocol_Error_Code
                      else Frames.Flow_Control_Error));
               end if;
            end;
         elsif Header.Kind = Frames.Window_Update_Frame then
            declare
               Increment : constant Natural :=
                 Payloads.Window_Increment (Payload);
               Error : constant Frames.Error_Code :=
                 (if Increment = 0 then Frames.Protocol_Error_Code
                  else Frames.Flow_Control_Error);
               Stream_Failure : Boolean;
               Slot : Natural;
            begin
               State.Streams.Window_Update
                 (Header.Stream_ID, Increment, Accepted, Stream_Failure);
               if not Accepted and then Stream_Failure then
                  State.Streams.Reject_Stream
                    (Header.Stream_ID, Error, Slot, Accepted);
                  if Slot /= 0 and then Backends_By_Slot (Slot) /= null then
                     Backends_By_Slot (Slot).Token.Request;
                  end if;
               end if;
            end;
            if not Accepted then
               --  A zero increment and an idle stream are both connection
               --  PROTOCOL_ERROR cases; stream 0 is never idle, so a
               --  connection window overflow stays FLOW_CONTROL_ERROR.
               Protocol_Failure
                 ((if Payloads.Window_Increment (Payload) = 0
                     or else (Header.Stream_ID /= 0
                       and then State.Streams.Is_Idle (Header.Stream_ID))
                   then Frames.Protocol_Error_Code
                   else Frames.Flow_Control_Error));
            end if;
         elsif Header.Kind = Frames.Reset_Stream_Frame then
            declare
               Slot : Natural;
            begin
               State.Streams.Reset_Stream (Header.Stream_ID, Slot);
               if Slot = 0 and then
                 State.Streams.Is_Idle (Header.Stream_ID)
               then
                  Protocol_Failure;
               end if;
               if Slot /= 0 and then Backends_By_Slot (Slot) /= null then
                  Backends_By_Slot (Slot).Token.Request;
               end if;
            end;
         elsif Header.Kind = Frames.Goaway_Frame then
            State.Streams.Receive_Goaway;
         elsif Header.Kind = Frames.Push_Promise_Frame then
            Protocol_Failure;
         else
            null;
         end if;
      end Process_Frame;

      procedure Parse_Input is
         procedure Consume_Input (Count : Natural) is
         begin
            Input_Head := Input_Head + Count;
            Input_Count := Input_Count - Count;
            if Input_Count = 0 then
               Input_Head := 0;
            end if;
         end Consume_Input;
      begin
         if not Preface_Received then
            if Input_Count < Client_Preface'Length then
               return;
            end if;
            for Offset in 0 .. Client_Preface'Length - 1 loop
               if Input
                 (Input'First + Stream_Element_Offset (Input_Head + Offset)) /=
                   Stream_Element
                     (Character'Pos
                       (Client_Preface (Client_Preface'First + Offset)))
               then
                  Protocol_Failure;
               end if;
            end loop;
            Input_Head := Input_Head + Client_Preface'Length;
            Input_Count := Input_Count - Client_Preface'Length;
            Preface_Received := True;
         end if;
         loop
            exit when Input_Count < Frames.Frame_Header_Size;
            declare
               Wire : Frames.Wire_Header;
            begin
               for Index in Wire'Range loop
                  Wire (Index) := Input
                    (Input'First + Stream_Element_Offset (Input_Head) +
                       Index - Wire'First);
               end loop;
               declare
                  Header : constant Frames.Header := Frames.Decode (Wire);
                  Total : constant Natural :=
                    Frames.Frame_Header_Size + Header.Length;
                  Validity : constant Frames.Header_Validity :=
                    Frames.Validate (Header);
               begin
                  if Validity /= Frames.Valid_Header then
                     --  For a malformed frame that fits the bounded input
                     --  buffer, wait for and consume its declared payload.
                     --  Closing a Linux socket while those bytes remain
                     --  unread can replace the queued GOAWAY with TCP RST.
                     if Total <= Input'Length and then Input_Count < Total then
                        return;
                     elsif Input_Count >= Total then
                        Consume_Input (Total);
                     end if;
                     Protocol_Failure
                       ((if Validity in
                            Frames.Frame_Too_Large | Frames.Invalid_Length
                         then Frames.Frame_Size_Error
                         else Frames.Protocol_Error_Code));
                  elsif Input_Count < Total then
                     return;
                  end if;
                  declare
                     Payload : Stream_Element_Array
                       (1 .. Stream_Element_Offset (Header.Length));
                  begin
                     if Header.Length > 0 then
                        for Offset in 0 .. Header.Length - 1 loop
                           Payload
                             (Payload'First +
                                Stream_Element_Offset (Offset)) :=
                               Input
                                 (Input'First + Stream_Element_Offset
                                   (Input_Head + Frames.Frame_Header_Size +
                                      Offset));
                        end loop;
                     end if;
                     Process_Frame (Header, Payload);
                  end;
                  Consume_Input (Total);
               end;
            end;
         end loop;
      end Parse_Input;

      procedure Drive (IO : in out Drivers.Capability) is
         Step : Drivers.Step_Result;
         Last : Stream_Element_Offset;
         Waited : Drivers.Wait_Result;
         Progress : Boolean;

         procedure Compact_Input is
         begin
            if Input_Head > 0 and then Input_Count > 0 then
               for Offset in 0 .. Input_Count - 1 loop
                  Input (Input'First + Stream_Element_Offset (Offset)) :=
                    Input (Input'First + Stream_Element_Offset
                      (Input_Head + Offset));
               end loop;
               Input_Head := 0;
            elsif Input_Count = 0 then
               Input_Head := 0;
            end if;
         end Compact_Input;
      begin
         loop
            Reap;
            Progress := False;
            if not Fatal and then not State.Streams.Control_Backlogged then
               begin
                  Parse_Input;
               exception
                  when Stop_Parsing => null;
               end;
            end if;
            --  A fatal input error supersedes any application DATA already
            --  selected for transmission.  Pull the queued GOAWAY first.
            if Fatal and then Have_Output then
               Have_Output := False;
            end if;
            if not Have_Output then
               State.Streams.Pull_Output
                 (Output, Output_Last, Have_Output);
               Output_Cursor := Output'First;
            end if;
            if Have_Output then
               Drivers.Send
                 (IO, Output (Output_Cursor .. Output_Last), Last, Step);
               case Step is
                  when Drivers.Made_Progress =>
                     if Last >= Output_Cursor then
                        Output_Cursor := Last + 1;
                        Progress := True;
                     end if;
                     if Output_Cursor > Output_Last then
                        Have_Output := False;
                     end if;
                  when Drivers.Peer_Closed => raise Stop_Pump;
                  when Drivers.Need_Read | Drivers.Need_Write => null;
               end case;
            end if;
            if Fatal and then not Have_Output then
               State.Streams.Pull_Output
                 (Output, Output_Last, Have_Output);
               Output_Cursor := Output'First;
               if not Have_Output then
                  raise Stop_Pump;
               end if;
            end if;
            if not Fatal and then not State.Streams.Control_Backlogged then
               if Input_Head + Input_Count = Input'Length
                 and then Input_Head > 0
               then
                  Compact_Input;
               end if;
               if Input_Head + Input_Count < Input'Length then
                  Drivers.Receive
                    (IO, Input
                      (Input'First + Stream_Element_Offset
                        (Input_Head + Input_Count) .. Input'Last), Last, Step);
                  case Step is
                     when Drivers.Made_Progress =>
                        if Last >= Input'First + Stream_Element_Offset
                          (Input_Head + Input_Count)
                        then
                           Input_Count := Natural
                             (Last - Input'First -
                                Stream_Element_Offset (Input_Head) + 1);
                           Progress := True;
                        end if;
                     when Drivers.Peer_Closed => raise Stop_Pump;
                     when Drivers.Need_Read | Drivers.Need_Write => null;
                  end case;
               end if;
            end if;
            if not Progress then
               Drivers.Wait
                 (IO, State.Outbound,
                  (if Have_Output then Drivers.Duplex_Interest
                   elsif Fatal then Drivers.Protocol_Only
                   else Drivers.Read_Interest),
                  Result => Waited);
            end if;
         end loop;
      end Drive;
   begin
      begin
         Drivers.Run
           (Channel, Drive'Access, Timeout => Max_Connection_Age,
            Token => Token);
      exception
         when Stop_Pump => null;
         when others =>
            State.Streams.Fail_All (Frames.Internal_Error);
      end;
      for Slot in Backends_By_Slot'Range loop
         if Backends_By_Slot (Slot) /= null then
            Backends_By_Slot (Slot).Token.Request;
         end if;
      end loop;
      for Slot in Handlers'Range loop
         if Handlers (Slot) /= null then
            --  Dynamic Ada tasks must terminate before their task object and
            --  backend are deallocated. A handler may still be unwinding
            --  application code after connection cancellation reaches it.
            while not Handlers (Slot).all'Terminated loop
               delay 0.001;
            end loop;
            Free_Handler (Handlers (Slot));
            Free_Backend (Backends_By_Slot (Slot));
         end if;
      end loop;
   end Serve;

end Flyology.HTTP.Server.HTTP_2;
