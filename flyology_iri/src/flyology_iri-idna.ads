private package Flyology_IRI.IDNA is
   --  Internal UTS #46/IDNA support used by the web URL parser. This unit is
   --  not part of the crate's public API.

   --  Convert a UTF-8 domain to lower-case ASCII with the subset of UTS #46
   --  this crate carries: the ignorable and fullwidth mappings, case
   --  folding, rejection of the code points that carry no glyph, RFC 5893's
   --  prohibition on mixing letter directions inside one label, and RFC
   --  3492 Punycode encoding. It does not carry the full UTS #46 mapping
   --  table, the unassigned and mapped-symbol parts of the disallowed set,
   --  the ContextJ joiner rules, the remaining clauses of the bidi rule, or
   --  a Punycode decoder, so an already-encoded "xn--" label is copied
   --  through rather than decoded and revalidated. Per WHATWG, ToASCII runs
   --  with VerifyDnsLength false, so no DNS length limit is applied.
   --  @param Input UTF-8 domain bytes
   --  @param Success True when conversion succeeds
   --  @return ASCII domain, or an empty string on failure
   function To_ASCII (Input : String; Success : out Boolean) return String;

end Flyology_IRI.IDNA;
