with Flyology.Rate_Limit_Policy;

package body Flyology.HTTP.Server.Middleware_Rate_Limits is
   use type Ada.Real_Time.Time;

   Max_Route_Length : constant := 128;
   Max_Key_Length   : constant := 64;
   Shard_Count      : constant Positive := Positive'Min (16, Capacity);
   Shard_Capacity   : constant Positive := Capacity / Shard_Count;

   type Hash_Value is mod 2 ** 32;
   Hash_Seed : constant Hash_Value := 2_166_136_261;

   --  FNV-1a over Value, continued from Seed. One pass over the route name
   --  and then the client key yields both the shard index and, when either
   --  exceeds the prefix a bucket can store, the digest that keeps the
   --  bucket's identity total instead of denying the route outright.
   function Hashed (Seed : Hash_Value; Value : String) return Hash_Value;

   function Hashed (Seed : Hash_Value; Value : String) return Hash_Value is
      Result : Hash_Value := Seed;
   begin
      for Item of Value loop
         Result :=
           (Result xor Hash_Value (Character'Pos (Item))) * 16_777_619;
      end loop;
      return Result;
   end Hashed;

   type Bucket_Entry is record
      Used         : Boolean := False;
      Digest       : Hash_Value := 0;
      Route        : String (1 .. Max_Route_Length) := (others => ' ');
      Route_Length : Natural := 0;
      Key          : String (1 .. Max_Key_Length) := (others => ' ');
      Key_Length   : Natural := 0;
      Tokens       : Duration := 0.0;
      Seen         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;
   type Entry_Array is array (Positive range <>) of Bucket_Entry;

   protected type Limiter_Bucket is
      procedure Admit
        (Route   : String;
         Key     : String;
         Digest  : Hash_Value;
         Rate    : Positive;
         Now     : Ada.Real_Time.Time;
         Allowed : out Boolean);
   private
      Values : Entry_Array (1 .. Shard_Capacity);
   end Limiter_Bucket;

   protected body Limiter_Bucket is
      procedure Admit
        (Route   : String;
         Key     : String;
         Digest  : Hash_Value;
         Rate    : Positive;
         Now     : Ada.Real_Time.Time;
         Allowed : out Boolean)
      is
         Route_Head : constant Natural :=
           Natural'Min (Route'Length, Max_Route_Length);
         Key_Head   : constant Natural :=
           Natural'Min (Key'Length, Max_Key_Length);
         Route_Text : String renames
           Route (Route'First .. Route'First + Route_Head - 1);
         Key_Text   : String renames
           Key (Key'First .. Key'First + Key_Head - 1);
         Slot   : Natural := 0;
         Empty  : Natural := 0;
         Oldest : Positive := Values'First;
      begin
         Allowed := False;
         for Index in Values'Range loop
            if Values (Index).Used
              and then Values (Index).Route_Length = Route'Length
              and then Values (Index).Key_Length = Key'Length
              and then Values (Index).Route (1 .. Route_Head) = Route_Text
              and then Values (Index).Key (1 .. Key_Head) = Key_Text
              and then Values (Index).Digest = Digest
            then
               Slot := Index;
               exit;
            elsif not Values (Index).Used and then Empty = 0 then
               Empty := Index;
            elsif Values (Index).Used
              and then Values (Index).Seen < Values (Oldest).Seen
            then
               Oldest := Index;
            end if;
         end loop;
         if Slot = 0 then
            Slot := (if Empty > 0 then Empty else Oldest);
            Values (Slot).Used := True;
            Values (Slot).Digest := Digest;
            Values (Slot).Route_Length := Route'Length;
            Values (Slot).Key_Length := Key'Length;
            Values (Slot).Route (1 .. Route_Head) := Route_Text;
            Values (Slot).Key (1 .. Key_Head) := Key_Text;
            Values (Slot).Tokens := Duration (Rate);
            Values (Slot).Seen := Now;
         else
            declare
               Elapsed : constant Duration :=
                 Ada.Real_Time.To_Duration (Now - Values (Slot).Seen);
            begin
               Values (Slot).Tokens :=
                 Flyology.Rate_Limit_Policy.Refilled_Tokens
                   (Values (Slot).Tokens, Elapsed, Rate);
               Values (Slot).Seen := Now;
            end;
         end if;
         if Values (Slot).Tokens >= 1.0 then
            Values (Slot).Tokens := Values (Slot).Tokens - 1.0;
            Allowed := True;
         end if;
      end Admit;
   end Limiter_Bucket;

   type Limiter_Array is
     array (Positive range 1 .. Shard_Count) of Limiter_Bucket;
   Limiters : Limiter_Array;

   procedure Count_Denial is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Metrics.Rate_Limit_Denial);
      end if;
   exception
      when others => null;
   end Count_Denial;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Rate    : constant Natural := X.Rate_Per_Second;
      Allowed : Boolean;
   begin
      if Rate = 0 then
         Next.Call (Context, X);
         return;
      end if;
      declare
         Route  : constant String := X.Route_Name;
         Key    : constant String := Client_Key (X);
         Full   : constant Hash_Value :=
           Hashed (Hashed (Hash_Seed, Route), Key);
         --  A route name and client key that both fit their stored prefix
         --  are already identified exactly, so they carry no digest.
         Digest : constant Hash_Value :=
           (if Route'Length > Max_Route_Length
              or else Key'Length > Max_Key_Length
            then Full else 0);
      begin
         Limiters (Natural (Full mod Hash_Value (Shard_Count)) + 1).Admit
           (Route, Key, Digest, Rate, Clock, Allowed);
      end;
      if not Allowed then
         Count_Denial;
         X.Add_Header ("Retry-After", "1");
         X.Problem (429, "rate-limit-exceeded", "Request rate is exceeded");
         return;
      end if;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Rate_Limits;
