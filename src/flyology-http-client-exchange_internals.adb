separate (Flyology.HTTP.Client)
--  Owns admission, DNS, connect, TLS establishment, and shutdown/cancellation
--  translation. Protocol serialization and parsing remain in HTTP_1_Internals.
package body Exchange_Internals is
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   function Test_Barrier_Arrive
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arrive";
   function Test_Barrier_Released
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_released";

   procedure Test_Barrier (Point : Interfaces.C.int) is
   begin
      if Test_Barrier_Arrive (Point) /= 0 then
         while Test_Barrier_Released (Point) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Test_Barrier;
#end if;

   procedure Check_Deadline
     (Started : Ada.Real_Time.Time; Timeout : Duration) is
   begin
      if Timeout >= 0.0 and then Remaining (Started, Timeout) <= 0.0 then
         raise Flyology.IO.Timeout_Error;
      end if;
   end Check_Deadline;

   procedure Interrupt_Sources
     (State   : not null Client_State_Access;
      Token   : access Flyology.Cancellation.Token;
      Sources : out Flyology.IO.Interrupt_Set;
      Count   : out Natural)
   is
      FD        : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      Count := 0;
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      end if;
      Count := Count + 1;
      Sources (Sources'First + Count - 1) := FD;
      if Token /= null then
         Token.Wait_Source (FD, Requested);
         if Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Count := Count + 1;
         Sources (Sources'First + Count - 1) := FD;
      end if;
   end Interrupt_Sources;

   procedure Translate_Interruption
     (State : not null Client_State_Access;
      Token : access Flyology.Cancellation.Token)
   is
      FD : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      elsif Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      else
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Translate_Interruption;

   procedure Establish
     (State      : not null Client_State_Access;
      Slot_Index : Positive;
      Connection : in out Pooled_Connection_Access;
      Use_HTTP_3  : Boolean;
      Target_Port : Port_Number;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Socket    : Sockets.Socket_Type;
      Connected : Boolean := False;
      --  Whether the connect policy refused an address, and whether any
      --  address survived it far enough to open a socket.
      Refused   : Boolean := False;
      Attempted : Boolean := False;
      Last_Error : Unbounded_String;
      Last_Address : Unbounded_String;
      Family_Known : Boolean := False;
      Preferred_Family : Sockets.Address_Family := Sockets.IPv4;

      procedure Cleanup is
      begin
         if Sockets.Is_Open (Socket) then
            begin
               Sockets.Close_Socket (Socket);
            exception
               when others => null;
            end;
         end if;
         if Connection /= null then
            begin
               Connections.Close (Connection.Channel);
            exception
               when others => null;
            end;
            if Connection.HTTP_2 /= null then
               H2_Connections.Destroy (Connection.HTTP_2);
            end if;
            if Sockets.Is_Open (Connection.UDP) then
               begin
                  Sockets.Close_Socket (Connection.UDP);
               exception
                  when others => null;
               end;
            end if;
         end if;
      end Cleanup;
   begin
      if Use_HTTP_3 then
         State.Successful_Address.Current
           (Family_Known, Preferred_Family);
      end if;
      declare
         Sources : Flyology.IO.Interrupt_Set (1 .. 2);
         Count   : Natural;
      begin
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
         Test_Barrier (15);
#end if;
         Interrupt_Sources (State, Token, Sources, Count);
         Check_Deadline (Started, Timeout);
         declare
            Addresses : constant Flyology.IO.DNS.Address_Array :=
              Flyology.IO.DNS.Resolve
                (Host (State.Origin_Value),
                 Timeout => Remaining (Started, Timeout),
                 Interrupts => Sources (1 .. Count));
         begin
            for Address of Addresses loop
               --  The application sees every resolved address before a
               --  socket exists for it, which is the only point at which a
               --  name that resolves to a private destination can be
               --  refused.
               if Use_HTTP_3 and then Family_Known
                 and then Address.Family /= Preferred_Family
               then
                  null;
               elsif State.Connect_Policy = null
                 or else State.Connect_Policy.all
                   (Host (State.Origin_Value),
                    Sockets.Image (Address),
                    Target_Port)
               then
                  begin
                     Attempted := True;
                     Last_Address := To_Unbounded_String
                       (Sockets.Image (Address));
                     Sockets.Create_Socket
                       (Socket, Address.Family,
                        (if Use_HTTP_3 then Sockets.Socket_Datagram
                         else Sockets.Socket_Stream));
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
                     Test_Barrier (16);
#end if;
                     Interrupt_Sources (State, Token, Sources, Count);
                     Check_Deadline (Started, Timeout);
                     if Use_HTTP_3 then
                        Sockets.Prepare (Socket);
                        Sockets.Connect_Socket
                          (Socket,
                           Sockets.Network_Endpoint
                             (Address, Sockets.Port (Target_Port)));
                     else
                        Sockets.Connect
                          (Socket,
                           Sockets.Network_Endpoint
                             (Address, Sockets.Port (Target_Port)),
                           Remaining (Started, Timeout),
                           Sources (1 .. Count));
                     end if;
                     Connected := True;
                     if not Use_HTTP_3 then
                        State.Successful_Address.Remember (Address.Family);
                     end if;
                  exception
                     when Sockets.Operation_Interrupted =>
                        if Sockets.Is_Open (Socket) then
                           Sockets.Close_Socket (Socket);
                        end if;
                        Translate_Interruption (State, Token);
                     when Flyology.IO.Timeout_Error =>
                        if Sockets.Is_Open (Socket) then
                           Sockets.Close_Socket (Socket);
                        end if;
                        raise;
                     when Error : Sockets.Socket_Error |
                          Flyology.IO.Device_Error =>
                        Last_Error := To_Unbounded_String
                          (Ada.Exceptions.Exception_Message (Error));
                        if Sockets.Is_Open (Socket) then
                           begin
                              Sockets.Close_Socket (Socket);
                           exception
                              when others => null;
                           end;
                        end if;
                  end;
               else
                  Refused := True;
               end if;
               exit when Connected;
            end loop;
         end;
      end;

      if not Connected then
         if Refused and then not Attempted then
            raise Connection_Error with
              "HTTP connect policy refused every resolved endpoint";
         end if;
         raise Connection_Error with
           "all resolved HTTP endpoints failed" &
             (if Length (Last_Address) = 0 then ""
              else " at " & To_String (Last_Address)) &
             (if Length (Last_Error) = 0 then ""
              else ": " & To_String (Last_Error));
      end if;

      Connection := new Pooled_Connection;
      if Use_HTTP_3 then
         Sockets.Move (Socket, Connection.UDP);
      else
         Connections.Take (State.Manager, Socket, Connection.Channel);
      end if;
      State.Pool.Publish_Connecting (Slot_Index, Connection);
      if Use_HTTP_3 then
         Start_Connection (State, Connection, Started, Timeout, Token);
      elsif Scheme (State.Origin_Value) = Secure_HTTPS then
         if State.Protocol_Policy = HTTP_1_Only then
            Flyology.IO.Connections.TLS.Upgrade
              (Connection.Channel, State.Backend.all,
               Flyology.IO.TLS.Client, Host (State.Origin_Value),
               Remaining (Started, Timeout), Token);
         else
            declare
               use Flyology.IO.TLS.ALPN;
               Protocols : Protocol_List := Offer ("h2");
            begin
               if State.Protocol_Policy in
                 Negotiate_HTTP_2 | Negotiate_HTTP_3
               then
                  Append (Protocols, "http/1.1");
               end if;
               Flyology.IO.Connections.TLS.Upgrade
                 (Item        => Connection.Channel,
                  Backend     => Flyology.IO.TLS.ALPN.Provider'Class
                    (State.Backend.all),
                  Side        => Flyology.IO.TLS.Client,
                  Server_Name => Host (State.Origin_Value),
                  Protocols   => Protocols,
                  Timeout     => Remaining (Started, Timeout),
                  Token       => Token);
               declare
                  Selected : constant String :=
                    Flyology.IO.Connections.TLS.Selected_Protocol
                      (Connection.Channel);
               begin
                  if Selected = "h2" then
                     Connection.Protocol := HTTP_2_Transport;
                  elsif State.Protocol_Policy in
                    Negotiate_HTTP_2 | Negotiate_HTTP_3
                    and then (Selected = "" or else Selected = "http/1.1")
                  then
                     Connection.Protocol := HTTP_1_Transport;
                  else
                     raise Protocol_Error with
                       "TLS peer did not negotiate required HTTP/2";
                  end if;
               end;
            end;
         end if;
      elsif State.Protocol_Policy = HTTP_2_Prior_Knowledge then
         Connection.Protocol := HTTP_2_Transport;
      end if;
      if Connection.Protocol = HTTP_2_Transport then
         H2_Connections.Create
           (Connection.HTTP_2, Connection.Channel'Unchecked_Access);
      end if;
   exception
      when Flyology.IO.DNS.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when Flyology.IO.DNS.Name_Not_Found |
           Flyology.IO.DNS.Resolution_Failed |
           Flyology.IO.DNS.Malformed_Response =>
         Cleanup;
         raise Connection_Error with "HTTP origin resolution failed";
      when Connections.Admission_Closed =>
         Cleanup;
         raise Client_Closed;
      when Flyology.Cancellation.Operation_Cancelled =>
         Cleanup;
         Translate_Interruption (State, Token);
      when others =>
         Cleanup;
         raise;
   end Establish;

   procedure Wait_For_Pool
     (State   : not null Client_State_Access;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Pool_FD   : Flyology.IO.Descriptor;
      Token_FD  : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Ready_Now : Boolean;
      Cancelled : Boolean := False;
      Index     : Natural;
   begin
      State.Pool.Wait_Source (Pool_FD, Ready_Now);
      if Ready_Now then
         return;
      end if;
      if Token /= null then
         Token.Wait_Source (Token_FD, Cancelled);
         if Cancelled then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end if;
      if Token = null then
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 1);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      else
         declare
            Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
         begin
            Sources (1) :=
              (FD => Pool_FD, Condition => Flyology.IO.For_Read);
            Sources (2) :=
              (FD => Token_FD, Condition => Flyology.IO.For_Read);
            Index := Flyology.IO.Wait_Any
              (Sources, Remaining (Started, Timeout));
         end;
      end if;
      if Index = 0 then
         State.Pool.Record_Admission_Timeout;
         raise Flyology.IO.Timeout_Error;
      elsif Index = 2 then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Wait_For_Pool;

   --  A pooled HTTP/1 transport that became readable while idle is
   --  desynchronized: this client never pipelines, so nothing legitimate can
   --  precede the response to the request about to be written. A transport
   --  that reports orderly closure instead is left to the stale-retry path.
   function Carries_Stray_Input
     (Item : in out Connections.Connection) return Boolean
   is
      Probe : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      Connections.Receive (Item, Probe, Last, Timeout => 0.0);
      return Last >= Probe'First;
   exception
      when others =>
         --  A probe that cannot complete leaves the transport to the
         --  established failure paths rather than failing admission here.
         return False;
   end Carries_Stray_Input;

   procedure Checkout
     (Item       : in out Client;
      Connection : out Pooled_Connection_Access;
      Slot_Index : out Positive;
      Was_Reused : out Boolean;
      Force_TCP  : Boolean;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token)
   is
      Result : Checkout_Result;
      Index  : Natural;
      Value  : Pooled_Connection_Access;
      Verify : Boolean;
      Waiting : Boolean := False;
      Use_HTTP_3 : Boolean := False;
      Target_Port : Port_Number := 443;

      --  Withdraw a checked-out transport whose quiescence probe failed and
      --  close it outside the pool lock.
      procedure Discard_Checkout is
         Outcome : Return_Result;
         Stale   : Pooled_Connection_Access;
      begin
         Item.Control.State.Pool.Reject_Reuse
           (Positive (Index), Outcome, Stale);
         if Outcome = Return_Close then
            Close_And_Finish (Item.Control.State, Positive (Index), Stale);
         end if;
      end Discard_Checkout;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      end if;
      Was_Reused := False;
      Target_Port := Port (Item.Control.State.Origin_Value);
      if not Force_TCP then
         if Item.Control.State.Protocol_Policy = Require_HTTP_3 then
            Use_HTTP_3 := True;
         elsif Item.Control.State.Protocol_Policy = Negotiate_HTTP_3 then
            declare
               Alternative_Port : Port_Number;
            begin
               Item.Control.State.HTTP_3_Alternative.Preferred
                 (Ada.Real_Time.Clock, Use_HTTP_3, Alternative_Port);
               if Use_HTTP_3 then
                  Target_Port := Alternative_Port;
               end if;
            end;
         end if;
      end if;
      loop
         Item.Control.State.Pool.Try_Checkout
           (Ada.Real_Time.Clock, Result, Index, Value, Verify);
         case Result is
            when Checkout_Idle =>
               if Value.Protocol /= HTTP_2_Transport
                 and then
                   ((Use_HTTP_3 and then Value.Protocol /= HTTP_3_Transport)
                    or else
                      (not Use_HTTP_3
                         and then Value.Protocol = HTTP_3_Transport))
               then
                  Discard_Checkout;
               elsif Verify
                 and then Value.Protocol = HTTP_1_Transport
                 and then Carries_Stray_Input (Value.Channel)
               then
                  Discard_Checkout;
               else
                  if Waiting then
                     Item.Control.State.Pool.Unregister_Waiter;
                     Waiting := False;
                  end if;
                  Connection := Value;
                  Slot_Index := Positive (Index);
                  Was_Reused := True;
                  return;
               end if;
            when Checkout_Create =>
               begin
                  Establish
                    (Item.Control.State, Positive (Index), Value,
                     Use_HTTP_3, Target_Port, Started, Timeout, Token);
                  Item.Control.State.Pool.Install
                    (Positive (Index), Value, Ada.Real_Time.Clock);
               exception
                  when others =>
                     declare
                        Failure : Failure_Result;
                     begin
                        Item.Control.State.Pool.Creation_Failed
                          (Positive (Index), Failure);
                        if Failure = Failure_Free and then Value /= null then
                           Dispose_Connection (Value);
                        end if;
                     end;
                     if Waiting then
                        Item.Control.State.Pool.Unregister_Waiter;
                        Waiting := False;
                     end if;
                     raise;
               end;
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               Connection := Value;
               Slot_Index := Positive (Index);
               Was_Reused := False;
               return;
            when Checkout_Discard =>
               Close_And_Finish
                 (Item.Control.State, Positive (Index), Value);
            when Checkout_Busy =>
               if not Waiting then
                  Item.Control.State.Pool.Register_Waiter;
                  Waiting := True;
               end if;
               Wait_For_Pool
                 (Item.Control.State, Started, Timeout, Token);
            when Checkout_Closed =>
               if Waiting then
                  Item.Control.State.Pool.Unregister_Waiter;
                  Waiting := False;
               end if;
               raise Client_Closed;
         end case;
      end loop;
   exception
      when others =>
         if Waiting then
            begin
               Item.Control.State.Pool.Unregister_Waiter;
            exception
               when others => null;
            end;
         end if;
         raise;
   end Checkout;
end Exchange_Internals;
