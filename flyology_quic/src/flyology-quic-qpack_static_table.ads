--  Internal QPACK static table from RFC 9204 Appendix A.
private package Flyology.QUIC.QPACK_Static_Table
  with Preelaborate,
       SPARK_Mode => On
is
   subtype Static_Index is Natural range 0 .. 98;

   function Name (Index : Static_Index) return String
   with Global => null;

   function Value (Index : Static_Index) return String
   with Global => null;

   type Lookup_Result is record
      Found : Boolean := False;
      Index : Static_Index := 0;
   end record;

   function Find_Exact
     (Field_Name  : String;
      Field_Value : String) return Lookup_Result
   with Global => null;

   function Find_Name (Field_Name : String) return Lookup_Result
   with Global => null;
end Flyology.QUIC.QPACK_Static_Table;
