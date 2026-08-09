with Ada.Command_Line;
with Flyology.Execution_Groups;
with Flyology.IO;

procedure HTTP3_Stress_Runtime_Probe is
   Expected_Loops : constant Flyology.Execution_Groups.Loop_Pool_Size :=
     (if Ada.Command_Line.Argument_Count = 0 then 1
      else Flyology.Execution_Groups.Loop_Pool_Size'Value
        (Ada.Command_Line.Argument (1)));

   protected Result is
      procedure Finish (Lightweight : Boolean);
      entry Wait (Lightweight : out Boolean);
   private
      Done : Boolean := False;
      Is_Lightweight : Boolean := False;
   end Result;

   protected body Result is
      procedure Finish (Lightweight : Boolean) is
      begin
         Is_Lightweight := Lightweight;
         Done := True;
      end Finish;

      entry Wait (Lightweight : out Boolean) when Done is
      begin
         Lightweight := Is_Lightweight;
      end Wait;
   end Result;

   task Probe;

   task body Probe is
   begin
      Result.Finish (Flyology.IO.Is_Lightweight_Task);
   end Probe;

   Lightweight : Boolean;
begin
   Result.Wait (Lightweight);
   if not Lightweight then
      raise Program_Error with
        "HTTP/3 stress RTS does not default new tasks to lightweight mode";
   end if;
   if Flyology.Execution_Groups.Configured_Pool_Size /= Expected_Loops then
      raise Program_Error with
        "HTTP/3 stress RTS has an unexpected loop-pool size";
   end if;
end HTTP3_Stress_Runtime_Probe;
