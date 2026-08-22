package body Flyology.IO.TLS.Testing is

   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64
   is
      Snapshot     : aliased Descriptor_Generation;
      State        : aliased Operation_State := Unregistered;
      FD           : Descriptor;
      Lease_Source : Descriptor;
      Close_Source : Descriptor;
   begin
      Item.Controller.Start_Operation
        (Snapshot'Access,
         State'Access,
         FD,
         Lease_Source,
         Close_Source);
      Item.Controller.Abandon_Operation (Snapshot, State'Access);
      return Interfaces.Unsigned_64 (Snapshot);
   end Generation;

   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean)
   is
      FD           : Descriptor;
      Actual       : aliased Descriptor_Generation;
      State        : aliased Operation_State := Unregistered;
      Lease_Source : Descriptor;
      Close_Source : Descriptor;
      Result       : Lease_Result;
   begin
      Item.Controller.Start_Operation
        (Actual'Access,
         State'Access,
         FD,
         Lease_Source,
         Close_Source);
      Item.Controller.Try_Acquire
        (Descriptor_Generation (Snapshot),
         State'Access,
         Result,
         FD,
         Close_Source);
      Was_Replaced := Result = Lease_Cancelled;
      case State is
         when Unregistered =>
            null;
         when Registered =>
            Item.Controller.Abandon_Operation (Actual, State'Access);
         when Acquired =>
            Item.Controller.Release (Actual, State'Access);
      end case;
   end Attempt_Stale_Acquisition;

end Flyology.IO.TLS.Testing;
