with Ada.Finalization;

package body Flyology.HTTP.Server.Middleware_Bulkheads is

   Max_Route_Length : constant := 128;

   type Hash_Value is mod 2 ** 32;
   Hash_Seed : constant Hash_Value := 2_166_136_261;

   --  Digest identifying a route name a counter cannot store in full. Names
   --  within Max_Route_Length are identified exactly by their length and
   --  text, so they need no digest and pay nothing for this; only a longer
   --  name is hashed, which is what keeps the counter's identity total
   --  instead of denying the route outright.
   function Route_Digest (Value : String) return Hash_Value;

   --  Outcome of one admission attempt. Reporting an exhausted counter table
   --  separately keeps a structural inability to meter a route distinct from
   --  a genuine concurrency denial.
   --  @enum Admitted A permit was granted and must be released
   --  @enum At_Capacity A configured global or route concurrency limit is met
   --  @enum Unmeterable Route_Capacity cannot hold another active route
   type Admission is (Admitted, At_Capacity, Unmeterable);

   function Route_Digest (Value : String) return Hash_Value is
      Result : Hash_Value := Hash_Seed;
   begin
      if Value'Length <= Max_Route_Length then
         return 0;
      end if;
      for Item of Value loop
         Result :=
           (Result xor Hash_Value (Character'Pos (Item))) * 16_777_619;
      end loop;
      return Result;
   end Route_Digest;

   type Route_Entry is record
      Used   : Boolean := False;
      Digest : Hash_Value := 0;
      Name   : String (1 .. Max_Route_Length) := (others => ' ');
      Length : Natural := 0;
      Active : Natural := 0;
   end record;
   type Route_Array is array (Positive range <>) of Route_Entry;

   protected type Manager is
      procedure Acquire
        (Route  : String;
         Digest : Hash_Value;
         Limit  : Natural;
         Slot   : out Natural;
         Result : out Admission);
      procedure Release (Slot : Natural);
   private
      Global_Active : Natural := 0;
      Routes        : Route_Array (1 .. Route_Capacity);
   end Manager;

   protected body Manager is
      procedure Acquire
        (Route  : String;
         Digest : Hash_Value;
         Limit  : Natural;
         Slot   : out Natural;
         Result : out Admission)
      is
         Head : constant Natural :=
           Natural'Min (Route'Length, Max_Route_Length);
         Text : String renames Route (Route'First .. Route'First + Head - 1);
         Empty : Natural := 0;
      begin
         Slot := 0;
         Result := At_Capacity;
         if Global_Limit > 0 and then Global_Active >= Global_Limit then
            return;
         end if;
         if Limit > 0 then
            for Index in Routes'Range loop
               if Routes (Index).Used
                 and then Routes (Index).Length = Route'Length
                 and then Routes (Index).Name (1 .. Head) = Text
                 and then Routes (Index).Digest = Digest
               then
                  Slot := Index;
                  exit;
               elsif not Routes (Index).Used and then Empty = 0 then
                  Empty := Index;
               end if;
            end loop;
            if Slot = 0 and then Empty = 0 then
               --  A counter at rest holds no state, so a full table takes
               --  one over rather than denying every unseen route forever.
               --  This second pass runs only once the table is full.
               for Index in Routes'Range loop
                  if Routes (Index).Active = 0 then
                     Empty := Index;
                     exit;
                  end if;
               end loop;
            end if;
            if Slot = 0 then
               if Empty = 0 then
                  Result := Unmeterable;
                  return;
               end if;
               Slot := Empty;
               Routes (Slot).Used := True;
               Routes (Slot).Digest := Digest;
               Routes (Slot).Length := Route'Length;
               Routes (Slot).Name (1 .. Head) := Text;
               Routes (Slot).Active := 0;
            end if;
            if Routes (Slot).Active >= Limit then
               return;
            end if;
            Routes (Slot).Active := Routes (Slot).Active + 1;
         end if;
         Global_Active := Global_Active + 1;
         Result := Admitted;
      end Acquire;

      procedure Release (Slot : Natural) is
      begin
         if Global_Active = 0 then
            raise Program_Error with "HTTP bulkhead permit underflow";
         end if;
         Global_Active := Global_Active - 1;
         if Slot > 0 then
            if Slot not in Routes'Range or else Routes (Slot).Active = 0 then
               raise Program_Error with "HTTP route permit underflow";
            end if;
            Routes (Slot).Active := Routes (Slot).Active - 1;
         end if;
      end Release;
   end Manager;

   State : aliased Manager;

   type Guard is new Ada.Finalization.Limited_Controlled with record
      Slot : Natural := 0;
      Held : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Guard) is
   begin
      if Item.Held then
         State.Release (Item.Slot);
         Item.Held := False;
      end if;
   end Finalize;

   procedure Activate (Item : in out Guard; Slot : Natural) is
   begin
      Item.Slot := Slot;
      Item.Held := True;
   end Activate;

   procedure Count_Denial is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Metrics.Bulkhead_Denial);
      end if;
   exception
      when others => null;
   end Count_Denial;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Permit : Guard;
      Result : Admission;
   begin
      declare
         Route : constant String := X.Route_Name;
      begin
         State.Acquire
           (Route, Route_Digest (Route), X.Concurrency_Limit,
            Permit.Slot, Result);
      end;
      case Result is
         when Admitted =>
            Activate (Permit, Permit.Slot);
            Next.Call (Context, X);
         when At_Capacity =>
            Count_Denial;
            X.Add_Header ("Retry-After", "1");
            X.Problem (503, "bulkhead-full", "Request concurrency is full");
         when Unmeterable =>
            Count_Denial;
            X.Add_Header ("Retry-After", "1");
            X.Problem
              (503, "bulkhead-unmeterable",
               "Route concurrency counters are exhausted");
      end case;
   end Call;

end Flyology.HTTP.Server.Middleware_Bulkheads;
