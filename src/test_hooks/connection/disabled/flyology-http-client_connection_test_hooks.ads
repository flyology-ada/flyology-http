--  Disabled client connection test seams selected by the owning project.
--  Imported-only declarations make a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.HTTP.Client_Connection_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Barrier (Point : Natural)
   with Import,
        External_Name =>
          "flyology_http_disabled_hook_must_be_elided_barrier";

   function Receive_Limit (Requested : Positive) return Positive
   with Import,
        External_Name =>
          "flyology_http_disabled_hook_must_be_elided_receive_limit";

   procedure Receive_Observed
   with Import,
        External_Name =>
          "flyology_http_disabled_hook_must_be_elided_receive_observed";

end Flyology.HTTP.Client_Connection_Test_Hooks;
