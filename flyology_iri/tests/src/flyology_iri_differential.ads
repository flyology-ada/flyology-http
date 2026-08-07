--  Differential harness over the parsing entry points. Can_Parse,
--  Diagnose, Parse and Try_Parse each reach the grammar through a
--  different route, and Web_URL_Syntax has two of those routes again in a
--  fast path and a WHATWG path. This harness drives every entry point over
--  one seeded corpus and reports each pair that disagrees.
package Flyology_IRI_Differential is

   --  Run the fixed cases and the seeded corpus through every entry point.
   --  Each disagreement is printed to standard output.
   --  @return Number of observed disagreements
   function Disagreements return Natural;

end Flyology_IRI_Differential;
