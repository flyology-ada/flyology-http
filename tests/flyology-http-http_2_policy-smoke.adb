procedure Flyology.HTTP.HTTP_2_Policy.Smoke is

   procedure Check_Streams is
   begin
      pragma Assert (Transition (Idle, Open_Stream) = (True, Open));
      pragma Assert
        (Transition (Open, End_Local) = (True, Half_Closed_Local));
      pragma Assert
        (Transition (Open, End_Remote) = (True, Half_Closed_Remote));
      pragma Assert
        (Transition (Half_Closed_Local, End_Remote) = (True, Closed));
      pragma Assert
        (Transition (Half_Closed_Remote, End_Local) = (True, Closed));
      pragma Assert (Transition (Open, Reset_Stream) = (True, Closed));

      for State in Stream_State loop
         for Event in Stream_Event loop
            declare
               Result : constant Stream_Transition :=
                 Transition (State, Event);
            begin
               pragma Assert
                 (Result.Accepted or else Result.State = State);
               pragma Assert
                 (not Result.Accepted or else Result.State /= Idle);
            end;
         end loop;
      end loop;
   end Check_Streams;

   procedure Check_Flow_Control is
   begin
      pragma Assert (Consume (65_535, 16_384) = (True, 49_151));
      pragma Assert (Consume (1, 2) = (False, 1));
      pragma Assert (Consume (-1, 0) = (False, -1));
      pragma Assert
        (Increase (Maximum_Window - 1, 1) = (True, Maximum_Window));
      pragma Assert
        (Increase (Maximum_Window, 1) = (False, Maximum_Window));
      pragma Assert (Adjust_Initial_Window (1, -2) = (True, -1));
      pragma Assert
        (Adjust_Initial_Window
           (Maximum_Window, 1) = (False, Maximum_Window));
   end Check_Flow_Control;

   procedure Check_Retries is
   begin
      for Cause in Retry_Cause loop
         for Replay in Replay_Kind loop
            for Retried in Boolean loop
               for Idempotent in Boolean loop
                  for Saw_Response in Boolean loop
                     for Source_Failed in Boolean loop
                        for Time_Remains in Boolean loop
                           for Beyond_Go_Away in Boolean loop
                              declare
                                 Stream_Id : constant Natural :=
                                   (if Beyond_Go_Away then 5 else 3);
                                 Last_Id : constant Natural := 3;
                                 Eligible : constant Boolean :=
                                   not Retried
                                     and then Idempotent
                                     and then not Saw_Response
                                     and then not Source_Failed
                                     and then Time_Remains
                                     and then Replay /= One_Shot_Stream
                                     and then
                                       (Cause = Refused_Stream
                                          or else Beyond_Go_Away);
                                 Expected : constant Retry_Action :=
                                   (if not Eligible
                                    then Propagate_Failure
                                    elsif Replay = Direct_Replay
                                    then Retry_Directly
                                    else Rewind_And_Retry);
                              begin
                                 pragma Assert
                                   (Classify_Retry
                                      (Cause, Replay, Stream_Id, Last_Id,
                                       Retried, Idempotent, Saw_Response,
                                       Source_Failed, Time_Remains) =
                                    Expected);
                              end;
                           end loop;
                        end loop;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Check_Retries;

begin
   Check_Streams;
   Check_Flow_Control;
   Check_Retries;
end Flyology.HTTP.HTTP_2_Policy.Smoke;
