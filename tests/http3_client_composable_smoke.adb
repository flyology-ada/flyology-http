with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.QUIC.Test_Connections;
with Flyology.Wake_Sources;
with HTTP_Client_Corpus_Oracle;
with HTTP_Client_Corpus_Sources;
with HTTP_Client_Corpus_Sinks;
with Interfaces;

procedure HTTP3_Client_Composable_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Buffers renames Flyology.Buffers;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;
   package Fixtures renames Flyology.QUIC.Test_Connections;
   package Corpus renames HTTP_Client_Corpus_Oracle;
   package Golden renames HTTP_Client_Corpus_Oracle.Golden;
   package Faults renames HTTP_Client_Corpus_Sources;
   package Sink_Faults renames HTTP_Client_Corpus_Sinks;

   use type Client.Exchange_Result_Kind;
   use type Client.Admission_Certainty;
   use type Client.Source_Step_Kind;
   use type Sink_Faults.Fault_Kind;
   use type Flyology.HTTP.Protocol;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;

   type Blocked_Source is limited new
     Client.Operation_Request_Body_Source with record
      Wake : Flyology.Wake_Sources.Source;
      Releases : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : Blocked_Source) return Client.Body_Length;
   overriding procedure Read_Now
     (Item   : in out Blocked_Source;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Client.Source_Step_Kind);
   overriding procedure Source_Wait_Source
     (Item        : in out Blocked_Source;
      Required    : Client.Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean);
   overriding procedure Release_Source (Item : in out Blocked_Source);

   type Parent_Operation
     (Set         : not null access Operations.Completion_Set'Class;
      HTTP        : not null access Client.Client;
      Ask         : not null access constant Client.Request;
      Destination : not null access Buffers.Unique_Buffer)
   is new Operations.Operation (Set) with record
      Child : Client.Exchange_Operation (Set);
      Passed : Boolean := False;
   end record;

   overriding procedure Drive
     (Item : in out Parent_Operation;
      Event : Operations.Driver_Event);
   overriding procedure Request_Cancellation (Item : in out Parent_Operation);

   overriding procedure Drive
     (Item : in out Parent_Operation;
      Event : Operations.Driver_Event) is
   begin
      if Event = Operations.Start_Operation then
         Client.Exchange_To_Buffer
           (Item.HTTP, Item.Ask, Item.Destination.all,
            Client.Deadline_After (10.0), null, Item.Child);
         Operations.Continue_After (Item, Item.Child);
      elsif Event = Operations.Dependency_Changed then
         declare
            Result : Client.Exchange_Result;
            Reply : Client.Response;
         begin
            Client.Finish
              (Item.Child, Result, Reply, Item.Destination.all);
            Item.Passed :=
              Client.Kind (Result) = Client.Response_Complete
                and then Client.Certainty (Result) =
                  Client.Response_Observed
                and then Client.Status (Reply) = 200
                and then Buffers.Length (Item.Destination.all) = 5;
         end;
         Operations.Release (Item.Child);
         Drivers.Complete
           (Item,
            (if Item.Passed then Operations.Succeeded
             else Operations.Failed));
      else
         Drivers.Complete (Item, Operations.Failed);
      end if;
   exception
      when others =>
         if Operations.Is_Terminal (Item.Child) then
            Operations.Release (Item.Child);
         end if;
         Item.Passed := False;
         Drivers.Complete (Item, Operations.Failed);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Parent_Operation) is
   begin
      Operations.Cancel (Item.Child);
   exception
      when others => null;
   end Request_Cancellation;

   overriding function Declared_Length
     (Item : Blocked_Source) return Client.Body_Length is
     (Client.Known_Length (1_048_577));

   overriding procedure Read_Now
     (Item   : in out Blocked_Source;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Client.Source_Step_Kind) is
   begin
      Data := (others => 0);
      Last := Data'First - 1;
      Result := Client.Source_Needs_Read;
   end Read_Now;

   overriding procedure Source_Wait_Source
     (Item        : in out Blocked_Source;
      Required    : Client.Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean) is
   begin
      pragma Assert (Required = Client.Source_Needs_Read);
      Flyology.Wake_Sources.Ensure (Item.Wake);
      Descriptor := Flyology.Wake_Sources.Descriptor (Item.Wake);
      Ready_Now := False;
   end Source_Wait_Source;

   overriding procedure Release_Source (Item : in out Blocked_Source) is
   begin
      if Item.Releases = 0 then
         Flyology.Wake_Sources.Release (Item.Wake);
         Item.Releases := 1;
      end if;
   end Release_Source;

   Port : constant String :=
     (if Ada.Command_Line.Argument_Count = 0 then "4437"
      else Ada.Command_Line.Argument (1));
   Model : constant Flyology.Execution_Model :=
     (if Ada.Command_Line.Argument_Count < 2 then Flyology.Native_Task
      elsif Ada.Command_Line.Argument (2) = "lightweight" then
        Flyology.Lightweight_Task
      else Flyology.Native_Task);

   HTTP : aliased Client.Client (Capacity => 1);
   protected Outcome is
      procedure Report (Passed : Boolean; Detail : String := "");
      entry Wait (Passed : out Boolean;
                  Detail : out Ada.Strings.Unbounded.Unbounded_String);
   private
      Done : Boolean := False;
      OK : Boolean := False;
      Message : Ada.Strings.Unbounded.Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean; Detail : String := "") is
      begin
         OK := Passed;
         Message := Ada.Strings.Unbounded.To_Unbounded_String (Detail);
         Done := True;
      end Report;
      entry Wait (Passed : out Boolean;
                  Detail : out Ada.Strings.Unbounded.Unbounded_String)
        when Done is
      begin
         Passed := OK;
         Detail := Message;
      end Wait;
   end Outcome;

   task Caller is
      pragma Task_Info (Model);
   end Caller;

   task body Caller is
      Value : aliased Client.Request;
      Pool : aliased Buffers.Pool (Block_Size => 64, Capacity => 2);
      Large_Pool : aliased Buffers.Pool
        (Block_Size => 40_000, Capacity => 1);
      Destination : aliased Buffers.Unique_Buffer (Pool'Access);
      Destination_2 : aliased Buffers.Unique_Buffer (Pool'Access);
      Large_Destination : aliased Buffers.Unique_Buffer (Large_Pool'Access);
      Set : aliased Operations.Completion_Set (4);
      Get_OK : Boolean := False;
      Large_OK : Boolean := False;
      Sync_Large_OK : Boolean := False;
      Parent_OK : Boolean := False;
      Validation_OK : Boolean := False;
      Put_OK : Boolean := False;
      Source_OK : Boolean := False;
      Source_Contracts_OK : Boolean := False;
      Sink_Contracts_OK : Boolean := False;
      Cancel_OK : Boolean := False;
      Abandon_OK : Boolean := False;
      Reuse_OK : Boolean := False;
      Multiplex_OK : Boolean := False;
      Reported : Boolean := False;
   begin
      Client.Configure
        (HTTP,
         Flyology.HTTP.Parse_Origin ("https://127.0.0.1:" & Port),
         Client.Require_HTTP_3,
         HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
      Client.Set_Target (Value, "/hello");
      Buffers.Acquire (Destination);
      declare
         Result : Client.Exchange_Result;
         Reply : Client.Response;
         Operation : Client.Exchange_Operation :=
           Client.Exchange_To_Buffer
             (Set'Access, HTTP'Access, Value'Unchecked_Access,
              Destination, Client.Deadline_After (10.0));
      begin
         Operations.Wait_All (Set);
         Client.Finish
           (Operation, Result, Reply, Destination);
         Corpus.Check
           (Golden.Complete_Fixed, Golden.H3, Golden.Composable_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Status_Known => True,
             Status => Client.Status (Reply),
             Body_Effect => Golden.Complete,
             others => <>));
         Get_OK :=
           Client.Kind (Result) = Client.Response_Complete
             and then Client.Certainty (Result) = Client.Response_Observed
             and then Client.Status (Reply) = 200
             and then Client.Negotiated_Protocol (Reply) =
               Flyology.HTTP.HTTP_3_Protocol
             and then Buffers.Length (Destination) = 5;
         if not Get_OK then
            Outcome.Report
              (False,
               "GET " & Client.Exchange_Result_Kind'Image
                 (Client.Kind (Result)) & " / " &
                 Client.Admission_Certainty'Image
                   (Client.Certainty (Result)) & " / " &
                 Client.Failure_Detail (Result));
            Reported := True;
         end if;
      end;

      if Get_OK then
         Client.Set_Target (Value, "/large");
         Buffers.Acquire (Large_Destination);
         declare
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                 (Set'Access, HTTP'Access, Value'Unchecked_Access,
                 Large_Destination, Client.Deadline_After (30.0));
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Operation, Result, Reply, Large_Destination);
            Large_OK :=
              Client.Kind (Result) = Client.Response_Complete
                and then Client.Status (Reply) = 200
                and then Buffers.Length (Large_Destination) = 32_768;
            if not Large_OK then
               Outcome.Report
                 (False,
                  "HTTP/3 rolling response window " &
                    Client.Exchange_Result_Kind'Image
                      (Client.Kind (Result)) & " / " &
                    Client.Failure_Detail (Result));
               Reported := True;
            end if;
         end;
         Buffers.Release (Large_Destination);
         if Large_OK then
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Value, Timeout => 30.0);
               Content : constant Flyology.Bytes.Unbounded_Bytes :=
                 Client.Read_All (Reply, Maximum => 40_000);
            begin
               Client.Set_Target (Value, "/hello");
               declare
                  Reused : Client.Response :=
                    Client.Execute (HTTP, Value, Timeout => 10.0);
                  Reused_Body : constant Flyology.Bytes.Unbounded_Bytes :=
                    Client.Read_All (Reused);
               begin
                  Sync_Large_OK :=
                    Client.Negotiated_Protocol (Reply) =
                      Flyology.HTTP.HTTP_3_Protocol
                      and then Flyology.Bytes.Length (Content) = 32_768
                      and then Client.Status (Reused) = 200
                      and then Flyology.Bytes.To_Byte_String
                        (Reused_Body) = "hello"
                      and then Client.Diagnostics
                        (HTTP).Transports_Created = 1;
               end;
               if not Sync_Large_OK then
                  Outcome.Report
                    (False, "synchronous HTTP/3 rolling response window");
                  Reported := True;
               end if;
            end;
         end if;
         Client.Set_Target (Value, "/hello");
      end if;

      if Get_OK and Large_OK and Sync_Large_OK then
         declare
            Batch : Operations.Completion_Batch (Set.Capacity);
            Parent : aliased Parent_Operation
              (Set'Access, HTTP'Access, Value'Unchecked_Access,
               Destination'Unchecked_Access);
         begin
            Drivers.Start (Parent);
            Operations.Drive
              (Operations.Operation'Class (Parent),
               Operations.Start_Operation);
            Operations.Wait_For_Success (Set, Batch);
            Parent_OK :=
              Batch.Count = 1
                and then Operations.Outcome (Parent) = Operations.Succeeded
                and then Parent.Passed
                and then Client.Diagnostics (HTTP).Transports_Created = 1;
            Operations.Consume (Parent);
            Operations.Release (Parent);
            if not Parent_OK then
               Outcome.Report (False, "HTTP/3 established child");
               Reported := True;
            end if;
         end;
      end if;

      if Get_OK and Parent_OK then
         declare
            Invalid : aliased Client.Request;
            Result : Client.Exchange_Result;
            Reply : Client.Response;
         begin
      Client.Set_Expect_Continue (Invalid);
            Buffers.Set_Tag (Destination, 77);
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Invalid'Unchecked_Access,
                    Destination, Client.Deadline_After (10.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Operation, Result, Reply, Destination);
            end;
            Validation_OK :=
              Client.Kind (Result) = Client.Pre_Admission_Rejected
                and then Client.Certainty (Result) = Client.Not_Admitted
                and then Buffers.Has_Buffer (Destination)
                and then Buffers.Length (Destination) = 5
                and then Buffers.Tag (Destination) = 77;
            if not Validation_OK then
               Outcome.Report (False, "HTTP/3 pre-admission validation");
               Reported := True;
            end if;
         end;
      end if;

      if Get_OK and Validation_OK then
         Client.Set_Method (Value, Flyology.HTTP.To_Method ("PUT"));
         Client.Set_Target (Value, "/upload");
         Client.Add_Header (Value, "If-None-Match", "*");
         Client.Set_Body (Value, "commit-bytes");
         declare
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Value'Unchecked_Access,
                 Destination, Client.Deadline_After (10.0));
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Operation, Result, Reply, Destination);
            Corpus.Check
              (Golden.Complete_Fixed, Golden.H3, Golden.Composable_Buffer,
               (Kind => Corpus.To_Golden (Client.Kind (Result)),
                Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                Status_Known => True,
                Status => Client.Status (Reply),
                Body_Effect => Golden.Complete,
                others => <>));
            Put_OK :=
              Client.Kind (Result) = Client.Response_Complete
                and then Client.Certainty (Result) = Client.Response_Observed
                and then Client.Status (Reply) = 200
                and then Client.Negotiated_Protocol (Reply) =
                  Flyology.HTTP.HTTP_3_Protocol
                and then Buffers.Length (Destination) = 8;
            if not Put_OK then
               declare
                  Required : constant Client.Length_Requirement :=
                    Client.Required_Body_Length (Result);
               begin
                  Outcome.Report
                    (False,
                     "PUT " & Client.Exchange_Result_Kind'Image
                       (Client.Kind (Result)) & " / " &
                       Client.Admission_Certainty'Image
                         (Client.Certainty (Result)) & " / " &
                       Client.Failure_Detail (Result) &
                       (if Required.Known then
                          " required=" & Client.Body_Size'Image
                            (Required.Bytes)
                        else " required=unknown"));
               end;
               Reported := True;
            end if;
         end;
      end if;

      if Put_OK then
         Client.Set_Target (Value, "/early-upload");
         Client.Set_Body (Value, "");
         declare
            Source : aliased Blocked_Source;
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Value'Unchecked_Access,
                 Source'Access, Destination,
                 Client.Deadline_After (10.0));
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Operation, Result, Reply, Destination);
            Corpus.Check
              (Golden.Blocked_Source_Early_Final, Golden.H3,
               Golden.Composable_Buffer,
               (Kind => Corpus.To_Golden (Client.Kind (Result)),
                Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                Status_Known => True,
                Status => Client.Status (Reply),
                Body_Effect => Golden.Empty,
                Source_Releases => Source.Releases,
                Request_Reset => True,
                others => <>));
            Source_OK :=
              Client.Kind (Result) = Client.Response_Complete
                and then Client.Certainty (Result) =
                  Client.Response_Observed
                and then Client.Status (Reply) = 413
                and then Source.Releases = 1
                and then Buffers.Length (Destination) = 0;
            if not Source_OK then
               Outcome.Report
                 (False,
                  "source early final " &
                    Client.Exchange_Result_Kind'Image
                      (Client.Kind (Result)) & " / " &
                    Client.Admission_Certainty'Image
                      (Client.Certainty (Result)));
               Reported := True;
            end if;
         end;
      end if;

      if Source_OK then
         Client.Set_Target (Value, "/upload");
         declare
            Passed : Boolean := True;

            procedure Check_Fault
              (Fault    : Faults.Fault_Kind;
               Scenario : Golden.Case_Kind) is
               Source : aliased Faults.Fault_Source (Fault, null);
               Result : Client.Exchange_Result;
               Reply : Client.Response;
            begin
               declare
                  Operation : Client.Exchange_Operation :=
                    Client.Exchange_To_Buffer
                      (Set'Access, HTTP'Access,
                       Value'Unchecked_Access, Source'Access,
                       Destination, Client.Deadline_After (10.0));
               begin
                  Operations.Wait_All (Set);
                  Client.Finish
                    (Operation, Result, Reply, Destination);
               end;
               Corpus.Check
                 (Scenario, Golden.H3, Golden.Composable_Buffer,
                  (Kind => Corpus.To_Golden (Client.Kind (Result)),
                   Certainty =>
                     Corpus.To_Golden (Client.Certainty (Result)),
                   Body_Effect => Golden.Zero,
                   Source_Releases => Faults.Release_Count (Source),
                   others => <>));
               Passed := Passed
                 and then Client.Kind (Result) =
                   Client.Request_Source_Failed
                 and then Client.Certainty (Result) =
                   Client.Possibly_Admitted
                 and then Faults.Release_Count (Source) = 1
                 and then Buffers.Length (Destination) = 0;
            end Check_Fault;
         begin
            Check_Fault (Faults.Short_Source, Golden.Source_Short);
            Check_Fault (Faults.Long_Source, Golden.Source_Long);
            Check_Fault
              (Faults.Zero_Progress_Source,
               Golden.Source_Zero_Progress);
            Check_Fault
              (Faults.Needs_With_Bytes_Source,
               Golden.Source_Needs_With_Bytes);
            Check_Fault
              (Faults.Exceptional_Source, Golden.Source_Exception);
            Source_Contracts_OK := Passed;
            if not Source_Contracts_OK then
               Outcome.Report (False, "HTTP/3 source contract");
               Reported := True;
            end if;
         end;
      end if;

      if Source_Contracts_OK then
         Client.Set_Method (Value, Flyology.HTTP.To_Method ("GET"));
         Client.Set_Target (Value, "/hello");
         Client.Set_Body (Value, "");
         declare
            Passed : Boolean := True;

            procedure Check_Fault
              (Fault    : Sink_Faults.Fault_Kind;
               Scenario : Golden.Case_Kind) is
               Sink : aliased Sink_Faults.Fault_Sink (Fault);
               Result : Client.Exchange_Result;
               Reply : Client.Response;
            begin
               declare
                  Operation : Client.Exchange_Operation :=
                    Client.Exchange_To_Sink
                      (Set'Access, HTTP'Access,
                       Value'Unchecked_Access, Sink'Access,
                       Client.Deadline_After (10.0));
               begin
                  Operations.Wait_All (Set);
                  Client.Finish (Operation, Result, Reply);
               end;
               Corpus.Check
                 (Scenario, Golden.H3, Golden.Composable_Sink,
                  (Kind => Corpus.To_Golden (Client.Kind (Result)),
                   Certainty =>
                     Corpus.To_Golden (Client.Certainty (Result)),
                   Body_Effect => Golden.Partial_Visible,
                   others => <>));
               Passed := Passed
                 and then Client.Kind (Result) =
                   Client.Response_Sink_Failed
                 and then Client.Certainty (Result) =
                   Client.Response_Observed
                 and then Sink_Faults.Write_Count (Sink) = 1
                 and then
                   (if Fault = Sink_Faults.Partial_Failure
                    then Sink_Faults.Visible_Bytes (Sink) > 0
                    else Sink_Faults.Visible_Bytes (Sink) = 0);
            end Check_Fault;
         begin
            Check_Fault
              (Sink_Faults.Partial_Failure,
               Golden.Sink_Partial_Then_Failure);
            Check_Fault
              (Sink_Faults.Immediate_Failure,
               Golden.Sink_Exception);
            Sink_Contracts_OK := Passed;
            if not Sink_Contracts_OK then
               Outcome.Report (False, "HTTP/3 sink contract");
               Reported := True;
            end if;
         end;
      end if;

      if Sink_Contracts_OK then
         Client.Set_Method (Value, Flyology.HTTP.To_Method ("PUT"));
         Client.Set_Target (Value, "/slow-upload");
         declare
            Token : aliased Flyology.Cancellation.Token;
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Value'Unchecked_Access,
                 Destination, Client.Deadline_After (10.0), Token'Access);
            task Canceller;
            task body Canceller is
            begin
               delay 0.2;
               Token.Request;
            end Canceller;
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Operation, Result, Reply, Destination);
            Corpus.Check
              (Golden.Cancel_After_Admission, Golden.H3,
               Golden.Composable_Buffer,
               (Kind => Corpus.To_Golden (Client.Kind (Result)),
                Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                Body_Effect => Golden.Zero,
                Request_Reset => True,
                others => <>));
            Cancel_OK :=
              Client.Kind (Result) = Client.Cancelled
                and then Client.Certainty (Result) =
                  Client.Possibly_Admitted
                and then Buffers.Length (Destination) = 0;
            if not Cancel_OK then
               Outcome.Report
                 (False,
                  "cancel " & Client.Exchange_Result_Kind'Image
                    (Client.Kind (Result)) & " / " &
                    Client.Admission_Certainty'Image
                      (Client.Certainty (Result)) & " / " &
                    Client.Failure_Detail (Result));
               Reported := True;
            end if;
         end;
      end if;

      if Cancel_OK then
         Client.Set_Method (Value, Flyology.HTTP.To_Method ("PUT"));
         Client.Set_Target (Value, "/slow-upload");
         declare
            Token : aliased Flyology.Cancellation.Token;
            Terminal_OK : Boolean := False;
         begin
            declare
               Operation : constant Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Value'Unchecked_Access,
                    Destination, Client.Deadline_After (10.0), Token'Access);
               task Canceller;
               task body Canceller is
               begin
                  delay 0.2;
                  Token.Request;
               end Canceller;
            begin
               Operations.Wait_All (Set);
               Terminal_OK :=
                 Operations.Outcome (Operation) = Operations.Cancelled
                   and then Client.Admission (Operation) =
                     Client.Possibly_Admitted;
               --  Deliberately omit Finish. Finalization must drain before
               --  returning the detached token to its pool.
            end;
            Abandon_OK :=
              Terminal_OK and then not Buffers.Has_Buffer (Destination);
            Buffers.Acquire (Destination);
            Abandon_OK :=
              Abandon_OK and then Buffers.Length (Destination) = 0;
            if not Abandon_OK then
               Outcome.Report (False, "HTTP/3 abandonment drain");
               Reported := True;
            end if;
         end;
      end if;

      if Abandon_OK then
         Client.Set_Method (Value, Flyology.HTTP.To_Method ("GET"));
         Client.Set_Target (Value, "/hello");
         Client.Set_Body (Value, "");
         declare
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Value'Unchecked_Access,
                 Destination, Client.Deadline_After (10.0));
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Operation, Result, Reply, Destination);
            Reuse_OK :=
              Client.Kind (Result) = Client.Response_Complete
                and then Client.Status (Reply) = 200
                and then Client.Negotiated_Protocol (Reply) =
                  Flyology.HTTP.HTTP_3_Protocol
                and then Buffers.Length (Destination) = 5;
            if not Reuse_OK then
               Outcome.Report
                 (False,
                  "post-cancel GET " & Client.Exchange_Result_Kind'Image
                    (Client.Kind (Result)) & " / " &
                    Client.Admission_Certainty'Image
                      (Client.Certainty (Result)) & " / " &
                    Client.Failure_Detail (Result));
               Reported := True;
            end if;
         end;
      end if;

      if Reuse_OK then
         declare
            Slow_Request : aliased Client.Request;
            Fast_Request : aliased Client.Request;
            Slow_Result : Client.Exchange_Result;
            Fast_Result : Client.Exchange_Result;
            Slow_Reply : Client.Response;
            Fast_Reply : Client.Response;
         begin
            Client.Set_Target (Slow_Request, "/slow");
            Client.Set_Target (Fast_Request, "/hello");
            Buffers.Acquire (Destination_2);
            declare
               Slow_Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access,
                    Slow_Request'Unchecked_Access, Destination,
                    Client.Deadline_After (10.0));
               Fast_Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access,
                    Fast_Request'Unchecked_Access, Destination_2,
                    Client.Deadline_After (10.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Slow_Operation, Slow_Result, Slow_Reply, Destination);
               Client.Finish
                 (Fast_Operation, Fast_Result, Fast_Reply, Destination_2);
            end;
            Multiplex_OK :=
              Client.Kind (Slow_Result) = Client.Response_Complete
                and then Client.Kind (Fast_Result) =
                  Client.Response_Complete
                and then Client.Status (Slow_Reply) = 200
                and then Client.Status (Fast_Reply) = 200
                and then Buffers.Length (Destination) = 4
                and then Buffers.Length (Destination_2) = 5;
            if not Multiplex_OK then
               Outcome.Report
                 (False,
                  "multiplex slow=" & Client.Exchange_Result_Kind'Image
                    (Client.Kind (Slow_Result)) & " fast=" &
                    Client.Exchange_Result_Kind'Image
                      (Client.Kind (Fast_Result)) & " / slow=" &
                    Client.Failure_Detail (Slow_Result) & " fast=" &
                    Client.Failure_Detail (Fast_Result) & " certainty=" &
                    Client.Admission_Certainty'Image
                      (Client.Certainty (Fast_Result)) & " phase=" &
                    Client.Exchange_Phase'Image
                      (Client.Phase (Fast_Result)) & " transports=" &
                    Client.Diagnostics (HTTP).Transports_Created'Image);
               Reported := True;
            end if;
            Buffers.Release (Destination_2);
         end;
      end if;

      Buffers.Release (Destination);
      Client.Shutdown (HTTP, Timeout => 5.0);
      if not Reported then
         Outcome.Report
           (Get_OK and Large_OK and Sync_Large_OK and Parent_OK
              and Validation_OK and Put_OK
              and Source_OK
              and Cancel_OK and Abandon_OK and Reuse_OK and Multiplex_OK);
      end if;
   exception
      when Error : others =>
         Outcome.Report
           (False, Ada.Exceptions.Exception_Information (Error));
   end Caller;
begin
   declare
      Passed : Boolean;
      Detail : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Outcome.Wait (Passed, Detail);
      if not Passed then
         raise Program_Error with
           "composable HTTP/3 failure: " &
           Ada.Strings.Unbounded.To_String (Detail);
      end if;
   end;
   Ada.Text_IO.Put_Line ("composable HTTP/3 client passed");
end HTTP3_Client_Composable_Smoke;
