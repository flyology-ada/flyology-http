with Flyology.HTTP.Client;
with HTTP_Client_Corpus_Golden;

package HTTP_Client_Corpus_Oracle is
   package Golden renames HTTP_Client_Corpus_Golden;

   type Observation is record
      Kind                  : Golden.Result_Kind;
      Certainty             : Golden.Certainty_Kind;
      Status_Known          : Boolean := False;
      Status                : Natural := 0;
      Body_Effect           : Golden.Body_Effect_Kind;
      Required_Length_Known : Boolean := False;
      Required_Length       : Natural := 0;
      Source_Releases       : Natural := 0;
      Request_Reset         : Boolean := False;
      Automatic_Replay      : Boolean := False;
      Sibling_Kind_Known    : Boolean := False;
      Sibling_Kind          : Golden.Result_Kind := Golden.Cancelled;
   end record;

   function To_Golden
     (Kind : Flyology.HTTP.Client.Exchange_Result_Kind)
      return Golden.Result_Kind;
   function To_Golden
     (Certainty : Flyology.HTTP.Client.Admission_Certainty)
      return Golden.Certainty_Kind;

   procedure Check
     (Scenario : Golden.Case_Kind;
      Protocol : Golden.Protocol_Kind;
      API      : Golden.API_Style;
      Actual   : Observation);
end HTTP_Client_Corpus_Oracle;
