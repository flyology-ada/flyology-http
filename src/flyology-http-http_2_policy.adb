package body Flyology.HTTP.HTTP_2_Policy
  with SPARK_Mode => On
is

   function Transition
     (State : Stream_State;
      Event : Stream_Event) return Stream_Transition
   is
   begin
      case Event is
         when Open_Stream =>
            if State = Idle then
               return (Accepted => True, State => Open);
            end if;

         when End_Local =>
            case State is
               when Open =>
                  return (Accepted => True, State => Half_Closed_Local);
               when Half_Closed_Remote =>
                  return (Accepted => True, State => Closed);
               when others =>
                  null;
            end case;

         when End_Remote =>
            case State is
               when Open =>
                  return (Accepted => True, State => Half_Closed_Remote);
               when Half_Closed_Local =>
                  return (Accepted => True, State => Closed);
               when others =>
                  null;
            end case;

         when Reset_Stream =>
            if State in Open | Half_Closed_Local | Half_Closed_Remote then
               return (Accepted => True, State => Closed);
            end if;
      end case;

      return (Accepted => False, State => State);
   end Transition;

   function Consume
     (Window : Window_Size;
      Length : Data_Length) return Window_Result
   is
   begin
      if Window >= 0 and then Length <= Window then
         return (Accepted => True, Window => Window - Length);
      end if;
      return (Accepted => False, Window => Window);
   end Consume;

   function Increase
     (Window    : Window_Size;
      Increment : Window_Increment) return Window_Result
   is
   begin
      if Window <= Maximum_Window - Increment then
         return (Accepted => True, Window => Window + Increment);
      end if;
      return (Accepted => False, Window => Window);
   end Increase;

   function Adjust_Initial_Window
     (Window : Window_Size;
      Change : Window_Size) return Window_Result
   is
   begin
      if Change >= Window_Size'First - Window
        and then Change <= Window_Size'Last - Window
      then
         return (Accepted => True, Window => Window + Change);
      end if;
      return (Accepted => False, Window => Window);
   end Adjust_Initial_Window;

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
   is
      Eligible : constant Boolean :=
        not Already_Retried
          and then Idempotent
          and then not Saw_Response
          and then not Source_Failed
          and then Time_Remains
          and then Replay /= One_Shot_Stream
          and then
            (Cause = Refused_Stream or else Stream_Id > Last_Stream_Id);
   begin
      if not Eligible then
         return Propagate_Failure;
      elsif Replay = Direct_Replay then
         return Retry_Directly;
      else
         return Rewind_And_Retry;
      end if;
   end Classify_Retry;

end Flyology.HTTP.HTTP_2_Policy;
