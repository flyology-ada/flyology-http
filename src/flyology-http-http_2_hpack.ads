with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.HTTP.Headers;

--  Implements the connection-scoped HPACK contexts used by HTTP/2 clients.
--  Decoder storage and decoded field lists remain explicitly bounded.
private package Flyology.HTTP.HTTP_2_HPACK is

   Default_Table_Size : constant Natural := 4_096;
   Maximum_Dynamic_Entries : constant Positive :=
     Default_Table_Size / 32;

   Header_List_Too_Large : exception;
   Invalid_Request_Fields : exception;

   type Decoder is limited private;

   --  Decode a complete response field section. Status is present exactly
   --  once for a response head and absent for trailers.
   procedure Decode_Response
     (Item        : in out Decoder;
      Block       : Ada.Streams.Stream_Element_Array;
      Is_Trailers : Boolean;
      Fields      : in out Flyology.HTTP.Headers.List;
      Status      : out Status_Code;
      Has_Status  : out Boolean);

   --  Decode a complete request field section. Request pseudo-fields are
   --  returned separately and regular fields retain their wire order.
   procedure Decode_Request
     (Item        : in out Decoder;
      Block       : Ada.Streams.Stream_Element_Array;
      Is_Trailers : Boolean;
      Fields      : in out Flyology.HTTP.Headers.List;
      Method      : out Ada.Strings.Unbounded.Unbounded_String;
      Scheme      : out Ada.Strings.Unbounded.Unbounded_String;
      Authority   : out Ada.Strings.Unbounded.Unbounded_String;
      Path        : out Ada.Strings.Unbounded.Unbounded_String);

   --  Reset the compression context after its connection is discarded.
   procedure Reset (Item : in out Decoder);

   type Builder is private;

   procedure Clear (Item : in out Builder);
   procedure Add_Indexed (Item : in out Builder; Index : Positive);
   procedure Add_Field
     (Item          : in out Builder;
      Name          : String;
      Value         : String;
      Never_Indexed : Boolean := False);
   function Bytes (Item : Builder) return Flyology.Bytes.Unbounded_Bytes;

private
   type Dynamic_Entry is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
      Size  : Natural := 0;
   end record;
   type Dynamic_Entry_Array is
     array (Positive range <>) of Dynamic_Entry;

   type Decoder is limited record
      Entries : Dynamic_Entry_Array (1 .. Maximum_Dynamic_Entries);
      Count   : Natural := 0;
      Size    : Natural := 0;
      Maximum : Natural := Default_Table_Size;
   end record;

   type Builder is record
      Data : Flyology.Bytes.Unbounded_Bytes;
   end record;

end Flyology.HTTP.HTTP_2_HPACK;
