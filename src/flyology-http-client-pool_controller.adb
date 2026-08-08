separate (Flyology.HTTP.Client)
--  Serializes bounded transport-slot transitions and their coherent counters.
--  Socket establishment and close remain outside this protected object.
protected body Pool_Controller is
      --  The single admission predicate. Try_Checkout, the wake-source
      --  bookkeeping that decides whether a pending wake is drained, and
      --  Wait_Source must agree exactly: a wait predicate that reports a
      --  checkout the admission loop then refuses turns Checkout into a spin
      --  that reaches neither its deadline nor its cancellation token. An
      --  HTTP/2 slot therefore consults the peer's advertised stream limit
      --  here too, not only the client's own bound.
      function Has_Capacity (Item : Slot) return Boolean is
      begin
         return Item.Phase in Empty | Idle
           or else
             (Item.Phase = Shared
                and then Item.Active_Streams <
                  H2_Connections.Maximum_Concurrent_Streams
                and then Item.Connection /= null
                and then Item.Connection.HTTP_2 /= null
                and then H2_Connections.Can_Open
                  (Item.Connection.HTTP_2.all));
      end Has_Capacity;

      procedure Configure (Value : Pool_Configuration) is
      begin
         if Is_Configured then
            raise Program_Error with "HTTP client pool is already configured";
         end if;
         Policy := Value;
         Policy.Max_Idle := Natural'Min (Value.Max_Idle, Capacity);
         Is_Configured := True;
      end Configure;

      procedure Try_Checkout
        (Now        : Ada.Real_Time.Time;
         Prefer_HTTP_3 : Boolean;
         Allow_TCP_Fallback : Boolean;
         Result     : out Checkout_Result;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access;
         Verify     : out Boolean)
      is
         Available_After : Boolean := False;

         function Is_HTTP_3 (Item : Slot) return Boolean is
           (Item.Connection /= null
              and then Item.Connection.Protocol = HTTP_3_Transport);

         function Matches
           (Item : Slot; Want_HTTP_3 : Boolean) return Boolean is
           (Item.Connection /= null
              and then Is_HTTP_3 (Item) = Want_HTTP_3);

         function HTTP_3_Limit_Reached (Item : Slot) return Boolean is
           (Is_HTTP_3 (Item)
              and then Item.Request_Count >= HTTP_3_Requests_Per_Connection);

         function Expired (Item : Slot) return Boolean is
            Idle_Age : constant Duration := Ada.Real_Time.To_Duration
              (Now - Item.Last_Used);
            Total_Age : constant Duration := Ada.Real_Time.To_Duration
              (Now - Item.Born);
         begin
            return
              (Item.Active_Streams = 0
                 and then Policy.Idle_Timeout >= 0.0
                 and then Idle_Age >= Policy.Idle_Timeout)
              or else
              (Policy.Max_Connection_Age >= 0.0
                 and then Total_Age >= Policy.Max_Connection_Age)
              or else
              (Policy.Max_Requests_Per_Connection > 0
                 and then Item.Request_Count >=
                   Policy.Max_Requests_Per_Connection)
              or else HTTP_3_Limit_Reached (Item);
         end Expired;

         function Desired_Exists return Boolean is
         begin
            for Item of Slots loop
               if (Item.Phase = Connecting
                     and then Item.Connecting_HTTP_3 = Prefer_HTTP_3)
                 or else
                   (Item.Phase in Leased | Idle | Shared
                      and then Matches (Item, Prefer_HTTP_3))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Desired_Exists;

         procedure Select_Shared_TCP (Permit : Boolean) is
         begin
            if not Permit then
               return;
            end if;
            for Index in Slots'Range loop
               if Slots (Index).Phase = Shared
                 and then Matches (Slots (Index), Want_HTTP_3 => False)
                 and then Has_Capacity (Slots (Index))
               then
                  if Expired (Slots (Index)) then
                     Shared_Count := Shared_Count - 1;
                     if Slots (Index).Active_Streams = 0 then
                        Idle_Count := Idle_Count - 1;
                        Slots (Index).Phase := Closing;
                        Closing_Count := Closing_Count + 1;
                        Slot_Index := Index;
                        Connection := Slots (Index).Connection;
                        Result := Checkout_Discard;
                        return;
                     else
                        Slots (Index).Phase := Draining;
                     end if;
                  else
                     if Slots (Index).Active_Streams = 0 then
                        Idle_Count := Idle_Count - 1;
                     end if;
                     Slots (Index).Active_Streams :=
                       Slots (Index).Active_Streams + 1;
                     Slots (Index).Request_Count :=
                       Slots (Index).Request_Count + 1;
                     Leased_Count := Leased_Count + 1;
                     Reused_Count := Reused_Count + 1;
                     Slot_Index := Index;
                     Connection := Slots (Index).Connection;
                     Result := Checkout_Idle;
                     return;
                  end if;
               end if;
            end loop;
         end Select_Shared_TCP;

         procedure Select_Idle
           (Want_HTTP_3 : Boolean; Permit : Boolean) is
         begin
            if not Permit then
               return;
            end if;
            for Index in Slots'Range loop
               if Slots (Index).Phase = Idle
                 and then Matches (Slots (Index), Want_HTTP_3)
               then
                  Slot_Index := Index;
                  Connection := Slots (Index).Connection;
                  Idle_Count := Idle_Count - 1;
                  if Expired (Slots (Index)) then
                     Slots (Index).Phase := Closing;
                     Closing_Count := Closing_Count + 1;
                     Result := Checkout_Discard;
                  else
                     Slots (Index).Phase := Leased;
                     Slots (Index).Request_Count :=
                       Slots (Index).Request_Count + 1;
                     Leased_Count := Leased_Count + 1;
                     Reused_Count := Reused_Count + 1;
                     Verify := Slots (Index).Verify_On_Reuse;
                     Slots (Index).Verify_On_Reuse := False;
                     Result := Checkout_Idle;
                  end if;
                  return;
               end if;
            end loop;
         end Select_Idle;

         procedure Discard_Incompatible_Idle is
         begin
            for Index in Slots'Range loop
               if Slots (Index).Connection /= null
                 and then not Matches (Slots (Index), Prefer_HTTP_3)
                 and then
                   (Slots (Index).Phase = Idle
                      or else
                    (Slots (Index).Phase = Shared
                       and then Slots (Index).Active_Streams = 0))
               then
                  if Slots (Index).Phase = Shared then
                     Shared_Count := Shared_Count - 1;
                  end if;
                  Idle_Count := Idle_Count - 1;
                  Slots (Index).Phase := Closing;
                  Closing_Count := Closing_Count + 1;
                  Slot_Index := Index;
                  Connection := Slots (Index).Connection;
                  Result := Checkout_Discard;
                  return;
               end if;
            end loop;
         end Discard_Incompatible_Idle;
      begin
         Slot_Index := 0;
         Connection := null;
         Verify := False;
         if Stopping then
            Result := Checkout_Closed;
            return;
         end if;

         Select_Shared_TCP (Permit => not Prefer_HTTP_3);
         if Slot_Index = 0 then
            Select_Idle (Prefer_HTTP_3, Permit => True);
         end if;

         --  Once the preferred H3 lane exists but is busy or connecting, a
         --  negotiated client can immediately use retained TCP capacity.
         --  This keeps H1/H2 and H3 available at the same time without
         --  duplicating one application request across transports.
         if Slot_Index = 0
           and then Prefer_HTTP_3
           and then Allow_TCP_Fallback
           and then Desired_Exists
         then
            Select_Shared_TCP (Permit => True);
            if Slot_Index = 0 then
               Select_Idle (Want_HTTP_3 => False, Permit => True);
            end if;
         end if;

         if Slot_Index = 0 then
            for Index in Slots'Range loop
               if Slots (Index).Phase = Empty then
                  Slots (Index).Phase := Connecting;
                  Slots (Index).Connecting_HTTP_3 := Prefer_HTTP_3;
                  Connecting_Count := Connecting_Count + 1;
                  Slot_Index := Index;
                  Result := Checkout_Create;
                  exit;
               end if;
            end loop;
         end if;

         --  A capacity-one pool cannot retain both stacks. Replace only an
         --  idle incompatible transport so the explicitly preferred stack
         --  can still make progress; active exchanges are never displaced.
         if Slot_Index = 0 then
            Discard_Incompatible_Idle;
         end if;

         if Slot_Index = 0 then
            Result := Checkout_Busy;
         end if;

         --  A pending wake is drained only when nothing is left to check
         --  out, so the scan is needed only while a waiter has armed the
         --  source. Keeping it out of the uncontended path also keeps the
         --  pool lock off every pooled session's lock.
         if Checkout_Signalled then
            for Item of Slots loop
               if Has_Capacity (Item) then
                  Available_After := True;
                  exit;
               end if;
            end loop;
            if not Available_After then
               Flyology.Wake_Sources.Consume (Checkout_Wake);
               Checkout_Signalled := False;
            end if;
         end if;
      end Try_Checkout;

      procedure Install
        (Slot_Index : Positive;
         Connection : Pooled_Connection_Access;
         Now        : Ada.Real_Time.Time) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
           or else Connection = null
         then
            raise Program_Error with "invalid HTTP pool connection install";
         elsif Stopping then
            raise Client_Closed;
         end if;
         Slots (Slot_Index) :=
           (Phase         =>
              (if Connection.Protocol = HTTP_2_Transport
               then Shared else Leased),
            Connection    => Connection,
            Born          => Now,
            Last_Used     => Now,
            Request_Count => 1,
            Active_Streams =>
              (if Connection.Protocol = HTTP_2_Transport then 1 else 0),
            Interrupting  => False,
            Interrupt_Sent => False,
            Owner_Done    => False,
            Verify_On_Reuse => False,
            Connecting_HTTP_3 => False);
         Connecting_Count := Connecting_Count - 1;
         Leased_Count := Leased_Count + 1;
         if Connection.Protocol = HTTP_2_Transport then
            Shared_Count := Shared_Count + 1;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
         Created_Count := Created_Count + 1;
      end Install;

      procedure Publish_Connecting
        (Slot_Index : Positive; Connection : Pooled_Connection_Access) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
           or else Connection = null
         then
            raise Program_Error with
              "invalid HTTP pool connecting transport publication";
         elsif Stopping then
            raise Client_Closed;
         end if;
         Slots (Slot_Index).Connection := Connection;
      end Publish_Connecting;

      procedure Creation_Failed
        (Slot_Index : Positive; Result : out Failure_Result) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Connecting
         then
            raise Program_Error with "invalid HTTP pool creation failure";
         end if;
         Connecting_Count := Connecting_Count - 1;
         if Slots (Slot_Index).Interrupting then
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Failure_Free_Deferred;
         else
            Slots (Slot_Index) := (others => <>);
            Result := Failure_Free;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
      end Creation_Failed;

      procedure Return_Lease
        (Slot_Index : Positive;
         Reusable   : Boolean;
         Verify     : Boolean;
         Now        : Ada.Real_Time.Time;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access)
      is
         Total_Age : Duration;
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase not in Leased | Shared | Draining
         then
            raise Program_Error with "invalid HTTP pool lease return";
         end if;
         Connection := Slots (Slot_Index).Connection;
         Total_Age := Ada.Real_Time.To_Duration
           (Now - Slots (Slot_Index).Born);
         Leased_Count := Leased_Count - 1;
         if Slots (Slot_Index).Phase in Shared | Draining then
            if Slots (Slot_Index).Active_Streams = 0 then
               raise Program_Error with "invalid HTTP/2 stream lease return";
            end if;
            Slots (Slot_Index).Active_Streams :=
              Slots (Slot_Index).Active_Streams - 1;
            if Slots (Slot_Index).Phase = Shared
              and then
                (not Reusable
                   or else Stopping
                   or else
                     (Policy.Max_Connection_Age >= 0.0
                        and then Total_Age >= Policy.Max_Connection_Age)
                   or else
                     (Policy.Max_Requests_Per_Connection > 0
                        and then Slots (Slot_Index).Request_Count >=
                          Policy.Max_Requests_Per_Connection))
            then
               Slots (Slot_Index).Phase := Draining;
               Shared_Count := Shared_Count - 1;
            end if;
            if Slots (Slot_Index).Active_Streams > 0 then
               Result := Returned_Shared;
            elsif Slots (Slot_Index).Phase = Shared
              and then Idle_Count < Policy.Max_Idle
            then
               Slots (Slot_Index).Last_Used := Now;
               Idle_Count := Idle_Count + 1;
               Result := Returned_Shared;
            else
               if Slots (Slot_Index).Phase = Shared then
                  Shared_Count := Shared_Count - 1;
               end if;
               Slots (Slot_Index).Phase := Closing;
               Slots (Slot_Index).Owner_Done := True;
               Closing_Count := Closing_Count + 1;
               Result :=
                 (if Slots (Slot_Index).Interrupting
                  then Return_Close_Deferred else Return_Close);
            end if;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
            return;
         end if;
         if Reusable and then not Stopping
           and then Idle_Count < Policy.Max_Idle
           and then
             (Connection.Protocol /= HTTP_3_Transport
                or else Slots (Slot_Index).Request_Count <
                  HTTP_3_Requests_Per_Connection)
           and then
             (Policy.Max_Connection_Age < 0.0
                or else Total_Age < Policy.Max_Connection_Age)
           and then
             (Policy.Max_Requests_Per_Connection = 0
                or else Slots (Slot_Index).Request_Count <
                  Policy.Max_Requests_Per_Connection)
         then
            Slots (Slot_Index).Phase := Idle;
            Slots (Slot_Index).Last_Used := Now;
            Slots (Slot_Index).Verify_On_Reuse := Verify;
            Idle_Count := Idle_Count + 1;
            Result := Returned_Idle;
         elsif Slots (Slot_Index).Interrupting then
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Return_Close_Deferred;
         else
            Slots (Slot_Index).Phase := Closing;
            Slots (Slot_Index).Owner_Done := True;
            Closing_Count := Closing_Count + 1;
            Result := Return_Close;
         end if;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Return_Lease;

      --  Undo a reuse whose transport turned out to be desynchronized. The
      --  exchange was never assigned it, so the reuse tally is withdrawn and
      --  the slot moves straight to Closing.
      procedure Reject_Reuse
        (Slot_Index : Positive;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Leased
         then
            raise Program_Error with "invalid HTTP pool reuse rejection";
         end if;
         Connection := Slots (Slot_Index).Connection;
         Leased_Count := Leased_Count - 1;
         Reused_Count := Reused_Count - 1;
         Slots (Slot_Index).Phase := Closing;
         Slots (Slot_Index).Owner_Done := True;
         Closing_Count := Closing_Count + 1;
         Result :=
           (if Slots (Slot_Index).Interrupting
            then Return_Close_Deferred else Return_Close);
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Reject_Reuse;

      procedure Finish_Close (Slot_Index : Positive) is
      begin
         if Slot_Index > Capacity
           or else Slots (Slot_Index).Phase /= Closing
         then
            raise Program_Error with "invalid HTTP pool close completion";
         end if;
         Slots (Slot_Index) := (others => <>);
         Closing_Count := Closing_Count - 1;
         Closed_Count := Closed_Count + 1;
         if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
           and then not Checkout_Signalled
         then
            Flyology.Wake_Sources.Signal (Checkout_Wake);
            Checkout_Signalled := True;
         end if;
      end Finish_Close;

      procedure Take_Idle
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access) is
      begin
         Found := False;
         Slot_Index := 0;
         Connection := null;
         for Index in Slots'Range loop
            if Slots (Index).Phase = Idle
              or else
                (Slots (Index).Phase in Shared | Draining
                   and then Slots (Index).Active_Streams = 0)
            then
               if Slots (Index).Phase = Shared then
                  Shared_Count := Shared_Count - 1;
               end if;
               if Slots (Index).Phase in Idle | Shared then
                  Idle_Count := Idle_Count - 1;
               end if;
               Slots (Index).Phase := Closing;
               Closing_Count := Closing_Count + 1;
               Found := True;
               Slot_Index := Index;
               Connection := Slots (Index).Connection;
               exit;
            end if;
         end loop;
      end Take_Idle;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            Stopping := True;
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            Flyology.Wake_Sources.Signal (Shutdown_Wake);
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         end if;
      end Request_Shutdown;

      procedure Take_Active_For_Interrupt
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access) is
      begin
         Found := False;
         Slot_Index := 0;
         Connection := null;
         for Index in Slots'Range loop
            if (Slots (Index).Phase in Connecting | Leased
                  or else
                (Slots (Index).Phase in Shared | Draining
                   and then Slots (Index).Active_Streams > 0))
              and then Slots (Index).Connection /= null
              and then not Slots (Index).Interrupt_Sent
            then
               Slots (Index).Interrupting := True;
               Slots (Index).Interrupt_Sent := True;
               Found := True;
               Slot_Index := Index;
               Connection := Slots (Index).Connection;
               exit;
            end if;
         end loop;
      end Take_Active_For_Interrupt;

      procedure Finish_Interrupt
        (Slot_Index : Positive;
         Release_Ownership : out Boolean;
         Connection : out Pooled_Connection_Access) is
      begin
         if Slot_Index > Capacity
           or else not Slots (Slot_Index).Interrupting
         then
            raise Program_Error with "invalid HTTP pool interrupt completion";
         end if;
         Slots (Slot_Index).Interrupting := False;
         Release_Ownership :=
           Slots (Slot_Index).Phase = Closing
             and then Slots (Slot_Index).Owner_Done;
         if Release_Ownership then
            Connection := Slots (Slot_Index).Connection;
            Slots (Slot_Index) := (others => <>);
            Closing_Count := Closing_Count - 1;
            Closed_Count := Closed_Count + 1;
            if Flyology.Wake_Sources.Descriptor (Checkout_Wake) >= 0
              and then not Checkout_Signalled
            then
               Flyology.Wake_Sources.Signal (Checkout_Wake);
               Checkout_Signalled := True;
            end if;
         else
            Connection := null;
         end if;
      end Finish_Interrupt;

      entry Await_Drained
        when Connecting_Count + Leased_Count + Idle_Count + Closing_Count = 0
      is
      begin
         null;
      end Await_Drained;

      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean)
      is
      begin
         Can_Checkout := Stopping;
         if not Can_Checkout then
            for Item of Slots loop
               if Has_Capacity (Item) then
                  Can_Checkout := True;
                  exit;
               end if;
            end loop;
         end if;
         if Can_Checkout then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Checkout_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Checkout_Wake);
         end if;
      end Wait_Source;

      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean) is
      begin
         Requested := Stopping;
         if Stopping then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            Flyology.Wake_Sources.Ensure (Shutdown_Wake);
            FD := Flyology.Wake_Sources.Descriptor (Shutdown_Wake);
         end if;
      end Shutdown_Source;

      procedure Register_Waiter is
      begin
         Waiter_Count := Waiter_Count + 1;
      end Register_Waiter;

      procedure Unregister_Waiter is
      begin
         if Waiter_Count = 0 then
            raise Program_Error with "HTTP pool waiter released twice";
         end if;
         Waiter_Count := Waiter_Count - 1;
      end Unregister_Waiter;

      procedure Record_Admission_Timeout is
      begin
         Timeout_Count := Timeout_Count + 1;
      end Record_Admission_Timeout;

      procedure Record_Stale_Retry is
      begin
         Stale_Retry_Count := Stale_Retry_Count + 1;
      end Record_Stale_Retry;

      function Snapshot return Client_Diagnostics is
         Reusable : Natural := 0;
      begin
         for Item of Slots loop
            if Item.Phase in Idle | Shared then
               Reusable := Reusable + 1;
            end if;
         end loop;
         return
           (Transport_Capacity => Capacity,
            Pending_Transports => Connecting_Count,
            Active_Exchanges   => Leased_Count,
            Reusable_Transports => Reusable,
            Closing_Transports => Closing_Count,
            Admission_Waiters  => Waiter_Count,
            Transports_Created => Created_Count,
            Transport_Reuses   => Reused_Count,
            Transports_Closed  => Closed_Count,
            Stale_Retries      => Stale_Retry_Count,
            Admission_Timeouts => Timeout_Count);
      end Snapshot;

      function Is_Stopping return Boolean is (Stopping);
end Pool_Controller;
