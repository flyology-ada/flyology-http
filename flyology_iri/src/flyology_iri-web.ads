private package Flyology_IRI.Web is
   --  Internal WHATWG URL parser and serializer. This unit is not public API.

   --  Parse and serialize a WHATWG URL, optionally against a base URL.
   --  @param Input URL input bytes
   --  @param Base Serialized absolute base URL
   --  @param Has_Base True when Base is present
   --  @param Error No_Error on success, otherwise the failure category and
   --  its one-based byte offset into Input
   --  @return Canonical URL serialization, or an empty string on failure
   function Parse
     (Input    : String;
      Base     : String;
      Has_Base : Boolean;
      Error    : out Parse_Error) return String;

end Flyology_IRI.Web;
