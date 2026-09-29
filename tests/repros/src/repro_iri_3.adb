--  IRI-3: the IDNA host conversion applies neither UTS #46's NFC
--  normalization step nor its "must not begin with a combining mark"
--  validity criterion, and the crate's disclosure names neither.
--
--  Asserts the CORRECT behaviour:
--    UTS #46 section 4 "Processing" step 2: "Normalize the domain_name
--    string to Unicode Normalization Form C."
--    UTS #46 section 4.1 "Validity Criteria" 6: "The label must not begin
--    with a combining mark, that is: General_Category=Mark."

with Ada.Exceptions;
with Flyology_IRI;
with Repro_Support;

procedure Repro_IRI_3 is
   use Flyology_IRI;
   use Repro_Support;

   function Byte (Value : Natural) return String is
     ([1 => Character'Val (Value)]);

   --  UTF-8 for the code points used below.
   Combining_Diaeresis : constant String :=            --  U+0308
     Byte (16#CC#) & Byte (16#88#);
   Combining_Acute     : constant String :=            --  U+0301
     Byte (16#CC#) & Byte (16#81#);
   Combining_Grave     : constant String :=            --  U+0300
     Byte (16#CC#) & Byte (16#80#);
   Combining_Solidus   : constant String :=            --  U+0338
     Byte (16#CC#) & Byte (16#B8#);
   U_Diaeresis         : constant String :=            --  U+00FC
     Byte (16#C3#) & Byte (16#BC#);
   O_Grave             : constant String :=            --  U+00F2
     Byte (16#C3#) & Byte (16#B2#);

   function Host_Of (Input : String) return String is
     (if Can_Parse (Input, Web_URL_Syntax)
      then Host (Parse (Input, Web_URL_Syntax)) else "<rejected>");

   procedure Same_Host (Decomposed, Precomposed, Description : String) is
   begin
      Expect_Equal (Host_Of (Decomposed), Host_Of (Precomposed), Description);
   end Same_Host;

   procedure Must_Reject (Input, Description : String) is
   begin
      if Can_Parse (Input, Web_URL_Syntax) then
         Check (False, Description & " accepted with host ["
                & Host (Parse (Input, Web_URL_Syntax)) & "]");
      else
         Check (True, Description & " rejected");
      end if;
   end Must_Reject;

begin
   Note ("UTS #46 step 2: the NFD and NFC spellings of one host must give"
         & " one ASCII host");
   Same_Host ("http://bu" & Combining_Diaeresis & "cher.de/",
              "http://b" & U_Diaeresis & "cher.de/",
              "bucher.de decomposed versus precomposed");
   Same_Host ("http://foo" & Combining_Grave & ".bar.com/",
              "http://fo" & O_Grave & ".bar.com/",
              "fo-grave.bar.com decomposed versus precomposed");
   Note ("  decomposed gives [" & Host_Of ("http://bu" & Combining_Diaeresis
         & "cher.de/") & "], precomposed gives ["
         & Host_Of ("http://b" & U_Diaeresis & "cher.de/") & "]");

   Note ("UTS #46 criterion 6: a label must not begin with a combining mark");
   Must_Reject ("http://" & Combining_Diaeresis & "a.com/",
                "leading U+0308 in the first label");
   Must_Reject ("http://a." & Combining_Diaeresis & "b.com/",
                "leading U+0308 in an interior label");
   Must_Reject ("http://" & Combining_Acute & "x.com/",
                "leading U+0301 in the first label");

   Note ("NFC must run before the forbidden-code-point scan: '=' U+0338"
         & " composes to U+2260");
   Expect_Equal (Host_Of ("http://=" & Combining_Solidus & ".com/"),
                 "xn--1ch.com",
                 "'=' + U+0338 must normalize to U+2260 before validation");

   Note ("controls: the precomposed spellings the crate's own tests pin"
         & " still work");
   Expect_Equal (Host_Of ("http://b" & U_Diaeresis & "cher.de/"),
                 "xn--bcher-kva.de", "precomposed bucher.de");

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: "
            & Ada.Exceptions.Exception_Information (E));
      Check (False, "spike raised");
      Finish;
end Repro_IRI_3;
