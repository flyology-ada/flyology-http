with Ada.Characters.Handling;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Interfaces;
with Interfaces.C;
with System;
with Flyology.WebSocket_Client_Policy;
with Flyology.IO;
with Flyology.IO.Connections.TLS;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.Time_Math;

package body Flyology.HTTP.WebSocket_Client is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;

   package Policy renames Flyology.WebSocket_Client_Policy;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Policy.Header_Action;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Receive_Buffer_Size : constant Positive := 8 * 1_024;
   Send_Buffer_Size    : constant Positive := 8 * 1_024;
   Max_Target_Bytes    : constant Positive := 8 * 1_024;
   Max_Control_Frames  : constant Positive := 32;

   function Getentropy
     (Buffer : System.Address; Length : Interfaces.C.size_t)
      return Interfaces.C.int;
   pragma Import (C, Getentropy, "getentropy");

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      end if;
      return Flyology.Time_Math.Remaining
        (Timeout,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   function Bytes (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      if Value'Length > 0 then
         for Offset in 0 .. Value'Length - 1 loop
            Result
              (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos (Value (Value'First + Offset)));
         end loop;
      end if;
      return Result;
   end Bytes;

   function Text (Value : Ada.Streams.Stream_Element_Array) return String is
      Result : String (1 .. Natural (Value'Length));
      Cursor : Natural := 0;
   begin
      for Element of Value loop
         Cursor := Cursor + 1;
         Result (Cursor) := Character'Val (Element);
      end loop;
      return Result;
   end Text;

   function Is_Token (Value : String) return Boolean is
     (Value /= ""
      and then
        (for all Item of Value =>
           Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
             | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.'
             | '^' | '_' | '`' | '|' | '~'));

   function Equal_CI (Left, Right : String) return Boolean is
     (Ada.Characters.Handling.To_Lower (Left) =
        Ada.Characters.Handling.To_Lower (Right));

   function Trim_OWS (Value : String) return String is
      First : Natural := Value'First;
      Last  : Natural := Value'Last;
   begin
      while First <= Last and then Value (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Value (Last) in ' ' | Character'Val (9)
      loop
         Last := Last - 1;
      end loop;
      return Value (First .. Last);
   end Trim_OWS;

   function Is_Protocol (Value : String) return Boolean is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Value, "/");
   begin
      return
        (if Slash = 0 then Is_Token (Value)
         else Slash > Value'First
           and then Slash < Value'Last
           and then Ada.Strings.Fixed.Index
             (Value (Slash + 1 .. Value'Last), "/") = 0
           and then Is_Token (Value (Value'First .. Slash - 1))
           and then Is_Token (Value (Slash + 1 .. Value'Last)));
   end Is_Protocol;

   function Header_Has_Token
     (Fields        : Flyology.HTTP.Headers.List;
      Name, Token   : String;
      Protocol_List : Boolean := False)
      return Boolean
   is
      Found : Boolean := False;
   begin
      if Flyology.HTTP.Headers.Count (Fields, Name) = 0 then
         return False;
      end if;
      for Occurrence in 1 .. Flyology.HTTP.Headers.Count (Fields, Name) loop
         declare
            Value : constant String :=
              Flyology.HTTP.Headers.Value (Fields, Name, Occurrence);
            First : Natural := Value'First;
         begin
            if Value = "" then
               return False;
            end if;
            while First <= Value'Last loop
               declare
                  Comma : constant Natural :=
                    Ada.Strings.Fixed.Index (Value (First .. Value'Last), ",");
                  Last : constant Natural :=
                    (if Comma = 0 then Value'Last else Comma - 1);
                  Member : constant String :=
                    Trim_OWS (Value (First .. Last));
               begin
                  if (if Protocol_List then not Is_Protocol (Member)
                      else not Is_Token (Member))
                  then
                     return False;
                  elsif Equal_CI (Member, Token) then
                     Found := True;
                  end if;
                  exit when Comma = 0;
                  if Comma = Value'Last then
                     return False;
                  end if;
                  First := Comma + 1;
               end;
            end loop;
         end;
      end loop;
      return Found;
   end Header_Has_Token;

   function Valid_UTF8 (Value : String) return Boolean is
      Index : Natural := Value'First;
   begin
      while Index <= Value'Last loop
         declare
            First : constant Natural := Character'Pos (Value (Index));
            Count : Natural;
            Minimum : Natural;
            Code : Natural;
         begin
            if First <= 16#7F# then
               Count := 1;
               Minimum := 0;
               Code := First;
            elsif First in 16#C2# .. 16#DF# then
               Count := 2;
               Minimum := 16#80#;
               Code := First mod 32;
            elsif First in 16#E0# .. 16#EF# then
               Count := 3;
               Minimum := 16#800#;
               Code := First mod 16;
            elsif First in 16#F0# .. 16#F4# then
               Count := 4;
               Minimum := 16#10000#;
               Code := First mod 8;
            else
               return False;
            end if;
            if Count - 1 > Value'Last - Index then
               return False;
            end if;
            for Offset in 1 .. Count - 1 loop
               declare
                  Next : constant Natural :=
                    Character'Pos (Value (Index + Offset));
               begin
                  if Next not in 16#80# .. 16#BF# then
                     return False;
                  end if;
                  Code := Code * 64 + Next mod 64;
               end;
            end loop;
            if Code < Minimum
              or else Code in 16#D800# .. 16#DFFF#
              or else Code > 16#10FFFF#
            then
               return False;
            end if;
            Index := Index + Count;
         end;
      end loop;
      return True;
   end Valid_UTF8;

   subtype Word is Interfaces.Unsigned_32;
   type Word_Array is array (Natural range <>) of Word;
   type Octet_Array is array (Natural range <>) of Interfaces.Unsigned_8;

   function Rotate_Left (Value : Word; Amount : Natural) return Word is
     (Interfaces.Shift_Left (Value, Amount)
      or Interfaces.Shift_Right (Value, 32 - Amount));

   function SHA1 (Value : String) return String is
      Padded_Length : constant Natural := ((Value'Length + 9 + 63) / 64) * 64;
      Data : Octet_Array (0 .. Padded_Length - 1) := (others => 0);
      Bits : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Value'Length) * 8;
      H0 : Word := 16#67452301#;
      H1 : Word := 16#EFCDAB89#;
      H2 : Word := 16#98BADCFE#;
      H3 : Word := 16#10325476#;
      H4 : Word := 16#C3D2E1F0#;
   begin
      for Index in Value'Range loop
         Data (Index - Value'First) :=
           Interfaces.Unsigned_8 (Character'Pos (Value (Index)));
      end loop;
      Data (Value'Length) := 16#80#;
      for Offset in 0 .. 7 loop
         Data (Padded_Length - 1 - Offset) := Interfaces.Unsigned_8
           (Interfaces.Shift_Right (Bits, Offset * 8) and 16#FF#);
      end loop;
      for Block in 0 .. Padded_Length / 64 - 1 loop
         declare
            W : Word_Array (0 .. 79) := (others => 0);
            A : Word := H0;
            B : Word := H1;
            C : Word := H2;
            D : Word := H3;
            E : Word := H4;
         begin
            for Index in 0 .. 15 loop
               declare
                  Base : constant Natural := Block * 64 + Index * 4;
               begin
                  W (Index) :=
                    Interfaces.Shift_Left (Word (Data (Base)), 24)
                    or Interfaces.Shift_Left (Word (Data (Base + 1)), 16)
                    or Interfaces.Shift_Left (Word (Data (Base + 2)), 8)
                    or Word (Data (Base + 3));
               end;
            end loop;
            for Index in 16 .. 79 loop
               W (Index) := Rotate_Left
                 (W (Index - 3) xor W (Index - 8) xor W (Index - 14)
                  xor W (Index - 16), 1);
            end loop;
            for Index in 0 .. 79 loop
               declare
                  F : Word;
                  K : Word;
                  Temp : Word;
               begin
                  if Index <= 19 then
                     F := (B and C) or ((not B) and D);
                     K := 16#5A827999#;
                  elsif Index <= 39 then
                     F := B xor C xor D;
                     K := 16#6ED9EBA1#;
                  elsif Index <= 59 then
                     F := (B and C) or (B and D) or (C and D);
                     K := 16#8F1BBCDC#;
                  else
                     F := B xor C xor D;
                     K := 16#CA62C1D6#;
                  end if;
                  Temp := Rotate_Left (A, 5) + F + E + K + W (Index);
                  E := D;
                  D := C;
                  C := Rotate_Left (B, 30);
                  B := A;
                  A := Temp;
               end;
            end loop;
            H0 := H0 + A;
            H1 := H1 + B;
            H2 := H2 + C;
            H3 := H3 + D;
            H4 := H4 + E;
         end;
      end loop;
      declare
         Hash : constant Word_Array (0 .. 4) := (H0, H1, H2, H3, H4);
         Result : String (1 .. 20);
      begin
         for Index in Hash'Range loop
            for Offset in 0 .. 3 loop
               Result (Index * 4 + Offset + 1) := Character'Val
                 (Interfaces.Shift_Right (Hash (Index), (3 - Offset) * 8)
                  and 16#FF#);
            end loop;
         end loop;
         return Result;
      end;
   end SHA1;

   function Base64 (Value : String) return String is
      Alphabet : constant String :=
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      Result : String (1 .. 4 * ((Value'Length + 2) / 3));
      Input  : Natural := Value'First;
      Output : Natural := Result'First;
   begin
      while Input <= Value'Last loop
         declare
            Left : constant Natural := Value'Last - Input + 1;
            A : constant Natural := Character'Pos (Value (Input));
            B : constant Natural :=
              (if Left >= 2 then Character'Pos (Value (Input + 1)) else 0);
            C : constant Natural :=
              (if Left >= 3 then Character'Pos (Value (Input + 2)) else 0);
         begin
            Result (Output) := Alphabet (A / 4 + 1);
            Result (Output + 1) := Alphabet ((A mod 4) * 16 + B / 16 + 1);
            Result (Output + 2) :=
              (if Left >= 2 then Alphabet ((B mod 16) * 4 + C / 64 + 1)
               else '=');
            Result (Output + 3) :=
              (if Left >= 3 then Alphabet (C mod 64 + 1) else '=');
            Input := Input + 3;
            Output := Output + 4;
         end;
      end loop;
      return Result;
   end Base64;

   procedure Random_Bytes (Data : out Ada.Streams.Stream_Element_Array) is
   begin
      if Data'Length > 0
        and then Getentropy
          (Data'Address, Interfaces.C.size_t (Data'Length)) /= 0
      then
         raise Connection_Error with
           "operating-system entropy unavailable for WebSocket masking";
      end if;
   end Random_Bytes;

   function Host_Field (Value : Origin) return String is
      Host_Value : constant String := Host (Value);
      Authority : constant String :=
        (if Ada.Strings.Fixed.Index (Host_Value, ":") = 0 then Host_Value
         else "[" & Host_Value & "]");
      Default_Port : constant Boolean :=
        (Scheme (Value) = Plain_HTTP and then Port (Value) = 80)
        or else (Scheme (Value) = Secure_HTTPS and then Port (Value) = 443);
      Port_Image : constant String := Port_Number'Image (Port (Value));
   begin
      return Authority &
        (if Default_Port then ""
         else ":" & Port_Image (Port_Image'First + 1 .. Port_Image'Last));
   end Host_Field;

   procedure Set_Target (Item : in out Request; Value : String) is
   begin
      if Value'Length = 0
        or else Value'Length > Max_Target_Bytes
        or else Value (Value'First) /= '/'
        or else (for some Character_Value of Value =>
                   Character_Value = ' '
                     or else Character_Value = '#'
                     or else Character'Pos (Character_Value) < 33
                     or else Character'Pos (Character_Value) > 126)
      then
         raise Constraint_Error with "invalid WebSocket request target";
      end if;
      Item.Target := To_Unbounded_String (Value);
   end Set_Target;

   procedure Set_Origin (Item : in out Request; Value : String) is
      Check : Flyology.HTTP.Headers.List (Capacity => 1, Max_Bytes => 16_384);
   begin
      if Value /= "" then
         Flyology.HTTP.Headers.Add (Check, "Origin", Value);
      end if;
      Item.Origin := To_Unbounded_String (Value);
   exception
      when Flyology.HTTP.Headers.Headers_Too_Large =>
         raise Constraint_Error with "WebSocket Origin is too large";
   end Set_Origin;

   procedure Offer_Protocol (Item : in out Request; Value : String) is
      Separator_Bytes : constant Natural :=
        (if Item.Last_Protocol = 0 then 0 else 2);
      Added_Bytes : constant Long_Long_Integer :=
        Long_Long_Integer (Value'Length) +
        Long_Long_Integer (Separator_Bytes);
   begin
      if Value'Length > Max_Protocol_Length or else not Is_Token (Value) then
         raise Constraint_Error with "invalid WebSocket subprotocol";
      end if;
      for Index in 1 .. Item.Last_Protocol loop
         if To_String (Item.Protocols (Index)) = Value then
            raise Constraint_Error with "repeated WebSocket subprotocol";
         end if;
      end loop;
      if Item.Last_Protocol = Protocol_Count'Last then
         raise Constraint_Error with "too many WebSocket subprotocols";
      elsif Added_Bytes > Long_Long_Integer
        (Max_Protocol_Offer_Bytes - Item.Protocol_Bytes)
      then
         raise Constraint_Error with
           "WebSocket subprotocol offers are too large";
      end if;
      Item.Last_Protocol := Item.Last_Protocol + 1;
      Item.Protocols (Item.Last_Protocol) := To_Unbounded_String (Value);
      Item.Protocol_Bytes := Item.Protocol_Bytes + Natural (Added_Bytes);
   end Offer_Protocol;

   procedure Add_Header
     (Item : in out Request; Name : String; Value : String)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      if Lower in "host" | "connection" | "upgrade" | "content-length"
        | "transfer-encoding" | "expect" | "origin"
        or else (Lower'Length >= 14
                 and then Lower (Lower'First .. Lower'First + 13) =
                   "sec-websocket-")
      then
         raise Constraint_Error with "client-controlled WebSocket field";
      end if;
      Flyology.HTTP.Headers.Add (Item.Fields, Name, Value);
   end Add_Header;

   procedure Configure (Item : in out Client; Origin_Value : Origin) is
   begin
      if Item.Phase /= Unconfigured then
         raise Program_Error with "WebSocket client is already configured";
      elsif Scheme (Origin_Value) = Secure_HTTPS then
         raise Program_Error with "wss requires a retained TLS provider";
      end if;
      Item.Origin_Value := Origin_Value;
      Item.Phase := Inactive;
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class)
   is
      Retained : Flyology.IO.TLS.Provider_Access;
   begin
      if Item.Phase /= Unconfigured then
         raise Program_Error with "WebSocket client is already configured";
      end if;
      Retained := Flyology.IO.TLS.Retain (Backend.all);
      Item.Backend := Retained;
      Item.Origin_Value := Origin_Value;
      Item.Phase := Inactive;
   end Configure;

   procedure Drop_Transport (Item : in out Client) is
   begin
      if Connections.Is_Open (Item.Channel) then
         begin
            Connections.Close (Item.Channel);
         exception
            when others => null;
         end;
      end if;
      Item.Phase := Closed;
      Item.Pending := Null_Unbounded_String;
   end Drop_Transport;

   procedure Complete_Transport
     (Item    : in out Client;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      if Scheme (Item.Origin_Value) = Secure_HTTPS then
         Flyology.IO.Connections.TLS.Shutdown
           (Item.Channel, Remaining (Started, Timeout), Token);
      end if;
      Drop_Transport (Item);
   exception
      when others =>
         Drop_Transport (Item);
         raise;
   end Complete_Transport;

   procedure Establish
     (Item    : in out Client;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Socket : Sockets.Socket_Type;
      Connected : Boolean := False;
      Interrupt : Flyology.IO.Interrupt_Set (1 .. 1);
      Interrupt_Count : Natural := 0;

      procedure Prepare_Interrupt is
         Requested : Boolean := False;
      begin
         Interrupt_Count := 0;
         if Token /= null then
            Token.Wait_Source (Interrupt (1), Requested);
            if Requested then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            Interrupt_Count := 1;
         end if;
      end Prepare_Interrupt;
   begin
      Prepare_Interrupt;
      declare
         Addresses : constant Flyology.IO.DNS.Address_Array :=
           Flyology.IO.DNS.Resolve
             (Host (Item.Origin_Value),
              Timeout => Remaining (Started, Timeout),
              Interrupts => Interrupt (1 .. Interrupt_Count));
      begin
         for Address of Addresses loop
            begin
               Sockets.Create_Socket (Socket, Address.Family);
               Prepare_Interrupt;
               Sockets.Connect
                 (Socket,
                  Sockets.Network_Endpoint
                    (Address, Sockets.Port (Port (Item.Origin_Value))),
                  Remaining (Started, Timeout),
                  Interrupt (1 .. Interrupt_Count));
               Connected := True;
            exception
               when Sockets.Operation_Interrupted =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
                  raise Flyology.Cancellation.Operation_Cancelled;
               when Flyology.IO.Timeout_Error =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
                  raise;
               when Sockets.Socket_Error | Flyology.IO.Device_Error =>
                  if Sockets.Is_Open (Socket) then
                     begin
                        Sockets.Close_Socket (Socket);
                     exception
                        when others => null;
                     end;
                  end if;
            end;
            exit when Connected;
         end loop;
      end;
      if not Connected then
         raise Connection_Error with "all resolved WebSocket endpoints failed";
      end if;
      Connections.Take (Item.Manager, Socket, Item.Channel);
      if Scheme (Item.Origin_Value) = Secure_HTTPS then
         Flyology.IO.Connections.TLS.Upgrade
           (Item.Channel, Item.Backend.all, Flyology.IO.TLS.Client,
            Host (Item.Origin_Value), Remaining (Started, Timeout), Token);
      end if;
   exception
      when Flyology.IO.DNS.Operation_Cancelled =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise Flyology.Cancellation.Operation_Cancelled;
      when Flyology.IO.DNS.Name_Not_Found |
           Flyology.IO.DNS.Resolution_Failed |
           Flyology.IO.DNS.Malformed_Response =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise Connection_Error with "WebSocket origin resolution failed";
      when others =>
         if Sockets.Is_Open (Socket) then
            begin
               Sockets.Close_Socket (Socket);
            exception
               when others => null;
            end;
         end if;
         if Connections.Is_Open (Item.Channel) then
            begin
               Connections.Close (Item.Channel);
            exception
               when others => null;
            end;
         end if;
         raise;
   end Establish;

   procedure Receive_More
     (Item    : in out Client;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Buffer : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Connections.Receive
        (Item.Channel, Buffer, Last, Remaining (Started, Timeout),
         Token => Token);
      if Last < Buffer'First then
         raise Protocol_Error with
           "peer closed WebSocket transport without a close frame";
      end if;
      Append (Item.Pending, Text (Buffer (Buffer'First .. Last)));
   end Receive_More;

   procedure Ensure
     (Item    : in out Client;
      Count   : Natural;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
   begin
      while Length (Item.Pending) < Count loop
         Receive_More (Item, Started, Timeout, Token);
      end loop;
   end Ensure;

   procedure Consume (Item : in out Client; Count : Natural) is
   begin
      if Count = 0 then
         return;
      elsif Count = Length (Item.Pending) then
         Item.Pending := Null_Unbounded_String;
      else
         Delete (Item.Pending, 1, Count);
      end if;
   end Consume;

   procedure Parse_Response_Head (Item : in out Client; Head : String) is
      Line_End : Natural := Ada.Strings.Fixed.Index (Head, CRLF);
      Cursor : Natural;
   begin
      if Line_End = 0 then
         raise Protocol_Error with "malformed WebSocket response status";
      end if;
      declare
         Status_Line : constant String := Head (Head'First .. Line_End - 1);
      begin
         if Status_Line'Length < 13
           or else Status_Line
             (Status_Line'First .. Status_Line'First + 11) /= "HTTP/1.1 101"
           or else Status_Line (Status_Line'First + 12) /= ' '
         then
            raise Protocol_Error with
              "WebSocket upgrade did not return HTTP/1.1 101";
         elsif Status_Line'Length > 13
           and then
             (for some Index in Status_Line'First + 13 .. Status_Line'Last =>
                (Character'Pos (Status_Line (Index)) < 32
                   and then Status_Line (Index) /= Character'Val (9))
                  or else Character'Pos (Status_Line (Index)) = 127)
         then
            raise Protocol_Error with
              "invalid WebSocket upgrade response reason phrase";
         end if;
      end;
      Cursor := Line_End + 2;
      while Cursor <= Head'Last loop
         Line_End :=
           Ada.Strings.Fixed.Index (Head (Cursor .. Head'Last), CRLF);
         exit when Line_End = Cursor;
         if Line_End = 0 or else Head (Cursor) in ' ' | Character'Val (9) then
            raise Protocol_Error with "malformed WebSocket response field";
         end if;
         declare
            Colon : constant Natural :=
              Ada.Strings.Fixed.Index (Head (Cursor .. Line_End - 1), ":");
         begin
            if Colon = 0 then
               raise Protocol_Error with "malformed WebSocket response field";
            end if;
            Flyology.HTTP.Headers.Add
              (Item.Fields,
               Head (Cursor .. Colon - 1),
               Trim_OWS (Head (Colon + 1 .. Line_End - 1)));
         exception
            when Constraint_Error | Flyology.HTTP.Headers.Headers_Too_Large =>
               raise Protocol_Error with
                 "invalid or oversized WebSocket response head";
         end;
         Cursor := Line_End + 2;
      end loop;
   end Parse_Response_Head;

   function Offered (Value : Request; Protocol : String) return Boolean is
   begin
      for Index in 1 .. Value.Last_Protocol loop
         if To_String (Value.Protocols (Index)) = Protocol then
            return True;
         end if;
      end loop;
      return False;
   end Offered;

   procedure Validate_Handshake
     (Item : in out Client; Value : Request; Expected_Accept : String)
   is
      Selected : constant String :=
        Flyology.HTTP.Headers.Value (Item.Fields, "Sec-WebSocket-Protocol");
   begin
      if not Header_Has_Token
        (Item.Fields, "Upgrade", "websocket", Protocol_List => True)
        or else not Header_Has_Token (Item.Fields, "Connection", "upgrade")
        or else Flyology.HTTP.Headers.Count
          (Item.Fields, "Sec-WebSocket-Accept") /= 1
        or else Trim_OWS
          (Flyology.HTTP.Headers.Value
             (Item.Fields, "Sec-WebSocket-Accept")) /= Expected_Accept
      then
         raise Protocol_Error with "invalid WebSocket upgrade response";
      elsif Flyology.HTTP.Headers.Count (Item.Fields, "Content-Length") /= 0
        or else Flyology.HTTP.Headers.Count
          (Item.Fields, "Transfer-Encoding") /= 0
      then
         raise Protocol_Error with
           "invalid framing on WebSocket upgrade response";
      elsif Flyology.HTTP.Headers.Count
        (Item.Fields, "Sec-WebSocket-Extensions") /= 0
      then
         raise Protocol_Error with
           "server selected an unoffered WebSocket extension";
      elsif Flyology.HTTP.Headers.Count
        (Item.Fields, "Sec-WebSocket-Protocol") > 1
        or else
          (Flyology.HTTP.Headers.Count
             (Item.Fields, "Sec-WebSocket-Protocol") = 1
           and then (Selected = "" or else not Offered (Value, Selected)))
      then
         raise Protocol_Error with
           "server selected an unoffered WebSocket subprotocol";
      end if;
      Item.Protocol_Value := To_Unbounded_String (Selected);
   end Validate_Handshake;

   procedure Connect
     (Item    : in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Nonce : Ada.Streams.Stream_Element_Array (1 .. 16);
      Key : Unbounded_String;
      Request_Head : Unbounded_String;
   begin
      if Item.Phase = Unconfigured then
         raise Program_Error with "WebSocket client is not configured";
      elsif Item.Phase not in Inactive | Closed then
         raise Program_Error with "WebSocket client already has a session";
      end if;
      Item.Phase := Connecting;
      Flyology.HTTP.Headers.Clear (Item.Fields);
      Item.Pending := Null_Unbounded_String;
      Item.Protocol_Value := Null_Unbounded_String;
      Item.Peer_Close_Received := False;
      Item.Peer_Close_Code := 1_005;
      Item.Peer_Close_Reason := Null_Unbounded_String;
      Item.Handshake_Complete := False;
      begin
         Random_Bytes (Nonce);
         Key := To_Unbounded_String (Base64 (Text (Nonce)));
         Append
           (Request_Head,
            "GET " & To_String (Value.Target) & " HTTP/1.1" & CRLF
            & "Host: " & Host_Field (Item.Origin_Value) & CRLF
            & "Upgrade: websocket" & CRLF
            & "Connection: Upgrade" & CRLF
            & "Sec-WebSocket-Key: " & To_String (Key) & CRLF
            & "Sec-WebSocket-Version: 13" & CRLF);
         if Value.Origin /= Null_Unbounded_String then
            Append
              (Request_Head, "Origin: " & To_String (Value.Origin) & CRLF);
         end if;
         if Value.Last_Protocol > 0 then
            Append (Request_Head, "Sec-WebSocket-Protocol: ");
            for Index in 1 .. Value.Last_Protocol loop
               if Index > 1 then
                  Append (Request_Head, ", ");
               end if;
               Append (Request_Head, Value.Protocols (Index));
            end loop;
            Append (Request_Head, CRLF);
         end if;
         for Index in 1 .. Flyology.HTTP.Headers.Count (Value.Fields) loop
            Append
              (Request_Head,
               Flyology.HTTP.Headers.Name (Value.Fields, Index) & ": "
               & Flyology.HTTP.Headers.Value (Value.Fields, Index) & CRLF);
         end loop;
         Append (Request_Head, CRLF);
         if Length (Request_Head) > Max_Handshake_Bytes then
            raise Constraint_Error with
              "WebSocket handshake request is too large";
         end if;
         Establish (Item, Started, Timeout, Token);
         Connections.Send_All
           (Item.Channel, Bytes (To_String (Request_Head)),
            Remaining (Started, Timeout), Token => Token);
         loop
            declare
               End_Of_Head : constant Natural := Ada.Strings.Fixed.Index
                 (To_String (Item.Pending), CRLF & CRLF);
            begin
               if End_Of_Head /= 0 then
                  declare
                     Complete : constant String := To_String (Item.Pending);
                     Last : constant Natural := End_Of_Head + 3;
                  begin
                     Parse_Response_Head
                       (Item, Complete (Complete'First .. Last));
                     Consume (Item, Last);
                  end;
                  exit;
               elsif Length (Item.Pending) >=
                 Flyology.HTTP.Headers.Default_Max_Bytes
               then
                  raise Protocol_Error with
                    "WebSocket response head is too large";
               end if;
               Receive_More (Item, Started, Timeout, Token);
            end;
         end loop;
         Validate_Handshake
           (Item, Value, Base64 (SHA1 (To_String (Key) & GUID)));
         Item.Handshake_Complete := True;
         Item.Phase := Open;
      exception
         when others =>
            Drop_Transport (Item);
            raise;
      end;
   end Connect;

   function Is_Open (Item : Client) return Boolean is (Item.Phase = Open);

   procedure Require_Handshake (Item : Client) is
   begin
      if Item.Phase not in Open | Close_Pending | Closed
        or else not Item.Handshake_Complete
      then
         raise Program_Error with "WebSocket handshake is unavailable";
      end if;
   end Require_Handshake;

   function Negotiated_Protocol (Item : Client) return String is
   begin
      Require_Handshake (Item);
      return To_String (Item.Protocol_Value);
   end Negotiated_Protocol;

   function Header_Count (Item : Client) return Natural is
   begin
      Require_Handshake (Item);
      return Flyology.HTTP.Headers.Count (Item.Fields);
   end Header_Count;

   function Header_Count (Item : Client; Name : String) return Natural is
   begin
      Require_Handshake (Item);
      return Flyology.HTTP.Headers.Count (Item.Fields, Name);
   end Header_Count;

   function Header_Name (Item : Client; Index : Positive) return String is
   begin
      Require_Handshake (Item);
      return Flyology.HTTP.Headers.Name (Item.Fields, Index);
   end Header_Name;

   function Header_Value (Item : Client; Index : Positive) return String is
   begin
      Require_Handshake (Item);
      return Flyology.HTTP.Headers.Value (Item.Fields, Index);
   end Header_Value;

   function Header
     (Item : Client; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      Require_Handshake (Item);
      return Flyology.HTTP.Headers.Value (Item.Fields, Name, Occurrence);
   end Header;

   procedure Send_Frame
     (Item    : in out Client;
      Opcode  : Natural;
      Data    : Ada.Streams.Stream_Element_Array;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Length : constant Policy.Frame_Length :=
        Policy.Frame_Length (Data'Length);
      Form : constant Policy.Length_Form := Policy.Form_For (Length);
      Header_Length : constant Positive :=
        (case Form is
           when Policy.Short_Length => 6,
           when Policy.Medium_Length => 8,
           when Policy.Long_Length => 14);
      Header : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Header_Length));
      Mask : Ada.Streams.Stream_Element_Array (1 .. 4);
      Cursor : Natural;
      Offset : Natural := 0;
   begin
      Random_Bytes (Mask);
      Header (1) := Ada.Streams.Stream_Element (16#80# + Opcode);
      case Form is
         when Policy.Short_Length =>
            Header (2) := Ada.Streams.Stream_Element (16#80# + Length);
            Cursor := 3;
         when Policy.Medium_Length =>
            Header (2) := 16#80# + 126;
            Header (3) := Ada.Streams.Stream_Element (Length / 256);
            Header (4) := Ada.Streams.Stream_Element (Length mod 256);
            Cursor := 5;
         when Policy.Long_Length =>
            Header (2) := 16#80# + 127;
            for Index in 0 .. 7 loop
               Header (3 + Ada.Streams.Stream_Element_Offset (Index)) :=
                 Ada.Streams.Stream_Element
                   (Interfaces.Shift_Right
                      (Interfaces.Unsigned_64 (Length), (7 - Index) * 8)
                    and 16#FF#);
            end loop;
            Cursor := 11;
      end case;
      for Index in Mask'Range loop
         Header (Ada.Streams.Stream_Element_Offset (Cursor)) := Mask (Index);
         Cursor := Cursor + 1;
      end loop;
      Connections.Send_All
        (Item.Channel, Header, Remaining (Started, Timeout), Token => Token);
      while Offset < Natural (Data'Length) loop
         declare
            Count : constant Natural :=
              Natural'Min (Send_Buffer_Size, Natural (Data'Length) - Offset);
            Chunk : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Count));
         begin
            for Index in 0 .. Count - 1 loop
               Chunk
                 (Chunk'First + Ada.Streams.Stream_Element_Offset (Index)) :=
                   Data
                     (Data'First + Ada.Streams.Stream_Element_Offset
                        (Offset + Index))
                   xor Mask
                     (1 + Ada.Streams.Stream_Element_Offset
                        ((Offset + Index) mod 4));
            end loop;
            Connections.Send_All
              (Item.Channel, Chunk, Remaining (Started, Timeout),
               Token => Token);
            Offset := Offset + Count;
         end;
      end loop;
   exception
      when others =>
         Drop_Transport (Item);
         raise;
   end Send_Frame;

   procedure Send
     (Item    : in out Client;
      Kind    : Data_Kind;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
   begin
      if Item.Phase /= Open then
         raise Program_Error with "WebSocket connection is not open";
      elsif Data'Length > Max_Frame_Length then
         raise Constraint_Error with "WebSocket frame is too large";
      elsif Kind = Text_Message and then not Valid_UTF8 (Text (Data)) then
         raise Constraint_Error with "WebSocket text must contain valid UTF-8";
      end if;
      Send_Frame
        (Item, (if Kind = Text_Message then 1 else 2), Data,
         Ada.Real_Time.Clock, Timeout, Token);
   end Send;

   procedure Send
     (Item    : in out Client;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      if Item.Phase /= Open then
         raise Program_Error with "WebSocket connection is not open";
      elsif Data'Length > Max_Frame_Length then
         raise Constraint_Error with "WebSocket frame is too large";
      elsif not Valid_UTF8 (Data) then
         raise Constraint_Error with "WebSocket text must contain valid UTF-8";
      end if;
      Send_Frame
        (Item, 1, Bytes (Data), Ada.Real_Time.Clock, Timeout, Token);
   end Send;

   procedure Read_Frame_Payload
     (Item    : in out Client;
      Length  : Natural;
      Target  : in out Flyology.Bytes.Unbounded_Bytes;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      Left : Natural := Length;
   begin
      while Left > 0 loop
         if Ada.Strings.Unbounded.Length (Item.Pending) = 0 then
            Receive_More (Item, Started, Timeout, Token);
         end if;
         declare
            Count : constant Natural := Natural'Min
              (Left, Ada.Strings.Unbounded.Length (Item.Pending));
            Value : constant String := Slice (Item.Pending, 1, Count);
         begin
            Flyology.Bytes.Append (Target, Bytes (Value));
            Consume (Item, Count);
            Left := Left - Count;
         end;
      end loop;
   end Read_Frame_Payload;

   procedure Read_Header
     (Item        : in out Client;
      Opcode      : out Natural;
      Final       : out Boolean;
      Frame_Size  : out Policy.Frame_Length;
      Started     : Ada.Real_Time.Time;
      Timeout     : Duration;
      Token       : access Flyology.Cancellation.Token)
   is
      Length_Code : Natural;
      Length_Value : Interfaces.Unsigned_64;
      Extra : Natural;
      Action : Policy.Header_Action;
   begin
      Ensure (Item, 2, Started, Timeout, Token);
      declare
         Head : constant String := Slice (Item.Pending, 1, 2);
         First : constant Ada.Streams.Stream_Element :=
           Ada.Streams.Stream_Element (Character'Pos (Head (1)));
         Second : constant Ada.Streams.Stream_Element :=
           Ada.Streams.Stream_Element (Character'Pos (Head (2)));
      begin
         Final := (First and 16#80#) /= 0;
         Opcode := Natural (First and 16#0F#);
         Length_Code := Natural (Second and 16#7F#);
         Extra := (if Length_Code <= 125 then 0
                   elsif Length_Code = 126 then 2 else 8);
         Ensure (Item, 2 + Extra, Started, Timeout, Token);
         if Extra = 0 then
            Length_Value := Interfaces.Unsigned_64 (Length_Code);
         else
            Length_Value := 0;
            declare
               Header : constant String := Slice (Item.Pending, 3, 2 + Extra);
            begin
               for Character_Value of Header loop
                  Length_Value := Interfaces.Shift_Left (Length_Value, 8)
                    or Interfaces.Unsigned_64
                      (Character'Pos (Character_Value));
               end loop;
            end;
         end if;
         Action := Policy.Validate_Header
           (Reserved_Bits => (First and 16#70#) /= 0,
            Masked        => (Second and 16#80#) /= 0,
            Opcode        => Opcode,
            Final         => Final,
            Length_Code   => Length_Code,
            Length        =>
              (if Length_Value >
                    Interfaces.Unsigned_64 (Long_Long_Integer'Last)
               then Long_Long_Integer'Last
               else Long_Long_Integer (Length_Value)));
      end;
      if Action /= Policy.Accept_Header then
         raise Protocol_Error with
           "invalid WebSocket server frame: "
           & Policy.Header_Action'Image (Action);
      end if;
      Frame_Size := Policy.Frame_Length (Length_Value);
      Consume (Item, 2 + Extra);
   end Read_Header;

   procedure Receive
     (Item        : in out Client;
      Kind        : out Data_Kind;
      Data        : out Flyology.Bytes.Unbounded_Bytes;
      Closed      : out Boolean;
      Max_Message : Natural := Default_Max_Message;
      Timeout     : Duration := 30.0;
      Token       : access Flyology.Cancellation.Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Maximum : Policy.Frame_Length;
      Fragmented : Boolean := False;
      Message_Kind : Data_Kind := Text_Message;
      Control_Count : Natural := 0;
   begin
      Kind := Text_Message;
      Flyology.Bytes.Clear (Data);
      Closed := False;
      if Item.Phase not in Open | Close_Pending then
         raise Program_Error with "WebSocket connection is not active";
      elsif Max_Message > Max_Frame_Length then
         raise Constraint_Error with "WebSocket message bound is too large";
      end if;
      Maximum := Policy.Frame_Length (Max_Message);
      loop
         declare
            Opcode : Natural;
            Final : Boolean;
            Frame_Size : Policy.Frame_Length;
            Payload : Flyology.Bytes.Unbounded_Bytes;
         begin
            Read_Header
              (Item, Opcode, Final, Frame_Size, Started, Timeout, Token);
            if Opcode <= 2 then
               declare
                  Action : constant Policy.Data_Action := Policy.Classify_Data
                    (Opcode, Fragmented,
                     Policy.Frame_Length (Flyology.Bytes.Length (Data)),
                     Frame_Size, Maximum);
               begin
                  case Action is
                     when Policy.Begin_Text => Message_Kind := Text_Message;
                     when Policy.Begin_Binary =>
                        Message_Kind := Binary_Message;
                     when Policy.Continue_Message => null;
                     when Policy.Reject_Message_Too_Large =>
                        raise Message_Too_Large;
                     when others =>
                        raise Protocol_Error with
                          "invalid WebSocket fragmentation sequence";
                  end case;
               end;
               Read_Frame_Payload
                 (Item, Frame_Size, Data, Started, Timeout, Token);
               Fragmented := not Final;
               if Final then
                  if Message_Kind = Text_Message
                    and then not Valid_UTF8
                      (Flyology.Bytes.To_Byte_String (Data))
                  then
                     raise Protocol_Error with "invalid UTF-8 WebSocket text";
                  end if;
                  Kind := Message_Kind;
                  return;
               end if;
            else
               Control_Count := Control_Count + 1;
               if Control_Count > Max_Control_Frames then
                  raise Protocol_Error with
                    "too many WebSocket control frames";
               end if;
               Read_Frame_Payload
                 (Item, Frame_Size, Payload, Started, Timeout, Token);
               if Opcode = 9 then
                  Send_Frame
                    (Item, 10, Flyology.Bytes.To_Array (Payload),
                     Started, Timeout, Token);
               elsif Opcode = 8 then
                  declare
                     Value : constant String :=
                       Flyology.Bytes.To_Byte_String (Payload);
                     Code : Natural := 1_005;
                  begin
                     if Value'Length = 1 then
                        raise Protocol_Error with
                          "invalid WebSocket close payload";
                     elsif Value'Length >= 2 then
                        Code := Character'Pos (Value (Value'First)) * 256
                          + Character'Pos (Value (Value'First + 1));
                        if not Policy.Valid_Close_Code (Code) then
                           raise Protocol_Error with
                             "invalid WebSocket close code";
                        end if;
                        declare
                           Tail : constant String :=
                             Value (Value'First + 2 .. Value'Last);
                        begin
                           if not Valid_UTF8 (Tail) then
                              raise Protocol_Error with
                                "invalid UTF-8 WebSocket close reason";
                           end if;
                           Item.Peer_Close_Reason :=
                             To_Unbounded_String (Tail);
                        end;
                     end if;
                     Item.Peer_Close_Code := Code;
                     Item.Peer_Close_Received := True;
                     if Item.Phase = Open then
                        Send_Frame
                          (Item, 8, Flyology.Bytes.To_Array (Payload),
                           Started, Timeout, Token);
                     end if;
                     Complete_Transport
                       (Item, Started, Timeout, Token);
                     Kind := Text_Message;
                     Flyology.Bytes.Clear (Data);
                     Closed := True;
                     return;
                  end;
               end if;
            end if;
         end;
      end loop;
   exception
      when Flyology.IO.Timeout_Error |
           Flyology.Cancellation.Operation_Cancelled =>
         Drop_Transport (Item);
         raise;
      when Message_Too_Large | Protocol_Error =>
         Drop_Transport (Item);
         raise;
      when others =>
         Drop_Transport (Item);
         raise;
   end Receive;

   function Close_Code (Item : Client) return Natural is
   begin
      if not Item.Peer_Close_Received then
         raise Program_Error with "no WebSocket peer close was received";
      end if;
      return Item.Peer_Close_Code;
   end Close_Code;

   function Close_Reason (Item : Client) return String is
   begin
      if not Item.Peer_Close_Received then
         raise Program_Error with "no WebSocket peer close was received";
      end if;
      return To_String (Item.Peer_Close_Reason);
   end Close_Reason;

   procedure Close
     (Item    : in out Client;
      Code    : Positive := 1_000;
      Reason  : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Payload : String (1 .. 2 + Reason'Length);
   begin
      if Item.Phase not in Open | Close_Pending then
         raise Program_Error with "WebSocket connection is not active";
      elsif not Policy.Valid_Close_Code (Code)
        or else Reason'Length > 123
        or else not Valid_UTF8 (Reason)
      then
         raise Constraint_Error with "invalid WebSocket close payload";
      end if;
      Payload (1) := Character'Val (Code / 256);
      Payload (2) := Character'Val (Code mod 256);
      if Reason'Length > 0 then
         Payload (3 .. Payload'Last) := Reason;
      end if;
      if Item.Phase = Open then
         Send_Frame (Item, 8, Bytes (Payload), Started, Timeout, Token);
         Item.Phase := Close_Pending;
      end if;
      while not Item.Peer_Close_Received loop
         declare
            Kind : Data_Kind;
            Data : Flyology.Bytes.Unbounded_Bytes;
            Closed_Result : Boolean;
         begin
            Receive
              (Item, Kind, Data, Closed_Result,
               Timeout => Remaining (Started, Timeout), Token => Token);
            --  Data sent before the peer observes our Close can still cross
            --  it on the wire. Discard such complete messages and keep
            --  waiting for the peer Close under the original deadline.
            exit when Closed_Result;
         end;
      end loop;
   end Close;

   procedure Abort_Connection (Item : in out Client) is
   begin
      if Item.Phase = Unconfigured then
         return;
      end if;
      Drop_Transport (Item);
   end Abort_Connection;

   overriding procedure Finalize (Item : in out Client) is
   begin
      begin
         Drop_Transport (Item);
         Item.Manager.Request_Shutdown;
      exception
         when others => null;
      end;
      Flyology.IO.TLS.Release (Item.Backend);
   end Finalize;

end Flyology.HTTP.WebSocket_Client;
