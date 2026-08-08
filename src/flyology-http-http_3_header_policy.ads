with Flyology.HTTP.QPACK_Field_Section_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 header-section semantic validation.
--
--  The policy applies RFC 9114 pseudo-header ordering and message-context
--  rules after QPACK decompression. It also rejects malformed field syntax
--  and connection-specific fields before values reach HTTP applications.
private package Flyology.HTTP.HTTP_3_Header_Policy
  with SPARK_Mode => On
is
   type Validation_Status is
     (Valid,
      Empty_Name,
      Invalid_Name,
      Invalid_Value,
      Pseudo_After_Regular,
      Pseudo_In_Trailers,
      Unknown_Pseudo,
      Duplicate_Pseudo,
      Missing_Method,
      Invalid_Method,
      Missing_Scheme,
      Invalid_Scheme,
      Missing_Path,
      Missing_Authority,
      Invalid_Authority,
      Authority_Mismatch,
      Invalid_Path,
      Invalid_Connect,
      Missing_Status,
      Invalid_Status,
      Invalid_Content_Length,
      Prohibited_Field,
      Invalid_TE);

   type Validation_Result is record
      Status        : Validation_Status := Valid;
      Is_Connect    : Boolean := False;
      Is_Head       : Boolean := False;
      Response_Code : Natural range 0 .. 599 := 0;
      Is_Interim    : Boolean := False;
      Has_Content_Length : Boolean := False;
      Content_Length : Flyology.QUIC.Varint_Policy.Value_Type := 0;
   end record;

   function Validate_Request
     (Block : QPACK_Field_Section_Policy.Header_Block)
      return Validation_Result
   with Global => null;

   function Validate_Response
     (Block : QPACK_Field_Section_Policy.Header_Block)
      return Validation_Result
   with Global => null;

   function Validate_Trailers
     (Block : QPACK_Field_Section_Policy.Header_Block)
      return Validation_Result
   with Global => null;
end Flyology.HTTP.HTTP_3_Header_Policy;
