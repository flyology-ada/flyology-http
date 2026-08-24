with Ada.Streams;
with Flyology.Bytes;
with Flyology.IO;

procedure Flyology.HTTP.HTTP_2_Client_Connection.Smoke is
   use type Flyology.IO.Descriptor;

   Header : constant Ada.Streams.Stream_Element_Array (1 .. 1) := (1 => 0);
   Item   : Session_Access;
   First, Second, Third, Fourth : Stream_Handle;
   Accepted : Boolean;
   Claimed  : Boolean;
   Ready    : Boolean;
   FD       : Flyology.IO.Descriptor;

   procedure Open_Stream (Handle : out Stream_Handle) is
   begin
      Open
        (Item.all, Header, Flyology.Bytes.Empty,
         Streaming => False, Head_Request => False,
         Handle => Handle, Accepted => Accepted);
      pragma Assert (Accepted);
   end Open_Stream;
begin
   Create (Item);
   Open_Stream (First);
   Open_Stream (Second);
   Open_Stream (Third);
   Open_Stream (Fourth);

   Try_Claim_Pump (Item.all, First, Claimed);
   pragma Assert (Claimed and then Owns_Pump (Item.all, First));
   Try_Claim_Pump (Item.all, Second, Claimed);
   pragma Assert (not Claimed);
   Try_Claim_Pump (Item.all, Third, Claimed);
   pragma Assert (not Claimed);

   Release_Pump (Item.all, First);
   pragma Assert (Owns_Pump (Item.all, Second));
   Pump_Wait_Source (Item.all, Second, FD, Ready);
   pragma Assert (Ready and then FD = Flyology.IO.Invalid_Descriptor);

   --  A newcomer cannot cut ahead of the already-waiting third stream.
   Try_Claim_Pump (Item.all, Fourth, Claimed);
   pragma Assert (not Claimed);
   Release_Pump (Item.all, Second);
   pragma Assert (Owns_Pump (Item.all, Third));
   Release_Pump (Item.all, Third);
   pragma Assert (Owns_Pump (Item.all, Fourth));
   Release_Pump (Item.all, Fourth);

   Release_Stream (Item.all, First);
   Release_Stream (Item.all, Second);
   Release_Stream (Item.all, Third);
   Release_Stream (Item.all, Fourth);
   Destroy (Item);
end Flyology.HTTP.HTTP_2_Client_Connection.Smoke;
