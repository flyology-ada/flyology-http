package body Flyology.HTTP.Fixed_Response_Policy
  with SPARK_Mode => On
is
   procedure Start
     (Item       : out Tracker;
      Length     : Body_Size;
      Suppressed : Boolean)
   is
   begin
      Item :=
        (State      => Active,
         Length     => Length,
         Count      => 0,
         Suppressed => Suppressed);
   end Start;

   procedure Reset (Item : out Tracker) is
   begin
      Item := (others => <>);
   end Reset;

   procedure Write
     (Item   : in out Tracker;
      Count  : Body_Size;
      Result : out Write_Result)
   is
   begin
      if Item.State /= Active then
         Result := Inactive;
      elsif Item.Suppressed or else Count = 0 then
         Result := Accepted;
      elsif Count > Item.Length - Item.Count then
         Item.State := Failed;
         Result := Overrun;
      else
         Item.Count := Item.Count + Count;
         Result := Accepted;
      end if;
   end Write;

   procedure Finish
     (Item   : in out Tracker;
      Result : out Finish_Result)
   is
   begin
      if Item.State /= Active then
         Result := Finish_Inactive;
      elsif Item.Suppressed or else Item.Count = Item.Length then
         Item.State := Idle;
         Result := Complete;
      else
         Item.State := Failed;
         Result := Underrun;
      end if;
   end Finish;

   function Is_Active (Item : Tracker) return Boolean is
     (Item.State = Active);

   function Expected (Item : Tracker) return Body_Size is (Item.Length);

   function Written (Item : Tracker) return Body_Size is (Item.Count);
end Flyology.HTTP.Fixed_Response_Policy;
