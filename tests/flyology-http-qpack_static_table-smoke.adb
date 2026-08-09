procedure Flyology.HTTP.QPACK_Static_Table.Smoke is
begin
   for Index in Static_Index loop
      declare
         Exact : constant Lookup_Result :=
           Find_Exact (Name (Index), Value (Index));
         Named : constant Lookup_Result := Find_Name (Name (Index));
      begin
         pragma Assert
           (Exact.Found
            and then Name (Exact.Index) = Name (Index)
            and then Value (Exact.Index) = Value (Index));
         pragma Assert
           (Named.Found and then Name (Named.Index) = Name (Index));
      end;
   end loop;
   pragma Assert (Name (0) = ":authority" and then Value (0) = "");
   pragma Assert (Name (17) = ":method" and then Value (17) = "GET");
   pragma Assert (Name (23) = ":scheme" and then Value (23) = "https");
   pragma Assert (Name (25) = ":status" and then Value (25) = "200");
   pragma Assert
     (Name (98) = "x-frame-options" and then Value (98) = "sameorigin");
   pragma Assert
     (Find_Exact (":method", "GET") = (Found => True, Index => 17));
   pragma Assert
     (Find_Name ("content-type") = (Found => True, Index => 44));
   pragma Assert (not Find_Exact ("x-new-field", "value").Found);
end Flyology.HTTP.QPACK_Static_Table.Smoke;
