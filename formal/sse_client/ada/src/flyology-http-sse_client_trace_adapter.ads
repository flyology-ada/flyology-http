private with Flyology.HTTP.SSE_Client_Policy;

--  Test-only access to the production SSE reconnect policy for TLA+ replay.
package Flyology.HTTP.SSE_Client_Trace_Adapter is

   type Phase is (Connecting, Open, Waiting, Stopped, Failed);

   type State is private;

   procedure Initialize (Item : out State; Initial_Delay : Duration);

   procedure Connection_Accepted (Item : in out State);

   procedure Connection_No_Content (Item : in out State);

   procedure Set_Event_ID_Buffer
     (Item : in out State; Value : String);

   procedure Set_Retry_Delay
     (Item : in out State; Value : Duration);

   function Retry_Delay_From_Milliseconds (Value : String) return Duration;

   procedure Dispatch_Event (Item : in out State);

   procedure End_Of_Body (Item : in out State);

   procedure Reconnect_Wait_Elapsed (Item : in out State);

   function Current_Phase (Item : State) return Phase;

   function Last_Event_ID (Item : State) return String;

   function Event_ID_Buffer (Item : State) return String;

   function Sent_Last_Event_ID (Item : State) return String;

   function Reconnect_Delay (Item : State) return Duration;

   function Selected_Wait_Delay (Item : State) return Duration;

private
   type State is record
      Value : Flyology.HTTP.SSE_Client_Policy.State;
   end record;

end Flyology.HTTP.SSE_Client_Trace_Adapter;
