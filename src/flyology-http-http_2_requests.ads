with Flyology.Bytes;
with Flyology.HTTP.Headers;

--  Builds one HTTP/2 request field section without transport or stream policy.
private package Flyology.HTTP.HTTP_2_Requests is

   function Encode_Head
     (Method_Text       : String;
      Scheme_Text       : String;
      Authority         : String;
      Target            : String;
      Fields            : Flyology.HTTP.Headers.List;
      Has_Content_Length : Boolean;
      Content_Length    : Long_Long_Integer;
      Expect_Continue   : Boolean) return Flyology.Bytes.Unbounded_Bytes
   with Pre => Content_Length >= 0;

   function Encode_Trailers
     (Fields : Flyology.HTTP.Headers.List)
      return Flyology.Bytes.Unbounded_Bytes;

end Flyology.HTTP.HTTP_2_Requests;
