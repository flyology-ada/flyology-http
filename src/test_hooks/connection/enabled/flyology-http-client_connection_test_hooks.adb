with Interfaces.C;

package body Flyology.HTTP.Client_Connection_Test_Hooks is
   use type Interfaces.C.int;

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

   function Test_Receive_Limit
     (Requested : Interfaces.C.int) return Interfaces.C.int
   with Import,
        Convention => C,
        External_Name => "flyology_http_test_connection_receive_limit";

   procedure Test_Receive_Observed
   with Import,
        Convention => C,
        External_Name => "flyology_http_test_connection_receive_observed";

   procedure Barrier (Point : Natural) is
      Position : constant Interfaces.C.int := Interfaces.C.int (Point);
   begin
      if Test_Barrier_Arrive (Position) /= 0 then
         while Test_Barrier_Released (Position) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Barrier;

   function Receive_Limit (Requested : Positive) return Positive
   is (Positive (Test_Receive_Limit (Interfaces.C.int (Requested))));

   procedure Receive_Observed is
   begin
      Test_Receive_Observed;
   end Receive_Observed;

end Flyology.HTTP.Client_Connection_Test_Hooks;
