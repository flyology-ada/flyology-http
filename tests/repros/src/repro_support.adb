with Ada.Command_Line;
with Ada.Text_IO;
with GNAT.Sockets;

package body Repro_Support is

   use type Ada.Streams.Stream_Element_Offset;

   Failure_Count : Natural := 0;
   Check_Count   : Natural := 0;

   Digits_16 : constant String := "0123456789abcdef";

   procedure Check (Condition : Boolean; Description : String) is
   begin
      Check_Count := Check_Count + 1;
      if Condition then
         Ada.Text_IO.Put_Line ("  ok   " & Description);
      else
         Failure_Count := Failure_Count + 1;
         Ada.Text_IO.Put_Line ("  FAIL " & Description);
      end if;
   end Check;

   procedure Note (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("  note " & Text);
   end Note;

   procedure Expect_Equal
     (Actual, Expected : String; Description : String) is
   begin
      Check (Actual = Expected, Description);
      if Actual /= Expected then
         Ada.Text_IO.Put_Line ("         expected: [" & Expected & "]");
         Ada.Text_IO.Put_Line ("         actual:   [" & Actual & "]");
      end if;
   end Expect_Equal;

   procedure Expect_Equal
     (Actual, Expected : Integer; Description : String) is
   begin
      Check (Actual = Expected, Description);
      if Actual /= Expected then
         Ada.Text_IO.Put_Line
           ("         expected:" & Expected'Image
            & "   actual:" & Actual'Image);
      end if;
   end Expect_Equal;

   procedure Finish is
   begin
      Ada.Text_IO.Put_Line
        ("checks:" & Check_Count'Image & "  failures:" & Failure_Count'Image);
      if Failure_Count = 0 then
         Ada.Text_IO.Put_Line ("PASS");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
      else
         Ada.Text_IO.Put_Line ("BUG REPRODUCED");
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Finish;

   function Failures return Natural is (Failure_Count);

   function B (Text : String) return Byte_Array is
      Result : Byte_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      Index  : Ada.Streams.Stream_Element_Offset := Result'First;
   begin
      for Position in Text'Range loop
         Result (Index) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (Position)));
         Index := Index + 1;
      end loop;
      return Result;
   end B;

   function S (Data : Byte_Array) return String is
      Result : String (1 .. Natural (Data'Length));
      Index  : Natural := Result'First;
   begin
      for Position in Data'Range loop
         Result (Index) := Character'Val (Natural (Data (Position)));
         Index := Index + 1;
      end loop;
      return Result;
   end S;

   function Hex (Data : Byte_Array) return String is
      Result : String (1 .. Natural (Data'Length) * 3);
      Index  : Natural := Result'First;
   begin
      if Data'Length = 0 then
         return "";
      end if;
      for Position in Data'Range loop
         Result (Index) :=
           Digits_16 (Digits_16'First + Natural (Data (Position)) / 16);
         Result (Index + 1) :=
           Digits_16 (Digits_16'First + Natural (Data (Position)) mod 16);
         Result (Index + 2) := ' ';
         Index := Index + 3;
      end loop;
      return Result (Result'First .. Result'Last - 1);
   end Hex;

   function Printable (Data : Byte_Array) return String is
      Result : String (1 .. Natural (Data'Length) * 4);
      Last   : Natural := Result'First - 1;
   begin
      for Position in Data'Range loop
         declare
            Value : constant Natural := Natural (Data (Position));
         begin
            if Value in 32 .. 126 then
               Last := Last + 1;
               Result (Last) := Character'Val (Value);
            else
               Result (Last + 1 .. Last + 4) :=
                 "\x" & Digits_16 (Digits_16'First + Value / 16)
                 & Digits_16 (Digits_16'First + Value mod 16);
               Last := Last + 4;
            end if;
         end;
      end loop;
      return Result (Result'First .. Last);
   end Printable;

   function Ephemeral_Port return Positive is
      Socket  : GNAT.Sockets.Socket_Type;
      Address : GNAT.Sockets.Sock_Addr_Type;
      Bound   : GNAT.Sockets.Sock_Addr_Type;
   begin
      GNAT.Sockets.Create_Socket (Socket);
      GNAT.Sockets.Set_Socket_Option
        (Socket,
         GNAT.Sockets.Socket_Level,
         (GNAT.Sockets.Reuse_Address, True));
      Address.Addr := GNAT.Sockets.Loopback_Inet_Addr;
      Address.Port := 0;
      GNAT.Sockets.Bind_Socket (Socket, Address);
      Bound := GNAT.Sockets.Get_Socket_Name (Socket);
      GNAT.Sockets.Close_Socket (Socket);
      return Positive (Bound.Port);
   end Ephemeral_Port;

end Repro_Support;
