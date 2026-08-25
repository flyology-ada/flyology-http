with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.Wake_Sources;
with HTTP_Client_Corpus_Oracle;
with HTTP_Client_Corpus_Sources;
with HTTP_Client_Corpus_Sinks;
with Interfaces;

procedure HTTP2_Client_Integration is
   package Client renames Flyology.HTTP.Client;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Corpus renames HTTP_Client_Corpus_Oracle;
   package Golden renames HTTP_Client_Corpus_Oracle.Golden;
   package Faults renames HTTP_Client_Corpus_Sources;
   package Sink_Faults renames HTTP_Client_Corpus_Sinks;
   package Drivers renames Flyology.Operations.Drivers;
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Client.Admission_Certainty;
   use type Client.Exchange_Result_Kind;
   use type Client.Source_Step_Kind;
   use type Sink_Faults.Fault_Kind;
   use type Flyology.HTTP.Protocol;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;
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
     (Set         : not null access Flyology.Operations.Completion_Set'Class;
      HTTP        : not null access Client.Client;
      Ask         : not null access constant Client.Request;
      Destination : not null access Flyology.Buffers.Unique_Buffer)
   is new Flyology.Operations.Operation (Set) with record
      Child : Client.Exchange_Operation (Set);
      Passed : Boolean := False;
   end record;

   overriding procedure Drive
     (Item  : in out Parent_Operation;
      Event : Flyology.Operations.Driver_Event);
   overriding procedure Request_Cancellation (Item : in out Parent_Operation);

   overriding procedure Drive
     (Item  : in out Parent_Operation;
      Event : Flyology.Operations.Driver_Event) is
   begin
      if Event = Flyology.Operations.Start_Operation then
         Client.Exchange_To_Buffer
           (Item.HTTP, Item.Ask, Item.Destination.all,
            Client.Deadline_After (30.0), null, Item.Child);
         Flyology.Operations.Continue_After (Item, Item.Child);
      elsif Event = Flyology.Operations.Dependency_Changed then
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
                and then Flyology.Buffers.Length (Item.Destination.all) = 14;
         end;
         Flyology.Operations.Release (Item.Child);
         Drivers.Complete
           (Item,
            (if Item.Passed then Flyology.Operations.Succeeded
             else Flyology.Operations.Failed));
      else
         Drivers.Complete (Item, Flyology.Operations.Failed);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Terminal (Item.Child) then
            Flyology.Operations.Release (Item.Child);
         end if;
         Item.Passed := False;
         Drivers.Complete (Item, Flyology.Operations.Failed);
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Parent_Operation) is
   begin
      Flyology.Operations.Cancel (Item.Child);
   exception
      when others => null;
   end Request_Cancellation;

   overriding function Declared_Length
     (Item : Blocked_Source) return Client.Body_Length is
     (Client.Known_Length (8));

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

   Origin_Text : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_ORIGIN");
   Scenario : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_SCENARIO");
   Certificate : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_CA");
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");
   Model : constant Flyology.Execution_Model :=
     (if Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_TEST_MODEL", "native") = "lightweight"
      then Flyology.Lightweight_Task else Flyology.Native_Task);

   protected type Outcome (Expected : Positive) is
      procedure Report (Passed : Boolean; Detail : String := "");
      entry Await_All;
      function Passed return Boolean;
      function Detail return String;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
      Message : Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean; Detail : String := "") is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         if not Passed and then Length (Message) = 0 then
            Message := To_Unbounded_String (Detail);
         end if;
      end Report;

      entry Await_All when Count = Expected is
      begin
         null;
      end Await_All;

      function Passed return Boolean is (OK);
      function Detail return String is (To_String (Message));
   end Outcome;

   procedure Check_Body
     (Reply    : in out Client.Response;
      Expected : String)
   is
      Value : constant String := Flyology.Bytes.To_Byte_String
        (Client.Read_All (Reply, Maximum => 300_000));
   begin
      pragma Assert
        (Client.Negotiated_Protocol (Reply) =
           Flyology.HTTP.HTTP_2_Protocol);
      pragma Assert (Client.Status (Reply) = 200);
      pragma Assert (Value = Expected);
   end Check_Body;

   procedure Check_Flow (Reply : in out Client.Response) is
      Value : constant Ada.Streams.Stream_Element_Array :=
        Flyology.Bytes.To_Array
          (Client.Read_All (Reply, Maximum => 300_000));
   begin
      pragma Assert (Value'Length = 256 * 1_024);
      for Index in Value'Range loop
         pragma Assert
           (Natural (Value (Index)) = Natural (Index - Value'First) mod 256);
      end loop;
   end Check_Flow;

   Item : aliased Client.Client (Capacity => 1);
   Backend : aliased OpenSSL.OpenSSL_Provider;
   Pool : constant Client.Pool_Configuration :=
     (if Scenario = "long-sync"
      then
        (Max_Idle                    => 1,
         Idle_Timeout                => -1.0,
         Max_Connection_Age          => -1.0,
         Max_Requests_Per_Connection => 0)
      else Client.Default_Pool_Configuration);
begin
   if Scenario in
     "prior" | "early-final" | "early-final-body" | "composable" |
     "long-sync" |
     "composable-body-forbidden" |
     "composable-source-early-final" |
     "composable-source-contract" | "composable-sink-contract" |
     "composable-stream-isolation"
   then
      Client.Configure
        (Item, Flyology.HTTP.Parse_Origin (Origin_Text),
         Client.HTTP_2_Prior_Knowledge, Pool);
   else
      OpenSSL.Initialize_Client
        (Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      Client.Configure
        (Item, Flyology.HTTP.Parse_Origin (Origin_Text), Backend'Access,
         (if Scenario = "fallback" then Client.Negotiate_HTTP_2
          else Client.Require_HTTP_2),
         Pool);
   end if;

   if Scenario = "composable-stream-isolation" then
      declare
         package Buffers renames Flyology.Buffers;
         package Operations renames Flyology.Operations;
         Pool : aliased Buffers.Pool (Block_Size => 64, Capacity => 2);
         Bad_Buffer  : Buffers.Unique_Buffer (Pool'Access);
         Good_Buffer : Buffers.Unique_Buffer (Pool'Access);
         Set : aliased Operations.Completion_Set (4);
         Bad_Request  : aliased Client.Request;
         Good_Request : aliased Client.Request;
         Bad_Result  : Client.Exchange_Result;
         Good_Result : Client.Exchange_Result;
         Bad_Reply  : Client.Response;
         Good_Reply : Client.Response;
      begin
         Client.Set_Target (Bad_Request, "/bad");
         Client.Set_Target (Good_Request, "/good");
         Buffers.Acquire (Bad_Buffer);
         Buffers.Acquire (Good_Buffer);
         declare
            Bad_Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, Item'Access, Bad_Request'Unchecked_Access,
                 Bad_Buffer, Client.Deadline_After (30.0));
            Good_Operation : Client.Exchange_Operation :=
              Client.Exchange_To_Buffer
                (Set'Access, Item'Access, Good_Request'Unchecked_Access,
                 Good_Buffer, Client.Deadline_After (30.0));
         begin
            Operations.Wait_All (Set);
            Client.Finish
              (Bad_Operation, Bad_Result, Bad_Reply, Bad_Buffer);
            Client.Finish
              (Good_Operation, Good_Result, Good_Reply, Good_Buffer);
         end;
         pragma Assert
           (Client.Kind (Bad_Result) = Client.Response_Invalid);
         pragma Assert
           (Client.Certainty (Bad_Result) = Client.Response_Observed);
         pragma Assert (Buffers.Length (Bad_Buffer) = 0);
         pragma Assert
           (Client.Kind (Good_Result) = Client.Response_Complete);
         pragma Assert (Client.Status (Good_Reply) = 200);
         pragma Assert (Buffers.Length (Good_Buffer) = 14);
         Corpus.Check
           (Golden.Malformed_Stream_Isolation, Golden.H2,
            Golden.Composable_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Bad_Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Bad_Result)),
             Body_Effect => Golden.Zero,
             Request_Reset => True,
             Sibling_Kind_Known => True,
             Sibling_Kind =>
               Corpus.To_Golden (Client.Kind (Good_Result)),
             others => <>));
         Buffers.Release (Bad_Buffer);
         Buffers.Release (Good_Buffer);
      end;
   elsif Scenario = "composable-body-forbidden" then
      declare
         package Buffers renames Flyology.Buffers;
         package Operations renames Flyology.Operations;
         Pool : aliased Buffers.Pool (Block_Size => 1, Capacity => 1);
         Destination : Buffers.Unique_Buffer (Pool'Access);

         procedure Check
           (Target          : String;
            Method          : Flyology.HTTP.Method;
            Expected_Status : Flyology.HTTP.Status_Code)
         is
            Set     : aliased Operations.Completion_Set (4);
            Request : aliased Client.Request;
            Result  : Client.Exchange_Result;
            Reply   : Client.Response;
         begin
            Client.Set_Target (Request, Target);
            Client.Set_Method (Request, Method);
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, Item'Access, Request'Unchecked_Access,
                    Destination, Client.Deadline_After (30.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Operation, Result, Reply, Destination);
            end;
            pragma Assert
              (Client.Kind (Result) = Client.Response_Complete);
            pragma Assert
              (Client.Certainty (Result) = Client.Response_Observed);
            pragma Assert (Client.Status (Reply) = Expected_Status);
            pragma Assert
              (Client.Header (Reply, "content-length") = "5368709129");
            pragma Assert (Buffers.Length (Destination) = 0);
         end Check;
      begin
         Buffers.Acquire (Destination);
         Check ("/head", Flyology.HTTP.Methods.HEAD, 200);
         Check ("/not-modified", Flyology.HTTP.Methods.GET, 304);
         Buffers.Release (Destination);
      end;
   elsif Scenario in
     "multiplex" | "continuation" | "peer-capacity" | "stream-order"
   then
      declare
         Results : Outcome (2);
         task type Caller (Second : Boolean) is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : aliased Client.Request;
         begin
            Client.Set_Target
              (Value, (if Second then "/second" else "/first"));
            if Scenario = "continuation" then
               Client.Add_Header (Value, "x-large", (1 .. 16_000 => 'x'));
            end if;
            declare
               Reply : Client.Response :=
                 Client.Execute (Item, Value, Timeout => 30.0);
               Content : constant String := Flyology.Bytes.To_Byte_String
                 (Client.Read_All (Reply, Maximum => 100));
            begin
               Results.Report
                 (Client.Negotiated_Protocol (Reply) =
                    Flyology.HTTP.HTTP_2_Protocol
                    and then
                      (if Scenario = "multiplex"
                       then Content in "first-response" | "second"
                       else Content = "flyology-http2"));
            end;
         exception
            when Event : others =>
               Results.Report
                 (False,
                  (if Second then "second: " else "first: ")
                    & Ada.Exceptions.Exception_Information (Event));
         end Caller;

         First  : Caller (False);
         Second : Caller (True);
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   elsif Scenario = "shutdown-race" then
      declare
         protected type Gate is
            procedure Mark_Ready;
            entry Await_Ready;
            procedure Release;
            entry Await_Release;
         private
            Ready    : Boolean := False;
            Released : Boolean := False;
         end Gate;

         protected body Gate is
            procedure Mark_Ready is
            begin
               Ready := True;
            end Mark_Ready;

            entry Await_Ready when Ready is
            begin
               null;
            end Await_Ready;

            procedure Release is
            begin
               Released := True;
            end Release;

            entry Await_Release when Released is
            begin
               null;
            end Await_Release;
         end Gate;

         Sync    : Gate;
         Results : Outcome (2);

         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : Client.Request;
         begin
            Client.Set_Target (Value, "/shutdown-race");
            declare
               Reply : constant Client.Response :=
                 Client.Execute (Item, Value, Timeout => 30.0);
            begin
               pragma Assert (Client.Status (Reply) = 200);
               Sync.Mark_Ready;
               Sync.Await_Release;
            end;
            Results.Report (True);
         exception
            when Event : others =>
               Sync.Mark_Ready;
               Sync.Release;
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;

         task Stopper is
            pragma Task_Info (Model);
         end Stopper;

         task body Stopper is
         begin
            Sync.Await_Ready;
            Sync.Release;
            Client.Shutdown (Item, Timeout => 5.0);
            Results.Report (True);
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Stopper;
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   elsif Scenario = "long-sync" then
      declare
         Results : Outcome (1);
         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value    : Client.Request;
            Reply    : Client.Response;
            Content  : Flyology.Bytes.Unbounded_Bytes;
            Expected : constant String := "flyology-http2";
         begin
            Client.Set_Target (Value, "/long-sync");
            for Iteration in 1 .. 10_000 loop
               Client.Execute (Item, Value, Reply, Timeout => 30.0);
               Client.Read_All (Reply, Content, Maximum => 300_000);
               pragma Assert
                 (Client.Negotiated_Protocol (Reply) =
                    Flyology.HTTP.HTTP_2_Protocol);
               pragma Assert (Client.Status (Reply) = 200);
               pragma Assert
                 (Flyology.Bytes.Length (Content) = Expected'Length);
               for Index in Expected'Range loop
                  pragma Assert
                    (Flyology.Bytes.Element (Content, Index) =
                       Ada.Streams.Stream_Element
                         (Character'Pos (Expected (Index))));
               end loop;
            end loop;
            Results.Report (True);
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   elsif Scenario = "reset-race" then
      declare
         First : Client.Request;
      begin
         Client.Set_Target (First, "/reset-race");
         declare
            Reply : constant Client.Response :=
              Client.Execute (Item, First, Timeout => 30.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
         end;
      end;
      declare
         Second : Client.Request;
      begin
         Client.Set_Target (Second, "/after-reset");
         declare
            Reply : Client.Response :=
              Client.Execute (Item, Second, Timeout => 30.0);
         begin
            Check_Body (Reply, "flyology-http2");
         end;
      end;
   else
      declare
         Results : Outcome (1);
         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : aliased Client.Request;
         begin
            Client.Set_Target (Value, "/" & Scenario);
            if Scenario = "composable-abandon" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : Buffers.Unique_Buffer (Pool'Access);
                  Set : aliased Operations.Completion_Set (3);
                  Token : aliased Flyology.Cancellation.Token;
                  Terminal_OK : Boolean := False;
               begin
                  Buffers.Acquire (Destination);
                  declare
                     Operation : constant Client.Exchange_Operation :=
                       Client.Exchange_To_Buffer
                         (Set'Access, Item'Access, Value'Unchecked_Access,
                          Destination, Client.Deadline_After (30.0),
                          Token'Access);
                     task Canceller;
                     task body Canceller is
                     begin
                        delay 0.10;
                        Token.Request;
                     end Canceller;
                  begin
                     Operations.Wait_All (Set);
                     Terminal_OK :=
                       Operations.Outcome (Operation) = Operations.Cancelled
                         and then Client.Admission (Operation) =
                           Client.Response_Observed;
                     --  Deliberately omit Finish. Finalization must drain the
                     --  reset and return the detached token to its pool.
                  end;
                  pragma Assert (not Buffers.Has_Buffer (Destination));
                  Buffers.Acquire (Destination);
                  Results.Report
                    (Terminal_OK and then Buffers.Length (Destination) = 0);
                  Buffers.Release (Destination);
               end;
            elsif Scenario = "composable-cancel" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : Buffers.Unique_Buffer (Pool'Access);
                  Set : aliased Operations.Completion_Set (3);
                  Result : Client.Exchange_Result;
                  Reply : Client.Response;
               begin
                  Buffers.Acquire (Destination);
                  declare
                     Operation : aliased Client.Exchange_Operation :=
                       Client.Exchange_To_Buffer
                         (Set'Access, Item'Access, Value'Unchecked_Access,
                          Destination, Client.Deadline_After (30.0));
                     task Canceller;
                     task body Canceller is
                     begin
                        delay 0.10;
                        Operations.Cancel (Operation);
                     end Canceller;
                  begin
                     Operations.Wait_All (Set);
                     Client.Finish
                       (Operation, Result, Reply, Destination);
                  end;
                  Results.Report
                    (Client.Kind (Result) = Client.Cancelled
                       and then Client.Certainty (Result) =
                         Client.Response_Observed
                       and then Buffers.Length (Destination) = 0);
                  Buffers.Release (Destination);
               end;
            elsif Scenario = "composable-parent" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : aliased Buffers.Unique_Buffer (Pool'Access);
                  Set : aliased Operations.Completion_Set (4);
                  Batch : Operations.Completion_Batch (Set.Capacity);
                  Parent : aliased Parent_Operation
                    (Set'Access, Item'Access, Value'Unchecked_Access,
                     Destination'Unchecked_Access);
               begin
                  Buffers.Acquire (Destination);
                  Drivers.Start (Parent);
                  Operations.Drive
                    (Operations.Operation'Class (Parent),
                     Operations.Start_Operation);
                  Operations.Wait_For_Success (Set, Batch);
                  pragma Assert (Batch.Count = 1);
                  Results.Report
                    (Operations.Outcome (Parent) = Operations.Succeeded
                       and then Parent.Passed);
                  Operations.Consume (Parent);
                  Operations.Release (Parent);
                  Buffers.Release (Destination);
               end;
            elsif Scenario in "composable" | "composable-tls" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : Buffers.Unique_Buffer (Pool'Access);
                  Set : aliased Operations.Completion_Set (3);
                  Result : Client.Exchange_Result;
                  Reply  : Client.Response;
               begin
                  Buffers.Acquire (Destination);
                  declare
                     Operation : Client.Exchange_Operation :=
                       Client.Exchange_To_Buffer
                         (Set'Access, Item'Access, Value'Unchecked_Access,
                          Destination, Client.Deadline_After (30.0));
                  begin
                     Operations.Wait_All (Set);
                     Client.Finish
                       (Operation, Result, Reply, Destination);
                  end;
                  Corpus.Check
                    (Golden.Complete_Fixed, Golden.H2,
                     Golden.Composable_Buffer,
                     (Kind => Corpus.To_Golden (Client.Kind (Result)),
                      Certainty =>
                        Corpus.To_Golden (Client.Certainty (Result)),
                      Status_Known => True,
                      Status => Client.Status (Reply),
                      Body_Effect => Golden.Complete,
                      others => <>));
                  Results.Report
                    (Client.Kind (Result) = Client.Response_Complete
                       and then Client.Certainty (Result) =
                         Client.Response_Observed
                       and then Client.Status (Reply) = 200
                       and then Client.Negotiated_Protocol (Reply) =
                         Flyology.HTTP.HTTP_2_Protocol
                       and then Buffers.Length (Destination) =
                         14);
                  Buffers.Release (Destination);
                  declare
                     Invalid : aliased Client.Request;
                     Invalid_Result : Client.Exchange_Result;
                     Invalid_Reply : Client.Response;
                  begin
                     Client.Set_Expect_Continue (Invalid);
                     Buffers.Acquire (Destination);
                     Buffers.Set_Tag (Destination, 42);
                     declare
                        Operation : Client.Exchange_Operation :=
                          Client.Exchange_To_Buffer
                            (Set'Access, Item'Access,
                             Invalid'Unchecked_Access, Destination,
                             Client.Deadline_After (30.0));
                     begin
                        Operations.Wait_All (Set);
                        Client.Finish
                          (Operation, Invalid_Result, Invalid_Reply,
                           Destination);
                     end;
                     pragma Assert
                       (Client.Kind (Invalid_Result) =
                          Client.Pre_Admission_Rejected);
                     pragma Assert
                       (Client.Certainty (Invalid_Result) =
                          Client.Not_Admitted);
                     pragma Assert (Buffers.Has_Buffer (Destination));
                     pragma Assert (Buffers.Length (Destination) = 0);
                     pragma Assert (Buffers.Tag (Destination) = 42);
                     Buffers.Release (Destination);
                  end;
               end;
            elsif Scenario = "composable-source-early-final" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : Buffers.Unique_Buffer (Pool'Access);
                  Source : aliased Blocked_Source;
                  Set : aliased Operations.Completion_Set (3);
                  Result : Client.Exchange_Result;
                  Reply : Client.Response;
               begin
                  Client.Set_Method (Value, Flyology.HTTP.Methods.POST);
                  Buffers.Acquire (Destination);
                  declare
                     Operation : Client.Exchange_Operation :=
                       Client.Exchange_To_Buffer
                         (Set'Access, Item'Access, Value'Unchecked_Access,
                          Source'Access, Destination,
                          Client.Deadline_After (30.0));
                  begin
                     Operations.Wait_All (Set);
                     Client.Finish
                       (Operation, Result, Reply, Destination);
                  end;
                  Corpus.Check
                    (Golden.Blocked_Source_Early_Final, Golden.H2,
                     Golden.Composable_Buffer,
                     (Kind => Corpus.To_Golden (Client.Kind (Result)),
                      Certainty =>
                        Corpus.To_Golden (Client.Certainty (Result)),
                      Status_Known => True,
                      Status => Client.Status (Reply),
                      Body_Effect => Golden.Empty,
                      Source_Releases => Source.Releases,
                      Request_Reset => True,
                      others => <>));
                  Results.Report
                    (Client.Kind (Result) = Client.Response_Complete
                       and then Client.Certainty (Result) =
                         Client.Response_Observed
                       and then Client.Status (Reply) = 413
                       and then Source.Releases = 1
                       and then Buffers.Length (Destination) = 0);
                  Buffers.Release (Destination);
               end;
            elsif Scenario = "composable-source-contract" then
               declare
                  package Buffers renames Flyology.Buffers;
                  package Operations renames Flyology.Operations;
                  Pool : aliased Buffers.Pool
                    (Block_Size => 64, Capacity => 1);
                  Destination : Buffers.Unique_Buffer (Pool'Access);
                  Set : aliased Operations.Completion_Set (3);
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
                            (Set'Access, Item'Access,
                             Value'Unchecked_Access, Source'Access,
                             Destination, Client.Deadline_After (30.0));
                     begin
                        Operations.Wait_All (Set);
                        Client.Finish
                          (Operation, Result, Reply, Destination);
                     end;
                     Corpus.Check
                       (Scenario, Golden.H2, Golden.Composable_Buffer,
                        (Kind => Corpus.To_Golden (Client.Kind (Result)),
                         Certainty =>
                           Corpus.To_Golden (Client.Certainty (Result)),
                         Body_Effect => Golden.Zero,
                         Source_Releases => Faults.Release_Count (Source),
                         Request_Reset => True,
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
                  Client.Set_Method (Value, Flyology.HTTP.Methods.POST);
                  Buffers.Acquire (Destination);
                  Check_Fault (Faults.Short_Source, Golden.Source_Short);
                  Check_Fault (Faults.Long_Source, Golden.Source_Long);
                  Check_Fault
                    (Faults.Zero_Progress_Source,
                     Golden.Source_Zero_Progress);
                  Check_Fault
                    (Faults.Needs_With_Bytes_Source,
                     Golden.Source_Needs_With_Bytes);
                  Check_Fault
                    (Faults.Exceptional_Source,
                     Golden.Source_Exception);
                  Results.Report (Passed, "composable source contract");
                  Buffers.Release (Destination);
               end;
            elsif Scenario = "composable-sink-contract" then
               declare
                  package Operations renames Flyology.Operations;
                  Set : aliased Operations.Completion_Set (3);
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
                            (Set'Access, Item'Access,
                             Value'Unchecked_Access, Sink'Access,
                             Client.Deadline_After (30.0));
                     begin
                        Operations.Wait_All (Set);
                        Client.Finish
                          (Operation, Result, Reply);
                     end;
                     Corpus.Check
                       (Scenario, Golden.H2, Golden.Composable_Sink,
                        (Kind => Corpus.To_Golden (Client.Kind (Result)),
                         Certainty =>
                           Corpus.To_Golden (Client.Certainty (Result)),
                         Body_Effect => Golden.Partial_Visible,
                         Request_Reset => True,
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
                  Results.Report (Passed, "composable sink contract");
               end;
            else
            if Scenario in "upload" | "early-final" | "early-final-body" then
               declare
                  type Payload_Access is access
                    Ada.Streams.Stream_Element_Array;
                  procedure Free is new Ada.Unchecked_Deallocation
                    (Ada.Streams.Stream_Element_Array, Payload_Access);
                  Payload : Payload_Access := new
                    Ada.Streams.Stream_Element_Array (1 .. 256 * 1_024);
               begin
                  for Index in Payload.all'Range loop
                     Payload.all (Index) := Ada.Streams.Stream_Element
                       (Natural (Index - Payload.all'First) mod 256);
                  end loop;
                  Client.Set_Body (Value, Payload.all);
                  Free (Payload);
               end;
               if Scenario in "early-final" | "early-final-body" then
                  Client.Set_Method
                    (Value, Flyology.HTTP.To_Method ("POST"));
               end if;
            elsif Scenario = "refused-post" then
               Client.Set_Method (Value, Flyology.HTTP.To_Method ("POST"));
            elsif Scenario = "head-empty-data" then
               Client.Set_Method (Value, Flyology.HTTP.Methods.HEAD);
            end if;
            if Scenario in
              "require-failure" | "refused-post" | "bad-preface" |
              "informational-end"
            then
               begin
                  declare
                     Reply : Client.Response :=
                       Client.Execute (Item, Value, Timeout => 30.0);
                     pragma Unreferenced (Reply);
                  begin
                     Results.Report
                       (False, "HTTP/2 request unexpectedly succeeded");
                  end;
               exception
                  when Flyology.HTTP.Protocol_Error =>
                     Results.Report (True);
               end;
            else
               declare
                  Reply : Client.Response :=
                    Client.Execute (Item, Value, Timeout => 30.0);
               begin
                  if Scenario = "flow" then
                     Check_Flow (Reply);
                  elsif Scenario in "early-final" | "early-final-body" then
                     pragma Assert (Client.Status (Reply) = 413);
                     declare
                        Content : constant Flyology.Bytes.Unbounded_Bytes :=
                          Client.Read_All (Reply);
                     begin
                        pragma Assert
                          (Flyology.Bytes.To_Byte_String (Content) =
                             (if Scenario = "early-final-body"
                              then "rejected" else ""));
                     end;
                     --  Terminal publication means the RST_STREAM frame has
                     --  been committed to the transport, not that the peer
                     --  task has already parsed it. Keep the pooled TLS
                     --  connection alive briefly so the peer-side wire oracle
                     --  can observe that committed frame before Item leaves
                     --  scope in either owner model.
                     delay 0.05;
                  elsif Scenario = "head-empty-data" then
                     pragma Assert
                       (Client.Header (Reply, "content-length") =
                          "5368709129");
                     pragma Assert
                       (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
                  elsif Scenario = "zero-read" then
                     declare
                        Empty : Ada.Streams.Stream_Element_Array (1 .. 0);
                        Last : Ada.Streams.Stream_Element_Offset;
                        Finished : Boolean;
                     begin
                        Client.Read_Body (Reply, Empty, Last, Finished);
                        pragma Assert (Last = Empty'First - 1);
                        pragma Assert (not Finished);
                     end;
                     Check_Body (Reply, "flyology-http2");
                  elsif Scenario = "fallback" then
                     pragma Assert
                       (Client.Negotiated_Protocol (Reply) =
                          Flyology.HTTP.HTTP_1_1_Protocol);
                     pragma Assert
                       (Flyology.Bytes.To_Byte_String
                          (Client.Read_All (Reply)) = "fallback");
                  else
                     Check_Body (Reply, "flyology-http2");
                  end if;
               end;
               Results.Report (True);
            end if;
            end if;
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   end if;
   Client.Shutdown (Item, Timeout => 5.0);
   Ada.Text_IO.Put_Line ("HTTP/2 client integration passed");
end HTTP2_Client_Integration;
