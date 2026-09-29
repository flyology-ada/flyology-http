--  H1-SERVER-2: chunk-extension BWS is rejected although the chunk-ext
--  grammar admits it.
--
--  RFC 9112 section 7.1.1:
--    chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )
--  and "A recipient MUST ignore unrecognized chunk extensions."
--  RFC 9110 section 5.6.3: "A recipient MUST parse for such bad whitespace
--  and remove it before interpreting the protocol element."
--
--  The program asserts the CORRECT behaviour: each grammatical chunk-ext
--  placement of BWS is parsed and ignored, and the body decodes to "x".
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Repro_Support;

procedure Repro_H1_Server_2 is
   package HTTP_Server renames Flyology.HTTP.Server;
   use Ada.Strings.Unbounded;
   use Repro_Support;

   HT : constant Character := Character'Val (9);

   type Memory_Transport is limited new HTTP_Server.Transport with record
      Input  : Unbounded_String;
      Output : Unbounded_String;
   end record;

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      use type Ada.Streams.Stream_Element_Offset;
      Available : constant String := To_String (Item.Input);
      Count     : Natural;
   begin
      Data := (others => 0);
      Last := Data'First - 1;
      if Available'Length = 0 then
         return;
      end if;
      Count := Natural'Min (Natural (Data'Length), Available'Length);
      for Index in 1 .. Count loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Index - 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Available (Index)));
      end loop;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count - 1);
      Item.Input :=
        (if Count = Available'Length then Null_Unbounded_String
         else To_Unbounded_String (Available (Count + 1 .. Available'Last)));
   end Receive;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      for Value of Data loop
         Append (Item.Output, Character'Val (Value));
      end loop;
   end Send_All;

   procedure Probe (Label, Size_Line : String) is
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Transfer-Encoding: chunked" & CRLF & CRLF
         & Size_Line & CRLF & "x" & CRLF & "0" & CRLF & CRLF);
      declare
         Peer   : HTTP_Server.Connection (Channel'Access);
         Value  : HTTP_Server.Request;
         Closed : Boolean;
      begin
         HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
         Expect_Equal (HTTP_Server.Content (Value), "x", Label);
      exception
         when Error : Flyology.HTTP.Protocol_Error =>
            Check (False, Label);
            Note
              ("  raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
   end Probe;
begin
   Note ("RFC 9112 section 7.1.1 chunk-ext admits BWS before the semicolon,");
   Note ("after the semicolon, and around the equals sign");

   --  Baseline: the same extension with no bad whitespace is accepted today.
   Probe ("chunk extension without BWS (baseline)", "1;a=b");

   Probe ("BWS before the chunk-ext semicolon", "1 ;a=b");
   Probe ("HTAB before the chunk-ext semicolon", "1" & HT & ";a=b");
   Probe ("BWS after the chunk-ext semicolon", "1; a=b");
   Probe ("BWS before the chunk-ext equals sign", "1;a =b");
   Probe ("BWS after the chunk-ext equals sign", "1;a= b");
   Probe ("BWS around a valueless chunk extension", "1 ; a ");

   Finish;
end Repro_H1_Server_2;
