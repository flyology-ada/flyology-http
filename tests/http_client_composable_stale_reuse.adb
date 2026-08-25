with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with GNAT.OS_Lib;
with HTTP_Client_Corpus_Oracle;

procedure HTTP_Client_Composable_Stale_Reuse is
   package Buffers renames Flyology.Buffers;
   package Client renames Flyology.HTTP.Client;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;
   package Sockets renames Flyology.IO.Sockets;
   package Corpus renames HTTP_Client_Corpus_Oracle;
   package Golden renames HTTP_Client_Corpus_Oracle.Golden;

   use Ada.Streams;
   use type Client.Exchange_Result_Kind;
   use type Operations.Driver_Event;
   use type Operations.Terminal_Outcome;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Error_Body : constant String :=
     "<Error>" & String'(1 .. 387 => 'x') & "</Error>";
   Reconciled_Body : constant String := "reconciled";
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
     "flyology-http-composable-stale-" &
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

   procedure Send (Socket : Sockets.Socket_Type; Value : String) is
   begin
      Sockets.Send_All (Socket, Bytes (Value), Timeout => 5.0);
   end Send;

   procedure Read_Head
     (Socket   : Sockets.Socket_Type;
      Expected : String)
   is
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
      pragma Assert
        (Ada.Strings.Fixed.Index (Seen (1 .. Used), Expected) /= 0);
   end Read_Head;

   procedure Remove_Path is
      Removed : Boolean;
   begin
      GNAT.OS_Lib.Delete_File (Path, Removed);
   end Remove_Path;

   type Parent_Phase is (Conditional_Put, Reconciliation_Get);

   type Reconciliation_Operation
     (Set             : not null access Operations.Completion_Set'Class;
      HTTP            : not null access Client.Client;
      Put_Request     : not null access constant Client.Request;
      Get_Request     : not null access constant Client.Request;
      Put_Destination : not null access Buffers.Unique_Buffer;
      Get_Destination : not null access Buffers.Unique_Buffer)
   is new Operations.Operation (Set) with record
      Child  : Client.Exchange_Operation (Set);
      Phase  : Parent_Phase := Conditional_Put;
      Passed : Boolean := False;
      Child_Kind : Client.Exchange_Result_Kind :=
        Client.Pre_Admission_Rejected;
      Child_Certainty : Client.Admission_Certainty := Client.Not_Admitted;
      Child_Status : Natural := 0;
   end record;

   overriding procedure Drive
     (Item  : in out Reconciliation_Operation;
      Event : Operations.Driver_Event);
   overriding procedure Request_Cancellation
     (Item : in out Reconciliation_Operation);

   overriding procedure Drive
     (Item  : in out Reconciliation_Operation;
      Event : Operations.Driver_Event)
   is
      Result : Client.Exchange_Result;
      Reply  : Client.Response;
   begin
      if Event = Operations.Start_Operation then
         Client.Exchange_To_Buffer
           (Item.HTTP, Item.Put_Request, Item.Put_Destination.all,
            Client.Deadline_After (5.0), null, Item.Child);
         Operations.Continue_After (Item, Item.Child);
      elsif Event = Operations.Dependency_Changed
        and then Item.Phase = Conditional_Put
      then
         Client.Finish
           (Item.Child, Result, Reply, Item.Put_Destination.all);
         Item.Passed :=
           Client.Kind (Result) = Client.Response_Complete
             and then Client.Status (Reply) = 412
             and then Buffers.Length (Item.Put_Destination.all) = 402;
         Operations.Release (Item.Child);
         if not Item.Passed then
            Drivers.Complete (Item, Operations.Failed);
            return;
         end if;
         Item.Phase := Reconciliation_Get;
         --  This immediate established-child restart is the object-storage
         --  reconciliation sequence: Finish, Release, and Continue_After all
         --  occur inside one serial owner-stack dependency callback.
         Client.Exchange_To_Buffer
           (Item.HTTP, Item.Get_Request, Item.Get_Destination.all,
            Client.Deadline_After (5.0), null, Item.Child);
         Operations.Continue_After (Item, Item.Child);
      elsif Event = Operations.Dependency_Changed then
         Client.Finish
           (Item.Child, Result, Reply, Item.Get_Destination.all);
         Item.Child_Kind := Client.Kind (Result);
         Item.Child_Certainty := Client.Certainty (Result);
         if Item.Child_Kind = Client.Response_Complete then
            Item.Child_Status := Client.Status (Reply);
         end if;
         Item.Passed :=
           Item.Child_Kind = Client.Response_Complete
             and then Item.Child_Status = 200
             and then Buffers.Length (Item.Get_Destination.all) =
               Reconciled_Body'Length;
         Operations.Release (Item.Child);
         Drivers.Complete
           (Item,
            (if Item.Passed
             then Operations.Succeeded
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
     (Item : in out Reconciliation_Operation) is
   begin
      Item.Passed := False;
      Operations.Cancel (Item.Child);
   exception
      when others => null;
   end Request_Cancellation;

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

   Listener      : Sockets.Socket_Type;
   Server_Passed : Boolean := False with Atomic;
   Caller_Passed : Boolean := False with Atomic;
begin
   Remove_Path;
   Sockets.Create_Unix_Stream_Socket (Listener);
   Sockets.Bind_Socket (Listener, Sockets.Unix_Pathname (Path));
   Sockets.Listen_Socket (Listener);

   declare
      task Server is
         pragma Task_Info (Flyology.Native_Task);
      end Server;

      task body Server is
         Peer  : Sockets.Socket_Type;
         Stage : Natural := 0;
      begin
         Stage := 1;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 10.0);
         Read_Head (Peer, "PUT /immutable ");
         Send
           (Peer, "HTTP/1.1 412 Precondition Failed" & CRLF &
              "Content-Type: application/xml" & CRLF &
              "Content-Length: 402" & CRLF & CRLF & Error_Body);
         --  MinIO can silently close after this fully framed response while
         --  omitting Connection: close, leaving a stale pooled H1 transport.
         --  Delay this deterministic oracle until the next safe request has
         --  reached the peer so the client must exercise its guarded
         --  Possibly_Admitted/no-response retry rather than winning a local
         --  pre-handoff close race.
         Read_Head (Peer, "GET /immutable ");
         Sockets.Close_Socket (Peer);

         Stage := 2;
         Sockets.Accept_Connection (Listener, Peer, Timeout => 10.0);
         Read_Head (Peer, "GET /immutable ");
         Send
           (Peer, "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 10" & CRLF & CRLF & Reconciled_Body);
         Sockets.Close_Socket (Peer);
         Server_Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "composable stale server failed at stage" & Natural'Image (Stage) &
                 ": " & Ada.Exceptions.Exception_Information (Error));
      end Server;

      task Caller is
         pragma Task_Info (Model);
      end Caller;

      task body Caller is
         HTTP : aliased Client.Client (Capacity => 1);
         Pool : aliased Buffers.Pool (Block_Size => 512, Capacity => 2);
         Put_Destination : aliased Buffers.Unique_Buffer (Pool'Access);
         Get_Destination : aliased Buffers.Unique_Buffer (Pool'Access);
         Put_Request : aliased Client.Request;
         Get_Request : aliased Client.Request;
         Set : aliased Operations.Completion_Set (3);
         Parent : Reconciliation_Operation
           (Set'Access, HTTP'Access, Put_Request'Access, Get_Request'Access,
            Put_Destination'Access, Get_Destination'Access);
      begin
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin ("http://composable.local"),
            Client.Unix_Socket (Path));
         Buffers.Acquire (Put_Destination);
         Buffers.Acquire (Get_Destination);
         Client.Set_Method (Put_Request, Flyology.HTTP.Methods.PUT);
         Client.Set_Target (Put_Request, "/immutable");
         Client.Add_Header (Put_Request, "If-None-Match", "*");
         Client.Set_Target (Get_Request, "/immutable");

         Drivers.Start (Parent);
         Operations.Drive
           (Operations.Operation'Class (Parent), Operations.Start_Operation);
         Operations.Wait_All (Set);
         pragma Assert
           (Operations.Outcome (Parent) = Operations.Succeeded);
         pragma Assert (Parent.Passed);
         Corpus.Check
           (Golden.Safe_Stale_After_Handoff_One_Retry,
            Golden.H1, Golden.Established_Child,
            (Kind => Corpus.To_Golden (Parent.Child_Kind),
             Certainty => Corpus.To_Golden (Parent.Child_Certainty),
             Status_Known => True,
             Status => Parent.Child_Status,
             Body_Effect => Golden.Complete,
             Automatic_Replay =>
               Client.Diagnostics (HTTP).Stale_Retries = 1,
             others => <>));
         Check_Payload (Get_Destination, Reconciled_Body);
         Operations.Consume (Parent);
         Operations.Release (Parent);
         Client.Shutdown (HTTP, Timeout => 5.0);
         Caller_Passed := True;
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "composable stale caller failed: " &
                 Ada.Exceptions.Exception_Information (Error));
      end Caller;
   begin
      null;
   end;

   Sockets.Close_Socket (Listener);
   Remove_Path;
   pragma Assert (Server_Passed);
   pragma Assert (Caller_Passed);
end HTTP_Client_Composable_Stale_Reuse;
