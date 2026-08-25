with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Execution_Groups;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Operations;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Client_Stress_Probe is
   package Client renames Flyology.HTTP.Client;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Flyology.HTTP.Protocol;
   use type Client.Exchange_Result_Kind;

   Worker_Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 1 then 1
      else Positive'Value (Ada.Command_Line.Argument (1)));
   Requests_Per_Worker : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 2 then 100
      else Positive'Value (Ada.Command_Line.Argument (2)));
   Port : constant Positive :=
     (if Ada.Command_Line.Argument_Count < 3 then 4_433
      else Positive'Value (Ada.Command_Line.Argument (3)));
   Expected_Loops : constant Flyology.Execution_Groups.Loop_Pool_Size :=
     (if Ada.Command_Line.Argument_Count < 4 then 1
      else Flyology.Execution_Groups.Loop_Pool_Size'Value
        (Ada.Command_Line.Argument (4)));
   Max_Idle : constant Natural :=
     (if Ada.Command_Line.Argument_Count < 5 then 1
      else Natural'Value (Ada.Command_Line.Argument (5)));
   Request_Timeout : constant Duration :=
     (if Ada.Command_Line.Argument_Count < 6 then 8.0
      else Duration'Value (Ada.Command_Line.Argument (6)));

   function Decimal (Value : Positive) return String is
      Image : constant String := Positive'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   HTTP : aliased Client.Client (Capacity => Worker_Count);

   type Body_Storage is
     array (Positive range 1 .. 5) of Ada.Streams.Stream_Element;

   type Body_Sink is limited new Client.Response_Body_Sink with record
      Storage  : Body_Storage := (others => 0);
      Length   : Natural range 0 .. 5 := 0;
      Overflow : Boolean := False;
   end record;

   overriding procedure Write
     (Item : in out Body_Sink;
      Data : Ada.Streams.Stream_Element_Array);

   overriding procedure Write
     (Item : in out Body_Sink;
      Data : Ada.Streams.Stream_Element_Array)
   is
   begin
      if Data'Length > Item.Storage'Length - Item.Length then
         Item.Overflow := True;
         return;
      end if;
      for Index in Data'Range loop
         Item.Length := Item.Length + 1;
         Item.Storage (Item.Length) := Data (Index);
      end loop;
   end Write;

   function Is_Hello (Item : Body_Sink) return Boolean is
     (not Item.Overflow
        and then Item.Length = 5
        and then Item.Storage =
          (Character'Pos ('h'), Character'Pos ('e'), Character'Pos ('l'),
           Character'Pos ('l'), Character'Pos ('o')));

   protected Results is
      procedure Start;
      entry Await_Start;
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
      Released : Boolean := False;
      Completed : Natural := 0;
      Passed : Natural := 0;
      Failed : Natural := 0;
      Total : Duration := 0.0;
      Max : Duration := 0.0;
      Detail : Unbounded_String;
   end Results;

   protected body Results is
      procedure Start is
      begin
         Released := True;
      end Start;

      entry Await_Start when Released is
      begin
         null;
      end Await_Start;

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
      Results.Await_Start;
      for Iteration in 1 .. Requests_Per_Worker loop
         declare
            Value : aliased Client.Request;
            Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            Client.Set_Target (Value, "/hello");
            declare
               --  Root exchange, DNS resolver, and resolver socket child.
               Set : aliased Flyology.Operations.Completion_Set (3);
               Sink : aliased Body_Sink;
               Result : Client.Exchange_Result;
               Reply : Client.Response;
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Sink
                   (Set'Access, HTTP'Access, Value'Unchecked_Access,
                    Sink'Access, Client.Deadline_After (Request_Timeout));
            begin
               Flyology.Operations.Wait_All (Set);
               Client.Finish (Operation, Result, Reply);
               if Client.Kind (Result) = Client.Response_Complete
                 and then Client.Status (Reply) = 200
                 and then Client.Negotiated_Protocol (Reply) =
                   Flyology.HTTP.HTTP_3_Protocol
                 and then Is_Hello (Sink)
               then
                  Results.Succeed
                    (Ada.Real_Time.To_Duration
                       (Ada.Real_Time.Clock - Started));
               else
                  Results.Fail
                    (Client.Exchange_Result_Kind'Image (Client.Kind (Result))
                     & " / " & Client.Admission_Certainty'Image
                       (Client.Certainty (Result))
                     & " / " & Client.Exchange_Phase'Image
                       (Client.Phase (Result))
                     & " / " & Client.Failure_Detail (Result));
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
   if Flyology.Execution_Groups.Configured_Pool_Size /= Expected_Loops then
      raise Program_Error with
        "HTTP/3 stress client linked an unexpected loop-pool size";
   end if;
   if Worker_Count > 256 then
      raise Constraint_Error with "worker count exceeds stress ceiling";
   end if;
   Client.Configure
     (HTTP,
      Flyology.HTTP.Parse_Origin
        ("https://127.0.0.1:" & Decimal (Port)),
      Client.Require_HTTP_3,
      HTTP_3_Certificate_DER => Fixtures.Server_Certificate,
      Pool => (Max_Idle => Max_Idle, others => <>));
   Started := Ada.Real_Time.Clock;
   declare
      type Worker_Array is array (Positive range <>) of Worker;
      Group : Worker_Array (1 .. Worker_Count);
      pragma Unreferenced (Group);
   begin
      Results.Start;
      Results.Wait;
   end;
   declare
      Wall : constant Duration :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Passed : constant Natural := Results.Successes;
      Pool_State : constant Client.Client_Diagnostics :=
        Client.Diagnostics (HTTP);
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
      Ada.Text_IO.Put_Line
        ("pool_created=" & Natural'Image (Pool_State.Transports_Created)
         & " pool_reused=" & Natural'Image (Pool_State.Transport_Reuses)
         & " pool_idle=" & Natural'Image (Pool_State.Reusable_Transports)
         & " pool_closed=" & Natural'Image (Pool_State.Transports_Closed));
      if Results.Failures > 0 then
         Ada.Text_IO.Put_Line ("first_error=" & Results.First_Error);
      end if;
   end;
   Client.Shutdown (HTTP, Timeout => 8.0);
   if Results.Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end HTTP3_Client_Stress_Probe;
