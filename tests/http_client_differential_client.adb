with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.Operations;
with Flyology.QUIC.Test_Connections;

procedure HTTP_Client_Differential_Client is
   package Buffers renames Flyology.Buffers;
   package Client renames Flyology.HTTP.Client;
   package Operations renames Flyology.Operations;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Client.Exchange_Result_Kind;
   use type Client.Admission_Certainty;
   use type Flyology.HTTP.Protocol;

   Style : constant String := Ada.Command_Line.Argument (1);
   Model : constant Flyology.Execution_Model :=
     (if Ada.Command_Line.Argument (2) = "lightweight" then
        Flyology.Lightweight_Task
      else Flyology.Native_Task);
   Protocol_Name : constant String := Ada.Command_Line.Argument (3);
   URL : constant String := Ada.Command_Line.Argument (4);

   function Compact (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   procedure Put_Hex (Data : Ada.Streams.Stream_Element_Array) is
      Hex_Characters : constant String := "0123456789abcdef";
   begin
      Ada.Text_IO.Put ("body_hex=");
      for Value of Data loop
         Ada.Text_IO.Put
           (Hex_Characters (Natural (Value) / 16 + 1) &
            Hex_Characters (Natural (Value) mod 16 + 1));
      end loop;
      Ada.Text_IO.New_Line;
   end Put_Hex;

   procedure Emit
     (Reply : Client.Response;
      Content_Data : Ada.Streams.Stream_Element_Array)
   is
      Negotiated : constant Flyology.HTTP.Protocol :=
        Client.Negotiated_Protocol (Reply);
   begin
      Ada.Text_IO.Put_Line
        ("status=" & Ada.Strings.Fixed.Trim
           (Natural'Image (Natural (Client.Status (Reply))), Ada.Strings.Both));
      Ada.Text_IO.Put_Line
        ("protocol=" &
         (if Negotiated = Flyology.HTTP.HTTP_1_1_Protocol then "h1"
          elsif Negotiated = Flyology.HTTP.HTTP_2_Protocol then "h2"
          else "h3"));
      Put_Hex (Content_Data);
      for Index in 1 .. Client.Header_Count (Reply) loop
         declare
            Name : constant String := Ada.Characters.Handling.To_Lower
              (Client.Header_Name (Reply, Index));
         begin
            if Name'Length >= 9
              and then Name (Name'First .. Name'First + 8) = "x-corpus-"
            then
               Ada.Text_IO.Put_Line
                 ("header=" & Name & ":" &
                  Client.Header_Value (Reply, Index));
            end if;
         end;
      end loop;
      for Index in 1 .. Client.Trailer_Count (Reply) loop
         declare
            Name : constant String := Ada.Characters.Handling.To_Lower
              (Client.Trailer_Name (Reply, Index));
         begin
            if Name'Length >= 9
              and then Name (Name'First .. Name'First + 8) = "x-corpus-"
            then
               Ada.Text_IO.Put_Line
                 ("trailer=" & Name & ":" &
                  Client.Trailer_Value (Reply, Index));
            end if;
         end;
      end loop;
   end Emit;

   task Caller is
      pragma Task_Info (Model);
      entry Join (Success : out Boolean);
   end Caller;

   task body Caller is
      HTTP : aliased Client.Client (Capacity => 1);
      Ask  : aliased Client.Request;

      procedure Prime_Reused_Transport is
         Primer : aliased Client.Request;
      begin
         Client.Set_Target (Primer, "/prime");
         if Style = "sync-lost" then
            declare
               Reply : Client.Response := Client.Execute (HTTP, Primer, 3.0);
               Content : constant Flyology.Bytes.Unbounded_Bytes :=
                 Client.Read_All (Reply, Maximum => 1);
            begin
               if Client.Status (Reply) /= 200
                 or else Flyology.Bytes.Length (Content) /= 0
               then
                  raise Program_Error with "stale oracle primer failed";
               end if;
            end;
         else
            declare
               Pool : aliased Buffers.Pool
                 (Block_Size => 1, Capacity => 1);
               Destination : Buffers.Unique_Buffer (Pool'Access);
               Set : aliased Operations.Completion_Set (3);
               Result : Client.Exchange_Result;
               Reply : Client.Response;
            begin
               Buffers.Acquire (Destination);
               declare
                  Operation : Client.Exchange_Operation :=
                    Client.Exchange_To_Buffer
                      (Set'Access, HTTP'Access, Primer'Access, Destination,
                       Client.Deadline_After (3.0));
               begin
                  Operations.Wait_All (Set);
                  Client.Finish
                    (Operation, Result, Reply, Destination);
               end;
               if Client.Kind (Result) /= Client.Response_Complete
                 or else Client.Status (Reply) /= 200
                 or else Buffers.Length (Destination) /= 0
               then
                  raise Program_Error with "stale oracle primer failed";
               end if;
               Buffers.Release (Destination);
            end;
         end if;
      end Prime_Reused_Transport;
   begin
      if Protocol_Name = "h3" then
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin (URL), Client.Require_HTTP_3,
            HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
      else
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin (URL),
            (if Protocol_Name = "h2" then Client.HTTP_2_Prior_Knowledge
             else Client.HTTP_1_Only));
      end if;
      if Style in "sync-lost" | "composable-lost" then
         Prime_Reused_Transport;
         Client.Set_Method (Ask, Flyology.HTTP.Methods.PUT);
         Client.Set_Target (Ask, "/immutable-commit");
         Client.Add_Header (Ask, "If-None-Match", "*");
         Client.Set_Body (Ask, "immutable-commit-bytes");
      end if;
      if Style = "sync" then
         declare
            Reply : Client.Response := Client.Execute (HTTP, Ask, 3.0);
            Content : constant Flyology.Bytes.Unbounded_Bytes :=
              Client.Read_All (Reply, Maximum => 65_536);
         begin
            Emit (Reply, Flyology.Bytes.To_Array (Content));
         end;
      elsif Style = "composable" then
         declare
            Pool : aliased Buffers.Pool
              (Block_Size => 65_536, Capacity => 1);
            Destination : Buffers.Unique_Buffer (Pool'Access);
            Set : aliased Operations.Completion_Set (3);
            Result : Client.Exchange_Result;
            Reply : Client.Response;

            procedure Emit_Buffer
              (Data : Ada.Streams.Stream_Element_Array) is
            begin
               Emit (Reply, Data);
            end Emit_Buffer;
         begin
            Buffers.Acquire (Destination);
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Ask'Access, Destination,
                    Client.Deadline_After (3.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Operation, Result, Reply, Destination);
            end;
            if Client.Kind (Result) /= Client.Response_Complete then
               raise Program_Error with
                 "differential exchange failed: " &
                 Client.Exchange_Result_Kind'Image (Client.Kind (Result));
            end if;
            Buffers.With_Readable_Data (Destination, Emit_Buffer'Access);
            Buffers.Release (Destination);
         end;
      elsif Style = "sync-lost" then
         begin
            declare
               Reply : constant Client.Response :=
                 Client.Execute (HTTP, Ask, 3.0);
            begin
               raise Program_Error with
                 "lost-final-response unexpectedly completed with status" &
                 Client.Status (Reply)'Image;
            end;
         exception
            when Client.Connection_Error |
                 Flyology.IO.Device_Error |
                 Flyology.HTTP.Protocol_Error =>
               Ada.Text_IO.Put_Line ("outcome=failed");
         end;
      elsif Style = "composable-lost" then
         declare
            Pool : aliased Buffers.Pool
              (Block_Size => 65_536, Capacity => 1);
            Destination : Buffers.Unique_Buffer (Pool'Access);
            Set : aliased Operations.Completion_Set (3);
            Result : Client.Exchange_Result;
            Reply : Client.Response;
            Admission_Before : Client.Admission_Certainty;
         begin
            Buffers.Acquire (Destination);
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Ask'Access, Destination,
                    Client.Deadline_After (3.0));
            begin
               Operations.Wait_All (Set);
               Admission_Before := Client.Admission (Operation);
               Client.Finish
                 (Operation, Result, Reply, Destination);
            end;
            if Client.Kind (Result) = Client.Response_Complete
              or else Admission_Before /= Client.Possibly_Admitted
              or else Client.Certainty (Result) /= Client.Possibly_Admitted
              or else Buffers.Length (Destination) /= 0
            then
               raise Program_Error with
                 "lost-final-response certainty/body invariant failed";
            end if;
            Ada.Text_IO.Put_Line
              ("kind=" & Compact (Client.Exchange_Result_Kind'Image
                 (Client.Kind (Result))));
            Ada.Text_IO.Put_Line
              ("admission=" & Compact (Client.Admission_Certainty'Image
                 (Client.Certainty (Result))));
            Ada.Text_IO.Put_Line ("body_length=0");
            Buffers.Release (Destination);
         end;
      elsif Style = "composable-h3-isolation" then
         declare
            Pool : aliased Buffers.Pool
              (Block_Size => 64, Capacity => 2);
            Invalid_Body : Buffers.Unique_Buffer (Pool'Access);
            Valid_Body : Buffers.Unique_Buffer (Pool'Access);
            Invalid_Request : aliased Client.Request;
            Valid_Request : aliased Client.Request;
            Set : aliased Operations.Completion_Set (4);
            Invalid_Result : Client.Exchange_Result;
            Valid_Result : Client.Exchange_Result;
            Invalid_Reply : Client.Response;
            Valid_Reply : Client.Response;
         begin
            Client.Set_Target (Invalid_Request, "/invalid");
            Client.Set_Target (Valid_Request, "/valid");
            Buffers.Acquire (Invalid_Body);
            Buffers.Acquire (Valid_Body);
            declare
               Invalid_Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Invalid_Request'Access,
                    Invalid_Body, Client.Deadline_After (5.0));
               Valid_Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Valid_Request'Access,
                    Valid_Body, Client.Deadline_After (5.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Invalid_Operation, Invalid_Result, Invalid_Reply,
                  Invalid_Body);
               Client.Finish
                 (Valid_Operation, Valid_Result, Valid_Reply, Valid_Body);
            end;
            if Client.Kind (Invalid_Result) /= Client.Response_Invalid
              or else Client.Certainty (Invalid_Result) /=
                Client.Response_Observed
              or else Buffers.Length (Invalid_Body) /= 0
              or else Client.Kind (Valid_Result) /= Client.Response_Complete
              or else Client.Certainty (Valid_Result) /=
                Client.Response_Observed
              or else Client.Status (Valid_Reply) /= 200
              or else Buffers.Length (Valid_Body) /= 5
            then
               raise Program_Error with
                 "HTTP/3 malformed response stream isolation failed: " &
                 Client.Exchange_Result_Kind'Image
                   (Client.Kind (Invalid_Result)) & "/" &
                 Client.Admission_Certainty'Image
                   (Client.Certainty (Invalid_Result)) & "/" &
                 Buffers.Length (Invalid_Body)'Image & "; " &
                 Client.Exchange_Result_Kind'Image
                   (Client.Kind (Valid_Result)) & "/" &
                 Client.Admission_Certainty'Image
                   (Client.Certainty (Valid_Result)) & "/" &
                 Buffers.Length (Valid_Body)'Image;
            end if;
            Ada.Text_IO.Put_Line ("outcome=isolated");
            Buffers.Release (Invalid_Body);
            Buffers.Release (Valid_Body);
         end;
      else
         raise Program_Error with "unknown differential API style";
      end if;
      Client.Shutdown (HTTP);
      accept Join (Success : out Boolean) do
         Success := True;
      end Join;
   exception
      when Event : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            Ada.Exceptions.Exception_Information (Event));
         begin
            Client.Shutdown (HTTP, Timeout => 0.5);
         exception
            when others => null;
         end;
         accept Join (Success : out Boolean) do
            Success := False;
         end Join;
   end Caller;
begin
   if Ada.Command_Line.Argument_Count /= 4
     or else Protocol_Name not in "h1" | "h2" | "h3"
   then
      raise Program_Error with
        "usage: http_client_differential_client " &
        "{sync|composable|sync-lost|composable-lost|composable-h3-isolation} " &
        "{native|lightweight} {h1|h2|h3} URL";
   end if;
   declare
      Success : Boolean;
   begin
      Caller.Join (Success);
      if not Success then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end;
end HTTP_Client_Differential_Client;
