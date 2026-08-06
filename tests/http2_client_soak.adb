with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO.TLS.OpenSSL;
with Interfaces.C;

procedure HTTP2_Client_Soak is
   package Client renames Flyology.HTTP.Client;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Flyology.Execution_Model;
   use type Flyology.HTTP.Protocol;
   use type Interfaces.C.int;
   use type Interfaces.C.long;

   Maximum_Workers : constant := 16;
   Origin_Text : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_SOAK_ORIGIN");
   Certificate : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_SOAK_CA");
   Requests_Per_Worker : constant Positive := Positive'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_REQUESTS", "250"));
   Soak_Seconds : constant Duration := Duration'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_SECONDS", "0.0"));
   Epochs : constant Positive := Positive'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_EPOCHS", "3"));
   Epoch_Seconds : constant Duration := Soak_Seconds / Epochs;
   RSS_Tolerance : constant Interfaces.C.long := Interfaces.C.long'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_RSS_TOLERANCE", "33554432"));
   Concurrency : constant Positive := Positive'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_CONCURRENCY", "4"));
   Transport_Capacity : constant Positive := Positive'Value
     (Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_CAPACITY", "1"));
   Seed : constant Natural := Natural'Value
     (Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_SOAK_SEED", "1"));
   Model : constant Flyology.Execution_Model :=
     (if Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_SOAK_MODEL", "native") = "lightweight"
      then Flyology.Lightweight_Task else Flyology.Native_Task);
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   function Current_RSS return Interfaces.C.long
     with Import, Convention => C,
          External_Name => "flyology_test_current_rss_bytes";

   function Thread_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_thread_count";

   function Image (Value : Natural) return String is
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Image;

   function Expected_Body
     (Identifier : String;
      Length     : Natural) return String
   is
      Unit   : constant String := Identifier & ":";
      Result : String (1 .. Length);
   begin
      for Index in Result'Range loop
         Result (Index) := Unit
           (Unit'First + (Index - Result'First) mod Unit'Length);
      end loop;
      return Result;
   end Expected_Body;

   protected type Outcome (Expected : Positive) is
      procedure Report
        (Passed     : Boolean;
         Completed  : Natural;
         Cancelled  : Natural;
         Detail     : String := "");
      entry Await_All;
      function Passed return Boolean;
      function Completed return Natural;
      function Cancelled return Natural;
      function Detail return String;
   private
      Count            : Natural := 0;
      OK               : Boolean := True;
      Completed_Count  : Natural := 0;
      Cancelled_Count  : Natural := 0;
      Message          : Unbounded.Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Report
        (Passed     : Boolean;
         Completed  : Natural;
         Cancelled  : Natural;
         Detail     : String := "")
      is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         Completed_Count := Completed_Count + Completed;
         Cancelled_Count := Cancelled_Count + Cancelled;
         if not Passed and then Unbounded.Length (Message) = 0 then
            Message := Unbounded.To_Unbounded_String (Detail);
         end if;
      end Report;

      entry Await_All when Count = Expected is
      begin
         null;
      end Await_All;

      function Passed return Boolean is (OK);
      function Completed return Natural is (Completed_Count);
      function Cancelled return Natural is (Cancelled_Count);
      function Detail return String is (Unbounded.To_String (Message));
   end Outcome;

   protected type Dispatcher is
      procedure Claim (Identifier : out Natural; Active : out Boolean);
   private
      Next : Positive := 1;
   end Dispatcher;

   protected body Dispatcher is
      procedure Claim (Identifier : out Natural; Active : out Boolean) is
      begin
         Identifier := Next;
         Active := Next <= Concurrency;
         Next := Next + 1;
      end Claim;
   end Dispatcher;

   Backend : aliased OpenSSL.OpenSSL_Provider;

   procedure Warm is
      HTTP  : aliased Client.Client (Capacity => 1);
      Value : Client.Request;
   begin
      Client.Configure
        (HTTP, Flyology.HTTP.Parse_Origin (Origin_Text), Backend'Access,
         Client.Require_HTTP_2);
      Client.Set_Target (Value, "/soak/1");
      Client.Add_Header (Value, "x-soak-id", "warm");
      declare
         Reply : Client.Response := Client.Execute (HTTP, Value);
         Content : constant String := Flyology.Bytes.To_Byte_String
           (Client.Read_All (Reply, Maximum => 1));
      begin
         pragma Assert (Content = "w");
      end;
      Client.Shutdown (HTTP);
   end Warm;

   generic
      Execution : Flyology.Execution_Model;
   procedure Run (Epoch : Positive);

   procedure Run (Epoch : Positive) is
      Results : Outcome (Concurrency);
      Work    : Dispatcher;
      Pool    : constant Client.Pool_Configuration :=
        (Max_Idle                    => 1,
         Idle_Timeout                => -1.0,
         Max_Connection_Age          => -1.0,
         Max_Requests_Per_Connection => 0);
   begin
      declare
         HTTP : aliased Client.Client (Capacity => Transport_Capacity);
      begin
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin (Origin_Text), Backend'Access,
            Client.Require_HTTP_2, Pool);
         declare
            task type Worker is
               pragma Task_Info (Execution);
            end Worker;

            task body Worker is
               Worker_ID       : Natural;
               Active          : Boolean := False;
               Completed_Count : Natural := 0;
               Cancelled_Count : Natural := 0;
               Iteration       : Natural := 0;
               Started         : constant Ada.Real_Time.Time :=
                 Ada.Real_Time.Clock;
            begin
               Work.Claim (Worker_ID, Active);
               if Active then
                  loop
                     exit when
                       (if Epoch_Seconds > 0.0
                        then Ada.Real_Time.To_Duration
                          (Ada.Real_Time.Clock - Started) >= Epoch_Seconds
                        else Iteration >= Requests_Per_Worker);
                     Iteration := Iteration + 1;
                     declare
                        Identifier : constant String :=
                          Image (Seed) & "-" & Image (Worker_ID) & "-" &
                          Image (Iteration);
                        Choice : constant Natural := Natural
                          ((Long_Long_Integer (Seed mod 997) +
                            Long_Long_Integer (Worker_ID) * 13 +
                            Long_Long_Integer (Iteration) * 37) mod 101);
                        Is_Cancel : constant Boolean := Choice mod 29 = 0;
                        Is_Upload : constant Boolean :=
                          not Is_Cancel and then Choice mod 7 = 0;
                        Size : constant Natural :=
                          (if Choice mod 11 = 0 then 0
                           elsif Choice mod 5 = 0 then 8 * 1_024
                           else 17 + Choice);
                        Value : Client.Request;
                     begin
                        if Is_Cancel then
                           Client.Set_Target (Value, "/cancel");
                           declare
                              Reply : Client.Response :=
                                Client.Execute (HTTP, Value, Timeout => 30.0);
                              Buffer : Ada.Streams.Stream_Element_Array
                                (1 .. 128);
                              Last : Ada.Streams.Stream_Element_Offset;
                              Finished : Boolean;
                           begin
                              Client.Read_Body
                                (Reply, Buffer, Last, Finished);
                              pragma Assert (Last >= Buffer'First);
                              pragma Assert (not Finished);
                           end;
                           Cancelled_Count := Cancelled_Count + 1;
                        else
                           declare
                              Expected : constant String :=
                                Expected_Body (Identifier, Size);
                           begin
                              if Is_Upload then
                                 Client.Set_Target (Value, "/echo");
                                 Client.Set_Method
                                   (Value, Flyology.HTTP.Methods.POST);
                                 Client.Set_Body (Value, Expected);
                              else
                                 Client.Set_Target
                                   (Value, "/soak/" & Image (Size));
                                 Client.Add_Header
                                   (Value, "x-soak-id", Identifier);
                              end if;
                              declare
                                 Reply : Client.Response := Client.Execute
                                   (HTTP, Value, Timeout => 30.0);
                                 Content : constant String :=
                                   Flyology.Bytes.To_Byte_String
                                     (Client.Read_All
                                        (Reply, Maximum => 8 * 1_024));
                              begin
                                 pragma Assert (Client.Status (Reply) = 200);
                                 pragma Assert
                                   (Client.Negotiated_Protocol (Reply) =
                                      Flyology.HTTP.HTTP_2_Protocol);
                                 pragma Assert
                                   (Client.Header (Reply, "x-peer") = "h2");
                                 pragma Assert (Content = Expected);
                              end;
                              Completed_Count := Completed_Count + 1;
                           end;
                        end if;
                     end;
                  end loop;
                  Results.Report
                    (True, Completed_Count, Cancelled_Count);
               end if;
            exception
               when Error : others =>
                  if Active then
                     Results.Report
                       (False, Completed_Count, Cancelled_Count,
                        Ada.Exceptions.Exception_Information (Error));
                  end if;
            end Worker;

            type Worker_Array is array (1 .. Maximum_Workers) of Worker;
            Workers : Worker_Array;
            pragma Unreferenced (Workers);
         begin
            if Concurrency > Maximum_Workers then
               raise Constraint_Error with
                 "FLYOLOGY_HTTP2_SOAK_CONCURRENCY exceeds " &
                 Image (Maximum_Workers);
            end if;
            Results.Await_All;
            if not Results.Passed then
               raise Program_Error with Results.Detail;
            end if;
         end;
         pragma Assert
           (if Epoch_Seconds > 0.0
            then Results.Completed + Results.Cancelled >= Concurrency
            else Results.Completed + Results.Cancelled =
              Concurrency * Requests_Per_Worker);
         declare
            State : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            pragma Assert (State.Pending_Transports = 0);
            pragma Assert (State.Active_Exchanges = 0);
            pragma Assert
              (State.Reusable_Transports in 1 .. Transport_Capacity);
            pragma Assert (State.Closing_Transports = 0);
            pragma Assert
              (State.Transports_Created in 1 .. Transport_Capacity);
         end;
         Client.Shutdown (HTTP, Timeout => 10.0);
         declare
            State : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            pragma Assert (State.Pending_Transports = 0);
            pragma Assert (State.Active_Exchanges = 0);
            pragma Assert (State.Reusable_Transports = 0);
            pragma Assert (State.Closing_Transports = 0);
            pragma Assert (State.Transports_Created = State.Transports_Closed);
         end;
      end;
      Ada.Text_IO.Put_Line
         ("HTTP/2 soak passed: model=" &
         (if Execution = Flyology.Native_Task then "native" else "lightweight") &
         " epoch=" & Image (Epoch) & "/" & Image (Epochs) &
         " seed=" & Image (Seed) &
         " seconds=" & Duration'Image (Epoch_Seconds) &
         " completed=" & Image (Results.Completed) &
         " cancelled=" & Image (Results.Cancelled));
   end Run;

   procedure Run_Native is new Run (Flyology.Native_Task);
   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
begin
   if Soak_Seconds < 0.0 then
      raise Constraint_Error with "FLYOLOGY_HTTP2_SOAK_SECONDS is negative";
   elsif RSS_Tolerance < 0 then
      raise Constraint_Error with
        "FLYOLOGY_HTTP2_SOAK_RSS_TOLERANCE is negative";
   end if;
   if Concurrency > Maximum_Workers then
      raise Constraint_Error with
        "FLYOLOGY_HTTP2_SOAK_CONCURRENCY exceeds " & Image (Maximum_Workers);
   end if;
   OpenSSL.Initialize_Client
     (Backend, CA_File => Certificate,
      Library_Directory => Library_Directory);
   Warm;
   declare
      Baseline : constant Interfaces.C.int := Open_FD_Count;
      Plateau_RSS : Interfaces.C.long := -1;
      Plateau_Threads : Interfaces.C.int := -1;
   begin
      for Epoch in 1 .. Epochs loop
         if Model = Flyology.Native_Task then
            Run_Native (Epoch);
         else
            Run_Lightweight (Epoch);
         end if;
         pragma Assert (Open_FD_Count = Baseline);
         declare
            RSS : constant Interfaces.C.long := Current_RSS;
            Threads : constant Interfaces.C.int := Thread_Count;
         begin
            if Epoch = 1 then
               Plateau_RSS := RSS;
               Plateau_Threads := Threads;
            else
               pragma Assert
                 (RSS < 0 or else Plateau_RSS < 0
                    or else RSS <= Plateau_RSS + RSS_Tolerance);
               pragma Assert
                 (Threads < 0 or else Plateau_Threads < 0
                    or else Threads <= Plateau_Threads);
            end if;
            Ada.Text_IO.Put_Line
              ("HTTP/2 soak resources: epoch=" & Image (Epoch) &
               " rss=" & Interfaces.C.long'Image (RSS) &
               " threads=" & Interfaces.C.int'Image (Threads) &
               " fds=" & Interfaces.C.int'Image (Open_FD_Count));
         end;
      end loop;
   end;
end HTTP2_Client_Soak;
