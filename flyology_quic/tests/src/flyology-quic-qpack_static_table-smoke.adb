procedure Flyology.QUIC.QPACK_Static_Table.Smoke is
begin
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
end Flyology.QUIC.QPACK_Static_Table.Smoke;
