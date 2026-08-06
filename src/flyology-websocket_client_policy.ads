--  Proved scalar policy consumed by the WebSocket client framing core.
private package Flyology.WebSocket_Client_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   --  @exclude Internal proof policy, not part of the public API.

   Max_Frame_Length : constant := 16 * 1_024 * 1_024;
   subtype Frame_Length is Natural range 0 .. Max_Frame_Length;

   type Length_Form is (Short_Length, Medium_Length, Long_Length);

   function Form_For (Length : Frame_Length) return Length_Form
   with
     Global => null,
     Contract_Cases =>
       (Length <= 125 => Form_For'Result = Short_Length,
        (Length in 126 .. 65_535) => Form_For'Result = Medium_Length,
        Length > 65_535 => Form_For'Result = Long_Length);

   type Header_Action is
     (Accept_Header,
      Reject_Reserved_Bits,
      Reject_Masked_Server_Frame,
      Reject_Opcode,
      Reject_Fragmented_Control,
      Reject_Control_Length,
      Reject_Noncanonical_Length,
      Reject_Frame_Too_Large);

   function Validate_Header
     (Reserved_Bits : Boolean;
      Masked        : Boolean;
      Opcode        : Natural;
      Final         : Boolean;
      Length_Code   : Natural;
      Length        : Long_Long_Integer) return Header_Action
   with
     Global => null,
     Pre    => Length_Code <= 127 and then Length >= 0,
     Post   =>
       (if Validate_Header'Result = Accept_Header then
          (not Reserved_Bits
           and then not Masked
           and then Opcode in 0 | 1 | 2 | 8 | 9 | 10
           and then (Opcode < 8 or else (Final and then Length <= 125))
           and then
             (if Length_Code <= 125 then
                 Length = Long_Long_Integer (Length_Code)
              elsif Length_Code = 126 then Length in 126 .. 65_535
              else Length >= 65_536)
           and then Length <= Long_Long_Integer (Max_Frame_Length)));

   type Data_Action is
     (Begin_Text,
      Begin_Binary,
      Continue_Message,
      Reject_Unexpected_Continuation,
      Reject_Interleaved_Message,
      Reject_Message_Too_Large);

   function Classify_Data
     (Opcode       : Natural;
      Fragmented   : Boolean;
      Current_Size : Frame_Length;
      Frame_Size   : Frame_Length;
      Maximum      : Frame_Length) return Data_Action
   with
     Global => null,
     Pre    => Opcode in 0 .. 2 and then Current_Size <= Maximum,
     Contract_Cases =>
       (Opcode = 0 and then not Fragmented =>
          Classify_Data'Result = Reject_Unexpected_Continuation,
        Opcode /= 0 and then Fragmented =>
          Classify_Data'Result = Reject_Interleaved_Message,
        (Opcode = 0) = Fragmented
          and then Frame_Size > Maximum - Current_Size =>
            Classify_Data'Result = Reject_Message_Too_Large,
        (Opcode = 0) = Fragmented
          and then Frame_Size <= Maximum - Current_Size
          and then Opcode = 0 =>
            Classify_Data'Result = Continue_Message,
        (Opcode = 0) = Fragmented
          and then Frame_Size <= Maximum - Current_Size
          and then Opcode = 1 =>
            Classify_Data'Result = Begin_Text,
        others => Classify_Data'Result = Begin_Binary);

   function Valid_Close_Code (Code : Natural) return Boolean
   with
     Global => null,
     Post   =>
       Valid_Close_Code'Result =
         (Code in 1_000 .. 1_003
          or else Code in 1_007 .. 1_014
          or else Code in 3_000 .. 4_999);

end Flyology.WebSocket_Client_Policy;
