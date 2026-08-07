with Ada.Strings.Unbounded;

package body HTTP_Client_Audit_Filters is
   use Ada.Strings.Unbounded;

   Calls        : Natural := 0;
   Last_Host    : Unbounded_String;
   Last_Address : Unbounded_String;
   Last_Port    : Flyology.HTTP.Port_Number := 1;

   procedure Record_Target
     (Host    : String;
      Address : String;
      Port    : Flyology.HTTP.Port_Number) is
   begin
      Calls := Calls + 1;
      Last_Host := To_Unbounded_String (Host);
      Last_Address := To_Unbounded_String (Address);
      Last_Port := Port;
   end Record_Target;

   function Refuse_Loopback
     (Host    : String;
      Address : String;
      Port    : Flyology.HTTP.Port_Number) return Boolean is
   begin
      Record_Target (Host, Address, Port);
      return Address /= "127.0.0.1" and then Address /= "::1";
   end Refuse_Loopback;

   function Allow_Everything
     (Host    : String;
      Address : String;
      Port    : Flyology.HTTP.Port_Number) return Boolean is
   begin
      Record_Target (Host, Address, Port);
      return True;
   end Allow_Everything;

   procedure Reset is
   begin
      Calls := 0;
      Last_Host := Null_Unbounded_String;
      Last_Address := Null_Unbounded_String;
      Last_Port := 1;
   end Reset;

   function Observed_Calls return Natural is (Calls);

   function Observed_Host return String is (To_String (Last_Host));

   function Observed_Address return String is (To_String (Last_Address));

   function Observed_Port return Flyology.HTTP.Port_Number is (Last_Port);

end HTTP_Client_Audit_Filters;
