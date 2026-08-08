package body Flyology.QUIC.Stream_ID_Policy
  with SPARK_Mode => On
is
   function Initiator (ID : Stream_ID) return Stream_Initiator is
     (if ID mod 2 = 0 then Client_Initiated else Server_Initiated);

   function Direction (ID : Stream_ID) return Stream_Direction is
     (if ID mod 4 < 2 then Bidirectional else Unidirectional);

   function Ordinal (ID : Stream_ID) return Stream_Count is
     (Stream_Count (ID / 4) + 1);

   function Is_Local (Role : Endpoint_Role; ID : Stream_ID) return Boolean is
     ((Role = Client and then Initiator (ID) = Client_Initiated)
      or else (Role = Server and then Initiator (ID) = Server_Initiated));

   function Can_Send (Role : Endpoint_Role; ID : Stream_ID) return Boolean is
     (Direction (ID) = Bidirectional or else Is_Local (Role, ID));

   function Can_Receive (Role : Endpoint_Role; ID : Stream_ID) return Boolean is
     (Direction (ID) = Bidirectional or else not Is_Local (Role, ID));

   function Local_Role (Item : Allocator) return Endpoint_Role is
     (Item.Role);

   function Opened_Count
     (Item      : Allocator;
      Direction : Stream_Direction) return Stream_Count
   is
     (if Direction = Bidirectional then Item.Next_Bidi else Item.Next_Uni);

   procedure Reset (Item : out Allocator; Role : Endpoint_Role) is
   begin
      Item := (Role => Role, Next_Bidi => 0, Next_Uni => 0);
   end Reset;

   procedure Open_Local
     (Item       : in out Allocator;
      Direction  : Stream_Direction;
      Peer_Limit : Varint_Policy.Value_Type;
      ID         : out Stream_ID;
      Status     : out Open_Status)
   is
      Count : constant Stream_Count := Opened_Count (Item, Direction);
      Base  : Stream_ID;
   begin
      ID := 0;
      if Peer_Limit > Varint_Policy.Value_Type (Stream_Count'Last) then
         Status := Invalid_Stream_Limit;
         return;
      elsif Count >= Stream_Count (Peer_Limit) then
         Status := Stream_Limit_Reached;
         return;
      end if;

      Base :=
        (case Direction is
            when Bidirectional =>
              (if Item.Role = Client then 0 else 1),
            when Unidirectional =>
              (if Item.Role = Client then 2 else 3));
      pragma Assert (Count < Stream_Count'Last);
      pragma Assert (Count * 4 <= Stream_Count'Last * 4 - 4);
      ID := Stream_ID (Count * 4) + Base;
      case Direction is
         when Bidirectional =>
            Item.Next_Bidi := Item.Next_Bidi + 1;
         when Unidirectional =>
            Item.Next_Uni := Item.Next_Uni + 1;
      end case;
      Status := Opened;
   end Open_Local;
end Flyology.QUIC.Stream_ID_Policy;
