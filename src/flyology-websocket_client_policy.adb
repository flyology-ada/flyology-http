package body Flyology.WebSocket_Client_Policy
  with SPARK_Mode => On
is
   function Form_For (Length : Frame_Length) return Length_Form is
     (if Length <= 125 then Short_Length
      elsif Length <= 65_535 then Medium_Length
      else Long_Length);

   function Validate_Header
     (Reserved_Bits : Boolean;
      Masked        : Boolean;
      Opcode        : Natural;
      Final         : Boolean;
      Length_Code   : Natural;
      Length        : Long_Long_Integer) return Header_Action
   is
   begin
      if Reserved_Bits then
         return Reject_Reserved_Bits;
      elsif Masked then
         return Reject_Masked_Server_Frame;
      elsif Opcode not in 0 | 1 | 2 | 8 | 9 | 10 then
         return Reject_Opcode;
      elsif Opcode >= 8 and then not Final then
         return Reject_Fragmented_Control;
      elsif Opcode >= 8 and then Length > 125 then
         return Reject_Control_Length;
      elsif (Length_Code <= 125
             and then Length /= Long_Long_Integer (Length_Code))
        or else
          (Length_Code = 126 and then Length not in 126 .. 65_535)
        or else (Length_Code = 127 and then Length < 65_536)
      then
         return Reject_Noncanonical_Length;
      elsif Length > Long_Long_Integer (Max_Frame_Length) then
         return Reject_Frame_Too_Large;
      else
         return Accept_Header;
      end if;
   end Validate_Header;

   function Classify_Data
     (Opcode       : Natural;
      Fragmented   : Boolean;
      Current_Size : Frame_Length;
      Frame_Size   : Frame_Length;
      Maximum      : Frame_Length) return Data_Action
   is
   begin
      if Opcode = 0 and then not Fragmented then
         return Reject_Unexpected_Continuation;
      elsif Opcode /= 0 and then Fragmented then
         return Reject_Interleaved_Message;
      elsif Frame_Size > Maximum - Current_Size then
         return Reject_Message_Too_Large;
      elsif Opcode = 0 then
         return Continue_Message;
      elsif Opcode = 1 then
         return Begin_Text;
      else
         return Begin_Binary;
      end if;
   end Classify_Data;

   function Valid_Close_Code (Code : Natural) return Boolean is
     (Code in 1_000 .. 1_003
      or else Code in 1_007 .. 1_014
      or else Code in 3_000 .. 4_999);

end Flyology.WebSocket_Client_Policy;
