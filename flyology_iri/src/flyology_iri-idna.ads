private package Flyology_IRI.IDNA is
   --  Internal UTS #46/IDNA support used by the web URL parser. This unit is
   --  not part of the crate's public API.

   --  Convert a UTF-8 domain to lower-case ASCII using the URL parser's UTS
   --  #46 mapping and Punycode implementation.
   --  @param Input UTF-8 domain bytes
   --  @param Success True when conversion succeeds
   --  @return ASCII domain, or an empty string on failure
   function To_ASCII (Input : String; Success : out Boolean) return String;

end Flyology_IRI.IDNA;
