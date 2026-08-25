with Ada.Command_Line;
with Flyology;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.Operations;

procedure HTTP2_H2spec_Client is
   package Buffers renames Flyology.Buffers;
   package Client renames Flyology.HTTP.Client;
   package Operations renames Flyology.Operations;

   Style : constant String := Ada.Command_Line.Argument (1);
   Model : constant Flyology.Execution_Model :=
     (if Ada.Command_Line.Argument (2) = "lightweight" then
        Flyology.Lightweight_Task
      else Flyology.Native_Task);
   URL : constant String := Ada.Command_Line.Argument (3);

   task Caller is
      pragma Task_Info (Model);
   end Caller;

   task body Caller is
      HTTP : aliased Client.Client (Capacity => 1);
      Ask  : aliased Client.Request;
   begin
      Client.Configure
        (HTTP, Flyology.HTTP.Parse_Origin (URL),
         Client.HTTP_2_Prior_Knowledge);
      --  This executable exits after one exchange, so keep the owner-driven
      --  operation alive briefly for malicious frames h2spec sends just after
      --  END_STREAM. Production clients retain the zero-cost default.
      Client.Testing.Set_HTTP_2_Settlement_Grace (HTTP, 0.25);
      if Style = "sync" then
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Ask, Timeout => 2.0);
            Content : constant Flyology.Bytes.Unbounded_Bytes :=
              Client.Read_All (Reply, Maximum => 262_144);
            pragma Unreferenced (Content);
         begin
            null;
         end;
      elsif Style = "composable" then
         declare
            Pool : aliased Buffers.Pool
              (Block_Size => 262_144, Capacity => 1);
            Destination : Buffers.Unique_Buffer (Pool'Access);
            Set : aliased Operations.Completion_Set (3);
            Result : Client.Exchange_Result;
            Reply : Client.Response;
         begin
            Buffers.Acquire (Destination);
            declare
               Operation : Client.Exchange_Operation :=
                 Client.Exchange_To_Buffer
                   (Set'Access, HTTP'Access, Ask'Access, Destination,
                    Client.Deadline_After (2.0));
            begin
               Operations.Wait_All (Set);
               Client.Finish
                 (Operation, Result, Reply, Destination);
            end;
            Buffers.Release (Destination);
         end;
      else
         raise Program_Error with "unknown h2spec client API style";
      end if;
      Client.Shutdown (HTTP, Timeout => 0.5);
   exception
      when others =>
         begin
            Client.Shutdown (HTTP, Timeout => 0.5);
         exception
            when others => null;
         end;
   end Caller;
begin
   if Ada.Command_Line.Argument_Count /= 3 then
      raise Program_Error with
        "usage: http2_h2spec_client {sync|composable} " &
        "{native|lightweight} URL";
   end if;
end HTTP2_H2spec_Client;
