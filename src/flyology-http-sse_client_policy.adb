package body Flyology.HTTP.SSE_Client_Policy is
   use Ada.Strings.Unbounded;

   procedure Require_Phase (Item : State; Expected : Phase) is
   begin
      if Item.Phase_Value /= Expected then
         raise Program_Error with "invalid SSE lifecycle transition";
      end if;
   end Require_Phase;

   procedure Initialize (Item : out State; Initial_Delay : Duration) is
   begin
      if Initial_Delay < 0.0 then
         raise Constraint_Error with "negative SSE reconnect delay";
      end if;
      Item :=
        (Phase_Value       => Connecting,
         Last_ID_Value     => Null_Unbounded_String,
         Event_ID_Value    => Null_Unbounded_String,
         Sent_ID_Value     => Null_Unbounded_String,
         Retry_Delay_Value => Initial_Delay,
         Wait_Delay_Value  => Initial_Delay);
   end Initialize;

   procedure Connection_Accepted (Item : in out State) is
   begin
      Require_Phase (Item, Connecting);
      Item.Event_ID_Value := Null_Unbounded_String;
      Item.Phase_Value := Open;
   end Connection_Accepted;

   procedure Connection_No_Content (Item : in out State) is
   begin
      Require_Phase (Item, Connecting);
      Item.Phase_Value := Stopped;
   end Connection_No_Content;

   procedure Connection_Recoverable_Failure (Item : in out State) is
   begin
      if Item.Phase_Value not in Connecting | Open then
         raise Program_Error with "invalid recoverable SSE failure";
      end if;
      Item.Wait_Delay_Value := Item.Retry_Delay_Value;
      Item.Phase_Value := Waiting;
   end Connection_Recoverable_Failure;

   procedure Connection_Fatal_Failure (Item : in out State) is
   begin
      if Item.Phase_Value not in Connecting | Open then
         raise Program_Error with "invalid fatal SSE failure";
      end if;
      Item.Phase_Value := Failed;
   end Connection_Fatal_Failure;

   procedure Set_Event_ID_Buffer
     (Item : in out State; Value : String) is
   begin
      Require_Phase (Item, Open);
      Item.Event_ID_Value := To_Unbounded_String (Value);
   end Set_Event_ID_Buffer;

   procedure Set_Retry_Delay
     (Item : in out State; Value : Duration) is
   begin
      Require_Phase (Item, Open);
      if Value < 0.0 then
         raise Constraint_Error with "negative SSE reconnect delay";
      end if;
      Item.Retry_Delay_Value := Value;
   end Set_Retry_Delay;

   function Retry_Delay_From_Milliseconds
     (Value : String) return Duration
   is
      First_Digit : Positive := Value'First;
   begin
      while First_Digit < Value'Last
        and then Value (First_Digit) = '0'
      loop
         First_Digit := First_Digit + 1;
      end loop;
      declare
         Canonical : constant String := Value (First_Digit .. Value'Last);
      begin
         return
           (if Canonical'Length <= 3 then
               Duration'Value
                 ("0." &
                  String'(1 .. 3 - Canonical'Length => '0') & Canonical)
            else
               Duration'Value
                 (Canonical
                    (Canonical'First .. Canonical'Last - 3) &
                  "." & Canonical
                    (Canonical'Last - 2 .. Canonical'Last)));
      end;
   end Retry_Delay_From_Milliseconds;

   procedure Dispatch_Event (Item : in out State) is
   begin
      Require_Phase (Item, Open);
      Item.Last_ID_Value := Item.Event_ID_Value;
   end Dispatch_Event;

   procedure End_Of_Body (Item : in out State) is
   begin
      Require_Phase (Item, Open);
      Item.Wait_Delay_Value := Item.Retry_Delay_Value;
      Item.Phase_Value := Waiting;
   end End_Of_Body;

   procedure Reconnect_Wait_Elapsed (Item : in out State) is
   begin
      Require_Phase (Item, Waiting);
      Item.Sent_ID_Value := Item.Last_ID_Value;
      Item.Phase_Value := Connecting;
   end Reconnect_Wait_Elapsed;

   procedure Stop (Item : in out State) is
   begin
      if Item.Phase_Value not in Stopped | Failed then
         Item.Phase_Value := Stopped;
      end if;
   end Stop;

   function Current_Phase (Item : State) return Phase is
     (Item.Phase_Value);

   function Last_Event_ID (Item : State) return String is
     (To_String (Item.Last_ID_Value));

   function Event_ID_Buffer (Item : State) return String is
     (To_String (Item.Event_ID_Value));

   function Sent_Last_Event_ID (Item : State) return String is
     (To_String (Item.Sent_ID_Value));

   function Reconnect_Delay (Item : State) return Duration is
     (Item.Retry_Delay_Value);

   function Selected_Wait_Delay (Item : State) return Duration is
     (Item.Wait_Delay_Value);

end Flyology.HTTP.SSE_Client_Policy;
