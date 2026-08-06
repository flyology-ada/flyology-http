private package Flyology_IRI.Web is
   --  Internal WHATWG URL parser and serializer. This unit is not public API.

   --  Parse and serialize a WHATWG URL, optionally against a base URL.
   --  @param Input URL input bytes
   --  @param Base Serialized absolute base URL
   --  @param Has_Base True when Base is present
   --  @param Success True when parsing succeeds
   --  @return Canonical URL serialization, or an empty string on failure
   function Parse
     (Input    : String;
      Base     : String;
      Has_Base : Boolean;
      Success  : out Boolean) return String;

end Flyology_IRI.Web;
