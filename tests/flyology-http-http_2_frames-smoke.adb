with Ada.Streams;
with Interfaces;

procedure Flyology.HTTP.HTTP_2_Frames.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   procedure Round_Trip (Value : Header) is
   begin
      pragma Assert (Decode (Encode (Value)) = Value);
   end Round_Trip;

begin
   Round_Trip
     ((Length => 0, Kind => Settings_Frame, Flags => 0, Stream_ID => 0));
   Round_Trip
     ((Length => Largest_Frame_Size,
       Kind => Frame_Code'Last,
       Flags => Frame_Flags'Last,
       Stream_ID => Stream_Identifier'Last));

   declare
      Reserved : Wire_Header := Encode
        ((Length => 8, Kind => Ping_Frame, Flags => Ack_Flag, Stream_ID => 0));
   begin
      Reserved (6) := Reserved (6) or 16#80#;
      pragma Assert (Decode (Reserved).Stream_ID = 0);
      pragma Assert ((Encode (Decode (Reserved)) (6) and 16#80#) = 0);
   end;

   pragma Assert
     (Validate
        ((Length => 0, Kind => Settings_Frame, Flags => 0, Stream_ID => 0)) =
      Valid_Header);
   pragma Assert
     (Validate
        ((Length => 6, Kind => Settings_Frame, Flags => 0, Stream_ID => 0)) =
      Valid_Header);
   pragma Assert
     (Validate
        ((Length => 6, Kind => Settings_Frame, Flags => Ack_Flag,
          Stream_ID => 0)) = Invalid_Length);
   pragma Assert
     (Validate
        ((Length => 8, Kind => Ping_Frame, Flags => 0, Stream_ID => 1)) =
      Invalid_Stream);
   pragma Assert
     (Validate
        ((Length => 4, Kind => Window_Update_Frame, Flags => 0,
          Stream_ID => 0)) = Valid_Header);
   pragma Assert
     (Validate
        ((Length => Default_Maximum_Frame_Size + 1,
          Kind => Data_Frame, Flags => 0, Stream_ID => 1)) =
      Frame_Too_Large);
   pragma Assert
     (Validate
        ((Length => 1, Kind => Frame_Code'Last, Flags => Frame_Flags'Last,
          Stream_ID => 0)) = Valid_Header);
end Flyology.HTTP.HTTP_2_Frames.Smoke;
