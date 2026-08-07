procedure Flyology.QUIC.Transport_Parameter_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Varint_Policy.Value_Type;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element :=
           Ada.Streams.Stream_Element
             (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   procedure Check_Status
     (Wire     : Ada.Streams.Stream_Element_Array;
      Role     : Endpoint_Role;
      Expected : Decode_Status)
   is
      Result : constant Decode_Result := Decode (Wire, Role);
   begin
      pragma Assert
        (Result.Status = Expected,
         "length" & Natural'Image (Natural (Wire'Length)) & ": expected "
         & Expected'Image & ", got " & Result.Status'Image);
         --  Keep failures attributable when several compact negative vectors
         --  share this helper.
   end Check_Status;

   RFC_Client_Parameters : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("0408ffffffffffffffff" &
        "05048000ffff" &
        "07048000ffff" &
        "080110" &
        "010480007530" &
        "090110" &
        "0f088394c8f03e515708" &
        "06048000ffff");
begin
   --  The transport-parameter extension from the RFC 9001 Appendix A.2
   --  ClientHello exercises non-minimal QUIC integer encodings.
   declare
      Result : constant Decode_Result :=
        Decode (RFC_Client_Parameters, Client);
   begin
      pragma Assert (Result.Status = Decoded and then Result.Count = 8);
      pragma Assert
        (Result.Parameters.Initial_Max_Data.Present
         and then Result.Parameters.Initial_Max_Data.Value = 2**62 - 1);
      pragma Assert
        (Result.Parameters.Initial_Max_Stream_Data_Bidi_Local.Value = 65_535);
      pragma Assert
        (Result.Parameters.Initial_Max_Stream_Data_Bidi_Remote.Value = 65_535);
      pragma Assert
        (Result.Parameters.Initial_Max_Stream_Data_Uni.Value = 65_535);
      pragma Assert
        (Result.Parameters.Initial_Max_Streams_Bidi.Value = 16
         and then Result.Parameters.Initial_Max_Streams_Uni.Value = 16);
      pragma Assert (Result.Parameters.Max_Idle_Timeout.Value = 30_000);
      pragma Assert
        (Result.Parameters.Initial_Source_Connection_ID.Present
         and then Result.Parameters.Initial_Source_Connection_ID.Length = 8
         and then
           Result.Parameters.Initial_Source_Connection_ID.Data (1 .. 8) =
             Hex ("8394c8f03e515708"));
      pragma Assert
        (not Result.Parameters.Max_UDP_Payload_Size.Present
         and then Result.Parameters.Max_UDP_Payload_Size.Value = 65_527
         and then not Result.Parameters.ACK_Delay_Exponent.Present
         and then Result.Parameters.ACK_Delay_Exponent.Value = 3
         and then not Result.Parameters.Max_ACK_Delay.Present
         and then Result.Parameters.Max_ACK_Delay.Value = 25
         and then not Result.Parameters.Active_Connection_ID_Limit.Present
         and then Result.Parameters.Active_Connection_ID_Limit.Value = 2);
   end;

   declare
      Parameters : Transport_Parameters;
      Wire       : Encode_Result;
      Parsed     : Decode_Result;
   begin
      Parameters.Initial_Source_Connection_ID :=
        (Present => True,
         Data => (1 => 16#83#, 2 => 16#94#, 3 => 16#C8#, 4 => 16#F0#,
                  5 => 16#3E#, 6 => 16#51#, 7 => 16#57#, 8 => 16#08#,
                  others => 0),
         Length => 8);
      Parameters.Initial_Max_Data := (True, 1_000_000);
      Parameters.Initial_Max_Streams_Bidi := (True, 100);
      Parameters.Max_UDP_Payload_Size := (True, 1_200);
      Parameters.Disable_Active_Migration := True;

      Wire := Encode (Parameters, Client);
      pragma Assert (Wire.Status = Encoded and then Wire.Length > 0);
      Parsed :=
        Decode
          (Wire.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)),
           Client);
      pragma Assert (Parsed.Status = Decoded and then Parsed.Count = 5);
      pragma Assert
        (Parsed.Parameters.Initial_Max_Data.Value = 1_000_000
         and then Parsed.Parameters.Initial_Max_Streams_Bidi.Value = 100
         and then Parsed.Parameters.Max_UDP_Payload_Size.Value = 1_200
         and then Parsed.Parameters.Disable_Active_Migration
         and then
           Parsed.Parameters.Initial_Source_Connection_ID.Data (1 .. 8) =
             Parameters.Initial_Source_Connection_ID.Data (1 .. 8));
   end;

   declare
      Parameters : Transport_Parameters;
      Wire       : Encode_Result;
      Parsed     : Decode_Result;
   begin
      Parameters.Original_Destination_Connection_ID :=
        (Present => True,
         Data => (1 => 16#44#, 2 => 16#55#, others => 0),
         Length => 2);
      Parameters.Initial_Source_Connection_ID :=
        (Present => True,
         Data => (1 => 16#AA#, 2 => 16#BB#, others => 0),
         Length => 2);
      Parameters.Stateless_Reset_Token :=
        (Present => True, Data => (others => 16#5A#));
      Parameters.Active_Connection_ID_Limit := (True, 4);

      Wire := Encode (Parameters, Server);
      pragma Assert (Wire.Status = Encoded);
      Parsed :=
        Decode
          (Wire.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)),
           Server);
      pragma Assert
        (Parsed.Status = Decoded
         and then Parsed.Parameters.Original_Destination_Connection_ID.Present
         and then Parsed.Parameters.Stateless_Reset_Token.Present
         and then Parsed.Parameters.Stateless_Reset_Token.Data =
           Parameters.Stateless_Reset_Token.Data
         and then Parsed.Parameters.Active_Connection_ID_Limit.Value = 4);
   end;

   Check_Status (Hex ("0f"), Client, Truncated);
   Check_Status (Hex ("0f02aa"), Client, Truncated);
   Check_Status (Hex ("0f01000f0100"), Client, Duplicate_Parameter);
   Check_Status (Hex ("0000"), Client, Forbidden_Parameter);
   Check_Status (Hex ("0200"), Client, Forbidden_Parameter);
   Check_Status (Hex ("0d00"), Client, Forbidden_Parameter);
   Check_Status (Hex ("1000"), Client, Forbidden_Parameter);
   Check_Status (Hex ("0301440f00"), Client, Invalid_Parameter_Value);
   Check_Status (Hex ("0808d0000000000000010f00"), Client,
                 Invalid_Parameter_Value);
   Check_Status (Hex ("0a01150f00"), Client, Invalid_Parameter_Value);
   Check_Status (Hex ("0b04800040000f00"), Client,
                 Invalid_Parameter_Value);
   Check_Status (Hex ("0e01010f00"), Client, Invalid_Parameter_Value);
   Check_Status (Hex ("0c01000f00"), Client, Invalid_Parameter_Value);
   Check_Status (Hex ("2101000f00"), Client, Decoded);
   Check_Status (Hex ("210021000f00"), Client, Duplicate_Parameter);
   Check_Status (Hex ("010100"), Client, Missing_Mandatory_Parameter);
   Check_Status (Hex ("0f00"), Server, Missing_Mandatory_Parameter);
   Check_Status (Hex ("00000f00"), Server, Decoded);

   --  preferred_address has 24 address/port bytes, one CID-length byte,
   --  a CID, and a 16-byte reset token.
   declare
      Preferred : Ada.Streams.Stream_Element_Array (1 .. 49) := (others => 0);
   begin
      Preferred (1) := 16#0D#;
      Preferred (2) := 43;
      Preferred (27) := 2;
      Preferred (46) := 0;
      Preferred (47) := 0;
      Preferred (48) := 16#0F#;
      Preferred (49) := 0;
      Check_Status (Preferred, Server, Decoded);
      Preferred (27) := 3;
      Check_Status (Preferred, Server, Invalid_Parameter_Value);
   end;

   declare
      Parameters : Transport_Parameters;
   begin
      pragma Assert (Encode (Parameters, Client).Status = Invalid_Parameters);
      Parameters.Initial_Source_Connection_ID.Present := True;
      Parameters.Max_UDP_Payload_Size := (True, 1_199);
      pragma Assert (Encode (Parameters, Client).Status = Invalid_Parameters);
      Parameters.Max_UDP_Payload_Size := (True, 1_200);
      Parameters.Original_Destination_Connection_ID.Present := True;
      pragma Assert (Encode (Parameters, Client).Status = Invalid_Parameters);
   end;

   declare
      Wire     : Ada.Streams.Stream_Element_Array (1 .. 1_024) := (others => 0);
      Last     : Natural range 0 .. 1_024 := 0;
      Encoded  : Varint_Policy.Encoded_Value;
   begin
      for Identifier in Varint_Policy.Value_Type range 32 .. 288 loop
         Encoded := Varint_Policy.Encode (Identifier);
         for Index in Positive range 1 .. Encoded.Length loop
            Last := Last + 1;
            Wire (Ada.Streams.Stream_Element_Offset (Last)) :=
              Encoded.Data (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         Last := Last + 1;
         Wire (Ada.Streams.Stream_Element_Offset (Last)) := 0;
      end loop;
      Check_Status
        (Wire (1 .. Ada.Streams.Stream_Element_Offset (Last)),
         Client,
         Too_Many_Parameters);
   end;
end Flyology.QUIC.Transport_Parameter_Policy.Smoke;
