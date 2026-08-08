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
      Socket       : Sockets.Socket_Type;
      Connected    : Boolean := False;
      Refused      : Boolean := False;
      Attempted    : Boolean := False;
      Last_Error   : Unbounded_String;
      Last_Address : Unbounded_String;

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
            type Allowed_Array is array (Addresses'Range) of Boolean;
            Allowed : Allowed_Array := (others => False);
         begin
            --  The application filter remains serialized on the requesting
            --  task even though the permitted endpoints are connected by two
            --  concurrent address-family lanes below.
            for Index in Addresses'Range loop
               if State.Connect_Policy = null
                 or else State.Connect_Policy.all
                   (Host (State.Origin_Value),
                    Sockets.Image (Addresses (Index)),
                    Target_Port)
               then
                  Allowed (Index) := True;
                  Attempted := True;
               else
                  Refused := True;
               end if;
            end loop;

            if Attempted then
               declare
                  type Socket_Array is array (Sockets.Address_Family) of
                    Sockets.Socket_Type;
                  type Connection_Array is array (Sockets.Address_Family) of
                    Pooled_Connection_Access;

                  Family_Sockets : Socket_Array;
                  Family_Connections : Connection_Array := (others => null);
                  Race_Stop : aliased Flyology.Cancellation.Token;
                  Winning_Family : Sockets.Address_Family := Sockets.IPv4;
                  Race_Succeeded : Boolean := False;

                  protected Race is
                     procedure Choose
                       (Family : Sockets.Address_Family;
                        Selected : out Boolean);
                     procedure Finish
                       (Address : Unbounded_String;
                        Error   : Unbounded_String);
                     entry Wait
                       (Family : out Sockets.Address_Family;
                        Succeeded : out Boolean);
                     procedure Failure
                       (Address : out Unbounded_String;
                        Error   : out Unbounded_String);
                  private
                     Winner       : Natural := 0;
                     Finished     : Natural := 0;
                     Failed_At    : Unbounded_String;
                     Failed_With  : Unbounded_String;
                  end Race;

                  protected body Race is
                     procedure Choose
                       (Family : Sockets.Address_Family;
                        Selected : out Boolean) is
                     begin
                        Selected := Winner = 0;
                        if Selected then
                           Winner :=
                             Sockets.Address_Family'Pos (Family) + 1;
                        end if;
                     end Choose;

                     procedure Finish
                       (Address : Unbounded_String;
                        Error   : Unbounded_String) is
                     begin
                        Finished := Finished + 1;
                        if Length (Error) > 0 then
                           Failed_At := Address;
                           Failed_With := Error;
                        end if;
                     end Finish;

                     entry Wait
                       (Family : out Sockets.Address_Family;
                        Succeeded : out Boolean)
                       when Winner /= 0 or else Finished = 2
                     is
                     begin
                        Succeeded := Winner /= 0;
                        if Succeeded then
                           Family := Sockets.Address_Family'Val (Winner - 1);
                        else
                           Family := Sockets.IPv4;
                        end if;
                     end Wait;

                     procedure Failure
                       (Address : out Unbounded_String;
                        Error   : out Unbounded_String) is
                     begin
                        Address := Failed_At;
                        Error := Failed_With;
                     end Failure;
                  end Race;

                  task type Connector
                    (Family : Sockets.Address_Family);

                  task body Connector is
                     Candidate     : Pooled_Connection_Access := null;
                     Candidate_Socket : Sockets.Socket_Type;
                     Selected      : Boolean := False;
                     Lane_Address  : Unbounded_String;
                     Lane_Error    : Unbounded_String;

                     procedure Close_Candidate is
                     begin
                        if Candidate /= null then
                           Dispose_Connection (Candidate);
                        end if;
                        if Sockets.Is_Open (Candidate_Socket) then
                           begin
                              Sockets.Close_Socket (Candidate_Socket);
                           exception
                              when others => null;
                           end;
                        end if;
                     end Close_Candidate;
                  begin
                     for Index in Addresses'Range loop
                        if Allowed (Index)
                          and then Addresses (Index).Family = Family
                        then
                           Lane_Address := To_Unbounded_String
                             (Sockets.Image (Addresses (Index)));
                           begin
                              Check_Deadline (Started, Timeout);
                              Sockets.Create_Socket
                                (Candidate_Socket, Family,
                                 (if Use_HTTP_3
                                  then Sockets.Socket_Datagram
                                  else Sockets.Socket_Stream));
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
                              Test_Barrier (16);
#end if;
                              --  A test hook, scheduler handoff, or slow
                              --  socket creation can consume the budget.
                              --  Do not start a connect after that point.
                              Check_Deadline (Started, Timeout);
                              if Race_Stop.Requested then
                                 raise Connection_Race_Lost;
                              end if;
                              if Use_HTTP_3 then
                                 Sockets.Prepare (Candidate_Socket);
                                 Sockets.Connect_Socket
                                   (Candidate_Socket,
                                    Sockets.Network_Endpoint
                                      (Addresses (Index),
                                       Sockets.Port (Target_Port)));
                                 Candidate := new Pooled_Connection;
                                 Sockets.Move
                                   (Candidate_Socket, Candidate.UDP);
                                 Start_Connection
                                   (State, Candidate, Started, Timeout, Token,
                                    Race_Stop'Access);
                              else
                                 declare
                                    Connect_Sources :
                                      Flyology.IO.Interrupt_Set (1 .. 3);
                                    Connect_Count : Natural;
                                    FD : Flyology.IO.Descriptor;
                                    Requested : Boolean;
                                 begin
                                    Interrupt_Sources
                                      (State, Token, Connect_Sources,
                                       Connect_Count);
                                    Race_Stop.Wait_Source (FD, Requested);
                                    if Requested then
                                       raise Connection_Race_Lost;
                                    end if;
                                    Connect_Count := Connect_Count + 1;
                                    Connect_Sources (Connect_Count) := FD;
                                    Sockets.Connect
                                      (Candidate_Socket,
                                       Sockets.Network_Endpoint
                                         (Addresses (Index),
                                          Sockets.Port (Target_Port)),
                                       Remaining (Started, Timeout),
                                       Connect_Sources (1 .. Connect_Count));
                                 end;
                              end if;

                              if Use_HTTP_3 then
                                 Family_Connections (Family) := Candidate;
                                 Candidate := null;
                              else
                                 Sockets.Move
                                   (Candidate_Socket,
                                    Family_Sockets (Family));
                              end if;
                              Race.Choose (Family, Selected);
                              if Selected then
                                 begin
                                    Race_Stop.Request;
                                 exception
                                    when others => null;
                                 end;
                                 exit;
                              end if;
                              if Use_HTTP_3 then
                                 Dispose_Connection
                                   (Family_Connections (Family));
                              elsif Sockets.Is_Open
                                (Family_Sockets (Family))
                              then
                                 Sockets.Close_Socket
                                   (Family_Sockets (Family));
                              end if;
                              exit;
                           exception
                              when Connection_Race_Lost =>
                                 Close_Candidate;
                                 exit;
                              when Sockets.Operation_Interrupted =>
                                 Close_Candidate;
                                 if Race_Stop.Requested then
                                    exit;
                                 end if;
                                 Lane_Error := To_Unbounded_String
                                   ("connection attempt interrupted");
                                 exit;
                              when Error : Flyology.IO.Timeout_Error |
                                   Client_Closed |
                                   Flyology.Cancellation.Operation_Cancelled =>
                                 Lane_Error := To_Unbounded_String
                                   (Ada.Exceptions.Exception_Message (Error));
                                 Close_Candidate;
                                 exit;
                              when Error : Sockets.Socket_Error |
                                   Flyology.IO.Device_Error | Protocol_Error =>
                                 Lane_Error := To_Unbounded_String
                                   (Ada.Exceptions.Exception_Message (Error));
                                 Close_Candidate;
                           end;
                        end if;
                     end loop;
                     Race.Finish (Lane_Address, Lane_Error);
                  exception
                     when Error : others =>
                        Close_Candidate;
                        Race.Finish
                          (Lane_Address,
                           To_Unbounded_String
                             (Ada.Exceptions.Exception_Message (Error)));
                  end Connector;

                  IPv4_Connector : Connector (Sockets.IPv4);
                  IPv6_Connector : Connector (Sockets.IPv6);
               begin
                  Race.Wait (Winning_Family, Race_Succeeded);
                  if Race_Succeeded then
                     Connected := True;
                     if Use_HTTP_3 then
                        Connection := Family_Connections (Winning_Family);
                        Family_Connections (Winning_Family) := null;
                     else
                        Sockets.Move
                          (Family_Sockets (Winning_Family), Socket);
                     end if;
                  else
                     Race.Failure (Last_Address, Last_Error);
                     --  Preserve terminal cancellation and deadline outcomes
                     --  observed by the connector tasks instead of flattening
                     --  them into address exhaustion.
                     Interrupt_Sources (State, Token, Sources, Count);
                     Check_Deadline (Started, Timeout);
                  end if;
               end;
            end if;
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

      if Use_HTTP_3 then
         State.Pool.Publish_Connecting (Slot_Index, Connection);
         return;
      end if;
      Connection := new Pooled_Connection;
      Connections.Take (State.Manager, Socket, Connection.Channel);
      State.Pool.Publish_Connecting (Slot_Index, Connection);
      if Scheme (State.Origin_Value) = Secure_HTTPS then
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
           (Now                => Ada.Real_Time.Clock,
            Prefer_HTTP_3      => Use_HTTP_3,
            Allow_TCP_Fallback =>
              Use_HTTP_3
                and then Item.Control.State.Protocol_Policy =
                  Negotiate_HTTP_3,
            Result             => Result,
            Slot_Index         => Index,
            Connection         => Value,
            Verify             => Verify);
         case Result is
            when Checkout_Idle =>
               if (Use_HTTP_3
                     and then Value.Protocol /= HTTP_3_Transport
                     and then Item.Control.State.Protocol_Policy /=
                       Negotiate_HTTP_3)
                 or else
                   (not Use_HTTP_3
                      and then Value.Protocol = HTTP_3_Transport)
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
