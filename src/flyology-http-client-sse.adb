with Ada.Characters.Handling;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.HTTP.Headers;
with Flyology.IO;
with Flyology.Operations.Drivers;

package body Flyology.HTTP.Client.SSE is
   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Flyology.Operations.Terminal_Outcome;

   package Policy renames Flyology.HTTP.SSE_Client_Policy;
   use type Policy.Phase;

   procedure Free_Exchange is new Ada.Unchecked_Deallocation
     (Exchange_Operation, Exchange_Operation_Access);
   procedure Free_Timer is new Ada.Unchecked_Deallocation
     (Flyology.IO.Timers.Timer_Operation, Timer_Operation_Access);

   function Data (Item : Event) return String is
     (To_String (Item.Data_Value));

   function Event_Type (Item : Event) return String is
     (To_String (Item.Event_Type_Value));

   function Last_Event_ID (Item : Event) return String is
     (To_String (Item.Last_Event_ID_Value));

   function Last_Event_ID (Item : Event_Source) return String is
   begin
      if not Item.Initialized then
         raise Program_Error with "SSE event source is not initialized";
      end if;
      return Policy.Last_Event_ID (Item.Lifecycle);
   end Last_Event_ID;

   function Reconnect_Delay (Item : Event_Source) return Duration is
   begin
      if not Item.Initialized then
         raise Program_Error with "SSE event source is not initialized";
      end if;
      return Policy.Reconnect_Delay (Item.Lifecycle);
   end Reconnect_Delay;

   function Remaining (Value : Monotonic_Deadline) return Duration is
   begin
      if not Value.Is_Limited then
         return Flyology.IO.Infinite;
      elsif Ada.Real_Time.Clock >= Value.Value then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration (Value.Value - Ada.Real_Time.Clock);
      end if;
   end Remaining;

   procedure Check_Control
     (Item  : Event_Source;
      Token : access Flyology.Cancellation.Token) is
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Expired (Item.Deadline) then
         raise Flyology.IO.Timeout_Error;
      end if;
   end Check_Control;

   function Equal_CI (Left, Right : String) return Boolean is
     (Ada.Characters.Handling.To_Lower (Left) =
        Ada.Characters.Handling.To_Lower (Right));

   function Trim_OWS (Value : String) return String is
      First : Natural := Value'First;
      Last  : Natural := Value'Last;
   begin
      while First <= Last
        and then Value (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Value (Last) in ' ' | Character'Val (9) loop
         Last := Last - 1;
      end loop;
      return Value (First .. Last);
   end Trim_OWS;

   function Decode_UTF8 (Value : String) return String is
      Replacement : constant String :=
        (Character'Val (16#EF#),
         Character'Val (16#BF#),
         Character'Val (16#BD#));
      Result      : Unbounded_String;
      Index       : Natural := Value'First;
   begin
      while Index <= Value'Last loop
         declare
            First          : constant Natural :=
              Character'Pos (Value (Index));
            Count          : Natural := 0;
            Second_Minimum : Natural := 16#80#;
            Second_Maximum : Natural := 16#BF#;
         begin
            if First <= 16#7F# then
               Append (Result, Value (Index));
               Index := Index + 1;
            elsif First in 16#C2# .. 16#DF# then
               Count := 2;
            elsif First in 16#E0# .. 16#EF# then
               Count := 3;
               if First = 16#E0# then
                  Second_Minimum := 16#A0#;
               elsif First = 16#ED# then
                  Second_Maximum := 16#9F#;
               end if;
            elsif First in 16#F0# .. 16#F4# then
               Count := 4;
               if First = 16#F0# then
                  Second_Minimum := 16#90#;
               elsif First = 16#F4# then
                  Second_Maximum := 16#8F#;
               end if;
            else
               Append (Result, Replacement);
               Index := Index + 1;
            end if;

            if Count > 0 then
               declare
                  Valid          : Boolean := True;
                  Missing        : Boolean := False;
                  Failure_Offset : Natural := 0;
               begin
                  for Offset in 1 .. Count - 1 loop
                     if Index + Offset > Value'Last then
                        Valid := False;
                        Missing := True;
                        exit;
                     end if;
                     declare
                        Next : constant Natural :=
                          Character'Pos (Value (Index + Offset));
                        Minimum : constant Natural :=
                          (if Offset = 1 then Second_Minimum else 16#80#);
                        Maximum : constant Natural :=
                          (if Offset = 1 then Second_Maximum else 16#BF#);
                     begin
                        if Next not in Minimum .. Maximum then
                           Valid := False;
                           Failure_Offset := Offset;
                           exit;
                        end if;
                     end;
                  end loop;
                  if Valid then
                     Append (Result, Value (Index .. Index + Count - 1));
                     Index := Index + Count;
                  else
                     Append (Result, Replacement);
                     Index :=
                       (if Missing then Value'Last + 1
                        else Index + Failure_Offset);
                  end if;
               end;
            end if;
         end;
      end loop;
      return To_String (Result);
   end Decode_UTF8;

   function Retained_Bytes (Item : Event_Source) return Natural is
     (Length (Item.Line) + Length (Item.Data_Buffer)
      + Length (Item.Event_Type_Buffer)
      + Policy.Last_Event_ID (Item.Lifecycle)'Length
      + Policy.Event_ID_Buffer (Item.Lifecycle)'Length
      + Policy.Sent_Last_Event_ID (Item.Lifecycle)'Length
      + Length (Item.Start_Bytes));

   procedure Require_Capacity (Item : Event_Source; Added : Natural) is
   begin
      if Added > Item.Maximum_Event_Bytes
        or else Retained_Bytes (Item) > Item.Maximum_Event_Bytes - Added
      then
         raise Event_Too_Large with
           "SSE retained event bytes exceed caller bound";
      end if;
   end Require_Capacity;

   procedure Require_Replacement
     (Item                : Event_Source;
      Existing_Length     : Natural;
      Replacement_Length  : Natural) is
      Retained : constant Natural := Retained_Bytes (Item);
      Other    : constant Natural := Retained - Existing_Length;
   begin
      if Replacement_Length > Item.Maximum_Event_Bytes
        or else Other > Item.Maximum_Event_Bytes - Replacement_Length
      then
         raise Event_Too_Large with
           "SSE retained event bytes exceed caller bound";
      end if;
   end Require_Replacement;

   procedure Replace_Bounded
     (Item   : Event_Source;
      Target : in out Unbounded_String;
      Value  : String) is
   begin
      Require_Replacement (Item, Length (Target), Value'Length);
      Target := To_Unbounded_String (Value);
   end Replace_Bounded;

   procedure Append_Bounded
     (Item : Event_Source; Target : in out Unbounded_String; Value : String) is
   begin
      Require_Capacity (Item, Value'Length);
      Append (Target, Value);
   end Append_Bounded;

   procedure Reset_Parser (Item : in out Event_Source) is
   begin
      Item.Line := Null_Unbounded_String;
      Item.Data_Buffer := Null_Unbounded_String;
      Item.Event_Type_Buffer := Null_Unbounded_String;
      Item.Start_Bytes := Null_Unbounded_String;
      Item.At_Stream_Start := True;
      Item.Skip_Next_LF := False;
      Item.Pending := Null_Unbounded_String;
      Item.Pending_Cursor := 0;
      Item.Body_Finished := False;
   end Reset_Parser;

   procedure Replace_Controlled_Headers
     (Value : in out Request; Last_ID : String) is
      Replacement : Flyology.HTTP.Headers.List
        (Value.Fields.Capacity, Value.Fields.Max_Bytes);
   begin
      for Index in 1 .. Flyology.HTTP.Headers.Count (Value.Fields) loop
         declare
            Name : constant String :=
              Flyology.HTTP.Headers.Name (Value.Fields, Index);
         begin
            if not Equal_CI (Name, "accept")
              and then not Equal_CI (Name, "last-event-id")
            then
               Flyology.HTTP.Headers.Add
                 (Replacement, Name,
                  Flyology.HTTP.Headers.Value (Value.Fields, Index));
            end if;
         end;
      end loop;
      --  WHATWG's EventSource fetch supplies this Accept value and sends the
      --  last event ID only when that value is nonempty.
      Flyology.HTTP.Headers.Add (Replacement, "Accept", "text/event-stream");
      if Last_ID /= "" then
         Flyology.HTTP.Headers.Add (Replacement, "Last-Event-ID", Last_ID);
      end if;
      Value.Fields := Replacement;
   end Replace_Controlled_Headers;

   procedure Open
     (Item                    : in out Event_Source;
      Value                   : Request;
      Initial_Reconnect_Delay : Duration;
      Maximum_Reconnect_Delay : Duration;
      Deadline                : Monotonic_Deadline) is
   begin
      if Item.Read_Active then
         raise Program_Error with "SSE read operation is active";
      elsif Initial_Reconnect_Delay < 0.0
        or else Maximum_Reconnect_Delay < 0.0
        or else Initial_Reconnect_Delay > Maximum_Reconnect_Delay
      then
         raise Constraint_Error with "invalid SSE reconnect delay bounds";
      end if;
      Finalize (Item.Reply);
      Item.Template := Value;
      Set_Method (Item.Template, To_Method ("GET"));
      Set_Body (Item.Template, "");
      Flyology.HTTP.Headers.Clear (Item.Template.Trailer_Fields);
      Item.Template.Expect_Continue := False;
      Item.Initialized := True;
      Item.Connected := False;
      Item.Deadline := Deadline;
      Item.Maximum_Delay := Maximum_Reconnect_Delay;
      Policy.Initialize (Item.Lifecycle, Initial_Reconnect_Delay);
      Reset_Parser (Item);
   end Open;

   function Is_Event_Stream (Item : Response) return Boolean is
   begin
      if Header_Count (Item, "content-type") /= 1 then
         return False;
      end if;
      declare
         Value     : constant String := Header (Item, "content-type");
         Semicolon : constant Natural := Ada.Strings.Fixed.Index (Value, ";");
         Last      : constant Natural :=
           (if Semicolon = 0 then Value'Last else Semicolon - 1);
      begin
         return Last >= Value'First
           and then Equal_CI (Trim_OWS (Value (Value'First .. Last)),
                              "text/event-stream");
      end;
   end Is_Event_Stream;

   procedure Parse_Retry (Item : in out Event_Source; Value : String) is
   begin
      if Value = "" then
         return;
      end if;
      for C of Value loop
         if C not in '0' .. '9' then
            return;
         end if;
      end loop;
      declare
         Reconnect_Value : Duration;
      begin
         begin
            Reconnect_Value :=
              Policy.Retry_Delay_From_Milliseconds (Value);
         exception
            when Constraint_Error =>
               raise Reconnect_Delay_Too_Large with
                 "SSE retry field exceeds caller maximum";
         end;
         if Reconnect_Value > Item.Maximum_Delay then
            raise Reconnect_Delay_Too_Large with
              "SSE retry field exceeds caller maximum";
         end if;
         Policy.Set_Retry_Delay (Item.Lifecycle, Reconnect_Value);
      end;
   end Parse_Retry;

   procedure Process_Field (Item : in out Event_Source; Raw : String) is
   begin
      if Raw = "" then
         return;
      end if;
      declare
         Decoded     : constant String := Decode_UTF8 (Raw);
         Colon       : constant Natural :=
           Ada.Strings.Fixed.Index (Decoded, ":");
         Name_Last   : constant Natural :=
           (if Colon = 0 then Decoded'Last else Colon - 1);
         Value_First : Natural :=
           (if Colon = 0 then Decoded'Last + 1 else Colon + 1);
      begin
         if Decoded (Decoded'First) /= ':' then
            if Value_First <= Decoded'Last
              and then Decoded (Value_First) = ' '
            then
               Value_First := Value_First + 1;
            end if;
            declare
               Name  : constant String :=
                 Decoded (Decoded'First .. Name_Last);
               Value : constant String :=
                 Decoded (Value_First .. Decoded'Last);
            begin
               if Name = "data" then
                  Append_Bounded
                    (Item, Item.Data_Buffer, Value & Character'Val (10));
               elsif Name = "event" then
                  Replace_Bounded (Item, Item.Event_Type_Buffer, Value);
               elsif Name = "id" then
                  if (for all C of Value => C /= Character'Val (0)) then
                     Require_Replacement
                       (Item,
                        Policy.Event_ID_Buffer (Item.Lifecycle)'Length,
                        Value'Length);
                     Policy.Set_Event_ID_Buffer (Item.Lifecycle, Value);
                  end if;
               elsif Name = "retry" then
                  Parse_Retry (Item, Value);
               end if;
            end;
         end if;
      end;
   end Process_Field;

   procedure Finish_Line
     (Item      : in out Event_Source;
      Available : out Boolean;
      Value     : out Event) is
   begin
      Available := False;
      if Length (Item.Line) = 0 then
         Policy.Dispatch_Event (Item.Lifecycle);
         if Length (Item.Data_Buffer) > 0 then
            declare
               Text : constant String := To_String (Item.Data_Buffer);
            begin
               Value.Data_Value := To_Unbounded_String
                 (Text (Text'First .. Text'Last - 1));
            end;
            Value.Event_Type_Value :=
              (if Length (Item.Event_Type_Buffer) = 0
               --  WHATWG assigns message when no event field was supplied.
               then To_Unbounded_String ("message")
               else Item.Event_Type_Buffer);
            Value.Last_Event_ID_Value := To_Unbounded_String
              (Policy.Last_Event_ID (Item.Lifecycle));
            Available := True;
         end if;
         Item.Data_Buffer := Null_Unbounded_String;
         Item.Event_Type_Buffer := Null_Unbounded_String;
      else
         Process_Field (Item, To_String (Item.Line));
      end if;
      Item.Line := Null_Unbounded_String;
   end Finish_Line;

   procedure Process_Octet
     (Item      : in out Event_Source;
      C         : Character;
      Available : out Boolean;
      Value     : out Event);

   procedure Process_Octet
     (Item      : in out Event_Source;
      C         : Character;
      Available : out Boolean;
      Value     : out Event) is
   begin
      Available := False;
      if Item.Skip_Next_LF then
         Item.Skip_Next_LF := False;
         if C = Character'Val (10) then
            return;
         end if;
      end if;
      if C = Character'Val (13) then
         Finish_Line (Item, Available, Value);
         Item.Skip_Next_LF := True;
      elsif C = Character'Val (10) then
         Finish_Line (Item, Available, Value);
      else
         Append_Bounded (Item, Item.Line, String'(1 => C));
      end if;
   end Process_Octet;

   procedure Process_Stream_Octet
     (Item      : in out Event_Source;
      C         : Character;
      Available : out Boolean;
      Value     : out Event) is
   begin
      Available := False;
      if not Item.At_Stream_Start then
         Process_Octet (Item, C, Available, Value);
         return;
      end if;
      Append_Bounded (Item, Item.Start_Bytes, String'(1 => C));
      declare
         Prefix : constant String := To_String (Item.Start_Bytes);
         Is_BOM_Prefix : constant Boolean :=
           (Prefix'Length = 1 and then Character'Pos (Prefix (1)) = 16#EF#)
           or else
           (Prefix'Length = 2
            and then Character'Pos (Prefix (1)) = 16#EF#
            and then Character'Pos (Prefix (2)) = 16#BB#);
      begin
         if Prefix'Length = 3 then
            Item.At_Stream_Start := False;
            Item.Start_Bytes := Null_Unbounded_String;
            if not (Character'Pos (Prefix (1)) = 16#EF#
                    and then Character'Pos (Prefix (2)) = 16#BB#
                    and then Character'Pos (Prefix (3)) = 16#BF#)
            then
               for Byte of Prefix loop
                  Process_Octet (Item, Byte, Available, Value);
                  exit when Available;
               end loop;
            end if;
         elsif not Is_BOM_Prefix then
            Item.At_Stream_Start := False;
            Item.Start_Bytes := Null_Unbounded_String;
            for Byte of Prefix loop
               Process_Octet (Item, Byte, Available, Value);
               exit when Available;
            end loop;
         end if;
      end;
   end Process_Stream_Octet;

   overriding procedure Write
     (Item : in out Event_Sink;
      Data : Ada.Streams.Stream_Element_Array)
   is
      Available : Boolean;
   begin
      if Item.Source = null then
         raise Program_Error with "SSE sink is detached";
      elsif Item.Available then
         return;
      end if;
      if Item.Source.Pending_Cursor = Length (Item.Source.Pending) then
         Item.Source.Pending := Null_Unbounded_String;
         Item.Source.Pending_Cursor := 0;
      end if;
      for Index in Data'Range loop
         Append
           (Item.Source.Pending,
            Character'Val (Ada.Streams.Stream_Element'Pos (Data (Index))));
      end loop;
      while Item.Source.Pending_Cursor < Length (Item.Source.Pending)
        and then not Item.Available
      loop
         Item.Source.Pending_Cursor := Item.Source.Pending_Cursor + 1;
         Process_Stream_Octet
           (Item.Source.all,
            Element (Item.Source.Pending, Item.Source.Pending_Cursor),
            Available, Item.Value);
         Item.Available := Available;
      end loop;
   end Write;

   overriding function Pause_Requested
     (Item : Event_Sink) return Boolean is
     (Item.Available);

   procedure Read
     (Item   : aliased in out Event_Source;
      Result : out Read_Result;
      Value  : out Event;
      Token  : access Flyology.Cancellation.Token := null)
   is
      --  The outer read, one exchange, and the exchange's deepest maintained
      --  resolver/transport child can coexist.  The reconnect timer reuses
      --  the released exchange slot.
      Set       : aliased Flyology.Operations.Completion_Set (4);
      Operation : Read_Operation := Read
        (Set'Access, Item'Unchecked_Access, Token);
   begin
      Flyology.Operations.Wait_All (Set);
      Finish (Operation, Result, Value);
   end Read;

   function Read
     (Set   : not null access Flyology.Operations.Completion_Set'Class;
      Item  : not null access Event_Source;
      Token : access Flyology.Cancellation.Token := null)
      return Read_Operation
   is
   begin
      return Result : Read_Operation (Set) do
         Read (Item, Token, Result);
      end return;
   end Read;

   procedure Read
     (Item      : not null access Event_Source;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Read_Operation) is
   begin
      if not Item.Initialized then
         raise Program_Error with "SSE event source is not initialized";
      elsif Item.Read_Active then
         raise Program_Error with
           "SSE event source already has an active read";
      end if;
      Operation.Source := Event_Source_Borrow'(Item.all'Unchecked_Access);
      Operation.Token :=
        (if Token = null
         then null
         else Token_Borrow'(Token.all'Unchecked_Access));
      Operation.Phase := Processing_Buffered;
      Operation.Result := Stream_Stopped;
      Operation.Value := (others => Null_Unbounded_String);
      Operation.Sink :=
        (Source => Operation.Source,
         Available => False,
         Value => (others => Null_Unbounded_String));
      Operation.Has_Error := False;
      Operation.Redirect_Hops := 0;
      Operation.Seen_Last := 0;
      Operation.Seen_Targets := (others => Null_Unbounded_String);
      if Operation.Exchange = null then
         Operation.Exchange := new Exchange_Operation
           (Operation.Set.all'Unchecked_Access);
      end if;
      if Operation.Timer = null then
         Operation.Timer := new Flyology.IO.Timers.Timer_Operation
           (Operation.Set.all'Unchecked_Access);
      end if;
      Item.Read_Active := True;
      Flyology.Operations.Drivers.Start (Operation);
      Flyology.Operations.Drive
        (Flyology.Operations.Operation'Class (Operation),
         Flyology.Operations.Start_Operation);
   exception
      when others =>
         Item.Read_Active := False;
         Operation.Source := null;
         Operation.Token := null;
         Operation.Sink.Source := null;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Read;

   overriding procedure Drive
     (Item  : in out Read_Operation;
      Cause : Flyology.Operations.Driver_Event)
   is
      pragma Unreferenced (Cause);
      procedure Save (Error : Ada.Exceptions.Exception_Occurrence) is
      begin
         Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
         Item.Has_Error := True;
      end Save;

      procedure Complete
        (Outcome : Flyology.Operations.Terminal_Outcome) is
      begin
         if Item.Source /= null then
            Item.Source.Read_Active := False;
         end if;
         Item.Source := null;
         Item.Token := null;
         Item.Sink.Source := null;
         Item.Phase := Read_Done;
         Flyology.Operations.Drivers.Complete (Item, Outcome);
      end Complete;

      procedure Move_Reply
        (Source : in out Response;
         Target : in out Response) is
      begin
         Finalize (Target);
         Target.Data := Source.Data;
         Source.Data := null;
      end Move_Reply;

      procedure Release_Exchange is
      begin
         if Item.Exchange /= null
           and then not Flyology.Operations.Is_Active (Item.Exchange.all)
           and then not Flyology.Operations.Is_Terminal (Item.Exchange.all)
         then
            Flyology.Operations.Release (Item.Exchange.all);
         end if;
      end Release_Exchange;

      procedure Begin_Reconnect is
         Interval : Duration :=
           Policy.Selected_Wait_Delay (Item.Source.Lifecycle);
      begin
         Finalize (Item.Source.Reply);
         Item.Source.Connected := False;
         if Item.Source.Deadline.Is_Limited then
            Interval := Duration'Min
              (Interval, Remaining (Item.Source.Deadline));
         end if;
         Flyology.IO.Timers.Sleep_For (Interval, Item.Timer.all);
         Item.Phase := Waiting_Reconnect;
         Flyology.Operations.Continue_After (Item, Item.Timer.all);
      end Begin_Reconnect;

      procedure Recover_Connection is
      begin
         Finalize (Item.Source.Reply);
         Item.Source.Connected := False;
         Policy.Connection_Recoverable_Failure (Item.Source.Lifecycle);
         Reset_Parser (Item.Source.all);
         Begin_Reconnect;
      end Recover_Connection;

      procedure Start_Current_Response_Head is
      begin
         Item.Request_Copy.Redirects := No_Redirects;
         Replace_Controlled_Headers
           (Item.Request_Copy,
            Policy.Sent_Last_Event_ID (Item.Source.Lifecycle));
         Exchange_To_Response
           (Client_Borrow (Item.Source.HTTP), Item.Request_Copy'Access,
            Item.Source.Deadline, Item.Token, Item.Exchange.all);
         Item.Phase := Waiting_Response_Head;
         Flyology.Operations.Continue_After (Item, Item.Exchange.all);
      end Start_Current_Response_Head;

      procedure Start_Response_Head is
      begin
         Item.Request_Copy := Item.Source.Template;
         Item.Redirect_Hops := 0;
         Item.Seen_Last := 0;
         Item.Seen_Targets := (others => Null_Unbounded_String);
         Item.Seen_Targets (0) := To_Unbounded_String
           (To_String (Item.Request_Copy.Target_Value));
         Start_Current_Response_Head;
      end Start_Response_Head;

      procedure Start_Response_Body is
      begin
         Item.Sink.Available := False;
         Item.Sink.Value := (others => Null_Unbounded_String);
         Resume_Response_To_Sink
            (Client_Borrow (Item.Source.HTTP), Item.Request_Copy'Access,
            Response_Borrow'(Item.Source.Reply'Unchecked_Access),
            Sink_Borrow'(Item.Sink'Unchecked_Access),
            Item.Source.Deadline, Item.Token, Item.Exchange.all);
         Item.Phase := Waiting_Response_Body;
         Flyology.Operations.Continue_After (Item, Item.Exchange.all);
      end Start_Response_Body;

      procedure Finish_Exchange
        (Result : out Exchange_Result;
         Reply  : out Response) is
      begin
         begin
            Flyology.HTTP.Client.Finish
              (Item.Exchange.all, Result, Reply);
         exception
            when others =>
               Release_Exchange;
               raise;
         end;
         Release_Exchange;
      end Finish_Exchange;

      procedure Handle_Exchange_Failure
        (Result : Exchange_Result) is
      begin
         case Kind (Result) is
            when Connection_Failed | Transport_Failed | Response_Invalid =>
               Recover_Connection;
            when Cancelled =>
               raise Flyology.Cancellation.Operation_Cancelled;
            when Timed_Out =>
               raise Flyology.IO.Timeout_Error;
            when Client_Unavailable =>
               raise Client_Closed;
            when others =>
               raise Invalid_Event_Stream with
                 "SSE HTTP exchange failed during " &
                 Exchange_Phase'Image (Phase (Result));
         end case;
      end Handle_Exchange_Failure;

      procedure Finish_Response_Head is
         Exchange_Result_Value : Exchange_Result;
         Reply                 : Response;

         procedure Follow_Redirect is
            Location_Count : constant Natural :=
              Header_Count (Reply, "location");
            Next_Target : Unbounded_String;
            Is_Same     : Boolean;
         begin
            if Location_Count /= 1 then
               raise Redirect_Error with
                 "redirect response must have one Location field";
            elsif Item.Redirect_Hops =
              Item.Source.Template.Redirects.Maximum_Hops
            then
               raise Redirect_Error with "redirect hop limit exceeded";
            end if;
            Resolve_Redirect_Target
              (Client_Borrow (Item.Source.HTTP),
               To_String (Item.Request_Copy.Target_Value),
               Header (Reply, "location"), Next_Target, Is_Same);
            if not Is_Same then
               raise Redirect_Error with
                 "redirect target is outside the configured origin";
            end if;
            for Index in Redirect_Limit range 0 .. Item.Seen_Last loop
               if Item.Seen_Targets (Index) = Next_Target then
                  raise Redirect_Error with "redirect loop detected";
               end if;
            end loop;
            Finalize (Reply);
            Item.Redirect_Hops := Item.Redirect_Hops + 1;
            Item.Seen_Last := Item.Seen_Last + 1;
            Item.Seen_Targets (Item.Seen_Last) := Next_Target;
            Set_Target (Item.Request_Copy, To_String (Next_Target));
            Item.Phase := Starting_Response_Head;
            --  A dependency callback must not create a child whose first
            --  immediate step is invisible to the current completion-set
            --  snapshot.  A due owner deadline schedules the next bounded
            --  child start in the following snapshot.
            Flyology.Operations.Drivers.Arm_Deadline (Item, 0.0);
         end Follow_Redirect;
      begin
         Finish_Exchange (Exchange_Result_Value, Reply);
         if Kind (Exchange_Result_Value) /= Response_Complete then
            Handle_Exchange_Failure (Exchange_Result_Value);
         elsif Status (Reply) = 204 then
            Policy.Connection_No_Content (Item.Source.Lifecycle);
            Finalize (Reply);
            Item.Source.Connected := False;
            Item.Result := Stream_Stopped;
            Complete (Flyology.Operations.Succeeded);
         elsif Status (Reply) in 301 | 302 | 303 | 307 | 308
           and then Item.Source.Template.Redirects.Mode = Follow_Same_Origin
           and then Header_Count (Reply, "location") > 0
         then
            Follow_Redirect;
         elsif Status (Reply) /= 200 then
            Policy.Connection_Fatal_Failure (Item.Source.Lifecycle);
            raise Invalid_Event_Stream with
              "SSE response status is" & Status_Code'Image (Status (Reply));
         elsif not Is_Event_Stream (Reply) then
            Policy.Connection_Fatal_Failure (Item.Source.Lifecycle);
            raise Invalid_Event_Stream with
              "SSE response Content-Type is not text/event-stream";
         else
            Move_Reply (Reply, Item.Source.Reply);
            Policy.Connection_Accepted (Item.Source.Lifecycle);
            Item.Source.Connected := True;
            Reset_Parser (Item.Source.all);
            Item.Phase := Processing_Buffered;
            Flyology.Operations.Drivers.Arm_Deadline (Item, 0.0);
         end if;
      end Finish_Response_Head;

      procedure Finish_Response_Body is
         Exchange_Result_Value : Exchange_Result;
         Reply                 : Response;
      begin
         Finish_Exchange (Exchange_Result_Value, Reply);
         if Kind (Exchange_Result_Value) /= Response_Complete then
            Handle_Exchange_Failure (Exchange_Result_Value);
         elsif Item.Sink.Available then
            Move_Reply (Reply, Item.Source.Reply);
            Item.Source.Connected := True;
            Item.Result := Event_Available;
            Item.Value := Item.Sink.Value;
            Complete (Flyology.Operations.Succeeded);
         else
            Finalize (Reply);
            Item.Source.Connected := False;
            Policy.End_Of_Body (Item.Source.Lifecycle);
            Reset_Parser (Item.Source.all);
            Begin_Reconnect;
         end if;
      end Finish_Response_Body;

      procedure Process_Buffered is
         Available : Boolean;
         Value     : Event;
      begin
         Check_Control (Item.Source.all, Item.Token);
         if Policy.Current_Phase (Item.Source.Lifecycle) = Policy.Stopped then
            Item.Result := Stream_Stopped;
            Complete (Flyology.Operations.Succeeded);
         elsif Item.Source.Pending_Cursor < Length (Item.Source.Pending) then
            Item.Source.Pending_Cursor := Item.Source.Pending_Cursor + 1;
            Process_Stream_Octet
              (Item.Source.all,
               Element (Item.Source.Pending, Item.Source.Pending_Cursor),
               Available, Value);
            if Available then
               Item.Result := Event_Available;
               Item.Value := Value;
               Complete (Flyology.Operations.Succeeded);
            else
               Flyology.Operations.Drivers.Reschedule (Item);
            end if;
         else
            Item.Source.Pending := Null_Unbounded_String;
            Item.Source.Pending_Cursor := 0;
            if Item.Source.Connected then
               if Body_Complete (Item.Source.Reply) then
                  Finalize (Item.Source.Reply);
                  Item.Source.Connected := False;
                  Policy.End_Of_Body (Item.Source.Lifecycle);
                  Reset_Parser (Item.Source.all);
                  Begin_Reconnect;
               else
                  Start_Response_Body;
               end if;
            elsif Policy.Current_Phase (Item.Source.Lifecycle) = Policy.Waiting
            then
               Begin_Reconnect;
            else
               Start_Response_Head;
            end if;
         end if;
      end Process_Buffered;
   begin
      case Item.Phase is
         when Processing_Buffered =>
            Process_Buffered;
         when Starting_Response_Head =>
            Check_Control (Item.Source.all, Item.Token);
            Start_Current_Response_Head;
         when Waiting_Reconnect =>
            Flyology.IO.Timers.Finish (Item.Timer.all);
            Flyology.Operations.Release (Item.Timer.all);
            Policy.Reconnect_Wait_Elapsed (Item.Source.Lifecycle);
            Check_Control (Item.Source.all, Item.Token);
            Item.Phase := Processing_Buffered;
            Flyology.Operations.Drivers.Arm_Deadline (Item, 0.0);
         when Waiting_Response_Head =>
            Finish_Response_Head;
         when Waiting_Response_Body =>
            Finish_Response_Body;
         when Read_Idle | Read_Done =>
            raise Program_Error with "SSE read operation is not driveable";
      end case;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         if Item.Source /= null then
            Finalize (Item.Source.Reply);
            Item.Source.Connected := False;
            Policy.Stop (Item.Source.Lifecycle);
         end if;
         Complete (Flyology.Operations.Cancelled);
      when Error : Flyology.IO.Timeout_Error =>
         Save (Error);
         if Item.Source /= null then
            Finalize (Item.Source.Reply);
            Item.Source.Connected := False;
            Policy.Stop (Item.Source.Lifecycle);
         end if;
         Complete (Flyology.Operations.Failed);
      when Error : others =>
         Save (Error);
         if Item.Source /= null then
            Finalize (Item.Source.Reply);
            Item.Source.Connected := False;
            if Policy.Current_Phase (Item.Source.Lifecycle) in
              Policy.Connecting | Policy.Open
            then
               Policy.Connection_Fatal_Failure (Item.Source.Lifecycle);
            end if;
         end if;
         Complete (Flyology.Operations.Failed);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Read_Operation) is
   begin
      case Item.Phase is
         when Waiting_Reconnect =>
            Flyology.Operations.Cancel (Item.Timer.all);
         when Waiting_Response_Head | Waiting_Response_Body =>
            Flyology.Operations.Cancel (Item.Exchange.all);
         when Processing_Buffered | Starting_Response_Head =>
            if Item.Source /= null then
               Finalize (Item.Source.Reply);
               Item.Source.Connected := False;
               Policy.Stop (Item.Source.Lifecycle);
            end if;
            if Item.Source /= null then
               Item.Source.Read_Active := False;
            end if;
            Item.Source := null;
            Item.Token := null;
            Item.Sink.Source := null;
            Item.Phase := Read_Done;
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Cancelled);
         when Read_Idle | Read_Done => null;
      end case;
   exception
      when others => null;
   end Request_Cancellation;

   overriding procedure Finalize (Item : in out Read_Operation) is
   begin
      begin
         Flyology.Operations.Finalize
           (Flyology.Operations.Operation (Item));
      exception
         when others => null;
      end;
      if Item.Source /= null then
         Item.Source.Read_Active := False;
      end if;
      Item.Source := null;
      Item.Token := null;
      Item.Sink.Source := null;
      Free_Exchange (Item.Exchange);
      Free_Timer (Item.Timer);
   end Finalize;

   procedure Finish
     (Operation : in out Read_Operation;
      Result    : out Read_Result;
      Value     : out Event)
   is
      Outcome : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      Result := Operation.Result;
      Value := Operation.Value;
      Flyology.Operations.Consume (Operation);
      if Outcome = Flyology.Operations.Cancelled then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Operation.Has_Error then
         Ada.Exceptions.Reraise_Occurrence (Operation.Saved_Error);
      end if;
   end Finish;

end Flyology.HTTP.Client.SSE;
