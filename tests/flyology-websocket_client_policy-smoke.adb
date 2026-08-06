procedure Flyology.WebSocket_Client_Policy.Smoke is
begin
   pragma Assert (Form_For (0) = Short_Length);
   pragma Assert (Form_For (125) = Short_Length);
   pragma Assert (Form_For (126) = Medium_Length);
   pragma Assert (Form_For (65_535) = Medium_Length);
   pragma Assert (Form_For (65_536) = Long_Length);
   pragma Assert (Form_For (Max_Frame_Length) = Long_Length);

   pragma Assert
     (Validate_Header (False, False, 1, True, 5, 5) = Accept_Header);
   pragma Assert
     (Validate_Header (True, False, 1, True, 0, 0) =
        Reject_Reserved_Bits);
   pragma Assert
     (Validate_Header (False, True, 1, True, 0, 0) =
        Reject_Masked_Server_Frame);
   pragma Assert
     (Validate_Header (False, False, 3, True, 0, 0) = Reject_Opcode);
   pragma Assert
     (Validate_Header (False, False, 9, False, 0, 0) =
        Reject_Fragmented_Control);
   pragma Assert
     (Validate_Header (False, False, 9, True, 126, 126) =
        Reject_Control_Length);
   pragma Assert
     (Validate_Header (False, False, 2, True, 126, 125) =
        Reject_Noncanonical_Length);
   pragma Assert
     (Validate_Header (False, False, 2, True, 126, 65_536) =
        Reject_Noncanonical_Length);
   pragma Assert
     (Validate_Header
        (False, False, 2, True, 127,
         Long_Long_Integer (Max_Frame_Length) + 1) = Reject_Frame_Too_Large);

   pragma Assert
     (Classify_Data (1, False, 0, 3, 3) = Begin_Text);
   pragma Assert
     (Classify_Data (2, False, 0, 3, 3) = Begin_Binary);
   pragma Assert
     (Classify_Data (0, True, 2, 1, 3) = Continue_Message);
   pragma Assert
     (Classify_Data (0, False, 0, 1, 3) =
        Reject_Unexpected_Continuation);
   pragma Assert
     (Classify_Data (1, True, 1, 1, 3) = Reject_Interleaved_Message);
   pragma Assert
     (Classify_Data (0, True, 2, 2, 3) = Reject_Message_Too_Large);

   pragma Assert (Valid_Close_Code (1_000));
   pragma Assert (Valid_Close_Code (1_011));
   pragma Assert (Valid_Close_Code (1_012));
   pragma Assert (Valid_Close_Code (1_013));
   pragma Assert (Valid_Close_Code (1_014));
   pragma Assert (Valid_Close_Code (3_000));
   pragma Assert (Valid_Close_Code (4_999));
   pragma Assert (not Valid_Close_Code (999));
   pragma Assert (not Valid_Close_Code (1_005));
   pragma Assert (not Valid_Close_Code (1_015));
   pragma Assert (not Valid_Close_Code (2_000));
   pragma Assert (not Valid_Close_Code (5_000));
end Flyology.WebSocket_Client_Policy.Smoke;
