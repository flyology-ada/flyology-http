with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Flyology.HTTP.SSE_Client_Trace_Adapter;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with SSE_Client_Model;

procedure SSE_Client_Conformance is

   use Ada.Strings.Unbounded;
   use type SSE_Client_Model.Input_Id_Type;
   use type SSE_Client_Model.Input_TLA_Delay_Type;

   package Policy renames Flyology.HTTP.SSE_Client_Trace_Adapter;

   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 1_000,
      Maximum_JSON_Depth   => 64,
      Maximum_Object_Names => 10_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 500_000);

   type SSE_Adapter is new SSE_Client_Model.Adapter with record
      Buggy       : Boolean := False;
      Current     : Policy.State;
      Pc          : SSE_Client_Model.State_Pc_Type := 0;
      Last_Action : SSE_Client_Model.State_Last_Action_Type :=
        SSE_Client_Model.State_Last_Action_Init;
   end record;

   overriding procedure Reset
     (Self     : in out SSE_Adapter;
      Observed : out SSE_Client_Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding procedure Apply
     (Self         : in out SSE_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : SSE_Client_Model.Input_Type;
      Model_Source : String;
      Observed     : out SSE_Client_Model.Outcome_Type;
      State        : out SSE_Client_Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   function Phase_Of
     (Value : Policy.Phase) return SSE_Client_Model.State_Phase_Type is
     (case Value is
         when Policy.Connecting => SSE_Client_Model.State_Phase_Connecting,
         when Policy.Open       => SSE_Client_Model.State_Phase_Open,
         when Policy.Waiting    => SSE_Client_Model.State_Phase_Waiting,
         when Policy.Stopped    => SSE_Client_Model.State_Phase_Stopped,
         when Policy.Failed     => SSE_Client_Model.State_Phase_Failed);

   function Last_ID_Of
     (Value : String) return SSE_Client_Model.State_Last_Event_Id_Type is
     (if Value = "" then SSE_Client_Model.State_Last_Event_Id_None
      elsif Value = "one" then SSE_Client_Model.State_Last_Event_Id_One
      elsif Value = "two" then SSE_Client_Model.State_Last_Event_Id_Two
      else raise Program_Error with "unexpected last event ID");

   function Buffered_ID_Of
     (Value : String) return SSE_Client_Model.State_Event_Id_Buffer_Type is
     (if Value = "" then SSE_Client_Model.State_Event_Id_Buffer_None
      elsif Value = "one" then SSE_Client_Model.State_Event_Id_Buffer_One
      elsif Value = "two" then SSE_Client_Model.State_Event_Id_Buffer_Two
      else raise Program_Error with "unexpected buffered event ID");

   function Sent_ID_Of
     (Value : String) return SSE_Client_Model.State_Sent_Last_Event_Id_Type is
     (if Value = "" then SSE_Client_Model.State_Sent_Last_Event_Id_None
      elsif Value = "one" then SSE_Client_Model.State_Sent_Last_Event_Id_One
      elsif Value = "two" then SSE_Client_Model.State_Sent_Last_Event_Id_Two
      else raise Program_Error with "unexpected sent event ID");

   function Delay_Of
     (Value : Duration) return SSE_Client_Model.State_Retry_Delay_Type is
     (SSE_Client_Model.State_Retry_Delay_Type (Integer (Value)));

   function Wait_Of
     (Value : Duration) return SSE_Client_Model.State_Wait_Delay_Type is
     (SSE_Client_Model.State_Wait_Delay_Type (Integer (Value)));

   function Observe
     (Current     : Policy.State;
      Pc          : SSE_Client_Model.State_Pc_Type;
      Last_Action : SSE_Client_Model.State_Last_Action_Type)
      return SSE_Client_Model.State_Type is
     (Phase              => Phase_Of (Policy.Current_Phase (Current)),
      Last_Event_Id      => Last_ID_Of (Policy.Last_Event_ID (Current)),
      Event_Id_Buffer    => Buffered_ID_Of
        (Policy.Event_ID_Buffer (Current)),
      Sent_Last_Event_Id => Sent_ID_Of
        (Policy.Sent_Last_Event_ID (Current)),
      Retry_Delay        => Delay_Of (Policy.Reconnect_Delay (Current)),
      Wait_Delay         => Wait_Of
        (Policy.Selected_Wait_Delay (Current)),
      Pc                 => Pc,
      Last_Action        => Last_Action);

   procedure Reset
     (Self     : in out SSE_Adapter;
      Observed : out SSE_Client_Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome) is
   begin
      Policy.Initialize (Self.Current, Initial_Delay => 1.0);
      Self.Pc := 0;
      Self.Last_Action := SSE_Client_Model.State_Last_Action_Init;
      Observed := Observe (Self.Current, Self.Pc, Self.Last_Action);
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self         : in out SSE_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : SSE_Client_Model.Input_Type;
      Model_Source : String;
      Observed     : out SSE_Client_Model.Outcome_Type;
      State        : out SSE_Client_Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome) is
   begin
      if Role /= "lifecycle" or else Model_Source /= Action then
         Observed := (Accepted => False);
         State := Observe (Self.Current, Self.Pc, Self.Last_Action);
         Status :=
           (Succeeded => False,
            Detail    => To_Unbounded_String ("unsupported modeled action"));
         return;
      end if;

      if Action = "SSEClientTrace!ConnectionAccepted" then
         Policy.Connection_Accepted (Self.Current);
         Self.Last_Action :=
           SSE_Client_Model.State_Last_Action_Connection_Accepted;
      elsif Action = "SSEClientTrace!ReceiveRetry"
        and then Input.TLA_Delay = 2
      then
         Policy.Set_Retry_Delay
           (Self.Current, Duration (Input.TLA_Delay));
         Self.Last_Action := SSE_Client_Model.State_Last_Action_Receive_Retry;
      elsif Action = "SSEClientTrace!ReceiveIDOne"
        and then Input.Id = SSE_Client_Model.Input_Id_One
      then
         Policy.Set_Event_ID_Buffer (Self.Current, "one");
         Self.Last_Action := SSE_Client_Model.State_Last_Action_Receive_IDOne;
      elsif Action = "SSEClientTrace!ReceiveIDTwo"
        and then Input.Id = SSE_Client_Model.Input_Id_Two
      then
         Policy.Set_Event_ID_Buffer (Self.Current, "two");
         Self.Last_Action := SSE_Client_Model.State_Last_Action_Receive_IDTwo;
      elsif Action = "SSEClientTrace!DispatchEvent" then
         Policy.Dispatch_Event (Self.Current);
         Self.Last_Action := SSE_Client_Model.State_Last_Action_Dispatch_Event;
      elsif Action = "SSEClientTrace!EndOfBody" then
         Policy.End_Of_Body (Self.Current);
         Self.Last_Action := SSE_Client_Model.State_Last_Action_End_Of_Body;
      elsif Action = "SSEClientTrace!ReconnectWaitElapsed" then
         if not Self.Buggy then
            Policy.Reconnect_Wait_Elapsed (Self.Current);
         end if;
         Self.Last_Action :=
           SSE_Client_Model.State_Last_Action_Reconnect_Wait_Elapsed;
      elsif Action = "SSEClientTrace!ConnectionNoContent" then
         Policy.Connection_No_Content (Self.Current);
         Self.Last_Action :=
           SSE_Client_Model.State_Last_Action_Connection_No_Content;
      else
         Observed := (Accepted => False);
         State := Observe (Self.Current, Self.Pc, Self.Last_Action);
         Status :=
           (Succeeded => False,
            Detail    => To_Unbounded_String ("unsupported modeled input"));
         return;
      end if;

      Self.Pc := SSE_Client_Model.State_Pc_Type (Index);
      Observed := (Accepted => True);
      State := Observe (Self.Current, Self.Pc, Self.Last_Action);
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Apply;

   Flags : Flyology_TLA.Command_Line.Application_Flag_Array :=
     [1 => Flyology_TLA.Command_Line.Flag
       ("--buggy", "skip Last-Event-ID selection at reconnect")];

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration :=
        Flyology_TLA.Command_Line.Parse (Limits, Flags);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help (Flags);
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Command_Line.Load (Config);
         Adapter : SSE_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Adapter.Buggy := Flyology_TLA.Command_Line.Is_Set (Flags (1));
         SSE_Client_Model.Run
           (Adapter,
            Trace,
            Flyology_TLA.Command_Line.Limits (Config),
            Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail
        (Ada.Exceptions.Exception_Message (Error), Flags, Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail
        ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end SSE_Client_Conformance;
