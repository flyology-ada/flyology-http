with Flyology.HTTP;

--  Connect-target filters for the HTTP client audit's finding 38 lane.
--  Flyology.HTTP.Client.Connect_Target_Filter is a library-level access type,
--  so a filter cannot be declared inside the audit's main subprogram. Each
--  lane runs one exchange at a time on one task, so the recorded observation
--  needs no synchronization.
package HTTP_Client_Audit_Filters is

   --  Refuse loopback connect targets and allow everything else.
   --  @param Host Configured origin host
   --  @param Address Canonical numeric text of one resolved address
   --  @param Port Origin port the client would connect to
   --  @return True unless Address is an IPv4 or IPv6 loopback address
   function Refuse_Loopback
     (Host    : String;
      Address : String;
      Port    : Flyology.HTTP.Port_Number) return Boolean;

   --  Allow every connect target.
   --  @param Host Configured origin host
   --  @param Address Canonical numeric text of one resolved address
   --  @param Port Origin port the client would connect to
   --  @return True
   function Allow_Everything
     (Host    : String;
      Address : String;
      Port    : Flyology.HTTP.Port_Number) return Boolean;

   --  Forget every recorded observation.
   procedure Reset;

   --  Return how many connect targets a filter has seen since Reset.
   --  @return Recorded filter call count
   function Observed_Calls return Natural;

   --  Return the origin host of the most recent observation.
   --  @return Recorded host, or an empty string before the first call
   function Observed_Host return String;

   --  Return the resolved address text of the most recent observation.
   --  @return Recorded address, or an empty string before the first call
   function Observed_Address return String;

   --  Return the port of the most recent observation.
   --  @return Recorded port, or one before the first call
   function Observed_Port return Flyology.HTTP.Port_Number;

end HTTP_Client_Audit_Filters;
