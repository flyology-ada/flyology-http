package body HTTP_Client_Corpus_Oracle is
   use type Golden.Body_Effect_Kind;
   use type Golden.Boolean_Expectation;
   use type Golden.Certainty_Kind;
   use type Golden.Result_Kind;

   function To_Golden
     (Kind : Flyology.HTTP.Client.Exchange_Result_Kind)
      return Golden.Result_Kind is
     (case Kind is
         when Flyology.HTTP.Client.Response_Complete =>
            Golden.Response_Complete,
         when Flyology.HTTP.Client.Pre_Admission_Rejected =>
            Golden.Pre_Admission_Rejected,
         when Flyology.HTTP.Client.Cancelled => Golden.Cancelled,
         when Flyology.HTTP.Client.Timed_Out => Golden.Timed_Out,
         when Flyology.HTTP.Client.Client_Unavailable =>
            Golden.Client_Unavailable,
         when Flyology.HTTP.Client.Connection_Failed =>
            Golden.Connection_Failed,
         when Flyology.HTTP.Client.Transport_Failed =>
            Golden.Transport_Failed,
         when Flyology.HTTP.Client.Request_Source_Failed =>
            Golden.Request_Source_Failed,
         when Flyology.HTTP.Client.Response_Invalid => Golden.Response_Invalid,
         when Flyology.HTTP.Client.Response_Body_Too_Large =>
            Golden.Response_Body_Too_Large,
         when Flyology.HTTP.Client.Response_Sink_Failed =>
            Golden.Response_Sink_Failed);

   function To_Golden
     (Certainty : Flyology.HTTP.Client.Admission_Certainty)
      return Golden.Certainty_Kind is
     (case Certainty is
         when Flyology.HTTP.Client.Not_Admitted => Golden.Not_Admitted,
         when Flyology.HTTP.Client.Possibly_Admitted =>
            Golden.Possibly_Admitted,
         when Flyology.HTTP.Client.Response_Observed =>
            Golden.Response_Observed);

   procedure Fail
     (Scenario : Golden.Case_Kind;
      Field    : String) is
   begin
      raise Program_Error with
        Golden.Case_Kind'Image (Scenario) & ": " & Field;
   end Fail;

   procedure Check
     (Scenario : Golden.Case_Kind;
      Protocol : Golden.Protocol_Kind;
      API      : Golden.API_Style;
      Actual   : Observation)
   is
      Item : constant Golden.Case_Descriptor := Golden.Corpus (Scenario);
      Expected : constant Golden.Expected_Observation := Item.Expected;
   begin
      if not Item.Protocols (Protocol) then
         Fail (Scenario, "protocol adapter is not applicable");
      elsif not Item.APIs (API) then
         Fail (Scenario, "API adapter is not applicable");
      elsif Actual.Kind /= Expected.Kind then
         Fail (Scenario, "result kind");
      elsif Actual.Certainty /= Expected.Certainty then
         Fail (Scenario, "admission certainty");
      end if;

      if Expected.Status_Known
        and then (not Actual.Status_Known
                    or else Actual.Status /= Expected.Status)
      then
         Fail (Scenario, "response status");
      elsif Actual.Body_Effect /= Expected.Body_Effect then
         Fail (Scenario, "body effect");
      elsif Expected.Required_Length_Known
        and then (not Actual.Required_Length_Known
                    or else Actual.Required_Length /= Expected.Required_Length)
      then
         Fail (Scenario, "required body length");
      elsif Expected.Source_Releases_Known
        and then Actual.Source_Releases /= Expected.Source_Releases
      then
         Fail (Scenario, "source release count");
      elsif Expected.Request_Reset = Golden.Required_True
        and then not Actual.Request_Reset
      then
         Fail (Scenario, "request reset was not committed");
      elsif Expected.Request_Reset = Golden.Required_False
        and then Actual.Request_Reset
      then
         Fail (Scenario, "unexpected request reset");
      elsif Expected.Automatic_Replay = Golden.Required_True
        and then not Actual.Automatic_Replay
      then
         Fail (Scenario, "automatic replay was not observed");
      elsif Expected.Automatic_Replay = Golden.Required_False
        and then Actual.Automatic_Replay
      then
         Fail (Scenario, "automatic replay occurred");
      elsif Expected.Sibling_Kind_Known
        and then (not Actual.Sibling_Kind_Known
                    or else Actual.Sibling_Kind /= Expected.Sibling_Kind)
      then
         Fail (Scenario, "sibling result kind");
      end if;
   end Check;
end HTTP_Client_Corpus_Oracle;
