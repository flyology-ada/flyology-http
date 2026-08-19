with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.HTTP.Decoded_Path_Policy;
with Flyology.HTTP.Route_Parameter_Policy;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.HTTP.Server.HTTP_3;
with Flyology.Atomic_Primitives;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Structured_Servers;
with Flyology.IO.TLS;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Flyology.HTTP.Server.Routing is

   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   package App renames Flyology.HTTP.Server.Applications;
   package Decoded_Path_Policy renames
     Flyology.HTTP.Decoded_Path_Policy;
   package Parameter_Policy renames
     Flyology.HTTP.Route_Parameter_Policy;
   use type App.Authentication_Mode;
   use type App.Response_State;
   use type App.Upgrade_Mode;
   use type Decoded_Path_Policy.Path_Disposition;

   package Configuration_Conversions is new
     System.Address_To_Access_Conversions (Router_Configuration);

   procedure Free_Configuration is new Ada.Unchecked_Deallocation
     (Router_Configuration, Configuration_Access);

   protected Identity_Source is
      procedure Next_Route (Value : out Route_ID);
      procedure Next_Middleware (Value : out Middleware_ID);
   private
      Route_Value      : Interfaces.Unsigned_64 := 0;
      Middleware_Value : Interfaces.Unsigned_64 := 0;
   end Identity_Source;

   protected body Identity_Source is
      procedure Next_Route (Value : out Route_ID) is
      begin
         if Route_Value = Interfaces.Unsigned_64'Last then
            raise Route_Error with "HTTP route identity space exhausted";
         end if;
         Route_Value := Route_Value + 1;
         Value := Route_ID (Route_Value);
      end Next_Route;

      procedure Next_Middleware (Value : out Middleware_ID) is
      begin
         if Middleware_Value = Interfaces.Unsigned_64'Last then
            raise Route_Error with
              "HTTP middleware identity space exhausted";
         end if;
         Middleware_Value := Middleware_Value + 1;
         Value := Middleware_ID (Middleware_Value);
      end Next_Middleware;
   end Identity_Source;

   function Address_Word (Value : System.Address) return Interfaces.Unsigned_64
   is
     (Interfaces.Unsigned_64
        (System.Storage_Elements.To_Integer (Value)));

   function Word_Address (Value : Interfaces.Unsigned_64) return System.Address
   is
     (System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (Value)));

   function To_Configuration
     (Value : System.Address) return Configuration_Access
   is
     (if Value = System.Null_Address then null
      else Configuration_Access
             (Configuration_Conversions.To_Pointer (Value)));

   function Current_Configuration
     (Item : Router) return Configuration_Access
   is
      Bits : constant Interfaces.Unsigned_64 :=
        Flyology.Atomic_Primitives.Load_Acquire_U64
          (Item.Current_Configuration'Address);
      Configuration : constant Configuration_Access :=
        To_Configuration (Word_Address (Bits));
   begin
      if Configuration = null then
         raise Program_Error with "HTTP router is not initialized";
      end if;
      return Configuration;
   end Current_Configuration;

   --  Direct registration writes the published generation in place, so it
   --  cannot overlap dispatch. The first dispatch seals the router; every
   --  later configuration change goes through Begin_Update and Commit. The
   --  load keeps the steady-state cost to one read of a shared clean line
   --  instead of a store from every worker on every request.
   procedure Seal (Item : in out Router) is
   begin
      if Flyology.Atomic_Primitives.Load_Acquire_U64
           (Item.Sealed'Address) = 0
      then
         Flyology.Atomic_Primitives.Store_Release_U64
           (Item.Sealed'Address, 1);
      end if;
   end Seal;

   procedure Check_Not_Sealed (Item : Router) is
   begin
      if Flyology.Atomic_Primitives.Load_Acquire_U64
           (Item.Sealed'Address) /= 0
      then
         raise Route_Error with
           "HTTP router is dispatching; use Begin_Update and Commit";
      end if;
   end Check_Not_Sealed;

   protected body Publication_Gate is
      procedure Initialize (Configuration : Configuration_Access) is
      begin
         Latest := Configuration;
      end Initialize;

      procedure Try_Publish
        (Expected : Configuration_Access;
         Desired  : Configuration_Access;
         Accepted : out Boolean)
      is
      begin
         Accepted := Latest = Expected;
         if Accepted then
            Latest := Desired;
         end if;
      end Try_Publish;
   end Publication_Gate;

   --  The allocator is a statement, not a declaration, so a Storage_Error
   --  from it reaches the handler below instead of bypassing it.
   overriding procedure Initialize (Item : in out Router) is
      Configuration : Configuration_Access;
   begin
      Configuration := new Router_Configuration (Item.Capacity, Item.Slashes);
      Item.First_Configuration := Configuration;
      Item.Publisher.Initialize (Configuration);
      Flyology.Atomic_Primitives.Store_Release_U64
        (Item.Current_Configuration'Address,
         Address_Word (Configuration.all'Address));
   exception
      when others =>
         Item.First_Configuration := null;
         if Configuration /= null then
            Free_Configuration (Configuration);
         end if;
         raise;
   end Initialize;

   overriding procedure Finalize (Item : in out Router) is
      Retained : Configuration_Access := Item.First_Configuration;
   begin
      Flyology.Atomic_Primitives.Store_Release_U64
        (Item.Current_Configuration'Address, 0);
      while Retained /= null loop
         declare
            Configuration : Configuration_Access := Retained;
         begin
            Retained := Configuration.Previous;
            Free_Configuration (Configuration);
         end;
      end loop;
      Item.First_Configuration := null;
   end Finalize;

   overriding procedure Finalize (Item : in out Update_State) is
   begin
      if Item.Candidate /= null then
         Free_Configuration (Item.Candidate);
      end if;
      Item.Owner := System.Null_Address;
      Item.Base := null;
   end Finalize;

   function Exception_Summary
     (Error : Ada.Exceptions.Exception_Occurrence) return String is
     (Ada.Exceptions.Exception_Name (Error) & ": " &
      Ada.Exceptions.Exception_Message (Error));

   function Hex_Value (Value : Character) return Natural is
     (if Value in '0' .. '9' then Character'Pos (Value) - Character'Pos ('0')
      elsif Value in 'a' .. 'f'
      then Character'Pos (Value) - Character'Pos ('a') + 10
      elsif Value in 'A' .. 'F'
      then Character'Pos (Value) - Character'Pos ('A') + 10
      else raise Route_Error with "invalid percent escape in HTTP path");

   function Valid_UTF8 (Value : String) return Boolean is
      Index : Natural := Value'First;

      function Byte (Offset : Natural) return Natural is
        (Character'Pos (Value (Index + Offset)));
      function Continuation (Offset : Natural) return Boolean is
        (Index + Offset <= Value'Last
         and then Byte (Offset) in 16#80# .. 16#BF#);
   begin
      while Index <= Value'Last loop
         if Byte (0) <= 16#7F# then
            Index := Index + 1;
         elsif Byte (0) in 16#C2# .. 16#DF# and then Continuation (1) then
            Index := Index + 2;
         elsif Byte (0) = 16#E0#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#A0# .. 16#BF#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) in 16#E1# .. 16#EC# | 16#EE# .. 16#EF#
           and then Continuation (1) and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#ED#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#80# .. 16#9F#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#F0#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#90# .. 16#BF#
           and then Continuation (2) and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) in 16#F1# .. 16#F3#
           and then Continuation (1)
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) = 16#F4#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#80# .. 16#8F#
           and then Continuation (2) and then Continuation (3)
         then
            Index := Index + 4;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_UTF8;

   function Has_Scheme_Prefix (Target, Prefix : String) return Boolean is
   begin
      if Target'Length < Prefix'Length then
         return False;
      end if;
      for Offset in 0 .. Prefix'Length - 1 loop
         if Ada.Characters.Handling.To_Lower (Target (Target'First + Offset))
           /= Prefix (Prefix'First + Offset)
         then
            return False;
         end if;
      end loop;
      return True;
   end Has_Scheme_Prefix;

   --  Absolute form is recognized by an anchored scheme prefix only, matching
   --  how the request-head parser and Requests.Authority classify the target.
   --  Searching the whole target for "://" would treat a query string that
   --  carries a URL as the request-target's own authority and route the path
   --  found inside it.
   function Absolute_Form_Authority (Target : String) return Natural is
     (if Has_Scheme_Prefix (Target, "http://") then Target'First + 7
      elsif Has_Scheme_Prefix (Target, "https://") then Target'First + 8
      else 0);

   function Raw_Path (Target : String) return String is
      Query : Natural := Ada.Strings.Fixed.Index (Target, "?");
      Start : Natural := Target'First;
      Authority : constant Natural := Absolute_Form_Authority (Target);
   begin
      if Target = "*" then
         return "*";
      elsif Authority /= 0 then
         Start := 0;
         for Index in Authority .. Target'Last loop
            if Target (Index) = '/' then
               Start := Index;
               exit;
            elsif Target (Index) = '?' then
               return "/";
            end if;
         end loop;
         if Start = 0 then
            return "/";
         end if;
         Query := Ada.Strings.Fixed.Index (Target (Start .. Target'Last), "?");
      end if;
      return
        (if Query = 0 then Target (Start .. Target'Last)
         elsif Query = Start then "/"
         else Target (Start .. Query - 1));
   end Raw_Path;

   function Raw_Query_Suffix (Target : String) return String is
      Query : constant Natural := Ada.Strings.Fixed.Index (Target, "?");
   begin
      return
        (if Query = 0 then "" else Target (Query .. Target'Last));
   end Raw_Query_Suffix;

   function Decode_Path (Value : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Value'First;
      Byte   : Natural;
      Item   : Character;
      Escaped : Boolean;
   begin
      if Value = "*" then
         return Value;
      elsif Value'Length = 0 or else Value (Value'First) /= '/' then
         raise Route_Error with "routed HTTP path is not origin-form";
      end if;
      while Index <= Value'Last loop
         Escaped := Value (Index) = '%';
         if Value (Index) = '%' then
            if Index + 2 > Value'Last then
               raise Route_Error with "truncated percent escape in HTTP path";
            end if;
            Byte := Hex_Value (Value (Index + 1)) * 16
              + Hex_Value (Value (Index + 2));
            Item := Character'Val (Byte);
            Index := Index + 3;
         else
            Item := Value (Index);
            Index := Index + 1;
         end if;
         if Item = Character'Val (0)
           or else Item = Character'Val (92)
           or else Character'Pos (Item) < 32
           or else Character'Pos (Item) = 127
         then
            raise Route_Error with "unsafe decoded byte in HTTP path";
         elsif Item = '/' and then Escaped
         then
            raise Route_Error with "encoded path separator is ambiguous";
         end if;
         Append (Result, Item);
      end loop;
      declare
         Decoded : constant String := To_String (Result);
      begin
         if Ada.Strings.Fixed.Index (Decoded, "//") /= 0 then
            raise Route_Error with "empty HTTP path segment is ambiguous";
         elsif Decoded_Path_Policy.Classify (Decoded) =
           Decoded_Path_Policy.Reject_Dot_Segment
         then
            raise Route_Error with "decoded dot segment in HTTP path";
         elsif not Valid_UTF8 (Decoded) then
            raise Route_Error with "HTTP path is not valid UTF-8";
         end if;
         return Decoded;
      end;
   end Decode_Path;

   procedure Split_Path (Value : String; Result : out Segment_List) is
      First : Natural := Value'First + 1;
      Slash : Natural;
   begin
      Result := (Values => (others => Null_Unbounded_String),
                 Count => 0, Trailing => False);
      if Value = "*" then
         Result.Count := 1;
         Result.Values (1) := To_Unbounded_String ("*");
         return;
      elsif Value = "/" then
         return;
      end if;
      Result.Trailing := Value (Value'Last) = '/';
      while First <= Value'Last loop
         Slash := Ada.Strings.Fixed.Index (Value (First .. Value'Last), "/");
         if Slash = First then
            if Slash = Value'Last then
               exit;
            end if;
            raise Route_Error with "empty HTTP path segment";
         end if;
         if Result.Count = Max_Segments then
            raise Route_Error with "too many HTTP path segments";
         end if;
         Result.Count := Result.Count + 1;
         Result.Values (Result.Count) := To_Unbounded_String
           (if Slash = 0 then Value (First .. Value'Last)
            else Value (First .. Slash - 1));
         exit when Slash = 0 or else Slash = Value'Last;
         First := Slash + 1;
      end loop;
   end Split_Path;

   function Parameter_Name (Value : String) return String is
     (if Value'Length >= 3
        and then Value (Value'First) = '{'
        and then Value (Value'Last) = '}'
      then Value (Value'First + 1 .. Value'Last - 1) else "");

   function Is_Remainder (Value : String) return Boolean is
     (Value'Length >= 4
      and then Value (Value'First .. Value'First + 1) = "{*"
      and then Value (Value'Last) = '}');

   function Remainder_Name (Value : String) return String is
     (if Is_Remainder (Value)
      then Value (Value'First + 2 .. Value'Last - 1) else "");

   function Valid_Parameter_Name (Value : String) return Boolean is
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Parameter_Name;

   procedure Validate_Method (Value : String) is
   begin
      if Value'Length = 0 then
         raise Route_Error with "empty HTTP route method";
      end if;
      for Item of Value loop
         if Item not in 'A' .. 'Z' | '0' .. '9' | '-' then
            raise Route_Error with "HTTP route method must be uppercase";
         end if;
      end loop;
   end Validate_Method;

   procedure Validate_Pattern
     (Pattern : String;
      Static_Only : Boolean := False)
   is
      Segments : Segment_List;
      Names    : array (Parameter_Policy.Parameter_Index) of
        Unbounded_String := (others => Null_Unbounded_String);
      Count    : Parameter_Policy.Parameter_Count := 0;
   begin
      if Pattern'Length = 0 or else Pattern (Pattern'First) /= '/'
        or else Ada.Strings.Fixed.Index (Pattern, "?") /= 0
        or else Ada.Strings.Fixed.Index (Pattern, "#") /= 0
        or else Ada.Strings.Fixed.Index (Pattern, "%") /= 0
        or else Ada.Strings.Fixed.Index
          (Pattern, String'(1 => Character'Val (92))) /= 0
      then
         raise Route_Error with "invalid HTTP route pattern";
      end if;
      Split_Path (Pattern, Segments);
      for Index in 1 .. Segments.Count loop
         declare
            Segment : constant String := To_String (Segments.Values (Index));
            Name    : constant String :=
              (if Is_Remainder (Segment) then Remainder_Name (Segment)
               else Parameter_Name (Segment));
         begin
            if Ada.Strings.Fixed.Index (Segment, "{") /= 0
              or else Ada.Strings.Fixed.Index (Segment, "}") /= 0
            then
               if Static_Only or else not Valid_Parameter_Name (Name) then
                  raise Route_Error with "invalid HTTP route parameter";
               elsif Is_Remainder (Segment) and then Index /= Segments.Count
               then
                  raise Route_Error with
                    "HTTP route remainder must be the final segment";
               end if;
               for Prior in 1 .. Count loop
                  if To_String (Names (Prior)) = Name then
                     raise Route_Error with "duplicate HTTP route parameter";
                  end if;
               end loop;
               declare
                  Transition : constant Parameter_Policy.Capacity_Transition :=
                    Parameter_Policy.Advance (Count);
               begin
                  if not Transition.Accepted then
                     raise Route_Error with
                       "too many HTTP route parameters";
                  end if;
                  Count := Transition.Next_Count;
                  Names (Count) := To_Unbounded_String (Name);
               end;
            end if;
         end;
      end loop;
   end Validate_Pattern;

   function Specificity (Pattern : String) return Natural is
      Segments : Segment_List;
      Result   : Natural := 0;
   begin
      Split_Path (Pattern, Segments);
      for Index in 1 .. Segments.Count loop
         declare
            Segment : constant String := To_String (Segments.Values (Index));
         begin
            Result := Result
              + (if Is_Remainder (Segment) then 1
                 elsif Parameter_Name (Segment) /= "" then 10 else 100);
         end;
      end loop;
      return Result;
   end Specificity;

   function Compatible (Left, Right : String) return Boolean is
     (Parameter_Name (Left) /= "" or else Is_Remainder (Left)
      or else Parameter_Name (Right) /= "" or else Is_Remainder (Right)
      or else Left = Right);

   function Patterns_Overlap (Left, Right : String) return Boolean is
      L, R : Segment_List;
      Common : Natural;
   begin
      Split_Path (Left, L);
      Split_Path (Right, R);
      Common := Natural'Min (L.Count, R.Count);
      for Index in 1 .. Common loop
         exit when Is_Remainder (To_String (L.Values (Index)))
           or else Is_Remainder (To_String (R.Values (Index)));
         if not Compatible
           (To_String (L.Values (Index)), To_String (R.Values (Index)))
         then
            return False;
         end if;
      end loop;
      return L.Count = R.Count
        or else
          (L.Count > 0
           and then Is_Remainder (To_String (L.Values (L.Count))))
        or else
          (R.Count > 0
           and then Is_Remainder (To_String (R.Values (R.Count))));
   end Patterns_Overlap;

   --  Mounting copies the router's routes and middleware, so a registration
   --  afterwards cannot reach the copies. Refusing it at setup keeps the
   --  ordering hazard from becoming a silently unprotected mounted route.
   procedure Check_Not_Mounted (Item : Router_Configuration) is
   begin
      if Item.Mounted then
         raise Route_Error with
           "HTTP router is already mounted; register before mounting";
      end if;
   end Check_Not_Mounted;

   procedure Check_Add
     (Item : Router_Configuration; Method, Pattern : String)
   is
   begin
      Check_Not_Mounted (Item);
      Validate_Method (Method);
      Validate_Pattern (Pattern);
      if Item.Count = Item.Capacity then
         raise Route_Error with "HTTP router capacity exhausted";
      end if;
      for Index in 1 .. Item.Count loop
         if To_String (Item.Routes (Index).Method) = Method
           and then Patterns_Overlap
             (To_String (Item.Routes (Index).Pattern), Pattern)
           and then Specificity (To_String (Item.Routes (Index).Pattern)) =
             Specificity (Pattern)
         then
            raise Route_Error with "ambiguous HTTP route registration";
         end if;
      end loop;
   end Check_Add;

   function Route_Count (Item : Router) return Natural is
     (Current_Configuration (Item).Count);

   function Describe_Route
     (Item  : Router;
      Index : Positive) return Route_Description
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      if Index > Configuration.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      end if;
      return
        (ID               => Configuration.Routes (Index).ID,
         Method           => Configuration.Routes (Index).Method,
         Pattern          => Configuration.Routes (Index).Pattern,
         Name             => Configuration.Routes (Index).Name,
         Policy           => Configuration.Routes (Index).Policy,
         Middleware_Count => Configuration.Routes (Index).Middleware_Count);
   end Describe_Route;

   function Global_Middleware_Count (Item : Router) return Natural is
     (Current_Configuration (Item).Middleware_Count);

   function Describe_Global_Middleware
     (Item  : Router;
      Index : Positive) return Middleware_Description
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      if Index > Configuration.Middleware_Count then
         raise Constraint_Error with
           "HTTP global middleware introspection index invalid";
      end if;
      return
        (ID    => Configuration.Middleware (Index).ID,
         Name  => Configuration.Middleware (Index).Name,
         Stage => Configuration.Middleware (Index).Stage);
   end Describe_Global_Middleware;

   function Route_Middleware_Count
     (Item        : Router;
      Route_Index : Positive) return Natural
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      if Route_Index > Configuration.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      end if;
      return Configuration.Routes (Route_Index).Middleware_Count;
   end Route_Middleware_Count;

   function Describe_Route_Middleware
     (Item             : Router;
      Route_Index      : Positive;
      Middleware_Index : Positive) return Middleware_Description
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      if Route_Index > Configuration.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      elsif Middleware_Index >
        Configuration.Routes (Route_Index).Middleware_Count
      then
         raise Constraint_Error with
           "HTTP route middleware introspection index invalid";
      end if;
      return
        (ID    => Configuration.Routes (Route_Index).Middleware
                    (Middleware_Index).ID,
         Name  => Configuration.Routes (Route_Index).Middleware
                    (Middleware_Index).Name,
         Stage => Configuration.Routes (Route_Index).Middleware
                    (Middleware_Index).Stage);
   end Describe_Route_Middleware;

   procedure Find_Route
     (Item  : Router;
      Name  : String;
      Route : out Route_ID;
      Found : out Boolean)
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      for Index in 1 .. Configuration.Count loop
         if To_String (Configuration.Routes (Index).Name) = Name then
            Route := Configuration.Routes (Index).ID;
            Found := True;
            return;
         end if;
      end loop;
      Route := No_Route;
      Found := False;
   end Find_Route;

   function Route_Index
     (Item : Router_Configuration;
      ID   : Route_ID) return Natural
   is
   begin
      for Index in 1 .. Item.Count loop
         if Item.Routes (Index).ID = ID then
            return Index;
         end if;
      end loop;
      return 0;
   end Route_Index;

   procedure Add_To_Configuration
     (Item    : in out Router_Configuration;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
      Name    : String;
      Policy  : Route_Policy;
      Validate_Ambiguity : Boolean)
   is
      Effective_Name : constant String :=
        (if Name = "" then Method & " " & Pattern else Name);
      Pattern_Segments : Segment_List;
   begin
      if Validate_Ambiguity then
         Check_Add (Item, Method, Pattern);
      else
         Check_Not_Mounted (Item);
         Validate_Method (Method);
         Validate_Pattern (Pattern);
         if Item.Count = Item.Capacity then
            raise Route_Error with "HTTP router capacity exhausted";
         end if;
      end if;
      Split_Path (Pattern, Pattern_Segments);
      if Policy.Max_Body > Max_Request_Body then
         raise Route_Error with "route body limit exceeds server maximum";
      end if;
      if Validate_Ambiguity then
         for Index in 1 .. Item.Count loop
            if To_String (Item.Routes (Index).Name) = Effective_Name then
               raise Route_Error with "duplicate HTTP route name";
            end if;
         end loop;
      end if;
      Identity_Source.Next_Route (Route);
      --  Fill the slot before the count admits it: a reader that races a
      --  registration then sees the old route set, never a partial entry.
      Item.Routes (Item.Count + 1) :=
        (ID                  => Route,
         Method              => To_Unbounded_String (Method),
         Pattern             => To_Unbounded_String (Pattern),
         Pattern_Segments    => Pattern_Segments,
         Pattern_Specificity => Specificity (Pattern),
         Name                => To_Unbounded_String (Effective_Name),
         Handler             => Handler,
         Policy              => Policy,
         Middleware =>
           (others =>
              (ID        => No_Middleware,
               Component => null,
               Stage     => Request_Head,
               Name      => Null_Unbounded_String)),
         Middleware_Count => 0);
      Item.Count := Item.Count + 1;
   end Add_To_Configuration;

   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy)
   is
      Ignored : Route_ID;
   begin
      Add
        (Item, Method, Pattern, Handler, Ignored, Name, Policy);
   end Add;

   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy)
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Check_Not_Sealed (Item);
      Add_To_Configuration
        (Configuration.all, Method, Pattern, Handler, Route, Name, Policy,
         Validate_Ambiguity => True);
   end Add;

   procedure Add_Middleware
     (Item      : in out Router;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : String := "")
   is
      Ignored : Middleware_ID;
   begin
      Add_Middleware (Item, Component, Ignored, Stage, Name);
   end Add_Middleware;

   procedure Add_Middleware_To_Configuration
     (Item       : in out Router_Configuration;
      Component  : not null Middleware_Access;
      Middleware : out Middleware_ID;
      Stage      : Middleware_Stage;
      Name       : String)
   is
   begin
      Check_Not_Mounted (Item);
      if Item.Middleware_Count = Max_Global_Middleware then
         raise Route_Error with "global HTTP middleware capacity exhausted";
      end if;
      Identity_Source.Next_Middleware (Middleware);
      Item.Middleware (Item.Middleware_Count + 1) :=
        (ID        => Middleware,
         Component => Component,
         Stage     => Stage,
         Name      => To_Unbounded_String (Name));
      Item.Middleware_Count := Item.Middleware_Count + 1;
   end Add_Middleware_To_Configuration;

   procedure Add_Middleware
     (Item       : in out Router;
      Component  : not null Middleware_Access;
      Middleware : out Middleware_ID;
      Stage      : Middleware_Stage := Request_Head;
      Name       : String := "")
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Check_Not_Sealed (Item);
      Add_Middleware_To_Configuration
        (Configuration.all, Component, Middleware, Stage, Name);
   end Add_Middleware;

   procedure Add_Route_Middleware
     (Item      : in out Router;
      Name      : String;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Middleware_Name : String := "")
   is
      Ignored : Middleware_ID;
   begin
      Add_Route_Middleware
        (Item, Name, Component, Ignored, Stage, Middleware_Name);
   end Add_Route_Middleware;

   procedure Add_Route_Middleware
     (Item            : in out Router;
      Name            : String;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "")
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
      Route          : Route_ID := No_Route;
   begin
      Check_Not_Sealed (Item);
      for Index in 1 .. Configuration.Count loop
         if To_String (Configuration.Routes (Index).Name) = Name then
            Route := Configuration.Routes (Index).ID;
            exit;
         end if;
      end loop;
      if Route = No_Route then
         raise Route_Error with "unknown HTTP route name";
      end if;
      Add_Route_Middleware
        (Item, Route, Component, Middleware, Stage, Middleware_Name);
   end Add_Route_Middleware;

   procedure Add_Route_Middleware_To_Configuration
     (Item            : in out Router_Configuration;
      Route           : Route_ID;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage;
      Middleware_Name : String)
   is
      Index : constant Natural := Route_Index (Item, Route);
   begin
      Check_Not_Mounted (Item);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      elsif Item.Routes (Index).Middleware_Count = Max_Route_Middleware then
         raise Route_Error with "route HTTP middleware capacity exhausted";
      end if;
      Identity_Source.Next_Middleware (Middleware);
      Item.Routes (Index).Middleware
        (Item.Routes (Index).Middleware_Count + 1) :=
          (ID        => Middleware,
           Component => Component,
           Stage     => Stage,
           Name      => To_Unbounded_String (Middleware_Name));
      Item.Routes (Index).Middleware_Count :=
        Item.Routes (Index).Middleware_Count + 1;
   end Add_Route_Middleware_To_Configuration;

   procedure Add_Route_Middleware
     (Item            : in out Router;
      Route           : Route_ID;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "")
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Check_Not_Sealed (Item);
      Add_Route_Middleware_To_Configuration
        (Configuration.all, Route, Component, Middleware, Stage,
         Middleware_Name);
   end Add_Route_Middleware;

   procedure Get
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "GET", Pattern, Handler, Name, Policy);
   end Get;

   procedure Get
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "GET", Pattern, Handler, Route, Name, Policy);
   end Get;

   procedure Head
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "HEAD", Pattern, Handler, Name, Policy);
   end Head;

   procedure Head
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "HEAD", Pattern, Handler, Route, Name, Policy);
   end Head;

   procedure Post
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "POST", Pattern, Handler, Name, Policy);
   end Post;

   procedure Post
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "POST", Pattern, Handler, Route, Name, Policy);
   end Post;

   procedure Put
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PUT", Pattern, Handler, Name, Policy);
   end Put;

   procedure Put
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PUT", Pattern, Handler, Route, Name, Policy);
   end Put;

   procedure Patch
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PATCH", Pattern, Handler, Name, Policy);
   end Patch;

   procedure Patch
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PATCH", Pattern, Handler, Route, Name, Policy);
   end Patch;

   procedure Delete
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "DELETE", Pattern, Handler, Name, Policy);
   end Delete;

   procedure Delete
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "DELETE", Pattern, Handler, Route, Name, Policy);
   end Delete;

   procedure Options
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "OPTIONS", Pattern, Handler, Name, Policy);
   end Options;

   procedure Options
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Route : out Route_ID;
      Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "OPTIONS", Pattern, Handler, Route, Name, Policy);
   end Options;

   procedure Require_Candidate (Change : Update) is
   begin
      if Change.State.Candidate = null then
         raise Program_Error with "HTTP router update has no candidate";
      end if;
   end Require_Candidate;

   procedure Validate_Configuration (Item : Router_Configuration) is
   begin
      if Item.Count > Item.Capacity then
         raise Route_Error with "HTTP router capacity exhausted";
      end if;
      for Index in 1 .. Item.Count loop
         Validate_Method (To_String (Item.Routes (Index).Method));
         Validate_Pattern (To_String (Item.Routes (Index).Pattern));
         if Item.Routes (Index).ID = No_Route then
            raise Route_Error with "HTTP route has no identity";
         elsif Length (Item.Routes (Index).Name) = 0 then
            raise Route_Error with "empty HTTP route name";
         elsif Item.Routes (Index).Policy.Max_Body > Max_Request_Body then
            raise Route_Error with "route body limit exceeds server maximum";
         end if;
         for Prior in 1 .. Index - 1 loop
            if Item.Routes (Prior).ID = Item.Routes (Index).ID then
               raise Route_Error with "duplicate HTTP route identity";
            elsif Item.Routes (Prior).Name = Item.Routes (Index).Name then
               raise Route_Error with "duplicate HTTP route name";
            elsif Item.Routes (Prior).Method = Item.Routes (Index).Method
              and then Patterns_Overlap
                (To_String (Item.Routes (Prior).Pattern),
                 To_String (Item.Routes (Index).Pattern))
              and then Item.Routes (Prior).Pattern_Specificity =
                Item.Routes (Index).Pattern_Specificity
            then
               raise Route_Error with "ambiguous HTTP route registration";
            end if;
         end loop;
         for Middleware_Index in
           1 .. Item.Routes (Index).Middleware_Count
         loop
            if Item.Routes (Index).Middleware (Middleware_Index).ID =
              No_Middleware
            then
               raise Route_Error with "HTTP middleware has no identity";
            end if;
         end loop;
      end loop;
      for Index in 1 .. Item.Middleware_Count loop
         if Item.Middleware (Index).ID = No_Middleware then
            raise Route_Error with "HTTP middleware has no identity";
         end if;
      end loop;
   end Validate_Configuration;

   procedure Begin_Update (Item : Router; Change : in out Update) is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      if Change.State.Candidate /= null then
         raise Program_Error with "HTTP router update is already active";
      end if;
      Check_Not_Mounted (Configuration.all);
      Change.State.Owner := Item'Address;
      Change.State.Base := Configuration;
      Change.State.Candidate :=
        new Router_Configuration'(Configuration.all);
      Change.State.Candidate.Previous := null;
   end Begin_Update;

   procedure Add
     (Change  : in out Update;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Route   : out Route_ID;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy)
   is
   begin
      Require_Candidate (Change);
      Add_To_Configuration
        (Change.State.Candidate.all,
         Method, Pattern, Handler, Route, Name, Policy,
         Validate_Ambiguity => False);
   end Add;

   procedure Remove (Change : in out Update; Route : Route_ID) is
      Index : Natural;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Index := Route_Index (Change.State.Candidate.all, Route);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      end if;
      for Cursor in Index .. Change.State.Candidate.Count - 1 loop
         Change.State.Candidate.Routes (Cursor) :=
           Change.State.Candidate.Routes (Cursor + 1);
      end loop;
      Change.State.Candidate.Routes (Change.State.Candidate.Count) :=
        (others => <>);
      Change.State.Candidate.Count := Change.State.Candidate.Count - 1;
   end Remove;

   procedure Replace_Handler
     (Change  : in out Update;
      Route   : Route_ID;
      Handler : not null Handler_Access)
   is
      Index : Natural;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Index := Route_Index (Change.State.Candidate.all, Route);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      end if;
      Change.State.Candidate.Routes (Index).Handler := Handler;
   end Replace_Handler;

   procedure Set_Policy
     (Change : in out Update;
      Route  : Route_ID;
      Policy : Route_Policy)
   is
      Index : Natural;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Index := Route_Index (Change.State.Candidate.all, Route);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      elsif Policy.Max_Body > Max_Request_Body then
         raise Route_Error with "route body limit exceeds server maximum";
      end if;
      Change.State.Candidate.Routes (Index).Policy := Policy;
   end Set_Policy;

   procedure Set_Match
     (Change  : in out Update;
      Route   : Route_ID;
      Method  : String;
      Pattern : String)
   is
      Index    : Natural;
      Segments : Segment_List;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Validate_Method (Method);
      Validate_Pattern (Pattern);
      Index := Route_Index (Change.State.Candidate.all, Route);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      end if;
      Split_Path (Pattern, Segments);
      Change.State.Candidate.Routes (Index).Method :=
        To_Unbounded_String (Method);
      Change.State.Candidate.Routes (Index).Pattern :=
        To_Unbounded_String (Pattern);
      Change.State.Candidate.Routes (Index).Pattern_Segments := Segments;
      Change.State.Candidate.Routes (Index).Pattern_Specificity :=
        Specificity (Pattern);
   end Set_Match;

   procedure Rename
     (Change : in out Update;
      Route  : Route_ID;
      Name   : String)
   is
      Index : Natural;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      if Name'Length = 0 then
         raise Route_Error with "empty HTTP route name";
      end if;
      Index := Route_Index (Change.State.Candidate.all, Route);
      if Index = 0 then
         raise Route_Error with "unknown HTTP route identity";
      end if;
      Change.State.Candidate.Routes (Index).Name := To_Unbounded_String (Name);
   end Rename;

   procedure Add_Middleware
     (Change     : in out Update;
      Component  : not null Middleware_Access;
      Middleware : out Middleware_ID;
      Stage      : Middleware_Stage := Request_Head;
      Name       : String := "")
   is
   begin
      Require_Candidate (Change);
      Add_Middleware_To_Configuration
        (Change.State.Candidate.all, Component, Middleware, Stage, Name);
   end Add_Middleware;

   procedure Add_Route_Middleware
     (Change          : in out Update;
      Route           : Route_ID;
      Component       : not null Middleware_Access;
      Middleware      : out Middleware_ID;
      Stage           : Middleware_Stage := Request_Head;
      Middleware_Name : String := "")
   is
   begin
      Require_Candidate (Change);
      Add_Route_Middleware_To_Configuration
        (Change.State.Candidate.all, Route, Component, Middleware, Stage,
         Middleware_Name);
   end Add_Route_Middleware;

   procedure Remove_From_Chain
     (Chain      : in out Middleware_Array;
      Count      : in out Natural;
      Middleware : Middleware_ID;
      Removed    : in out Boolean)
   is
   begin
      for Index in 1 .. Count loop
         if Chain (Index).ID = Middleware then
            for Cursor in Index .. Count - 1 loop
               Chain (Cursor) := Chain (Cursor + 1);
            end loop;
            Chain (Count) := (others => <>);
            Count := Count - 1;
            Removed := True;
            return;
         end if;
      end loop;
   end Remove_From_Chain;

   procedure Remove_Middleware
     (Change     : in out Update;
      Middleware : Middleware_ID)
   is
      Removed : Boolean := False;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Remove_From_Chain
        (Change.State.Candidate.Middleware,
         Change.State.Candidate.Middleware_Count,
         Middleware, Removed);
      for Index in 1 .. Change.State.Candidate.Count loop
         Remove_From_Chain
           (Change.State.Candidate.Routes (Index).Middleware,
            Change.State.Candidate.Routes (Index).Middleware_Count,
            Middleware, Removed);
      end loop;
      if not Removed then
         raise Route_Error with "unknown HTTP middleware identity";
      end if;
   end Remove_Middleware;

   procedure Replace_Middleware
     (Change     : in out Update;
      Middleware : Middleware_ID;
      Component  : not null Middleware_Access)
   is
      Replaced : Boolean := False;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      for Index in 1 .. Change.State.Candidate.Middleware_Count loop
         if Change.State.Candidate.Middleware (Index).ID = Middleware then
            Change.State.Candidate.Middleware (Index).Component := Component;
            Replaced := True;
         end if;
      end loop;
      for Route in 1 .. Change.State.Candidate.Count loop
         for Index in
           1 .. Change.State.Candidate.Routes (Route).Middleware_Count
         loop
            if Change.State.Candidate.Routes (Route).Middleware (Index).ID =
              Middleware
            then
               Change.State.Candidate.Routes (Route).Middleware
                 (Index).Component := Component;
               Replaced := True;
            end if;
         end loop;
      end loop;
      if not Replaced then
         raise Route_Error with "unknown HTTP middleware identity";
      end if;
   end Replace_Middleware;

   procedure Set_Middleware_Stage
     (Change     : in out Update;
      Middleware : Middleware_ID;
      Stage      : Middleware_Stage)
   is
      Replaced : Boolean := False;
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      for Index in 1 .. Change.State.Candidate.Middleware_Count loop
         if Change.State.Candidate.Middleware (Index).ID = Middleware then
            Change.State.Candidate.Middleware (Index).Stage := Stage;
            Replaced := True;
         end if;
      end loop;
      for Route in 1 .. Change.State.Candidate.Count loop
         for Index in
           1 .. Change.State.Candidate.Routes (Route).Middleware_Count
         loop
            if Change.State.Candidate.Routes (Route).Middleware (Index).ID =
              Middleware
            then
               Change.State.Candidate.Routes (Route).Middleware
                 (Index).Stage := Stage;
               Replaced := True;
            end if;
         end loop;
      end loop;
      if not Replaced then
         raise Route_Error with "unknown HTTP middleware identity";
      end if;
   end Set_Middleware_Stage;

   procedure Set_Automatic_Admission
     (Change          : in out Update;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0)
   is
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      Change.State.Candidate.Automatic_Concurrency := Concurrency;
      Change.State.Candidate.Automatic_Rate := Rate_Per_Second;
   end Set_Automatic_Admission;

   procedure Set_Authentication_Challenge
     (Change    : in out Update;
      Challenge : String)
   is
   begin
      Require_Candidate (Change);
      Check_Not_Mounted (Change.State.Candidate.all);
      if Challenge'Length = 0 then
         raise Route_Error with "empty HTTP authentication challenge";
      end if;
      for Value of Challenge loop
         if Character'Pos (Value) < 32 or else Character'Pos (Value) = 127
         then
            raise Route_Error with
              "control byte in HTTP authentication challenge";
         end if;
      end loop;
      Change.State.Candidate.Challenge := To_Unbounded_String (Challenge);
   end Set_Authentication_Challenge;

   procedure Commit (Item : in out Router; Change : in out Update) is
      Candidate : Configuration_Access;
      Accepted  : Boolean;
   begin
      Require_Candidate (Change);
      if Change.State.Owner /= Item'Address then
         raise Route_Error with "HTTP router update belongs to another router";
      end if;
      Validate_Configuration (Change.State.Candidate.all);
      Candidate := Change.State.Candidate;
      Item.Publisher.Try_Publish (Change.State.Base, Candidate, Accepted);
      if not Accepted then
         raise Stale_Update with "HTTP router generation was replaced";
      end if;
      Candidate.Previous := Item.First_Configuration;
      Item.First_Configuration := Candidate;
      Flyology.Atomic_Primitives.Store_Release_U64
        (Item.Current_Configuration'Address,
         Address_Word (Candidate.all'Address));
      Change.State.Candidate := null;
      Change.State.Owner := System.Null_Address;
      Change.State.Base := null;
   end Commit;

   procedure Set_Automatic_Admission
     (Item            : in out Router;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0)
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Check_Not_Sealed (Item);
      Configuration.Automatic_Concurrency := Concurrency;
      Configuration.Automatic_Rate := Rate_Per_Second;
   end Set_Automatic_Admission;

   function Automatic_Concurrency (Item : Router) return Natural is
     (Current_Configuration (Item).Automatic_Concurrency);

   function Automatic_Rate_Per_Second (Item : Router) return Natural is
     (Current_Configuration (Item).Automatic_Rate);

   procedure Set_Authentication_Challenge
     (Item      : in out Router;
      Challenge : String)
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Check_Not_Sealed (Item);
      if Challenge'Length = 0 then
         raise Route_Error with "empty HTTP authentication challenge";
      end if;
      for Value of Challenge loop
         if Character'Pos (Value) < 32 or else Character'Pos (Value) = 127
         then
            raise Route_Error with
              "control byte in HTTP authentication challenge";
         end if;
      end loop;
      Configuration.Challenge := To_Unbounded_String (Challenge);
   end Set_Authentication_Challenge;

   function Authentication_Challenge (Item : Router) return String is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      return
        (if Length (Configuration.Challenge) = 0
         then App.Default_Authentication_Challenge
         else To_String (Configuration.Challenge));
   end Authentication_Challenge;

   function Join_Pattern (Prefix, Pattern : String) return String is
   begin
      if Prefix = "/" then
         return Pattern;
      elsif Pattern = "/" then
         return Prefix;
      elsif Prefix (Prefix'Last) = '/' then
         return Prefix (Prefix'First .. Prefix'Last - 1) & Pattern;
      else
         return Prefix & Pattern;
      end if;
   end Join_Pattern;

   procedure Mount
     (Item        : in out Router;
      Prefix      : String;
      Source      : in out Router;
      Name_Prefix : String := "")
   is
      Destination : constant Configuration_Access :=
        Current_Configuration (Item);
      Source_Configuration : constant Configuration_Access :=
        Current_Configuration (Source);
   begin
      Check_Not_Sealed (Item);
      Check_Not_Sealed (Source);
      Check_Not_Mounted (Destination.all);
      Validate_Pattern (Prefix, Static_Only => True);
      if Source_Configuration.Count >
        Destination.Capacity - Destination.Count
      then
         raise Route_Error with "HTTP router capacity exhausted by mount";
      end if;
      for Index in 1 .. Source_Configuration.Count loop
         declare
            --  Source is a variable view now that mounting seals it, so its
            --  discriminant-dependent route component cannot be renamed.
            New_Index : Positive;
         begin
            if Source_Configuration.Middleware_Count
              + Source_Configuration.Routes (Index).Middleware_Count >
                Max_Route_Middleware
            then
               raise Route_Error with
                 "mounted HTTP middleware capacity exhausted";
            end if;
            Add
              (Item,
               To_String (Source_Configuration.Routes (Index).Method),
               Join_Pattern
                 (Prefix,
                  To_String (Source_Configuration.Routes (Index).Pattern)),
               Source_Configuration.Routes (Index).Handler,
               (if Name_Prefix = "" then
                  To_String (Source_Configuration.Routes (Index).Name)
                else Name_Prefix &
                  To_String (Source_Configuration.Routes (Index).Name)),
               Source_Configuration.Routes (Index).Policy);
            New_Index := Destination.Count;
            --  Copies keep the source registration identity, so one
            --  Remove_Middleware or Replace_Middleware on that identity
            --  reaches every mounted chain that carries it.
            for Middleware_Index in
              1 .. Source_Configuration.Middleware_Count
            loop
               Destination.Routes (New_Index).Middleware
                 (Destination.Routes (New_Index).Middleware_Count + 1) :=
                   Source_Configuration.Middleware (Middleware_Index);
               Destination.Routes (New_Index).Middleware_Count :=
                 Destination.Routes (New_Index).Middleware_Count + 1;
            end loop;
            for Middleware_Index in
              1 .. Source_Configuration.Routes (Index).Middleware_Count
            loop
               Destination.Routes (New_Index).Middleware
                 (Destination.Routes (New_Index).Middleware_Count + 1) :=
                   Source_Configuration.Routes (Index).Middleware
                     (Middleware_Index);
               Destination.Routes (New_Index).Middleware_Count :=
                 Destination.Routes (New_Index).Middleware_Count + 1;
            end loop;
         end;
      end loop;
      Source_Configuration.Mounted := True;
   end Mount;

   function Match_Path
     (Pattern, Path : Segment_List;
      Ignore_Trailing : Boolean;
      Capture : Boolean;
      X : access App.Exchange := null) return Boolean
   is
      Last_Is_Remainder : Boolean;
      Normal_Count : Natural;
   begin
      Last_Is_Remainder := Pattern.Count > 0
        and then Is_Remainder
          (To_String (Pattern.Values (Pattern.Count)));
      Normal_Count :=
        (if Last_Is_Remainder then Pattern.Count - 1 else Pattern.Count);
      if Path.Count < Normal_Count
        or else
          (not Last_Is_Remainder and then Path.Count /= Pattern.Count)
        or else (not Ignore_Trailing and then not Last_Is_Remainder
                 and then Pattern.Trailing /= Path.Trailing)
      then
         return False;
      end if;
      for Index in 1 .. Normal_Count loop
         declare
            Pattern_Segment : constant String :=
              To_String (Pattern.Values (Index));
            Value_Segment   : constant String :=
              To_String (Path.Values (Index));
            Name : constant String := Parameter_Name (Pattern_Segment);
         begin
            if Name = "" then
               if Pattern_Segment /= Value_Segment then
                  return False;
               end if;
            elsif Capture then
               App.Add_Parameter (X.all, Name, Value_Segment);
            end if;
         end;
      end loop;
      if Last_Is_Remainder and then Capture then
         declare
            Remainder : Unbounded_String;
         begin
            for Index in Pattern.Count .. Path.Count loop
               if Index > Pattern.Count then
                  Append (Remainder, "/");
               end if;
               Append (Remainder, To_String (Path.Values (Index)));
            end loop;
            if Path.Trailing and then Path.Count >= Pattern.Count then
               Append (Remainder, "/");
            end if;
            App.Add_Parameter
              (X.all,
               Remainder_Name
                 (To_String (Pattern.Values (Pattern.Count))),
               To_String (Remainder));
         end;
      end if;
      return True;
   end Match_Path;

   procedure Add_Allowed (Allowed : in out Unbounded_String; Method : String)
   is
      Existing : constant String := To_String (Allowed);
      Wrapped  : constant String := ", " & Existing & ", ";
   begin
      if Ada.Strings.Fixed.Index (Wrapped, ", " & Method & ", ") = 0 then
         if Length (Allowed) > 0 then
            Append (Allowed, ", ");
         end if;
         Append (Allowed, Method);
      end if;
   end Add_Allowed;

   procedure Admit_Body
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Accepted : Boolean;
   begin
      App.Apply_Body_Policy (X, Accepted);
      if Accepted then
         Next.Call (Context, X);
      end if;
   end Admit_Body;

   procedure Require_Authentication
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
   begin
      if X.Authentication = App.Required_Authentication
        and then not X.Has_Principal
      then
         --  Reaching this backstop means nothing installed a principal
         --  first, which for a correctly staged application cannot happen.
         --  A distinct problem type keeps that misordering visible instead
         --  of reading as an ordinary credential rejection.
         X.Add_Header ("WWW-Authenticate", X.Authentication_Challenge);
         X.Problem
           (401, "authentication-not-installed", "Authentication required");
      else
         Next.Call (Context, X);
      end if;
   end Require_Authentication;

   procedure Automatic_Response
     (Context : in out App_Context;
      X       : in out App.Exchange)
   is
      pragma Unreferenced (Context);
      Name : constant String := X.Route_Name;
   begin
      if Name = "flyology.bad_request" then
         X.Problem (400, "invalid-path", "Request path is malformed");
      elsif Name = "flyology.redirect" then
         X.Respond (308, "", "");
      elsif Name = "flyology.options" then
         X.No_Content;
      elsif Name in "flyology.method_not_allowed" |
        "flyology.cors_preflight"
      then
         X.Problem (405, "method-not-allowed", "Method is not allowed");
      else
         X.Problem (404, "not-found", "Route does not exist");
      end if;
   end Automatic_Response;

   procedure Dispatch_Configuration
     (Item    : Router_Configuration;
      Context : in out App_Context;
      X       : in out App.Exchange)
   is
      Target_Value : constant String := X.Request_Target;
      Raw          : constant String := Raw_Path (Target_Value);
      Invalid_Path : Boolean := False;

      function Decode_For_Dispatch return String is
      begin
         return (if Raw = "*" then "*" else Decode_Path (Raw));
      exception
         when Route_Error =>
            Invalid_Path := True;
            return "/";
      end Decode_For_Dispatch;

      Path_Value   : constant String := Decode_For_Dispatch;
      Path_Segments : Segment_List;
      Request_Method : constant String := X.Request_Method;
      Selected       : Natural := 0;
      Fallback       : Natural := 0;
      Selected_Score : Natural := 0;
      Allowed        : Unbounded_String;
      Alternate      : Natural := 0;
      Preflight_Route : Natural := 0;
      function Matches (Index : Positive; Ignore : Boolean := False)
        return Boolean
      is (Match_Path
            (Item.Routes (Index).Pattern_Segments, Path_Segments,
             Ignore, Capture => False));

      procedure Consider (Index : Positive; Is_Fallback : Boolean := False) is
         Score : constant Natural :=
           Item.Routes (Index).Pattern_Specificity;
      begin
         if Is_Fallback then
            if Fallback = 0 or else Score >
              Item.Routes (Fallback).Pattern_Specificity
            then
               Fallback := Index;
            end if;
         elsif Selected = 0 or else Score > Selected_Score then
            Selected := Index;
            Selected_Score := Score;
         elsif Score = Selected_Score then
            raise Route_Error with "ambiguous HTTP route match";
         end if;
      end Consider;

      procedure Run_Automatic
        (Name : String;
         CORS_Policy : Natural := 0)
      is
         Pipeline : aliased Components.Pipeline
           (Capacity => Max_Global_Middleware);
      begin
         X.Configure_Route
           (Name, Path_Value, App.Reject_Body, App.No_Authentication,
            CORS_Policy, Item.Automatic_Concurrency, Item.Automatic_Rate,
            App.No_Upgrade);
         X.Seal_Route;
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Request_Head then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Application then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Execute (Context, X, Automatic_Response'Access);
      end Run_Automatic;
   begin
      Split_Path (Path_Value, Path_Segments);
      if Request_Method = "OPTIONS" and then Raw = "*" then
         Add_Allowed (Allowed, "OPTIONS");
         for Index in 1 .. Item.Count loop
            Add_Allowed (Allowed, To_String (Item.Routes (Index).Method));
            if To_String (Item.Routes (Index).Method) = "GET"
              and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
            then
               Add_Allowed (Allowed, "HEAD");
            end if;
         end loop;
         if Length (Allowed) > 0 then
            X.Add_Header ("Allow", To_String (Allowed));
         end if;
         Run_Automatic ("flyology.options");
         return;
      end if;
      if Invalid_Path then
         Run_Automatic ("flyology.bad_request");
         return;
      end if;
      for Index in 1 .. Item.Count loop
         if Matches (Index, Item.Slashes = Ignore_Slashes) then
            declare
               Route_Method : constant String :=
                 To_String (Item.Routes (Index).Method);
            begin
               if Item.Routes (Index).Policy.CORS_Policy /= 0
                 and then
                   (Preflight_Route = 0
                    or else
                      Item.Routes (Preflight_Route).Pattern_Specificity <
                      Item.Routes (Index).Pattern_Specificity)
               then
                  Preflight_Route := Index;
               end if;
               Add_Allowed (Allowed, Route_Method);
               if Route_Method = "GET"
                 and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
               then
                  Add_Allowed (Allowed, "HEAD");
               end if;
               if Route_Method = Request_Method then
                  Consider (Index);
               elsif Request_Method = "HEAD" and then Route_Method = "GET"
                 and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
               then
                  Consider (Index, Is_Fallback => True);
               end if;
            end;
         elsif Item.Slashes = Redirect_Slashes and then Matches (Index, True)
           and then (To_String (Item.Routes (Index).Method) = Request_Method
                     or else (Request_Method = "HEAD"
                              and then To_String
                                (Item.Routes (Index).Method) = "GET"
                              and then Item.Routes (Index).Policy.Upgrade =
                                No_Upgrade))
         then
            Alternate := Index;
         end if;
      end loop;
      if Selected = 0 then
         Selected := Fallback;
      end if;
      if Selected = 0 then
         if Alternate /= 0 then
            declare
               Location : constant String :=
                 (if Raw = "/" then Raw
                  elsif Raw (Raw'Last) = '/'
                  then Raw (Raw'First .. Raw'Last - 1)
                  else Raw & "/") & Raw_Query_Suffix (Target_Value);
            begin
               X.Add_Header ("Location", Location);
            end;
            --  Redirect responses also pass through global observation and
            --  security middleware; the Location header was staged above.
            Run_Automatic ("flyology.redirect");
         elsif Length (Allowed) > 0 then
            X.Add_Header ("Allow", To_String (Allowed));
            if Request_Method = "OPTIONS"
              and then X.Request_Header
                ("Access-Control-Request-Method") /= ""
              and then Preflight_Route /= 0
            then
               Run_Automatic
                 ("flyology.cors_preflight",
                  Item.Routes (Preflight_Route).Policy.CORS_Policy);
            else
               Run_Automatic ("flyology.method_not_allowed");
            end if;
         else
            Run_Automatic ("flyology.not_found");
         end if;
         return;
      end if;

      declare
         Pipeline : aliased Components.Pipeline
           (Capacity =>
              Max_Global_Middleware + Max_Route_Middleware + 2);
      begin
         X.Configure_Route
           (To_String (Item.Routes (Selected).Name), Path_Value,
            Item.Routes (Selected).Policy.Body_Handling,
            Item.Routes (Selected).Policy.Authentication,
            Item.Routes (Selected).Policy.CORS_Policy,
            Item.Routes (Selected).Policy.Concurrency,
            Item.Routes (Selected).Policy.Rate_Per_Second,
            Item.Routes (Selected).Policy.Upgrade);
         if Length (Item.Challenge) > 0
           and then Item.Routes (Selected).Policy.Authentication =
             App.Required_Authentication
         then
            X.Set_Authentication_Challenge (To_String (Item.Challenge));
         end if;
         if not Match_Path
           (Item.Routes (Selected).Pattern_Segments, Path_Segments,
            Item.Slashes = Ignore_Slashes, Capture => True, X => X'Access)
         then
            raise Program_Error with "selected HTTP route no longer matches";
         end if;
         X.Seal_Route;
         if Item.Routes (Selected).Policy.Timeout >= 0.0 then
            declare
               Candidate : constant Ada.Real_Time.Time := Ada.Real_Time.Clock
                 + Ada.Real_Time.To_Time_Span
                     (Item.Routes (Selected).Policy.Timeout);
            begin
               if Candidate < X.Deadline then
                  X.Narrow_Deadline (Candidate);
               end if;
            end;
         end if;
         begin
            X.Narrow_Body_Limit
              (Item.Routes (Selected).Policy.Max_Body);
         exception
            when Payload_Too_Large | Protocol_Error =>
               X.Problem (413, "body-too-large", "Request body is too large");
               return;
         end;

         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Request_Head then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Item.Routes (Selected).Middleware_Count loop
            if Item.Routes (Selected).Middleware (Index).Stage = Request_Head
            then
               Pipeline.Add
                 (Item.Routes (Selected).Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Add (Require_Authentication'Access);
         Pipeline.Add (Admit_Body'Access);
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Application then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Item.Routes (Selected).Middleware_Count loop
            if Item.Routes (Selected).Middleware (Index).Stage = Application
            then
               Pipeline.Add
                 (Item.Routes (Selected).Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Execute (Context, X, Item.Routes (Selected).Handler);
         if X.Response = App.Not_Started then
            X.No_Content;
         elsif X.Response in App.Streaming_Response | App.Streaming_SSE |
           App.Upgraded | App.Failed
         then
            --  A lifecycle must finish before its borrowed exchange returns.
            --  Returning while framing is active makes another HTTP read
            --  unsafe, so contain the fault to this connection.
            X.Mark_Failed;
         end if;
      exception
         when Resource_Exhausted =>
            if not X.Wire_Response_Started then
               X.Add_Header ("Retry-After", "1");
               X.Problem
                 (503, "ingress-budget-exhausted",
                  "Server ingress capacity is exhausted");
            else
               X.Mark_Failed;
            end if;
      end;
   exception
      when Route_Error =>
         if not X.Wire_Response_Started then
            X.Problem (400, "invalid-path", "Request path is malformed");
         end if;
      when Payload_Too_Large =>
         if not X.Wire_Response_Started then
            X.Problem (413, "body-too-large", "Request body is too large");
         else
            X.Mark_Failed;
         end if;
      when Expectation_Failed =>
         if not X.Wire_Response_Started then
            X.Problem
              (417, "expectation-failed", "Request expectation failed");
         else
            X.Mark_Failed;
         end if;
      when Protocol_Error =>
         if not X.Wire_Response_Started then
            X.Problem (400, "bad-request", "Request data is malformed");
         else
            X.Mark_Failed;
         end if;
   end Dispatch_Configuration;

   procedure Dispatch
     (Item    : in out Router;
      Context : in out App_Context;
      X       : in out App.Exchange)
   is
      Configuration : constant Configuration_Access :=
        Current_Configuration (Item);
   begin
      Seal (Item);
      Dispatch_Configuration (Configuration.all, Context, X);
   end Dispatch;

   procedure Dispatch
     (Item       : in out Router;
      Context    : in out App_Context;
      Connection : aliased in out Flyology.HTTP.Server.Connection;
      Value      : aliased in out Request;
      Peer       : Flyology.IO.Sockets.Endpoint;
      Token      : access Flyology.Cancellation.Token := null;
      Alt_Svc    : String := "";
      Scheme     : Origin_Scheme := Plain_HTTP)
   is
      X : App.Exchange := App.Create
        (Value, Connection, Peer, Token, Request_Deadline (Connection),
         Scheme);
   begin
      if Alt_Svc /= "" then
         X.Set_Header ("Alt-Svc", Alt_Svc);
      end if;
      Dispatch (Item, Context, X);
   end Dispatch;

   procedure Serve
     (Item         : in out Router;
      Context      : in out App_Context;
      Connection   : aliased in out Flyology.HTTP.Server.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Timeout      : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests : Natural := 1_000;
      Token        : access Flyology.Cancellation.Token := null;
      Header_Timeout : Duration := -1.0;
      Alt_Svc      : String := "";
      Scheme       : Origin_Scheme := Plain_HTTP)
   is
      Value  : aliased Request;
      Closed : Boolean;
      Count  : Natural := 0;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Head_Started : Ada.Real_Time.Time := Started;
      Head_Budget  : Duration := Timeout;

      function Read_Timeout return Duration is
         Age_Left : Duration;
      begin
         if Max_Connection_Age < 0.0 then
            return Timeout;
         end if;
         Age_Left := Max_Connection_Age - Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
         if Age_Left <= 0.0 then
            return 0.0;
         elsif Timeout < 0.0 then
            return Age_Left;
         else
            return Duration'Min (Timeout, Age_Left);
         end if;
      end Read_Timeout;

      function Head_Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Head_Started);
      begin
         if Head_Budget < 0.0 then
            return -1.0;
         elsif Elapsed >= Head_Budget then
            return 0.0;
         else
            return Head_Budget - Elapsed;
         end if;
      end Head_Time_Left;
   begin
      loop
         exit when Read_Timeout = 0.0;
         Head_Started := Ada.Real_Time.Clock;
         Head_Budget :=
           (if Header_Timeout < 0.0
            then Read_Timeout
            elsif Read_Timeout < 0.0
            then Header_Timeout
            else Duration'Min (Header_Timeout, Read_Timeout));
         begin
            Read_Request_Head
              (Connection, Value, Closed,
               Header_Timeout  => Head_Budget,
               Request_Timeout => Read_Timeout,
               Max_Body        => Max_Request_Body,
               Token           => Token);
         exception
            when Payload_Too_Large =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 413, "text/plain; charset=utf-8",
                     "request content is too large" & Character'Val (10),
                     Close => True, Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Expectation_Failed =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 417, "text/plain; charset=utf-8",
                     "request expectation failed" & Character'Val (10),
                     Close => True, Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Protocol_Error =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 400, "text/plain; charset=utf-8",
                     "bad request" & Character'Val (10), Close => True,
                     Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               return;
         end;
         exit when Closed;
         Count := Count + 1;
         if Max_Requests > 0 and then Count >= Max_Requests then
            Connection.Request_Close := True;
         end if;
         begin
            Dispatch
              (Item, Context, Connection, Value, Peer, Token, Alt_Svc,
               Scheme);
         exception
            when Flyology.Cancellation.Operation_Cancelled |
                 Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 Flyology.IO.Sockets.Socket_Error |
                 Resource_Exhausted =>
               return;
            when others =>
               if not Response_Started (Connection) then
                  begin
                     Respond
                       (Connection, 500, "text/plain; charset=utf-8",
                        "internal server error" & Character'Val (10),
                        Close => True, Timeout => Read_Timeout,
                        Token => Token);
                  exception
                     when others => null;
                  end;
               end if;
               return;
         end;
         exit when Should_Close (Connection);
      end loop;
   end Serve;

   procedure Serve
     (Item               : in out Router;
      Context            : in out App_Context;
      Channel            : aliased in out Flyology.IO.Connections.Connection;
      Peer               : Flyology.IO.Sockets.Endpoint;
      Mode               : Protocol_Mode := HTTP_1_Only;
      Timeout            : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Natural := 1_000;
      Token              : access Flyology.Cancellation.Token := null;
      Header_Timeout     : Duration := -1.0;
      Ingress            : access Ingress_Budget := null;
      Alt_Svc            : String := "";
      Scheme             : Origin_Scheme := Plain_HTTP)
   is
      procedure Serve_HTTP_1 is
         Transport : aliased
           Flyology.HTTP.Server.Connections.Connection_Transport
             (Channel'Access);
         Connection : aliased Flyology.HTTP.Server.Connection
           (Transport'Access);
      begin
         if Ingress /= null then
            Configure_Ingress_Budget (Connection, Ingress);
         end if;
         Serve
           (Item, Context, Connection, Peer, Timeout, Max_Connection_Age,
            Max_Requests, Token, Header_Timeout, Alt_Svc, Scheme);
      end Serve_HTTP_1;

      procedure Dispatch_HTTP_2
        (State : in out App_Context;
         X     : in out Applications.Exchange) is
      begin
         if Alt_Svc /= "" then
            X.Set_Header ("Alt-Svc", Alt_Svc);
         end if;
         Dispatch (Item, State, X);
      end Dispatch_HTTP_2;

      package HTTP_2_Engine is new
        Flyology.HTTP.Server.HTTP_2 (App_Context, Dispatch_HTTP_2);

      procedure Serve_HTTP_2 is
      begin
         HTTP_2_Engine.Serve
           (Context, Channel, Peer, Timeout, Max_Connection_Age, Token,
            Scheme);
      end Serve_HTTP_2;
   begin
      case Mode is
         when HTTP_1_Only =>
            Serve_HTTP_1;
         when HTTP_2_Only =>
            Serve_HTTP_2;
         when ALPN_Negotiated =>
            declare
               Selected : constant String :=
                 Flyology.IO.Connections.TLS.Selected_Protocol (Channel);
            begin
               if Selected = "h2" then
                  Serve_HTTP_2;
               elsif Selected = "" or else Selected = "http/1.1" then
                  Serve_HTTP_1;
               else
                  raise Protocol_Error with
                    "unsupported negotiated HTTP protocol: " & Selected;
               end if;
            end;
      end case;
   end Serve;

   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      Endpoint             : Flyology.IO.Sockets.Endpoint;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   is
      package Sockets renames Flyology.IO.Sockets;
      package Connection_TLS renames Flyology.IO.Connections.TLS;
      package ALPN renames Flyology.IO.TLS.ALPN;

      function Compact (Value : Natural) return String is
        (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

      Alt_Svc : constant String :=
        "h3=" & Character'Val (34) & ":" &
        Compact (Natural (Endpoint.Port)) & Character'Val (34) &
        "; ma=" & Compact (Alt_Svc_Max_Age);

      type TCP_Context is limited record
         Routes      : access Router;
         Application : access App_Context;
         Backend     : access ALPN.Provider'Class;
         Ingress     : access Ingress_Budget;
      end record;

      procedure Handle_TCP
        (State        : in out TCP_Context;
         Connection   : in out Flyology.IO.Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access
           Flyology.IO.Connections.Cancellation_Token)
      is
      begin
         Connection_TLS.Upgrade
           (Connection, State.Backend.all, Flyology.IO.TLS.Server, "",
            Protocols => ALPN.Empty_Protocol_List,
            Timeout => Handshake_Timeout, Token => Cancellation);
         State.Routes.Serve
           (State.Application.all, Connection, Peer,
            Mode               => ALPN_Negotiated,
            Timeout            => Timeout,
            Max_Connection_Age => Max_Connection_Age,
            Max_Requests       => TCP_Max_Requests,
            Token              => Cancellation,
            Header_Timeout     => Header_Timeout,
            Ingress            => State.Ingress,
            Alt_Svc            => Alt_Svc,
            Scheme             => Secure_HTTPS);
      exception
         --  A peer can disconnect, probe, or lose a dual-stack connection
         --  race before completing TLS. That terminates this accepted
         --  connection; it is not a listener or application failure.
         when Flyology.IO.TLS.TLS_Error =>
            null;
      end Handle_TCP;

      package TCP_Servers is new Flyology.IO.Structured_Servers
        (Handler_Context => TCP_Context,
         Handle          => Handle_TCP,
         Handler_Model   => Handler_Model);

      procedure Dispatch_HTTP_3
        (State : in out App_Context;
         X     : in out Applications.Exchange) is
      begin
         Dispatch (Item, State, X);
      end Dispatch_HTTP_3;

      package HTTP_3_Engine is new
        Flyology.HTTP.Server.HTTP_3
          (App_Context, Dispatch_HTTP_3, Handler_Model);

      protected Outcome is
         procedure Record_Failure (Message : String);
         function Failed return Boolean;
         function Detail return String;
      private
         Has_Failed : Boolean := False;
         Failure_Detail : Unbounded_String;
      end Outcome;

      protected body Outcome is
         procedure Record_Failure (Message : String) is
         begin
            if not Has_Failed then
               Failure_Detail := To_Unbounded_String (Message);
            end if;
            Has_Failed := True;
         end Record_Failure;

         function Failed return Boolean is (Has_Failed);

         function Detail return String is
           (To_String (Failure_Detail));
      end Outcome;

      TCP_Listener : Sockets.Socket_Type;
      UDP_Listener : aliased Sockets.Socket_Type;

      procedure Request_Stop is
      begin
         begin
            Token.Request;
         exception
            when others => null;
         end;
      end Request_Stop;

      procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
      begin
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
      end Close_If_Open;
   begin
      if HTTP_3_Capacity > 256 then
         raise Constraint_Error with
           "HTTP/3 listener capacity exceeds the bounded worker profile";
      elsif HTTP_3_Max_Requests >
        HTTP_3_Engine.Maximum_Requests_Per_Connection
      then
         raise Constraint_Error with
           "HTTP/3 request limit exceeds the bounded connection profile";
      elsif Handshake_Timeout <= 0.0 then
         raise Constraint_Error with
           "unified server handshake timeout must be positive";
      end if;

      Sockets.Create_Socket
        (TCP_Listener, Endpoint.Family, Sockets.Socket_Stream);
      Sockets.Set_Socket_Option
        (TCP_Listener,
         (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket (TCP_Listener, Endpoint);
      Sockets.Listen_Socket (TCP_Listener, TCP_Capacity);

      Sockets.Create_Socket
        (UDP_Listener, Endpoint.Family, Sockets.Socket_Datagram);
      Sockets.Set_Socket_Option
        (UDP_Listener,
         (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket (UDP_Listener, Endpoint);

      declare
         TCP_Manager : aliased TCP_Servers.Server
           (Capacity => TCP_Capacity);
         Shared : aliased TCP_Context :=
           (Routes      => Item'Unchecked_Access,
            Application => Context'Unchecked_Access,
            Backend     => TLS_Backend'Unchecked_Access,
            Ingress     => Ingress);

         task TCP_Task;
         task UDP_Task;
         task Stop_Task;

         task body TCP_Task is
         begin
            begin
               TCP_Servers.Serve
                 (TCP_Manager, TCP_Listener, Shared, Drain_Timeout);
            exception
               when Error : others =>
                  Outcome.Record_Failure
                    (Exception_Summary (Error));
                  Request_Stop;
            end;
         end TCP_Task;

         task body UDP_Task is
         begin
            begin
               HTTP_3_Engine.Serve_Listener
                 (Context, UDP_Listener, Certificate_DER, Private_Key,
                  Capacity => HTTP_3_Capacity,
                  Transport_Settings => Transport_Settings,
                  Timeout => Timeout,
                  Handshake_Timeout => Handshake_Timeout,
                  Max_Connection_Age => Max_Connection_Age,
                  Max_Requests => HTTP_3_Max_Requests,
                  Token => Token);
            exception
               when Error : others =>
                  Outcome.Record_Failure
                    (Exception_Summary (Error));
                  Request_Stop;
            end;
         end UDP_Task;

         task body Stop_Task is
         begin
            Token.Await_Request;
            TCP_Servers.Request_Shutdown (TCP_Manager);
         exception
            when Error : others =>
               Outcome.Record_Failure
                 (Exception_Summary (Error));
               Request_Stop;
         end Stop_Task;
      begin
         null;
      end;

      Close_If_Open (UDP_Listener);
      Close_If_Open (TCP_Listener);
      if Outcome.Failed then
         raise Unified_Server_Error with Outcome.Detail;
      end if;
   exception
      when others =>
         Request_Stop;
         Close_If_Open (UDP_Listener);
         Close_If_Open (TCP_Listener);
         raise;
   end Serve;

   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      HTTP_Endpoint        : Flyology.IO.Sockets.Endpoint;
      HTTPS_Endpoint       : Flyology.IO.Sockets.Endpoint;
      HTTPS_Origin         : Origin;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Cleartext            : Cleartext_Policy := Redirect_To_HTTPS;
      Cleartext_Capacity   : Positive := 64;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   is
      package Sockets renames Flyology.IO.Sockets;

      type Cleartext_Context is limited record
         Routes      : access Router;
         Application : access App_Context;
         Policy      : Cleartext_Policy;
         Origin      : Flyology.HTTP.Origin;
         Ingress     : access Ingress_Budget;
      end record;

      procedure Handle_Cleartext
        (State        : in out Cleartext_Context;
         Channel      : in out Flyology.IO.Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access
           Flyology.IO.Connections.Cancellation_Token)
      is
      begin
         if State.Policy = Serve_Cleartext then
            State.Routes.Serve
              (State.Application.all, Channel, Peer,
               Mode               => HTTP_1_Only,
               Timeout            => Timeout,
               Max_Connection_Age => Max_Connection_Age,
               Max_Requests       => TCP_Max_Requests,
               Token              => Cancellation,
               Header_Timeout     => Header_Timeout,
               Ingress            => State.Ingress,
               Scheme             => Plain_HTTP);
            return;
         end if;

         declare
            Transport : aliased
              Flyology.HTTP.Server.Connections.Connection_Transport
                (Channel'Access);
            HTTP_Connection : aliased Flyology.HTTP.Server.Connection
              (Transport'Access);
            Value  : Request;
            Closed : Boolean;
            Request_Timeout : constant Duration :=
              (if Max_Connection_Age < 0.0 then Timeout
               elsif Timeout < 0.0 then Max_Connection_Age
               else Duration'Min (Timeout, Max_Connection_Age));
            Head_Timeout : constant Duration :=
              (if Header_Timeout < 0.0 then Request_Timeout
               elsif Request_Timeout < 0.0 then Header_Timeout
               else Duration'Min (Header_Timeout, Request_Timeout));

            procedure Reject (Status : Positive; Message : String) is
            begin
               if not Response_Started (HTTP_Connection) then
                  begin
                     Respond
                       (HTTP_Connection, Status,
                        "text/plain; charset=utf-8",
                        Message & Character'Val (10), Close => True,
                        Timeout => Request_Timeout, Token => Cancellation);
                  exception
                     when others => null;
                  end;
               end if;
            end Reject;
         begin
            Read_Request_Head
              (HTTP_Connection, Value, Closed,
               Header_Timeout  => Head_Timeout,
               Request_Timeout => Request_Timeout,
               Max_Body        => Max_Request_Body,
               Token           => Cancellation);
            if Closed then
               return;
            end if;

            declare
               Raw_Target : constant String := Target (Value);
               Path : constant String :=
                 (if Raw_Target = "*" then "/"
                  else Raw_Path (Raw_Target) &
                    Raw_Query_Suffix (Raw_Target));
            begin
               if Path = "" or else Path (Path'First) /= '/' then
                  Respond
                    (HTTP_Connection, 400, "text/plain; charset=utf-8",
                     "bad request" & Character'Val (10), Close => True,
                     Timeout => Request_Timeout, Token => Cancellation);
               else
                  Respond
                    (HTTP_Connection, 308, "", "",
                     Extra_Headers =>
                       "Location: " & Flyology.HTTP.Image (State.Origin) &
                       Path & Character'Val (13) & Character'Val (10),
                     Close => True, Timeout => Request_Timeout,
                     Token => Cancellation);
               end if;
            end;
         exception
            when Payload_Too_Large =>
               Reject (413, "request content is too large");
            when Expectation_Failed =>
               Reject (417, "request expectation failed");
            when Protocol_Error =>
               Reject (400, "bad request");
            when Flyology.Cancellation.Operation_Cancelled |
                 Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               null;
         end;
      end Handle_Cleartext;

      package Cleartext_Servers is new Flyology.IO.Structured_Servers
        (Handler_Context => Cleartext_Context,
         Handle          => Handle_Cleartext,
         Handler_Model   => Handler_Model);

      protected Outcome is
         procedure Record_Failure (Message : String);
         function Failed return Boolean;
         function Detail return String;
      private
         Has_Failed : Boolean := False;
         Failure_Detail : Unbounded_String;
      end Outcome;

      protected body Outcome is
         procedure Record_Failure (Message : String) is
         begin
            if not Has_Failed then
               Failure_Detail := To_Unbounded_String (Message);
            end if;
            Has_Failed := True;
         end Record_Failure;

         function Failed return Boolean is (Has_Failed);
         function Detail return String is (To_String (Failure_Detail));
      end Outcome;

      HTTP_Listener : Sockets.Socket_Type;

      procedure Request_Stop is
      begin
         begin
            Token.Request;
         exception
            when others => null;
         end;
      end Request_Stop;
   begin
      if HTTP_Endpoint.Family /= HTTPS_Endpoint.Family
        or else HTTP_Endpoint.Port = Sockets.Any_Port
        or else HTTPS_Endpoint.Port = Sockets.Any_Port
        or else HTTP_Endpoint.Port = HTTPS_Endpoint.Port
      then
         raise Constraint_Error with
           "HTTP and HTTPS require distinct concrete same-family endpoints";
      elsif Scheme (HTTPS_Origin) /= Secure_HTTPS then
         raise Constraint_Error with "redirect origin must use https";
      end if;

      Sockets.Create_Socket
        (HTTP_Listener, HTTP_Endpoint.Family, Sockets.Socket_Stream);
      Sockets.Set_Socket_Option
        (HTTP_Listener, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket (HTTP_Listener, HTTP_Endpoint);
      Sockets.Listen_Socket (HTTP_Listener, Cleartext_Capacity);

      declare
         Cleartext_Manager : aliased Cleartext_Servers.Server
           (Capacity => Cleartext_Capacity);
         Shared : aliased Cleartext_Context :=
           (Routes      => Item'Unchecked_Access,
            Application => Context'Unchecked_Access,
            Policy      => Cleartext,
            Origin      => HTTPS_Origin,
            Ingress     => Ingress);

         task Cleartext_Task;
         task Secure_Task;
         task Stop_Task;

         task body Cleartext_Task is
         begin
            begin
               Cleartext_Servers.Serve
                 (Cleartext_Manager, HTTP_Listener, Shared, Drain_Timeout);
            exception
               when Error : others =>
                  Outcome.Record_Failure (Exception_Summary (Error));
                  Request_Stop;
            end;
         end Cleartext_Task;

         task body Secure_Task is
         begin
            begin
               Serve
                 (Item, Context,
                  Endpoint             => HTTPS_Endpoint,
                  TLS_Backend          => TLS_Backend,
                  Certificate_DER      => Certificate_DER,
                  Private_Key          => Private_Key,
                  TCP_Capacity         => TCP_Capacity,
                  HTTP_3_Capacity      => HTTP_3_Capacity,
                  Transport_Settings   => Transport_Settings,
                  Timeout              => Timeout,
                  Handshake_Timeout    => Handshake_Timeout,
                  Max_Connection_Age   => Max_Connection_Age,
                  TCP_Max_Requests     => TCP_Max_Requests,
                  HTTP_3_Max_Requests  => HTTP_3_Max_Requests,
                  Header_Timeout       => Header_Timeout,
                  Ingress              => Ingress,
                  Alt_Svc_Max_Age      => Alt_Svc_Max_Age,
                  Drain_Timeout        => Drain_Timeout,
                  Token                => Token,
                  Handler_Model        => Handler_Model);
            exception
               when Error : others =>
                  Outcome.Record_Failure (Exception_Summary (Error));
                  Request_Stop;
            end;
         end Secure_Task;

         task body Stop_Task is
         begin
            Token.Await_Request;
            Cleartext_Servers.Request_Shutdown (Cleartext_Manager);
         exception
            when Error : others =>
               Outcome.Record_Failure (Exception_Summary (Error));
               Request_Stop;
         end Stop_Task;
      begin
         null;
      end;

      if Outcome.Failed then
         raise Unified_Server_Error with Outcome.Detail;
      end if;
   exception
      when others =>
         Request_Stop;
         if Sockets.Is_Open (HTTP_Listener) then
            Sockets.Close_Socket (HTTP_Listener);
         end if;
         raise;
   end Serve;

   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      IPv4_HTTP_Endpoint   : Flyology.IO.Sockets.Endpoint;
      IPv6_HTTP_Endpoint   : Flyology.IO.Sockets.Endpoint;
      IPv4_HTTPS_Endpoint  : Flyology.IO.Sockets.Endpoint;
      IPv6_HTTPS_Endpoint  : Flyology.IO.Sockets.Endpoint;
      HTTPS_Origin         : Origin;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Cleartext            : Cleartext_Policy := Redirect_To_HTTPS;
      Cleartext_Capacity   : Positive := 64;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   is
      IPv4_Cleartext_Capacity : constant Positive :=
        Cleartext_Capacity / 2 + Cleartext_Capacity rem 2;
      IPv6_Cleartext_Capacity : constant Positive :=
        Cleartext_Capacity / 2;
      IPv4_TCP_Capacity : constant Positive :=
        TCP_Capacity / 2 + TCP_Capacity rem 2;
      IPv6_TCP_Capacity : constant Positive := TCP_Capacity / 2;
      IPv4_H3_Capacity : constant Positive :=
        HTTP_3_Capacity / 2 + HTTP_3_Capacity rem 2;
      IPv6_H3_Capacity : constant Positive := HTTP_3_Capacity / 2;

      protected Outcome is
         procedure Record_Failure (Message : String);
         function Failed return Boolean;
         function Detail return String;
      private
         Has_Failed : Boolean := False;
         Failure_Detail : Unbounded_String;
      end Outcome;

      protected body Outcome is
         procedure Record_Failure (Message : String) is
         begin
            if not Has_Failed then
               Failure_Detail := To_Unbounded_String (Message);
            end if;
            Has_Failed := True;
         end Record_Failure;
         function Failed return Boolean is (Has_Failed);
         function Detail return String is (To_String (Failure_Detail));
      end Outcome;

      procedure Request_Stop is
      begin
         begin
            Token.Request;
         exception
            when others => null;
         end;
      end Request_Stop;
   begin
      if IPv4_HTTP_Endpoint.Family /= Flyology.IO.Sockets.IPv4
        or else IPv6_HTTP_Endpoint.Family /= Flyology.IO.Sockets.IPv6
        or else IPv4_HTTPS_Endpoint.Family /= Flyology.IO.Sockets.IPv4
        or else IPv6_HTTPS_Endpoint.Family /= Flyology.IO.Sockets.IPv6
        or else IPv4_HTTP_Endpoint.Port = Flyology.IO.Sockets.Any_Port
        or else IPv4_HTTP_Endpoint.Port /= IPv6_HTTP_Endpoint.Port
        or else IPv4_HTTPS_Endpoint.Port = Flyology.IO.Sockets.Any_Port
        or else IPv4_HTTPS_Endpoint.Port /= IPv6_HTTPS_Endpoint.Port
        or else IPv4_HTTP_Endpoint.Port = IPv4_HTTPS_Endpoint.Port
      then
         raise Constraint_Error with
           "dual-stack HTTP and HTTPS endpoints are inconsistent";
      elsif Cleartext_Capacity < 2 or else TCP_Capacity < 2
        or else HTTP_3_Capacity < 2
      then
         raise Constraint_Error with
           "dual-stack capacity must admit each address family";
      end if;

      declare
         task IPv4_Server;
         task IPv6_Server;

         task body IPv4_Server is
         begin
            begin
               Serve
                 (Item, Context,
                  HTTP_Endpoint        => IPv4_HTTP_Endpoint,
                  HTTPS_Endpoint       => IPv4_HTTPS_Endpoint,
                  HTTPS_Origin         => HTTPS_Origin,
                  TLS_Backend          => TLS_Backend,
                  Certificate_DER      => Certificate_DER,
                  Private_Key          => Private_Key,
                  Cleartext            => Cleartext,
                  Cleartext_Capacity   => IPv4_Cleartext_Capacity,
                  TCP_Capacity         => IPv4_TCP_Capacity,
                  HTTP_3_Capacity      => IPv4_H3_Capacity,
                  Transport_Settings   => Transport_Settings,
                  Timeout              => Timeout,
                  Handshake_Timeout    => Handshake_Timeout,
                  Max_Connection_Age   => Max_Connection_Age,
                  TCP_Max_Requests     => TCP_Max_Requests,
                  HTTP_3_Max_Requests  => HTTP_3_Max_Requests,
                  Header_Timeout       => Header_Timeout,
                  Ingress              => Ingress,
                  Alt_Svc_Max_Age      => Alt_Svc_Max_Age,
                  Drain_Timeout        => Drain_Timeout,
                  Token                => Token,
                  Handler_Model        => Handler_Model);
            exception
               when Error : others =>
                  Outcome.Record_Failure (Exception_Summary (Error));
                  Request_Stop;
            end;
         end IPv4_Server;

         task body IPv6_Server is
         begin
            begin
               Serve
                 (Item, Context,
                  HTTP_Endpoint        => IPv6_HTTP_Endpoint,
                  HTTPS_Endpoint       => IPv6_HTTPS_Endpoint,
                  HTTPS_Origin         => HTTPS_Origin,
                  TLS_Backend          => TLS_Backend,
                  Certificate_DER      => Certificate_DER,
                  Private_Key          => Private_Key,
                  Cleartext            => Cleartext,
                  Cleartext_Capacity   => IPv6_Cleartext_Capacity,
                  TCP_Capacity         => IPv6_TCP_Capacity,
                  HTTP_3_Capacity      => IPv6_H3_Capacity,
                  Transport_Settings   => Transport_Settings,
                  Timeout              => Timeout,
                  Handshake_Timeout    => Handshake_Timeout,
                  Max_Connection_Age   => Max_Connection_Age,
                  TCP_Max_Requests     => TCP_Max_Requests,
                  HTTP_3_Max_Requests  => HTTP_3_Max_Requests,
                  Header_Timeout       => Header_Timeout,
                  Ingress              => Ingress,
                  Alt_Svc_Max_Age      => Alt_Svc_Max_Age,
                  Drain_Timeout        => Drain_Timeout,
                  Token                => Token,
                  Handler_Model        => Handler_Model);
            exception
               when Error : others =>
                  Outcome.Record_Failure (Exception_Summary (Error));
                  Request_Stop;
            end;
         end IPv6_Server;
      begin
         null;
      end;

      if Outcome.Failed then
         raise Unified_Server_Error with Outcome.Detail;
      end if;
   exception
      when others =>
         Request_Stop;
         raise;
   end Serve;

   procedure Serve
     (Item                 : aliased in out Router;
      Context              : aliased in out App_Context;
      IPv4_Endpoint        : Flyology.IO.Sockets.Endpoint;
      IPv6_Endpoint        : Flyology.IO.Sockets.Endpoint;
      TLS_Backend          : aliased in out
        Flyology.IO.TLS.ALPN.Provider'Class;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Flyology.QUIC.Connections.Ed25519_Private_Key;
      TCP_Capacity         : Positive := 64;
      HTTP_3_Capacity      : Positive := 128;
      Transport_Settings   : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout              : Duration := 30.0;
      Handshake_Timeout    : Duration := 10.0;
      Max_Connection_Age   : Duration := 300.0;
      TCP_Max_Requests     : Natural := 1_000;
      HTTP_3_Max_Requests  : Positive := 100_000;
      Header_Timeout       : Duration := -1.0;
      Ingress              : access Ingress_Budget := null;
      Alt_Svc_Max_Age      : Natural := 86_400;
      Drain_Timeout        : Duration := 30.0;
      Token                : not null access Flyology.Cancellation.Token;
      Handler_Model        : Flyology.Execution_Model :=
        Flyology.Project_Default)
   is
      IPv4_TCP_Capacity : constant Positive :=
        TCP_Capacity / 2 + TCP_Capacity rem 2;
      IPv6_TCP_Capacity : constant Positive := TCP_Capacity / 2;
      IPv4_H3_Capacity : constant Positive :=
        HTTP_3_Capacity / 2 + HTTP_3_Capacity rem 2;
      IPv6_H3_Capacity : constant Positive := HTTP_3_Capacity / 2;

      protected Outcome is
         procedure Record_Failure (Message : String);
         function Failed return Boolean;
         function Detail return String;
      private
         Has_Failed : Boolean := False;
         Failure_Detail : Unbounded_String;
      end Outcome;

      protected body Outcome is
         procedure Record_Failure (Message : String) is
         begin
            if not Has_Failed then
               Failure_Detail := To_Unbounded_String (Message);
            end if;
            Has_Failed := True;
         end Record_Failure;

         function Failed return Boolean is (Has_Failed);

         function Detail return String is
           (To_String (Failure_Detail));
      end Outcome;

      procedure Request_Stop is
      begin
         begin
            Token.Request;
         exception
            when others => null;
         end;
      end Request_Stop;
   begin
      if IPv4_Endpoint.Family /= Flyology.IO.Sockets.IPv4
        or else IPv6_Endpoint.Family /= Flyology.IO.Sockets.IPv6
      then
         raise Constraint_Error with
           "dual-stack endpoints must be ordered as IPv4 then IPv6";
      elsif IPv4_Endpoint.Port = Flyology.IO.Sockets.Any_Port
        or else IPv4_Endpoint.Port /= IPv6_Endpoint.Port
      then
         raise Constraint_Error with
           "dual-stack endpoints must use one concrete shared port";
      elsif TCP_Capacity < 2 or else HTTP_3_Capacity < 2 then
         raise Constraint_Error with
           "dual-stack capacity must admit each address family";
      end if;

      declare
         task IPv4_Server;
         task IPv6_Server;

         task body IPv4_Server is
         begin
            begin
               Serve
                 (Item, Context,
                  Endpoint             => IPv4_Endpoint,
                  TLS_Backend          => TLS_Backend,
                  Certificate_DER      => Certificate_DER,
                  Private_Key          => Private_Key,
                  Handler_Model        => Handler_Model,
                  TCP_Capacity         => IPv4_TCP_Capacity,
                  HTTP_3_Capacity      => IPv4_H3_Capacity,
                  Transport_Settings   => Transport_Settings,
                  Timeout              => Timeout,
                  Handshake_Timeout    => Handshake_Timeout,
                  Max_Connection_Age   => Max_Connection_Age,
                  TCP_Max_Requests     => TCP_Max_Requests,
                  HTTP_3_Max_Requests  => HTTP_3_Max_Requests,
                  Header_Timeout       => Header_Timeout,
                  Ingress              => Ingress,
                  Alt_Svc_Max_Age      => Alt_Svc_Max_Age,
                  Drain_Timeout        => Drain_Timeout,
                  Token                => Token);
            exception
               when Error : others =>
                  Outcome.Record_Failure
                    (Ada.Exceptions.Exception_Message (Error));
                  Request_Stop;
            end;
         end IPv4_Server;

         task body IPv6_Server is
         begin
            begin
               Serve
                 (Item, Context,
                  Endpoint             => IPv6_Endpoint,
                  TLS_Backend          => TLS_Backend,
                  Certificate_DER      => Certificate_DER,
                  Private_Key          => Private_Key,
                  Handler_Model        => Handler_Model,
                  TCP_Capacity         => IPv6_TCP_Capacity,
                  HTTP_3_Capacity      => IPv6_H3_Capacity,
                  Transport_Settings   => Transport_Settings,
                  Timeout              => Timeout,
                  Handshake_Timeout    => Handshake_Timeout,
                  Max_Connection_Age   => Max_Connection_Age,
                  TCP_Max_Requests     => TCP_Max_Requests,
                  HTTP_3_Max_Requests  => HTTP_3_Max_Requests,
                  Header_Timeout       => Header_Timeout,
                  Ingress              => Ingress,
                  Alt_Svc_Max_Age      => Alt_Svc_Max_Age,
                  Drain_Timeout        => Drain_Timeout,
                  Token                => Token);
            exception
               when Error : others =>
                  Outcome.Record_Failure
                    (Ada.Exceptions.Exception_Message (Error));
                  Request_Stop;
            end;
         end IPv6_Server;
      begin
         null;
      end;

      if Outcome.Failed then
         raise Unified_Server_Error with Outcome.Detail;
      end if;
   exception
      when others =>
         Request_Stop;
         raise;
   end Serve;

   procedure Serve_HTTP_3
     (Item               : in out Router;
      Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 100_000;
      Token              : access Flyology.Cancellation.Token := null)
   is
   begin
      Serve_HTTP_3
        (Item, Context, Socket, Certificate_DER, Private_Key,
         Flyology.QUIC.Connections.Random_Connection_ID,
         Transport_Settings, Timeout, Handshake_Timeout,
         Max_Connection_Age, Max_Requests, Token);
   end Serve_HTTP_3;

   procedure Serve_HTTP_3
     (Item               : in out Router;
      Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Source             : Flyology.QUIC.Connections.Connection_ID;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 100_000;
      Token              : access Flyology.Cancellation.Token := null)
   is
      procedure Dispatch_HTTP_3
        (State : in out App_Context;
         X     : in out Applications.Exchange) is
      begin
         Dispatch (Item, State, X);
      end Dispatch_HTTP_3;

      package HTTP_3_Engine is new
        Flyology.HTTP.Server.HTTP_3 (App_Context, Dispatch_HTTP_3);
   begin
      HTTP_3_Engine.Serve
        (Context, Socket, Certificate_DER, Private_Key, Source,
         Transport_Settings, Timeout, Handshake_Timeout,
         Max_Connection_Age, Max_Requests, Token);
   end Serve_HTTP_3;

   procedure Serve_HTTP_3_Listener
     (Item               : aliased in out Router;
      Context            : aliased in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Capacity           : Positive := 128;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := 100_000;
      Token              : not null access Flyology.Cancellation.Token)
   is
      procedure Dispatch_HTTP_3
        (State : in out App_Context;
         X     : in out Applications.Exchange) is
      begin
         Dispatch (Item, State, X);
      end Dispatch_HTTP_3;

      package HTTP_3_Engine is new
        Flyology.HTTP.Server.HTTP_3 (App_Context, Dispatch_HTTP_3);
   begin
      HTTP_3_Engine.Serve_Listener
        (Context, Socket, Certificate_DER, Private_Key, Capacity,
         Transport_Settings, Timeout, Handshake_Timeout,
         Max_Connection_Age, Max_Requests, Token);
   end Serve_HTTP_3_Listener;

end Flyology.HTTP.Server.Routing;
