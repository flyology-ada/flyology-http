--  Enabled client connection test seams selected by the owning project.
--  Native test controls widen narrowly identified ownership and readiness
--  race windows.
private package Flyology.HTTP.Client_Connection_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := True;

   procedure Barrier (Point : Natural);
   function Receive_Limit (Requested : Positive) return Positive;
   procedure Receive_Observed;

end Flyology.HTTP.Client_Connection_Test_Hooks;
