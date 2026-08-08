package body Flyology.HTTP.HTTP_3_Header_Policy
  with SPARK_Mode => On
is
   use QPACK_Field_Section_Policy;
   use type Flyology.QUIC.Varint_Policy.Value_Type;

   subtype Content_Length_Type is Flyology.QUIC.Varint_Policy.Value_Type;

   function Is_Pseudo (Name : String) return Boolean is
     (Name'Length > 0 and then Name (Name'First) = ':');

   function Is_Token_Character (Value : Character) return Boolean is
     (Value in 'a' .. 'z'
      or else Value in '0' .. '9'
      or else Value in '!' | '#' | '$' | '%' | '&' | ''' | '*'
        | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~');

   function Is_Method_Character (Value : Character) return Boolean is
     (Is_Token_Character (Value) or else Value in 'A' .. 'Z');

   function Valid_Method (Value : String) return Boolean is
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Item of Value loop
         if not Is_Method_Character (Item) then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Method;

   function Valid_Scheme (Value : String) return Boolean is
   begin
      if Value'Length = 0
        or else Value (Value'First) not in 'a' .. 'z' | 'A' .. 'Z'
      then
         return False;
      end if;
      if Value'Length > 1 then
         for Index in Value'First + 1 .. Value'Last loop
            if Value (Index) not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
              and then Value (Index) not in '+' | '-' | '.'
            then
               return False;
            end if;
         end loop;
      end if;
      return True;
   end Valid_Scheme;

   function Valid_Name (Name : String) return Boolean is
      Start : Integer;
   begin
      if Name'Length = 0 then
         return False;
      end if;
      Start := Name'First;
      if Is_Pseudo (Name) then
         if Name'Length = 1 then
            return False;
         end if;
         Start := Start + 1;
      end if;
      for Index in Start .. Name'Last loop
         if not Is_Token_Character (Name (Index)) then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Name;

   function Valid_Value (Value : String) return Boolean is
   begin
      for Item of Value loop
         if (Character'Pos (Item) < 32 and then Item /= ASCII.HT)
           or else Item = Character'Val (127)
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Value;

   function Is_Prohibited (Name : String) return Boolean is
     (Name = "connection"
      or else Name = "proxy-connection"
      or else Name = "keep-alive"
      or else Name = "transfer-encoding"
      or else Name = "upgrade");

   function Ordinary_Status
     (Name, Value : String;
      Allow_TE    : Boolean) return Validation_Status
   is
   begin
      if Is_Prohibited (Name) then
         return Prohibited_Field;
      elsif Name = "te" and then (not Allow_TE or else Value /= "trailers") then
         return Invalid_TE;
      end if;
      return Valid;
   end Ordinary_Status;

   function Syntax_Status (Item : Header_Field) return Validation_Status is
      Name  : constant String := Field_Name (Item);
      Value : constant String := Field_Value (Item);
   begin
      if Name'Length = 0 then
         return Empty_Name;
      elsif not Valid_Name (Name) then
         return Invalid_Name;
      elsif not Valid_Value (Value) then
         return Invalid_Value;
      end if;
      return Valid;
   end Syntax_Status;

   procedure Read_Content_Length
     (Value  : String;
      Result : in out Validation_Result)
   is
      Digit : Content_Length_Type;
   begin
      if Result.Has_Content_Length or else Value'Length = 0 then
         Result.Status := Invalid_Content_Length;
         return;
      end if;
      for Item of Value loop
         if Item not in '0' .. '9' then
            Result.Status := Invalid_Content_Length;
            return;
         end if;
         Digit := Content_Length_Type
           (Character'Pos (Item) - Character'Pos ('0'));
         if Result.Content_Length >
           (Content_Length_Type'Last - Digit) / 10
         then
            Result.Status := Invalid_Content_Length;
            return;
         end if;
         Result.Content_Length := 10 * Result.Content_Length + Digit;
      end loop;
      Result.Has_Content_Length := True;
   end Read_Content_Length;

   function Contains (Value : String; Needle : Character) return Boolean is
   begin
      for Item of Value loop
         if Item = Needle then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Validate_Request
     (Block : Header_Block) return Validation_Result
   is
      Result          : Validation_Result;
      Method_Index    : Field_Count := 0;
      Scheme_Index    : Field_Count := 0;
      Authority_Index : Field_Count := 0;
      Path_Index      : Field_Count := 0;
      Host_Index      : Field_Count := 0;
      Saw_Regular     : Boolean := False;
      Status          : Validation_Status;
   begin
      for Number in 1 .. Block.Count loop
         Status := Syntax_Status (Block.Fields (Number));
         if Status /= Valid then
            Result.Status := Status;
            return Result;
         end if;
         declare
            Name  : constant String := Field_Name (Block.Fields (Number));
            Value : constant String := Field_Value (Block.Fields (Number));
         begin
            if Is_Pseudo (Name) then
               if Saw_Regular then
                  Result.Status := Pseudo_After_Regular;
                  return Result;
               elsif Name = ":method" then
                  if Method_Index /= 0 then
                     Result.Status := Duplicate_Pseudo;
                     return Result;
                  end if;
                  Method_Index := Number;
               elsif Name = ":scheme" then
                  if Scheme_Index /= 0 then
                     Result.Status := Duplicate_Pseudo;
                     return Result;
                  end if;
                  Scheme_Index := Number;
               elsif Name = ":authority" then
                  if Authority_Index /= 0 then
                     Result.Status := Duplicate_Pseudo;
                     return Result;
                  end if;
                  Authority_Index := Number;
               elsif Name = ":path" then
                  if Path_Index /= 0 then
                     Result.Status := Duplicate_Pseudo;
                     return Result;
                  end if;
                  Path_Index := Number;
               else
                  Result.Status := Unknown_Pseudo;
                  return Result;
               end if;
            else
               Saw_Regular := True;
               Status := Ordinary_Status (Name, Value, Allow_TE => True);
               if Status /= Valid then
                  Result.Status := Status;
                  return Result;
               elsif Name = "host" then
                  if Host_Index /= 0 then
                     Result.Status := Invalid_Authority;
                     return Result;
                  end if;
                  Host_Index := Number;
                  if Value'Length = 0 then
                     Result.Status := Invalid_Authority;
                     return Result;
                  end if;
               elsif Name = "content-length" then
                  Read_Content_Length (Value, Result);
                  if Result.Status /= Valid then
                     return Result;
                  end if;
               end if;
            end if;
         end;
      end loop;

      if Method_Index = 0 then
         Result.Status := Missing_Method;
         return Result;
      end if;
      declare
         Method : constant String :=
           Field_Value (Block.Fields (Method_Index));
      begin
         if not Valid_Method (Method) then
            Result.Status := Invalid_Method;
            return Result;
         elsif Method = "CONNECT" then
            Result.Is_Connect := True;
            if Scheme_Index /= 0 or else Path_Index /= 0
              or else Authority_Index = 0
            then
               Result.Status := Invalid_Connect;
               return Result;
            elsif Field_Value (Block.Fields (Authority_Index))'Length = 0 then
               Result.Status := Invalid_Authority;
               return Result;
            elsif Contains
              (Field_Value (Block.Fields (Authority_Index)), '@')
            then
               Result.Status := Invalid_Authority;
               return Result;
            elsif Host_Index /= 0
              and then Field_Value (Block.Fields (Authority_Index)) /=
                Field_Value (Block.Fields (Host_Index))
            then
               Result.Status := Authority_Mismatch;
               return Result;
            end if;
            return Result;
         end if;
      end;

      if Scheme_Index = 0 then
         Result.Status := Missing_Scheme;
         return Result;
      elsif Path_Index = 0 then
         Result.Status := Missing_Path;
         return Result;
      end if;
      declare
         Scheme : constant String := Field_Value (Block.Fields (Scheme_Index));
         Path   : constant String := Field_Value (Block.Fields (Path_Index));
         Method : constant String := Field_Value (Block.Fields (Method_Index));
      begin
         if not Valid_Scheme (Scheme) then
            Result.Status := Invalid_Scheme;
            return Result;
         elsif (Scheme = "http" or else Scheme = "https") and then Path'Length = 0
         then
            Result.Status := Invalid_Path;
            return Result;
         elsif (Scheme = "http" or else Scheme = "https")
           and then Path /= "*"
           and then Path (Path'First) /= '/'
         then
            Result.Status := Invalid_Path;
            return Result;
         elsif (Scheme = "http" or else Scheme = "https")
           and then Path = "*" and then Method /= "OPTIONS"
         then
            Result.Status := Invalid_Path;
            return Result;
         elsif Scheme = "http" or else Scheme = "https" then
            if Authority_Index = 0 and then Host_Index = 0 then
               Result.Status := Missing_Authority;
               return Result;
            elsif Authority_Index /= 0
              and then Field_Value (Block.Fields (Authority_Index))'Length = 0
            then
               Result.Status := Invalid_Authority;
               return Result;
            elsif Host_Index /= 0
              and then Field_Value (Block.Fields (Host_Index))'Length = 0
            then
               Result.Status := Invalid_Authority;
               return Result;
            elsif Authority_Index /= 0
              and then Contains
                (Field_Value (Block.Fields (Authority_Index)), '@')
            then
               Result.Status := Invalid_Authority;
               return Result;
            end if;
         end if;
      end;
      if Authority_Index /= 0 and then Host_Index /= 0
        and then Field_Value (Block.Fields (Authority_Index)) /=
          Field_Value (Block.Fields (Host_Index))
      then
         Result.Status := Authority_Mismatch;
      end if;
      return Result;
   end Validate_Request;

   function Validate_Response
     (Block : Header_Block) return Validation_Result
   is
      Result       : Validation_Result;
      Status_Index : Field_Count := 0;
      Saw_Regular  : Boolean := False;
      Status       : Validation_Status;
   begin
      for Number in 1 .. Block.Count loop
         Status := Syntax_Status (Block.Fields (Number));
         if Status /= Valid then
            Result.Status := Status;
            return Result;
         end if;
         declare
            Name  : constant String := Field_Name (Block.Fields (Number));
            Value : constant String := Field_Value (Block.Fields (Number));
         begin
            if Is_Pseudo (Name) then
               if Saw_Regular then
                  Result.Status := Pseudo_After_Regular;
                  return Result;
               elsif Name /= ":status" then
                  Result.Status := Unknown_Pseudo;
                  return Result;
               elsif Status_Index /= 0 then
                  Result.Status := Duplicate_Pseudo;
                  return Result;
               end if;
               Status_Index := Number;
            else
               Saw_Regular := True;
               Status := Ordinary_Status (Name, Value, Allow_TE => False);
               if Status /= Valid then
                  Result.Status := Status;
                  return Result;
               elsif Name = "content-length" then
                  Read_Content_Length (Value, Result);
                  if Result.Status /= Valid then
                     return Result;
                  end if;
               end if;
            end if;
         end;
      end loop;
      if Status_Index = 0 then
         Result.Status := Missing_Status;
         return Result;
      end if;
      declare
         Value : constant String := Field_Value (Block.Fields (Status_Index));
         Code  : Natural;
      begin
         if Value'Length /= 3
           or else Value (Value'First) not in '1' .. '5'
           or else Value (Value'First + 1) not in '0' .. '9'
           or else Value (Value'First + 2) not in '0' .. '9'
         then
            Result.Status := Invalid_Status;
            return Result;
         end if;
         Code :=
           100 * (Character'Pos (Value (Value'First)) - Character'Pos ('0'))
           + 10 *
             (Character'Pos (Value (Value'First + 1)) - Character'Pos ('0'))
           + (Character'Pos (Value (Value'First + 2)) - Character'Pos ('0'));
         if Code = 101 then
            Result.Status := Invalid_Status;
            return Result;
         end if;
         Result.Response_Code := Code;
         Result.Is_Interim := Code < 200;
         return Result;
      end;
   end Validate_Response;

   function Validate_Trailers
     (Block : Header_Block) return Validation_Result
   is
      Result : Validation_Result;
      Status : Validation_Status;
   begin
      for Number in 1 .. Block.Count loop
         Status := Syntax_Status (Block.Fields (Number));
         if Status /= Valid then
            Result.Status := Status;
            return Result;
         end if;
         if Field_Name (Block.Fields (Number)) = "content-length" then
            Result.Status := Invalid_Content_Length;
            return Result;
         end if;
         declare
            Name  : constant String := Field_Name (Block.Fields (Number));
            Value : constant String := Field_Value (Block.Fields (Number));
         begin
            if Is_Pseudo (Name) then
               Result.Status := Pseudo_In_Trailers;
               return Result;
            end if;
            Status := Ordinary_Status (Name, Value, Allow_TE => False);
            if Status /= Valid then
               Result.Status := Status;
               return Result;
            end if;
         end;
      end loop;
      return Result;
   end Validate_Trailers;
end Flyology.HTTP.HTTP_3_Header_Policy;
