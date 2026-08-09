--  Internal QPACK static table from RFC 9204 Appendix A.
private package Flyology.HTTP.QPACK_Static_Table
  with SPARK_Mode => On
is
   subtype Static_Index is Natural range 0 .. 98;

   Max_Name_Length  : constant := 32;
   Max_Value_Length : constant := 64;

   function Name (Index : Static_Index) return String
   with Global => null,
        Post => Name'Result'Length in 1 .. Max_Name_Length;

   function Value (Index : Static_Index) return String
   with Global => null,
        Post => Value'Result'Length <= Max_Value_Length;

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

   procedure Find
     (Field_Name  : String;
      Field_Value : String;
      Exact       : out Lookup_Result;
      Named       : out Lookup_Result)
   with Global => null;
end Flyology.HTTP.QPACK_Static_Table;
