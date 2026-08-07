with Flyology.QUIC.Packet_Number_Policy;

--  Internal, proved packet-number state shared by QUIC encryption levels.
--
--  The receive window retains the newest 256 authenticated packet numbers.
--  Older numbers are rejected before they can affect ACK or frame state.
private package Flyology.QUIC.Connection_State_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Packet_Number_Policy.Packet_Number;

   subtype Packet_Number is Packet_Number_Policy.Packet_Number;
   Receive_Window : constant := 256;

   type Receive_Disposition is
     (New_Packet,
      Duplicate_Packet,
      Packet_Too_Old);

   type Connection_State is private;

   procedure Reset (Item : out Connection_State)
   with
     Global => null,
     Post =>
       not Has_Received (Item)
       and then Expected_Number (Item) = 0
       and then Can_Send (Item)
       and then Next_To_Send (Item) = 0;

   function Has_Received (Item : Connection_State) return Boolean
   with Global => null;

   function Largest_Received
     (Item : Connection_State) return Packet_Number
   with
     Global => null,
     Pre => Has_Received (Item);

   function Expected_Number
     (Item : Connection_State) return Packet_Number
   with
     Global => null,
     Post =>
       (if not Has_Received (Item) then Expected_Number'Result = 0
        elsif Largest_Received (Item) < Packet_Number'Last then
           Expected_Number'Result = Largest_Received (Item) + 1
        else Expected_Number'Result = Packet_Number'Last);

   function Was_Received
     (Item : Connection_State;
      Number : Packet_Number) return Boolean
   with
     Global => null,
     Post => not Was_Received'Result or else Has_Received (Item);

   procedure Record_Received
     (Item        : in out Connection_State;
      Number      : Packet_Number;
      Disposition : out Receive_Disposition)
   with
     Global => null,
     Post =>
       (if Disposition = New_Packet then
           Has_Received (Item)
           and then Was_Received (Item, Number)
           and then Largest_Received (Item) >= Number
        else Item = Item'Old);

   function Can_Send (Item : Connection_State) return Boolean
   with Global => null;

   function Next_To_Send
     (Item : Connection_State) return Packet_Number
   with
     Global => null,
     Pre => Can_Send (Item);

   procedure Commit_Sent (Item : in out Connection_State)
   with
     Global => null,
     Pre => Can_Send (Item),
     Post =>
       (if Next_To_Send (Item'Old) < Packet_Number'Last then
           Can_Send (Item)
           and then Next_To_Send (Item) = Next_To_Send (Item'Old) + 1
        else not Can_Send (Item));
private
   subtype Window_Index is Natural range 0 .. Receive_Window - 1;

   type Received_Entry is record
      Valid  : Boolean := False;
      Number : Packet_Number := 0;
   end record;

   type Received_Table is array (Window_Index) of Received_Entry;

   type Connection_State is record
      Received       : Received_Table := (others => (others => <>));
      Has_Largest    : Boolean := False;
      Largest        : Packet_Number := 0;
      Next_Send      : Packet_Number := 0;
      Send_Exhausted : Boolean := False;
   end record;
end Flyology.QUIC.Connection_State_Policy;
