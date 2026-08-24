with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.Wake_Sources;
with GNAT.OS_Lib;
with HTTP_Client_Corpus_Oracle;
with HTTP_Client_Corpus_Sources;
with HTTP_Client_Corpus_Sinks;

procedure HTTP_Client_Scoped_Smoke is
   package Buffers renames Flyology.Buffers;
   package Client renames Flyology.HTTP.Client;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;
   package Sockets renames Flyology.IO.Sockets;
   package Timers renames Flyology.IO.Timers;
   package Corpus renames HTTP_Client_Corpus_Oracle;
   package Golden renames HTTP_Client_Corpus_Oracle.Golden;
   package Faults renames HTTP_Client_Corpus_Sources;
   package Sink_Faults renames HTTP_Client_Corpus_Sinks;

   use Ada.Streams;
   use type Client.Admission_Certainty;
   use type Client.Exchange_Phase;
   use type Client.Exchange_Result_Kind;
   use type Client.Source_Step_Kind;
   use type Flyology.HTTP.Protocol;
   use type Sink_Faults.Fault_Kind;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Model : constant Flyology.Execution_Model :=
     (if Ada.Command_Line.Argument_Count > 0
        and then Ada.Command_Line.Argument (1) = "lightweight"
      then Flyology.Lightweight_Task
      else Flyology.Native_Task);

   function Decimal (Value : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   Prefix : constant String :=
     Ada.Environment_Variables.Value ("TMPDIR", "/tmp");
   Path : constant String :=
     Prefix & (if Prefix (Prefix'Last) = '/' then "" else "/") &
     "flyology-http-scoped-" &
     Decimal (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id)) &
     ".sock";

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   type Blocked_Source is limited new
     Client.Operation_Request_Body_Source with record
      Wake : Flyology.Wake_Sources.Source;
      Releases : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : Blocked_Source) return Client.Body_Length;
   overriding procedure Read_Now
     (Item   : in out Blocked_Source;
      Data   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset;
      Result : out Client.Source_Step_Kind);
   overriding procedure Source_Wait_Source
     (Item        : in out Blocked_Source;
      Required    : Client.Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean);
   overriding procedure Release_Source (Item : in out Blocked_Source);

   overriding function Declared_Length
     (Item : Blocked_Source) return Client.Body_Length is
     (Client.Known_Length (8));

   overriding procedure Read_Now
     (Item   : in out Blocked_Source;
      Data   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset;
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

   type Counting_Sink is new Client.Response_Body_Sink with record
      Count : Natural := 0;
      Sum : Natural := 0;
   end record;

   overriding procedure Write
     (Item : in out Counting_Sink;
      Data : Stream_Element_Array) is
   begin
      pragma Assert (Data'Length > 0);
      Item.Count := Item.Count + Data'Length;
      for Element of Data loop
         Item.Sum := Item.Sum + Natural (Element);
      end loop;
   end Write;

   type Parent_Operation
     (Set         : not null access Operations.Completion_Set'Class;
      HTTP        : not null access Client.Client;
      Ask         : not null access constant Client.Request;
      Destination : not null access Buffers.Unique_Buffer;
      Cancel_After_Start : Boolean)
   is new Operations.Operation (Set) with record
      Child : Client.Exchange_Operation (Set);
      Timer : Timers.Timer_Operation (Set);
      Passed : Boolean := False;
      Cancelling : Boolean := False;
      Child_Kind : Client.Exchange_Result_Kind :=
        Client.Pre_Admission_Rejected;
      Child_Certainty : Client.Admission_Certainty := Client.Not_Admitted;
   end record;

   overriding procedure Drive
     (Item : in out Parent_Operation;
      Event : Operations.Driver_Event);
   overriding procedure Request_Cancellation
     (Item : in out Parent_Operation);

   overriding procedure Drive
     (Item : in out Parent_Operation;
      Event : Operations.Driver_Event) is
   begin
      if Event = Operations.Start_Operation then
         Client.Scoped.Start
            (Item.Child, Item.HTTP, Item.Ask, Item.Destination.all,
            Client.Deadline_After (5.0));
         if Item.Cancel_After_Start then
            Timers.Sleep_For (0.05, Item.Timer);
            Operations.Continue_After (Item, Item.Timer);
         else
            Operations.Continue_After (Item, Item.Child);
         end if;
      elsif Event = Operations.Dependency_Changed then
         if Item.Cancel_After_Start
           and then not Item.Cancelling
           and then Operations.Is_Terminal (Item.Timer)
         then
            Timers.Finish (Item.Timer);
            Operations.Release (Item.Timer);
            Item.Cancelling := True;
            Operations.Cancel (Item.Child);
            Operations.Continue_After (Item, Item.Child);
            return;
         end if;
         declare
            Result : Client.Exchange_Result;
            Reply : Client.Response;
         begin
            Client.Scoped.Finish
              (Item.Child, Result, Reply, Item.Destination.all);
            Item.Child_Kind := Client.Kind (Result);
            Item.Child_Certainty := Client.Certainty (Result);
            if Item.Child_Kind = Client.Cancelled then
               Item.Cancelling := True;
            end if;
            if Item.Cancelling then
               Corpus.Check
                 (Golden.Cancel_After_Admission, Golden.H1,
                  Golden.Established_Child,
                  (Kind => Corpus.To_Golden (Client.Kind (Result)),
                   Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                   Body_Effect => Golden.Zero,
                   Request_Reset => True,
                   others => <>));
               Item.Passed :=
                 Client.Kind (Result) = Client.Cancelled
                   and then Client.Certainty (Result) =
                     Client.Possibly_Admitted
                   and then Buffers.Length (Item.Destination.all) = 0;
            else
               Corpus.Check
                 (Golden.Complete_Fixed, Golden.H1,
                  Golden.Established_Child,
                  (Kind => Corpus.To_Golden (Client.Kind (Result)),
                   Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                   Status_Known => True,
                   Status => Client.Status (Reply),
                   Body_Effect => Golden.Complete,
                   others => <>));
               Item.Passed :=
                 Client.Kind (Result) = Client.Response_Complete
                   and then Client.Status (Reply) = 200
                   and then Buffers.Length (Item.Destination.all) = 6;
            end if;
         end;
         Operations.Release (Item.Child);
         Drivers.Complete
           (Item,
            (if Item.Cancelling then Operations.Cancelled
             elsif Item.Passed then Operations.Succeeded
             else Operations.Failed));
      else
         Item.Passed := False;
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
      Item.Cancelling := True;
      Operations.Cancel (Item.Child);
   exception
      when others => null;
   end Request_Cancellation;

   procedure Send (Socket : Sockets.Socket_Type; Value : String) is
   begin
      Sockets.Send_All (Socket, Bytes (Value), Timeout => 5.0);
   end Send;

   procedure Read_Head
     (Socket   : Sockets.Socket_Type;
      Expected : String := "") is
      Data : Stream_Element_Array (1 .. 512);
      Last : Stream_Element_Offset;
      Seen : String (1 .. 2_048);
      Used : Natural := 0;
   begin
      loop
         Sockets.Receive (Socket, Data, Last, Timeout => 5.0);
         pragma Assert (Last >= Data'First);
         for Index in Data'First .. Last loop
            Used := Used + 1;
            Seen (Used) := Character'Val (Data (Index));
         end loop;
         exit when Ada.Strings.Fixed.Index
           (Seen (1 .. Used), CRLF & CRLF) /= 0;
      end loop;
      if Expected'Length > 0
        and then Ada.Strings.Fixed.Index
          (Seen (1 .. Used), " " & Expected & " ") = 0
      then
         raise Program_Error with
           "expected " & Expected & ", received " & Seen (1 .. Used);
      end if;
   end Read_Head;

   procedure Read_Until_Close (Socket : Sockets.Socket_Type) is
      Data : Stream_Element_Array (1 .. 512);
      Last : Stream_Element_Offset;
   begin
      loop
         Sockets.Receive (Socket, Data, Last, Timeout => 5.0);
         exit when Last < Data'First;
      end loop;
   end Read_Until_Close;

   procedure Remove_Path is
      Removed : Boolean;
   begin
      GNAT.OS_Lib.Delete_File (Path, Removed);
   end Remove_Path;

   procedure Check_Payload
     (Item : Buffers.Unique_Buffer; Expected : String)
   is
      procedure Check (Data : Stream_Element_Array) is
      begin
         pragma Assert (Data'Length = Expected'Length);
         for Offset in 0 .. Expected'Length - 1 loop
            pragma Assert
              (Data (Data'First + Stream_Element_Offset (Offset)) =
                 Stream_Element
                   (Character'Pos (Expected (Expected'First + Offset))));
         end loop;
      end Check;
   begin
      Buffers.With_Readable_Data (Item, Check'Access);
   end Check_Payload;

   protected type Gate is
      procedure Signal;
      entry Wait;
   private
      Ready : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Signal is
      begin
         Ready := True;
      end Signal;

      entry Wait when Ready is
      begin
         Ready := False;
      end Wait;
   end Gate;

   Source_Accept_Gate      : Gate;
   Parent_Accept_Gate      : Gate;
   Loop_Accept_Gate        : Gate;
   Sink_Accept_Gate        : Gate;
   Abandonment_Accept_Gate : Gate;
   Abandonment_Gate        : Gate;
   Fault_Wakes : array (Faults.Fault_Kind) of aliased
     Flyology.Wake_Sources.Source;

   Listener : Sockets.Socket_Type;
   Server_Passed : Boolean := False with Atomic;
   Caller_Passed : Boolean := False with Atomic;
   Client_Fault_Position : Natural := 0 with Atomic;
begin
   for Fault in Faults.Fault_Kind loop
      Flyology.Wake_Sources.Ensure (Fault_Wakes (Fault));
   end loop;
   Remove_Path;
   Sockets.Create_Unix_Stream_Socket (Listener);
   Sockets.Bind_Socket (Listener, Sockets.Unix_Pathname (Path));
   Sockets.Listen_Socket (Listener);

   declare
      task Server is
         pragma Task_Info (Flyology.Native_Task);
      end Server;

      task body Server is
         Peer : Sockets.Socket_Type;
         Stage : Natural := 0;
      begin
         Stage := 1;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
         Read_Head (Peer, "/");
         Send
           (Peer, "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 4" & CRLF & CRLF & "body");
         Read_Head (Peer, "/");
         Send
           (Peer, "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 40" & CRLF & CRLF &
              "0123456789012345678901234567890123456789");
         Read_Head (Peer, "/");
         Send
           (Peer, "HTTP/1.1 204 No Content" & CRLF &
              "Content-Length: 0" & CRLF & CRLF);
         Read_Head (Peer, "/");
         Send
           (Peer, "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 6" & CRLF & CRLF & "parent");
         Read_Head (Peer, "/");
         Send
           (Peer, "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 9" & CRLF & CRLF & "sink-data");
         Read_Head (Peer, "/early");
         Send
           (Peer, "HTTP/1.1 413 Content Too Large" & CRLF &
              "Content-Length: 0" & CRLF & CRLF);
         declare
            Data : Stream_Element_Array (1 .. 1);
            Last : Stream_Element_Offset;
         begin
            Sockets.Receive (Peer, Data, Last, Timeout => 5.0);
            pragma Assert (Last < Data'First);
         end;
         Sockets.Close_Socket (Peer);
         Stage := 2;
         for Fault in Faults.Fault_Kind loop
            Stage := 20 + Faults.Fault_Kind'Pos (Fault);
            Source_Accept_Gate.Signal;
            Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
            delay 0.05;
            Flyology.Wake_Sources.Signal (Fault_Wakes (Fault));
            Read_Until_Close (Peer);
            Sockets.Close_Socket (Peer);
         end loop;
         Stage := 3;
         Parent_Accept_Gate.Signal;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
         Read_Head (Peer, "/parent-cancel");
         Read_Until_Close (Peer);
         Sockets.Close_Socket (Peer);
         Stage := 4;
         Loop_Accept_Gate.Signal;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
         for Iteration in 1 .. 10_000 loop
            Stage := 40_000 + Iteration;
            Read_Head (Peer, "/slot-loop");
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF &
                 "Content-Length: 0" & CRLF & CRLF);
         end loop;
         for Iteration in 1 .. 10_000 loop
            Stage := 50_000 + Iteration;
            Read_Head (Peer, "/sync-loop");
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF &
                 "Content-Length: 0" & CRLF & CRLF);
         end loop;
         Sockets.Close_Socket (Peer);
         Stage := 5;
         Sink_Accept_Gate.Signal;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
         for Fault in Sink_Faults.Fault_Kind loop
            pragma Unreferenced (Fault);
            Read_Head (Peer, "/sink");
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF &
                 "Content-Length: 9" & CRLF & CRLF & "sink-data");
         end loop;
         Sockets.Close_Socket (Peer);
         Stage := 6;
         Abandonment_Accept_Gate.Signal;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 15.0);
         Read_Head (Peer, "/abandon");
         Abandonment_Gate.Signal;
         Read_Until_Close (Peer);
         Sockets.Close_Socket (Peer);
         Server_Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "scoped H1 server failed: " &
                 "stage" & Natural'Image (Stage) & ": " &
                 ", client-fault=" &
                 Natural'Image (Client_Fault_Position) &
                 ": " &
                    Ada.Exceptions.Exception_Information (Error));
            Source_Accept_Gate.Signal;
            for Fault in Faults.Fault_Kind loop
               Flyology.Wake_Sources.Signal (Fault_Wakes (Fault));
            end loop;
            Parent_Accept_Gate.Signal;
            Loop_Accept_Gate.Signal;
            Sink_Accept_Gate.Signal;
            Abandonment_Accept_Gate.Signal;
            Abandonment_Gate.Signal;
      end Server;

      task Caller is
         pragma Task_Info (Model);
      end Caller;

      task body Caller is
         HTTP : aliased Client.Client (Capacity => 1);
         Pool : aliased Buffers.Pool (Block_Size => 16, Capacity => 1);
         Destination : aliased Buffers.Unique_Buffer (Pool'Access);
         Ask  : aliased Client.Request;
         Stage : Natural := 0;
      begin
         Client.Configure
        (HTTP, Flyology.HTTP.Parse_Origin ("http://scoped.local"),
         Client.Unix_Socket (Path));
      Buffers.Acquire (Destination);
      Stage := 1;

      declare
         Set : aliased Operations.Completion_Set (3);
         Operation : Client.Exchange_Operation :=
           Client.Scoped.Exchange_To_Buffer
             (Set'Access, HTTP'Access, Ask'Access, Destination,
              Client.Deadline_After (5.0));
         Result : Client.Exchange_Result;
         Reply  : Client.Response;
      begin
         Operations.Cancel (Operation);
         if Operations.Is_Active (Operation) then
            Operations.Wait_All (Set);
         end if;
         Client.Scoped.Finish (Operation, Result, Reply, Destination);
         pragma Assert (Client.Kind (Result) = Client.Cancelled);
         pragma Assert
           (Client.Certainty (Result) = Client.Not_Admitted);
         pragma Assert (Buffers.Length (Destination) = 0);
         Corpus.Check
           (Golden.Cancel_Before_Admission, Golden.H1,
            Golden.Scoped_Buffer,
             (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Body_Effect => Golden.Zero,
             Request_Reset => False,
             others => <>));
      end;

      declare
         Set : aliased Operations.Completion_Set (5);
         Token : aliased Flyology.Cancellation.Token;
         Op  : Client.Exchange_Operation := Client.Scoped.Exchange_To_Buffer
           (Set'Access, HTTP'Access, Ask'Access, Destination,
            Client.Deadline_After (5.0), Token'Access);
         Result : Client.Exchange_Result;
         Reply  : Client.Response;
      begin
         pragma Assert (not Buffers.Has_Buffer (Destination));
         Operations.Wait_All (Set);
         Client.Scoped.Finish (Op, Result, Reply, Destination);
         pragma Assert (Client.Kind (Result) = Client.Response_Complete);
         pragma Assert
           (Client.Certainty (Result) = Client.Response_Observed);
         pragma Assert (Client.Status (Reply) = 200);
         pragma Assert (Client.Body_Complete (Reply));
         Check_Payload (Destination, "body");
         Corpus.Check
           (Golden.Complete_Fixed, Golden.H1, Golden.Scoped_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Status_Known => True,
             Status => Client.Status (Reply),
             Body_Effect => Golden.Complete,
             others => <>));
      end;
      Stage := 2;

      declare
         Set : aliased Operations.Completion_Set (3);
         Op  : Client.Exchange_Operation := Client.Scoped.Exchange_To_Buffer
           (Set'Access, HTTP'Access, Ask'Access, Destination,
            Client.Deadline_After (5.0));
         Result : Client.Exchange_Result;
         Reply  : Client.Response;
      begin
         Operations.Wait_All (Set);
         Client.Scoped.Finish (Op, Result, Reply, Destination);
         pragma Assert
           (Client.Kind (Result) = Client.Response_Body_Too_Large);
         pragma Assert (Buffers.Length (Destination) = 0);
         pragma Assert (Client.Required_Body_Length (Result).Known);
         pragma Assert
           (Client.Required_Body_Length (Result).Bytes = 40);
         Corpus.Check
           (Golden.Known_Capacity_Overflow, Golden.H1,
            Golden.Scoped_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Body_Effect => Golden.Zero,
             Required_Length_Known =>
               Client.Required_Body_Length (Result).Known,
             Required_Length =>
               Natural (Client.Required_Body_Length (Result).Bytes),
             others => <>));
      end;
      Stage := 3;

      declare
         Set : aliased Operations.Completion_Set (3);
         Op  : Client.Exchange_Operation := Client.Scoped.Exchange_To_Buffer
           (Set'Access, HTTP'Access, Ask'Access, Destination,
            Client.Deadline_After (5.0));
         Result : Client.Exchange_Result;
         Reply  : Client.Response;
      begin
         Operations.Wait_All (Set);
         Client.Scoped.Finish (Op, Result, Reply, Destination);
         pragma Assert (Client.Kind (Result) = Client.Response_Complete);
         pragma Assert (Client.Status (Reply) = 204);
         pragma Assert (Buffers.Length (Destination) = 0);
         Corpus.Check
           (Golden.No_Body_204, Golden.H1, Golden.Scoped_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Status_Known => True,
             Status => Client.Status (Reply),
             Body_Effect => Golden.Empty,
             others => <>));
      end;
      Stage := 4;

      declare
         Set : aliased Operations.Completion_Set (3);
         Parent : Parent_Operation
           (Set'Access, HTTP'Access, Ask'Access,
            Destination'Unchecked_Access, False);
      begin
         Drivers.Start (Parent);
         Operations.Drive
           (Operations.Operation'Class (Parent), Operations.Start_Operation);
         Operations.Wait_All (Set);
         pragma Assert (Operations.Outcome (Parent) = Operations.Succeeded);
         Operations.Consume (Parent);
         Operations.Release (Parent);
         pragma Assert (Parent.Passed);
         Check_Payload (Destination, "parent");
      end;
      Stage := 5;

      declare
         Sink : aliased Counting_Sink;
         Set : aliased Operations.Completion_Set (3);
         Operation : Client.Exchange_Operation :=
           Client.Scoped.Exchange_To_Sink
             (Set'Access, HTTP'Access, Ask'Access, Sink'Access,
              Client.Deadline_After (5.0));
         Result : Client.Exchange_Result;
         Reply : Client.Response;
      begin
         Operations.Wait_All (Set);
         Client.Scoped.Finish (Operation, Result, Reply);
         pragma Assert (Client.Kind (Result) = Client.Response_Complete);
         pragma Assert (Client.Status (Reply) = 200);
         pragma Assert (Sink.Count = 9);
         pragma Assert
           (Sink.Sum = Character'Pos ('s') + Character'Pos ('i') +
              Character'Pos ('n') + Character'Pos ('k') +
              Character'Pos ('-') + Character'Pos ('d') +
              Character'Pos ('a') + Character'Pos ('t') +
              Character'Pos ('a'));
         Corpus.Check
           (Golden.Complete_Fixed, Golden.H1, Golden.Scoped_Sink,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Status_Known => True,
             Status => Client.Status (Reply),
             Body_Effect => Golden.Complete,
             others => <>));
      end;
      Stage := 6;

      declare
         Source : aliased Blocked_Source;
         Set : aliased Operations.Completion_Set (3);
         Result : Client.Exchange_Result;
         Reply : Client.Response;
      begin
         Client.Set_Method (Ask, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Ask, "/early");
         declare
            Op : Client.Exchange_Operation :=
              Client.Scoped.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Ask'Access, Source'Access,
                 Destination, Client.Deadline_After (5.0));
         begin
            Operations.Wait_All (Set);
            Client.Scoped.Finish (Op, Result, Reply, Destination);
         end;
         pragma Assert (Client.Kind (Result) = Client.Response_Complete);
         pragma Assert (Client.Status (Reply) = 413);
         pragma Assert (Source.Releases = 1);
         pragma Assert (Buffers.Length (Destination) = 0);
         pragma Assert
           (Client.Diagnostics (HTTP).Reusable_Transports = 0);
         Corpus.Check
           (Golden.Blocked_Source_Early_Final, Golden.H1,
            Golden.Scoped_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Status_Known => True,
             Status => Client.Status (Reply),
             Body_Effect => Golden.Empty,
             Source_Releases => Source.Releases,
             Request_Reset => True,
             others => <>));
      end;
      Stage := 7;

      declare
         Set : aliased Operations.Completion_Set (3);
         Passed : Boolean := True;

         procedure Check_Fault
           (Fault    : Faults.Fault_Kind;
            Scenario : Golden.Case_Kind) is
            Fault_HTTP : aliased Client.Client (Capacity => 1);
            Source : aliased Faults.Fault_Source
              (Fault, Fault_Wakes (Fault)'Access);
            Result : Client.Exchange_Result;
            Reply : Client.Response;
         begin
            Client.Configure
              (Fault_HTTP, Flyology.HTTP.Parse_Origin
                 ("http://scoped.local"),
               Client.Unix_Socket (Path));
            Source_Accept_Gate.Wait;
            delay 0.01;
            Client_Fault_Position := Faults.Fault_Kind'Pos (Fault) + 1;
            Client.Set_Target
              (Ask, "/source-" &
                 Decimal (Faults.Fault_Kind'Pos (Fault)));
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Scoped.Exchange_To_Buffer
                   (Set'Access, Fault_HTTP'Access, Ask'Access, Source'Access,
                    Destination, Client.Deadline_After (5.0));
            begin
               Operations.Wait_All (Set);
               Client.Scoped.Finish
                 (Operation, Result, Reply, Destination);
            end;
            Corpus.Check
              (Scenario, Golden.H1, Golden.Scoped_Buffer,
               (Kind => Corpus.To_Golden (Client.Kind (Result)),
                Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                Body_Effect => Golden.Zero,
                Source_Releases => Faults.Release_Count (Source),
                others => <>));
            Passed := Passed
              and then Client.Kind (Result) = Client.Request_Source_Failed
              and then Client.Certainty (Result) =
                Client.Possibly_Admitted
              and then Faults.Release_Count (Source) = 1
              and then Buffers.Length (Destination) = 0;
            pragma Assert
              (Client.Diagnostics (Fault_HTTP).Reusable_Transports = 0);
            declare
               Snapshot : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (Fault_HTTP);
            begin
               pragma Assert (Snapshot.Active_Exchanges = 0);
               pragma Assert (Snapshot.Pending_Transports = 0);
               pragma Assert (Snapshot.Closing_Transports = 0);
               pragma Assert (Snapshot.Transports_Created = 1);
               pragma Assert (Snapshot.Transports_Closed = 1);
            end;
            Client_Fault_Position := Faults.Fault_Kind'Pos (Fault) + 101;
         end Check_Fault;
      begin
         Check_Fault (Faults.Short_Source, Golden.Source_Short);
         Check_Fault (Faults.Long_Source, Golden.Source_Long);
         Check_Fault
           (Faults.Zero_Progress_Source, Golden.Source_Zero_Progress);
         Check_Fault
           (Faults.Needs_With_Bytes_Source,
            Golden.Source_Needs_With_Bytes);
         Check_Fault (Faults.Exceptional_Source, Golden.Source_Exception);
         pragma Assert (Passed);
      end;
      Stage := 8;

      declare
         Set : aliased Operations.Completion_Set (6);
         Parent : aliased Parent_Operation
           (Set'Access, HTTP'Access, Ask'Access,
            Destination'Unchecked_Access, True);
      begin
         Parent_Accept_Gate.Wait;
         delay 0.01;
         Client.Set_Target (Ask, "/parent-cancel");
         Drivers.Start (Parent);
         Operations.Drive
           (Operations.Operation'Class (Parent), Operations.Start_Operation);
         Operations.Wait_All (Set);
         if Operations.Outcome (Parent) /= Operations.Cancelled then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "parent outcome=" &
                 Operations.Terminal_Outcome'Image
                   (Operations.Outcome (Parent)) &
                 " child=" & Client.Exchange_Result_Kind'Image
                   (Parent.Child_Kind) &
                 " certainty=" & Client.Admission_Certainty'Image
                   (Parent.Child_Certainty));
         end if;
         pragma Assert (Operations.Outcome (Parent) = Operations.Cancelled);
         Operations.Consume (Parent);
         Operations.Release (Parent);
         pragma Assert (Parent.Passed);
         pragma Assert (Buffers.Length (Destination) = 0);
         declare
            Snapshot : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            if Snapshot.Active_Exchanges /= 0
              or else Snapshot.Pending_Transports /= 0
              or else Snapshot.Reusable_Transports /= 0
              or else Snapshot.Closing_Transports /= 0
            then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "scoped H1 post-cancel pool: active" &
                    Natural'Image (Snapshot.Active_Exchanges) &
                    " pending" &
                    Natural'Image (Snapshot.Pending_Transports) &
                    " reusable" &
                    Natural'Image (Snapshot.Reusable_Transports) &
                    " closing" &
                    Natural'Image (Snapshot.Closing_Transports));
            end if;
            pragma Assert (Snapshot.Active_Exchanges = 0);
            pragma Assert (Snapshot.Pending_Transports = 0);
            pragma Assert (Snapshot.Reusable_Transports = 0);
            pragma Assert (Snapshot.Closing_Transports = 0);
         end;
      end;
      Stage := 9;

      declare
         Set : aliased Operations.Completion_Set (3);
         Batch : Operations.Completion_Batch (Set.Capacity);
      begin
         Loop_Accept_Gate.Wait;
         delay 0.01;
         Client.Set_Method (Ask, Flyology.HTTP.Methods.GET);
         Client.Set_Target (Ask, "/slot-loop");
         for Iteration in 1 .. 10_000 loop
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Scoped.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Ask'Access, Destination,
                    Client.Deadline_After (5.0));
               Result : Client.Exchange_Result;
               Reply : Client.Response;
            begin
               case Iteration is
                  when 1 =>
                     Operations.Wait_Some
                       (Set, Required => 1, Completed => Batch);
                     pragma Assert (Batch.Count = 1);
                  when 2 =>
                     Operations.Wait_For_Success (Set, Batch);
                     pragma Assert (Batch.Count = 1);
                  when others =>
                     Operations.Wait_All (Set);
               end case;
               Client.Scoped.Finish
                 (Operation, Result, Reply, Destination);
               if Client.Kind (Result) /= Client.Response_Complete then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "scoped H1 slot iteration" &
                       Positive'Image (Iteration) & ": " &
                       Client.Exchange_Result_Kind'Image
                         (Client.Kind (Result)) & " / " &
                       Client.Admission_Certainty'Image
                         (Client.Certainty (Result)) & " / " &
                       Client.Exchange_Phase'Image
                         (Client.Phase (Result)));
               end if;
               pragma Assert
                 (Client.Kind (Result) = Client.Response_Complete);
               pragma Assert (Client.Status (Reply) = 200);
               pragma Assert (Buffers.Length (Destination) = 0);
            end;
         end loop;
         Corpus.Check
           (Golden.Slot_Reuse_Loop, Golden.H1, Golden.Scoped_Buffer,
            (Kind => Golden.Response_Complete,
             Certainty => Golden.Response_Observed,
             Status_Known => True,
             Status => 200,
             Body_Effect => Golden.Complete,
             others => <>));
         Client.Set_Target (Ask, "/sync-loop");
         declare
            Reply   : Client.Response;
            Content : Flyology.Bytes.Unbounded_Bytes;
         begin
            for Iteration in 1 .. 10_000 loop
               Client.Execute (HTTP, Ask, Reply, Timeout => 5.0);
               pragma Assert (Client.Status (Reply) = 200);
               pragma Assert
                 (Client.Negotiated_Protocol (Reply) =
                    Flyology.HTTP.HTTP_1_1_Protocol);
               Client.Read_All (Reply, Content);
               pragma Assert (Flyology.Bytes.Length (Content) = 0);
            end loop;
         end;
      end;
      Stage := 10;

      declare
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
                 Client.Scoped.Exchange_To_Sink
                   (Set'Access, HTTP'Access, Ask'Access, Sink'Access,
                    Client.Deadline_After (5.0));
            begin
               Operations.Wait_All (Set);
               Client.Scoped.Finish (Operation, Result, Reply);
            end;
            if Client.Kind (Result) /= Client.Response_Sink_Failed then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "scoped H1 sink result: " &
                    Client.Exchange_Result_Kind'Image
                      (Client.Kind (Result)) & " / " &
                    Client.Admission_Certainty'Image
                      (Client.Certainty (Result)) & " / " &
                    Client.Exchange_Phase'Image
                      (Client.Phase (Result)));
            end if;
            Corpus.Check
              (Scenario, Golden.H1, Golden.Scoped_Sink,
               (Kind => Corpus.To_Golden (Client.Kind (Result)),
                Certainty => Corpus.To_Golden (Client.Certainty (Result)),
                Body_Effect => Golden.Partial_Visible,
                others => <>));
            Passed := Passed
              and then Client.Kind (Result) = Client.Response_Sink_Failed
              and then Client.Certainty (Result) = Client.Response_Observed
              and then Sink_Faults.Write_Count (Sink) = 1
              and then
                (if Fault = Sink_Faults.Partial_Failure
                 then Sink_Faults.Visible_Bytes (Sink) > 0
                 else Sink_Faults.Visible_Bytes (Sink) = 0);
         end Check_Fault;
      begin
         Sink_Accept_Gate.Wait;
         delay 0.01;
         Client.Set_Target (Ask, "/sink");
         Check_Fault
           (Sink_Faults.Partial_Failure,
            Golden.Sink_Partial_Then_Failure);
         Check_Fault
           (Sink_Faults.Immediate_Failure, Golden.Sink_Exception);
         pragma Assert (Passed);
      end;
      Stage := 11;

      declare
         Set : aliased Operations.Completion_Set (5);
         Token : aliased Flyology.Cancellation.Token;

         task Canceller is
            pragma Task_Info (Flyology.Native_Task);
         end Canceller;

         task body Canceller is
         begin
            select
               Abandonment_Gate.Wait;
            or
               delay 2.0;
            end select;
            Token.Request;
         end Canceller;
      begin
         Abandonment_Accept_Gate.Wait;
         delay 0.01;
         Client.Set_Target (Ask, "/abandon");
         declare
            Operation : constant Client.Exchange_Operation :=
              Client.Scoped.Exchange_To_Buffer
                (Set'Access, HTTP'Access, Ask'Access, Destination,
                 Client.Deadline_After (5.0), Token'Access);
         begin
            Operations.Wait_All (Set);
            pragma Assert
              (Operations.Outcome (Operation) = Operations.Cancelled);
            pragma Assert
              (Client.Scoped.Admission (Operation) =
                 Client.Possibly_Admitted);
            pragma Assert
              (Client.Scoped.Raw_Phase (Operation) /= Client.Draining);
            Corpus.Check
              (Golden.Abandonment_Drain, Golden.H1,
               Golden.Scoped_Buffer,
               (Kind => Golden.Cancelled,
                Certainty => Corpus.To_Golden
                  (Client.Scoped.Admission (Operation)),
                Body_Effect => Golden.Zero,
                Request_Reset => True,
                others => <>));
            --  Deliberately omit Finish.  Finalization must release the
            --  detached response token only after cancellation has drained.
         end;
         pragma Assert (not Buffers.Has_Buffer (Destination));
         Buffers.Acquire (Destination);
         pragma Assert (Buffers.Length (Destination) = 0);
      end;
      Stage := 12;

      declare
         Set : aliased Operations.Completion_Set (3);
         Before_Length : constant Natural := Buffers.Length (Destination);
         Op : Client.Exchange_Operation := Client.Scoped.Exchange_To_Buffer
           (Set'Access, HTTP'Access, Ask'Access, Destination,
            Client.Deadline_After (0.0));
         Result : Client.Exchange_Result;
         Reply  : Client.Response;
      begin
         pragma Assert (Buffers.Has_Buffer (Destination));
         pragma Assert (Buffers.Length (Destination) = Before_Length);
         Client.Scoped.Finish (Op, Result, Reply, Destination);
         pragma Assert (Client.Kind (Result) = Client.Timed_Out);
         pragma Assert
           (Client.Certainty (Result) = Client.Not_Admitted);
         Corpus.Check
           (Golden.Expired_At_Start, Golden.H1, Golden.Scoped_Buffer,
            (Kind => Corpus.To_Golden (Client.Kind (Result)),
             Certainty => Corpus.To_Golden (Client.Certainty (Result)),
             Body_Effect => Golden.Unchanged,
             others => <>));
      end;

      Buffers.Release (Destination);
         Sockets.Close_Socket (Listener);
         Caller_Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "scoped H1 caller failed: " &
                 "stage" & Natural'Image (Stage) & ": " &
                 Ada.Exceptions.Exception_Information (Error));
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
      end Caller;
   begin
      null;
   end;
   pragma Assert (Server_Passed);
   pragma Assert (Caller_Passed);
   Remove_Path;
end HTTP_Client_Scoped_Smoke;
