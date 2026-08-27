package body Flyology.HTTP.SSE_Client_Trace_Adapter is

   package Policy renames Flyology.HTTP.SSE_Client_Policy;

   procedure Initialize (Item : out State; Initial_Delay : Duration) is
   begin
      Policy.Initialize (Item.Value, Initial_Delay);
   end Initialize;

   procedure Connection_Accepted (Item : in out State) is
   begin
      Policy.Connection_Accepted (Item.Value);
   end Connection_Accepted;

   procedure Connection_No_Content (Item : in out State) is
   begin
      Policy.Connection_No_Content (Item.Value);
   end Connection_No_Content;

   procedure Set_Event_ID_Buffer
     (Item : in out State; Value : String) is
   begin
      Policy.Set_Event_ID_Buffer (Item.Value, Value);
   end Set_Event_ID_Buffer;

   procedure Set_Retry_Delay
     (Item : in out State; Value : Duration) is
   begin
      Policy.Set_Retry_Delay (Item.Value, Value);
   end Set_Retry_Delay;

   procedure Dispatch_Event (Item : in out State) is
   begin
      Policy.Dispatch_Event (Item.Value);
   end Dispatch_Event;

   procedure End_Of_Body (Item : in out State) is
   begin
      Policy.End_Of_Body (Item.Value);
   end End_Of_Body;

   procedure Reconnect_Wait_Elapsed (Item : in out State) is
   begin
      Policy.Reconnect_Wait_Elapsed (Item.Value);
   end Reconnect_Wait_Elapsed;

   function Current_Phase (Item : State) return Phase is
     (case Policy.Current_Phase (Item.Value) is
         when Policy.Connecting => Connecting,
         when Policy.Open       => Open,
         when Policy.Waiting    => Waiting,
         when Policy.Stopped    => Stopped,
         when Policy.Failed     => Failed);

   function Last_Event_ID (Item : State) return String is
     (Policy.Last_Event_ID (Item.Value));

   function Event_ID_Buffer (Item : State) return String is
     (Policy.Event_ID_Buffer (Item.Value));

   function Sent_Last_Event_ID (Item : State) return String is
     (Policy.Sent_Last_Event_ID (Item.Value));

   function Reconnect_Delay (Item : State) return Duration is
     (Policy.Reconnect_Delay (Item.Value));

   function Selected_Wait_Delay (Item : State) return Duration is
     (Policy.Selected_Wait_Delay (Item.Value));

end Flyology.HTTP.SSE_Client_Trace_Adapter;
