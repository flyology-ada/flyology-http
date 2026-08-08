with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Client_Stress_Probe is
   package Client renames Flyology.HTTP.Client;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Flyology.HTTP.Protocol;

   Worker_Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 1 then 1
      else Positive'Value (Ada.Command_Line.Argument (1)));
   Requests_Per_Worker : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 2 then 100
      else Positive'Value (Ada.Command_Line.Argument (2)));
   Port : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 3 then 4_433
      else Positive'Value (Ada.Command_Line.Argument (3)));

   function Decimal (Value : Positive) return String is
      Image : constant String := Positive'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   HTTP : aliased Client.Client (Capacity => 32);

   protected Results is
      procedure Succeed (Elapsed : Duration);
      procedure Fail (Message : String);
      procedure Finish;
      entry Wait;
      function Successes return Natural;
      function Failures return Natural;
      function Mean return Duration;
      function Maximum return Duration;
      function First_Error return String;
   private
      Completed : Natural := 0;
      Passed : Natural := 0;
      Failed : Natural := 0;
      Total : Duration := 0.0;
      Max : Duration := 0.0;
      Detail : Unbounded_String;
   end Results;

   protected body Results is
      procedure Succeed (Elapsed : Duration) is
      begin
         Passed := Passed + 1;
         Total := Total + Elapsed;
         Max := Duration'Max (Max, Elapsed);
      end Succeed;

      procedure Fail (Message : String) is
      begin
         Failed := Failed + 1;
         if Length (Detail) = 0 then
            Detail := To_Unbounded_String (Message);
         end if;
      end Fail;

      procedure Finish is
      begin
         Completed := Completed + 1;
      end Finish;

      entry Wait when Completed = Worker_Count is
      begin
         null;
      end Wait;

      function Successes return Natural is (Passed);
      function Failures return Natural is (Failed);
      function Mean return Duration is
        (if Passed = 0 then 0.0 else Total / Passed);
      function Maximum return Duration is (Max);
      function First_Error return String is (To_String (Detail));
   end Results;

   task type Worker;

   task body Worker is
   begin
      for Iteration in 1 .. Requests_Per_Worker loop
         declare
            Value : Client.Request;
            Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            Client.Set_Target (Value, "/hello");
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Value, Timeout => 8.0);
               Body_Value : constant String :=
                 Flyology.Bytes.To_Byte_String (Client.Read_All (Reply));
               Elapsed : constant Duration :=
                 Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
            begin
               if Client.Status (Reply) = 200
                 and then Client.Negotiated_Protocol (Reply) =
                   Flyology.HTTP.HTTP_3_Protocol
                 and then Body_Value = "hello"
               then
                  Results.Succeed (Elapsed);
               else
                  Results.Fail ("unexpected response");
               end if;
            end;
         exception
            when Error : others =>
               Results.Fail (Ada.Exceptions.Exception_Information (Error));
         end;
      end loop;
      Results.Finish;
   exception
      when Error : others =>
         Results.Fail (Ada.Exceptions.Exception_Information (Error));
         Results.Finish;
   end Worker;

   Started : Ada.Real_Time.Time;
begin
   if Worker_Count > 32 then
      raise Constraint_Error with "worker count exceeds client capacity";
   end if;
   Client.Configure
     (HTTP,
      Flyology.HTTP.Parse_Origin
        ("https://127.0.0.1:" & Decimal (Port)),
      Client.Require_HTTP_3,
      HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
   Started := Ada.Real_Time.Clock;
   declare
      type Worker_Array is array (Positive range <>) of Worker;
      Group : Worker_Array (1 .. Worker_Count);
      pragma Unreferenced (Group);
   begin
      Results.Wait;
   end;
   declare
      Wall : constant Duration :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Passed : constant Natural := Results.Successes;
   begin
      Ada.Text_IO.Put_Line
        ("workers=" & Decimal (Worker_Count)
         & " requests=" & Natural'Image (Worker_Count * Requests_Per_Worker)
         & " success=" & Natural'Image (Passed)
         & " failure=" & Natural'Image (Results.Failures)
         & " wall_s=" & Duration'Image (Wall)
         & " rate=" & Long_Float'Image
             ((if Wall = 0.0 then 0.0
               else Long_Float (Passed) / Long_Float (Wall)))
         & " mean_s=" & Duration'Image (Results.Mean)
         & " max_s=" & Duration'Image (Results.Maximum));
      if Results.Failures > 0 then
         Ada.Text_IO.Put_Line ("first_error=" & Results.First_Error);
      end if;
   end;
   Client.Shutdown (HTTP, Timeout => 8.0);
   if Results.Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end HTTP3_Client_Stress_Probe;
