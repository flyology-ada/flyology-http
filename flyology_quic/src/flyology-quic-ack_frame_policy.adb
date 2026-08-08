package body Flyology.QUIC.ACK_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Packet_Number;

   subtype Range_Count is ACK_Range_Policy.Range_Count;
   subtype Range_Index is ACK_Range_Policy.Range_Index;
   subtype Packet_Number is Connection_State_Policy.Packet_Number;

   type Range_Array is array (Range_Index) of ACK_Range_Policy.ACK_Range;

   function Encode
     (Item      : Connection_State_Policy.Connection_State;
      ACK_Delay : Varint_Policy.Value_Type) return Encode_Result
   is
      Result   : Encode_Result;
      Ranges   : Range_Array := (others => (others => <>));
      Count    : Range_Count := 1;
      Largest  : Packet_Number;
      Oldest   : Packet_Number;
      Number   : Packet_Number;
      Candidate : Packet_Number;
      Position : Frame_Length := 0;
      Gap      : Varint_Policy.Value_Type;

      procedure Append (Value : Varint_Policy.Value_Type)
      with
        Pre =>
          Position <= Max_Frame_Length
          and then Varint_Policy.Required_Length (Value) <=
            Max_Frame_Length - Position,
        Post =>
          Position = Position'Old + Varint_Policy.Required_Length (Value);

      procedure Append (Value : Varint_Policy.Value_Type) is
         Encoded_Value : constant Varint_Policy.Encoded_Value :=
           Varint_Policy.Encode (Value);
      begin
         for Index in 1 .. Encoded_Value.Length loop
            pragma Loop_Invariant (Position <= Max_Frame_Length);
            pragma Loop_Invariant
              (Index <= Max_Frame_Length - Position);
            Result.Data
              (Ada.Streams.Stream_Element_Offset (Position + Index)) :=
              Encoded_Value.Data (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         Position := Position + Encoded_Value.Length;
      end Append;
   begin
      if not Connection_State_Policy.Has_Received (Item) then
         return Result;
      end if;

      Largest := Connection_State_Policy.Largest_Received (Item);
      Oldest :=
        (if Largest >= Connection_State_Policy.Receive_Window - 1 then
            Largest - (Connection_State_Policy.Receive_Window - 1)
         else 0);
      Ranges (1) := (Smallest => Largest, Largest => Largest);
      Number := Largest;

      while Number > Oldest loop
         pragma Loop_Invariant (Count >= 1);
         pragma Loop_Invariant (Number >= Oldest);
         pragma Loop_Invariant
           (Ranges (Count).Smallest <= Ranges (Count).Largest);
         pragma Loop_Invariant (Number <= Ranges (Count).Smallest);
         pragma Loop_Invariant
           (for all Index in 1 .. Count =>
              Ranges (Index).Smallest <= Ranges (Index).Largest);
         pragma Loop_Invariant
           (for all Index in 2 .. Count =>
              Ranges (Index - 1).Smallest >= Ranges (Index).Largest + 2);
         pragma Loop_Variant (Decreases => Number - Oldest);
         Candidate := Number - 1;
         if Connection_State_Policy.Was_Received (Item, Candidate) then
            if Ranges (Count).Smallest > 0
              and then Candidate = Ranges (Count).Smallest - 1
            then
               Ranges (Count).Smallest := Candidate;
            elsif Count = ACK_Range_Policy.Max_Ranges then
               exit;
            else
               Count := Count + 1;
               Ranges (Count) :=
                 (Smallest => Candidate, Largest => Candidate);
            end if;
         end if;
         Number := Candidate;
      end loop;

      Append (16#02#);
      pragma Assert (Position >= 1);
      Append (Ranges (1).Largest);
      pragma Assert (Position >= 2);
      Append (ACK_Delay);
      pragma Assert (Position >= 3);
      Append (Varint_Policy.Value_Type (Count - 1));
      pragma Assert (Position >= 4);
      pragma Assert (Ranges (1).Largest - Ranges (1).Smallest <=
        Varint_Policy.Value_Type'Last);
      Append
        (Varint_Policy.Value_Type
           (Ranges (1).Largest - Ranges (1).Smallest));
      pragma Assert (Position >= 5);
      pragma Assert (Position <= 40);
      if Count > 1 then
         for Index in 2 .. Count loop
            pragma Loop_Invariant
              (Position <= 40 + Natural (Index - 2) * 16);
            pragma Loop_Invariant (Position >= 5);
            pragma Assert (Position <= Max_Frame_Length - 16);
            if Ranges (Index - 1).Smallest >= 2
              and then Ranges (Index).Largest <=
                Ranges (Index - 1).Smallest - 2
            then
               Gap :=
                 Ranges (Index - 1).Smallest
                 - Ranges (Index).Largest - 2;
            else
               Gap := 0;
            end if;
            Append (Gap);
            pragma Assert (Position <= Max_Frame_Length - 8);
            pragma Assert
              (Ranges (Index).Largest - Ranges (Index).Smallest <=
                 Varint_Policy.Value_Type'Last);
            Append
              (Varint_Policy.Value_Type
                 (Ranges (Index).Largest - Ranges (Index).Smallest));
         end loop;
      end if;
      pragma Assert (Position >= 5);
      Result.Length := Position;
      Result.Status := Encoded;
      return Result;
   end Encode;
end Flyology.QUIC.ACK_Frame_Policy;
