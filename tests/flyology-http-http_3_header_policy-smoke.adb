procedure Flyology.HTTP.HTTP_3_Header_Policy.Smoke is
   use QPACK_Field_Section_Policy;

   Fields : Header_Block;
   Result : Validation_Result;
begin
   Fields.Count := 5;
   Fields.Fields (1) := Make_Field (":method", "GET");
   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":path", "/resource?q=ada");
   Fields.Fields (4) := Make_Field (":authority", "example.com");
   Fields.Fields (5) := Make_Field ("te", "trailers");
   Result := Validate_Request (Fields);
   pragma Assert (Result.Status = Valid and then not Result.Is_Connect);

   Fields.Count := 2;
   Fields.Fields (1) := Make_Field (":method", "CONNECT");
   Fields.Fields (2) := Make_Field (":authority", "example.com:443");
   Result := Validate_Request (Fields);
   pragma Assert (Result.Status = Valid and then Result.Is_Connect);

   Fields.Count := 3;
   Fields.Fields (1) := Make_Field (":method", "CONNECT");
   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":authority", "example.com:443");
   pragma Assert (Validate_Request (Fields).Status = Invalid_Connect);

   Fields.Count := 3;
   Fields.Fields (1) := Make_Field (":method", "CONNECT");
   Fields.Fields (2) := Make_Field (":authority", "example.com:443");
   Fields.Fields (3) := Make_Field ("host", "other.example:443");
   pragma Assert (Validate_Request (Fields).Status = Authority_Mismatch);

   Fields.Count := 5;
   Fields.Fields (1) := Make_Field (":method", "GET");
   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":path", "/");
   Fields.Fields (4) := Make_Field ("accept", "*/*");
   Fields.Fields (5) := Make_Field (":authority", "example.com");
   pragma Assert (Validate_Request (Fields).Status = Pseudo_After_Regular);

   Fields.Count := 5;
   Fields.Fields (1) := Make_Field (":method", "GET");
   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":path", "/");
   Fields.Fields (4) := Make_Field (":authority", "example.com");
   Fields.Fields (5) := Make_Field ("host", "other.example");
   pragma Assert (Validate_Request (Fields).Status = Authority_Mismatch);

   Fields.Count := 4;
   Fields.Fields (1) := Make_Field (":method", "GET space");
   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":path", "/");
   Fields.Fields (4) := Make_Field (":authority", "example.com");
   pragma Assert (Validate_Request (Fields).Status = Invalid_Method);

   Fields.Fields (1) := Make_Field (":method", "GET");
   Fields.Fields (2) := Make_Field (":scheme", "1https");
   pragma Assert (Validate_Request (Fields).Status = Invalid_Scheme);

   Fields.Fields (2) := Make_Field (":scheme", "https");
   Fields.Fields (3) := Make_Field (":path", "relative");
   pragma Assert (Validate_Request (Fields).Status = Invalid_Path);

   Fields.Count := 2;
   Fields.Fields (1) := Make_Field (":status", "103");
   Fields.Fields (2) := Make_Field ("link", "</style.css>; rel=preload");
   Result := Validate_Response (Fields);
   pragma Assert
     (Result.Status = Valid and then Result.Response_Code = 103
      and then Result.Is_Interim);

   Fields.Count := 2;
   Fields.Fields (1) := Make_Field (":status", "200");
   Fields.Fields (2) := Make_Field ("content-type", "text/plain");
   Result := Validate_Response (Fields);
   pragma Assert
     (Result.Status = Valid and then Result.Response_Code = 200
      and then not Result.Is_Interim);

   Fields.Count := 1;
   Fields.Fields (1) := Make_Field (":status", "101");
   pragma Assert (Validate_Response (Fields).Status = Invalid_Status);

   Fields.Count := 1;
   Fields.Fields (1) := Make_Field ("Connection", "close");
   pragma Assert (Validate_Response (Fields).Status = Invalid_Name);

   Fields.Count := 1;
   Fields.Fields (1) := Make_Field ("connection", "close");
   pragma Assert (Validate_Trailers (Fields).Status = Prohibited_Field);

   Fields.Count := 1;
   Fields.Fields (1) := Make_Field (":status", "200");
   pragma Assert (Validate_Trailers (Fields).Status = Pseudo_In_Trailers);
end Flyology.HTTP.HTTP_3_Header_Policy.Smoke;
