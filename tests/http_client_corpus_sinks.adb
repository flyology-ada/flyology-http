package body HTTP_Client_Corpus_Sinks is
   overriding procedure Write
     (Item : in out Fault_Sink;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      Item.Writes := Item.Writes + 1;
      if Item.Fault = Partial_Failure then
         Item.Visible := Item.Visible + Natural (Data'Length);
      end if;
      raise Constraint_Error with "corpus sink failure";
   end Write;

   function Visible_Bytes (Item : Fault_Sink) return Natural is
     (Item.Visible);

   function Write_Count (Item : Fault_Sink) return Natural is
     (Item.Writes);
end HTTP_Client_Corpus_Sinks;
