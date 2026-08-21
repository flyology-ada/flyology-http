with Flyology.Bytes;
with Flyology.HTTP.Headers;

--  Builds HTTP/2 response field sections without transport or stream policy.
private package Flyology.HTTP.HTTP_2_Responses is

   function Encode_Head
     (Status             : Status_Code;
      Content_Type       : String;
      Fields             : Flyology.HTTP.Headers.List;
      Has_Content_Length : Boolean;
      Content_Length     : Body_Size) return Flyology.Bytes.Unbounded_Bytes;

end Flyology.HTTP.HTTP_2_Responses;
