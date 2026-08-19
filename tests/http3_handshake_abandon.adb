with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_3;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Connections.IO;
with Flyology.QUIC.Test_Connections;

--  A peer that abandons a QUIC handshake must not pin a listener connection
--  slot until the handshake timeout expires. Two mechanisms are covered here.
--  A cooperative peer, such as the losing lane of the client's address-family
--  race, sends a transport CONNECTION_CLOSE from the Initial or Handshake
--  space. A peer that simply stops answering is reclaimed by the listener's
--  no-progress deadline. Each phase saturates a listener of capacity N with
--  half-open handshakes and then asserts that a fresh Initial is admitted
--  well inside the handshake timeout.
procedure HTTP3_Handshake_Abandon is
   package App renames Flyology.HTTP.Server.Applications;
   package QUIC renames Flyology.QUIC.Connections;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;
   use type QUIC.Send_Status;

   Capacity : constant := 3;

   --  Far longer than every deadline asserted below, so a slot reclaimed
   --  inside one of those deadlines cannot be explained by this timeout.
   Server_Handshake_Timeout : constant Duration := 20.0;

   type Context is limited null record;

   procedure Handle (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Text (200, "ok");
   end Handle;

   package Engine is new Flyology.HTTP.Server.HTTP_3 (Context, Handle);

   --  Each phase runs its own listener and so needs its own shutdown token.
   --  A connection's state retains the token, so the tokens must live no
   --  deeper than the instance that allocates that state.
   Close_Stop  : aliased Flyology.Cancellation.Token;
   Silent_Stop : aliased Flyology.Cancellation.Token;

   protected Outcome is
      procedure Fail (Message : String);
      function Passed return Boolean;
      function Message return String;
   private
      Failed : Boolean := False;
      Detail : Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Fail (Message : String) is
      begin
         if not Failed then
            Detail := To_Unbounded_String (Message);
         end if;
         Failed := True;
      end Fail;

      function Passed return Boolean is (not Failed);

      function Message return String is (To_String (Detail));
   end Outcome;

   --  One client lane holding a half-open handshake against the listener.
   type Lane is limited record
      Socket    : Sockets.Socket_Type;
      Transport : QUIC.Connection;
      Initial   : QUIC.Datagram_Batch;
   end record;

   type Lane_Array is array (1 .. Capacity) of Lane;

   --  Send a client Initial and stop short of a completed handshake. When
   --  Advance is set the lane also consumes the ServerHello, which installs
   --  handshake keys; that lane then abandons from the Handshake space while
   --  the others abandon from the Initial space.
   procedure Start_Half_Open
     (Item    : in out Lane;
      Address : Sockets.Endpoint;
      Advance : Boolean)
   is
      Flight : QUIC.Datagram_Batch;
      Status : QUIC.Operation_Status;
   begin
      Sockets.Create_Socket
        (Item.Socket, Address.Family, Sockets.Socket_Datagram);
      Sockets.Connect_Socket (Item.Socket, Address);
      Fixtures.Initialize_Client (Item.Transport);
      QUIC.Start_Client (Item.Transport, Item.Initial, Status);
      pragma Assert (Status = QUIC.Succeeded, "client Initial not built");
      QUIC_IO.Send (Item.Socket, Item.Initial, Timeout => 5.0);
      if Advance then
         for Attempt in 1 .. 4 loop
            exit when QUIC.State (Item.Transport) = QUIC.Client_Handshake;
            QUIC_IO.Receive
              (Item.Socket, Item.Transport, Flight, Status, Timeout => 5.0);
            pragma Assert
              (Status in QUIC.Succeeded | QUIC.Waiting_For_More,
               "server handshake flight rejected");
            QUIC_IO.Send (Item.Socket, Flight, Timeout => 5.0);
         end loop;
         pragma Assert
           (QUIC.State (Item.Transport) = QUIC.Client_Handshake,
            "lane did not install handshake keys");
      end if;
   end Start_Half_Open;

   --  Abandon a half-open lane the way the losing lane of the client's
   --  address-family race does.
   procedure Abandon (Item : in out Lane) is
      Packet : QUIC.Datagram;
      Status : QUIC.Send_Status;
   begin
      pragma Assert
        (QUIC.State (Item.Transport) in
           QUIC.Client_Initial | QUIC.Client_Handshake,
         "lane completed its handshake before abandoning");
      QUIC.Build_Handshake_Close_Datagram (Item.Transport, Packet, Status);
      pragma Assert (Status = QUIC.Sent, "handshake close not built");
      pragma Assert (Packet.Length > 0, "handshake close is empty");
      QUIC_IO.Send (Item.Socket, Packet, Timeout => 5.0);
   end Abandon;

   --  Report whether the listener completes a fresh handshake within Budget.
   --  The Initial is repeated while no worker answers, the way a real client's
   --  probe timeout would, so a slot released partway through Budget is still
   --  taken up.
   procedure Probe_Admission
     (Address : Sockets.Endpoint;
      Budget  : Duration;
      Result  : out Boolean)
   is
      Item   : Lane;
      Flight : QUIC.Datagram_Batch;
      Status : QUIC.Operation_Status;
      Ends   : Ada.Real_Time.Time;
   begin
      Start_Half_Open (Item, Address, Advance => False);
      Ends := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Budget);
      while not QUIC.Is_Connected (Item.Transport)
        and then Ada.Real_Time.Clock < Ends
      loop
         begin
            QUIC_IO.Receive
              (Item.Socket, Item.Transport, Flight, Status, Timeout => 0.25);
            exit when Status not in QUIC.Succeeded | QUIC.Waiting_For_More;
            QUIC_IO.Send (Item.Socket, Flight, Timeout => 5.0);
         exception
            when Flyology.IO.Timeout_Error =>
               QUIC_IO.Send (Item.Socket, Item.Initial, Timeout => 5.0);
         end;
      end loop;
      Result := QUIC.Is_Connected (Item.Transport);
      Sockets.Close_Socket (Item.Socket);
   end Probe_Admission;

   --  Saturate a listener of capacity N with half-open handshakes, release
   --  them through Close_Lanes or through the no-progress deadline, and
   --  require a fresh Initial to be admitted inside Probe_Budget.
   procedure Run_Phase
     (Stop              : not null access Flyology.Cancellation.Token;
      Idle_Timeout      : Duration;
      Close_Lanes       : Boolean;
      Saturation_Budget : Duration;
      Probe_Budget      : Duration)
   is
      Listener : aliased Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      State    : aliased Context;
   begin
      Sockets.Create_Socket (Listener, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Address := Sockets.Get_Socket_Name (Listener);
      declare
         task type Server_Task_Type;
         for Server_Task_Type'Storage_Size use 16 * 1_024 * 1_024;
         Server_Task : Server_Task_Type;

         task body Server_Task_Type is
         begin
            Engine.Serve_Listener
              (State, Listener,
               Fixtures.Server_Certificate, Fixtures.Server_Private_Key,
               Capacity => Capacity,
               Timeout => 10.0,
               Handshake_Timeout => Server_Handshake_Timeout,
               Max_Connection_Age => 60.0,
               Token => Stop,
               Handshake_Idle_Timeout => Idle_Timeout);
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
               Stop.Request;
         end Server_Task_Type;

         Lanes    : Lane_Array;
         Admitted : Boolean;
      begin
         for Index in Lanes'Range loop
            Start_Half_Open
              (Lanes (Index), Address, Advance => Index mod 2 = 1);
         end loop;

         --  Every slot is now held by a handshake that will never complete.
         Probe_Admission (Address, Saturation_Budget, Admitted);
         pragma Assert
           (not Admitted,
            "listener admitted more connections than its capacity");

         if Close_Lanes then
            for Index in Lanes'Range loop
               Abandon (Lanes (Index));
            end loop;
         end if;

         Probe_Admission (Address, Probe_Budget, Admitted);
         pragma Assert
           (Admitted,
            "abandoned handshakes held their listener slots past the probe "
            & "budget");

         for Index in Lanes'Range loop
            Sockets.Close_Socket (Lanes (Index).Socket);
         end loop;
         Stop.Request;
      exception
         when others =>
            Stop.Request;
            raise;
      end;
      Sockets.Close_Socket (Listener);
   end Run_Phase;
begin
   --  A cooperative peer releases its slot as soon as its CONNECTION_CLOSE
   --  arrives, so the no-progress deadline is set beyond the whole phase to
   --  keep it out of the result.
   Run_Phase
     (Stop              => Close_Stop'Access,
      Idle_Timeout      => Server_Handshake_Timeout,
      Close_Lanes       => True,
      Saturation_Budget => 1.5,
      Probe_Budget      => 5.0);

   --  A peer that vanishes without a close is reclaimed by the no-progress
   --  deadline alone. The saturation probe finishes before that deadline can
   --  free a slot.
   Run_Phase
     (Stop              => Silent_Stop'Access,
      Idle_Timeout      => 2.0,
      Close_Lanes       => False,
      Saturation_Budget => 1.0,
      Probe_Budget      => 8.0);

   pragma Assert (Outcome.Passed, Outcome.Message);
exception
   when others =>
      --  A listener that died takes every client operation down with it, so
      --  report its own failure rather than the timeout it caused here.
      pragma Assert (Outcome.Passed, Outcome.Message);
      raise;
end HTTP3_Handshake_Abandon;
