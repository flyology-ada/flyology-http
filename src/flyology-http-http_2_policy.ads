private package Flyology.HTTP.HTTP_2_Policy
  with SPARK_Mode => On
is

   --  Pure HTTP/2 stream, flow-control, and replay decisions.  Keeping these
   --  decisions separate from the connection pump makes every transition
   --  independently testable and suitable for proof.

   type Stream_State is
     (Idle, Open, Half_Closed_Local, Half_Closed_Remote, Closed);

   type Stream_Event is
     (Open_Stream,
      End_Local,
      End_Remote,
      Reset_Stream);

   type Stream_Transition is record
      Accepted : Boolean;
      State    : Stream_State;
   end record;

   function Transition
     (State : Stream_State;
      Event : Stream_Event) return Stream_Transition
   with
     Global => null,
     Post   =>
       (if Transition'Result.Accepted
        then Transition'Result.State /= Idle
        else Transition'Result.State = State);

   Maximum_Window : constant := 2 ** 31 - 1;
   subtype Window_Size is
     Long_Long_Integer range -Maximum_Window .. Maximum_Window;
   subtype Window_Increment is Long_Long_Integer range 1 .. Maximum_Window;
   subtype Data_Length is Long_Long_Integer range 0 .. Maximum_Window;

   type Window_Result is record
      Accepted : Boolean;
      Window   : Window_Size;
   end record;

   function Consume
     (Window : Window_Size;
      Length : Data_Length) return Window_Result
   with
     Global => null,
     Post   =>
       (if Consume'Result.Accepted
        then Window >= 0
          and then Length <= Window
          and then Consume'Result.Window = Window - Length
        else Consume'Result.Window = Window);

   function Increase
     (Window    : Window_Size;
      Increment : Window_Increment) return Window_Result
   with
     Global => null,
     Post   =>
       (if Increase'Result.Accepted
        then Window <= Maximum_Window - Increment
          and then Increase'Result.Window = Window + Increment
        else Increase'Result.Window = Window);

   --  SETTINGS_INITIAL_WINDOW_SIZE changes can legitimately make an existing
   --  stream window negative.  They must still reject arithmetic outside the
   --  HTTP/2 signed window domain.
   function Adjust_Initial_Window
     (Window : Window_Size;
      Change : Window_Size) return Window_Result
   with
     Global => null,
     Post   =>
       (if Adjust_Initial_Window'Result.Accepted
        then Change >= Window_Size'First - Window
          and then Change <= Window_Size'Last - Window
          and then Adjust_Initial_Window'Result.Window = Window + Change
        else Adjust_Initial_Window'Result.Window = Window);

   type Replay_Kind is
     (Direct_Replay, One_Shot_Stream, Rewindable_Stream);
   type Retry_Cause is (Go_Away_Unprocessed, Refused_Stream);
   type Retry_Action is
     (Propagate_Failure, Retry_Directly, Rewind_And_Retry);

   function Classify_Retry
     (Cause           : Retry_Cause;
      Replay          : Replay_Kind;
      Stream_Id       : Natural;
      Last_Stream_Id  : Natural;
      Already_Retried : Boolean;
      Idempotent      : Boolean;
      Saw_Response    : Boolean;
      Source_Failed   : Boolean;
      Time_Remains    : Boolean) return Retry_Action
   with
     Global => null,
     Post   =>
       (if Classify_Retry'Result /= Propagate_Failure
        then Idempotent
          and then not Already_Retried
          and then not Saw_Response
          and then not Source_Failed
          and then Time_Remains
          and then Replay /= One_Shot_Stream
          and then
            (Cause = Refused_Stream or else Stream_Id > Last_Stream_Id));

end Flyology.HTTP.HTTP_2_Policy;
