with Ada.Streams;
with Ada.Streams.Stream_IO;
with Flyology.Bytes;
with Flyology.HTTP.Headers;
with Flyology.HTTP.HTTP_2_Settings;
with Repro_Support;

--  H2-6.  RFC 7541 4.2: "A change in the maximum size of the dynamic table
--  is signaled via a dynamic table size update (see Section 6.3).  This
--  dynamic table size update MUST occur at the beginning of the first header
--  block following the change to the dynamic table size.  In HTTP/2, this
--  follows a settings acknowledgment".  RFC 7541 6.3 gives the
--  representation: "A dynamic table size update starts with the '001' 3-bit
--  pattern", so the octet is 2#001xxxxx#.
--
--  The peer's SETTINGS_HEADER_TABLE_SIZE is stored
--  (src/flyology-http-http_2_settings.adb:43-44) and read by nothing; the
--  encoder has no size-update representation at all.  This spike asserts
--  that the first field section emitted after the reduction begins with one.
procedure Flyology.HTTP.HTTP_2_Requests.Repro_H2_6 is
   use Ada.Streams;
   use Repro_Support;
   package Settings renames Flyology.HTTP.HTTP_2_Settings;
   use type Settings.Apply_Result;

   Peer    : Settings.State;
   Applied : Settings.Apply_Result;
   Fields  : Flyology.HTTP.Headers.List;
   Evidence : constant String :=
     "tests/repros/obj/repro_h2_6_block.bin";
begin
   Note ("H2-6: dynamic table size update after a lowered HEADER_TABLE_SIZE");

   --  The peer disables the encoder's dynamic table: SETTINGS identifier 1
   --  with the value 0, which Envoy, HAProxy and nghttpx all offer.
   Settings.Apply (Peer, (0, 1, 0, 0, 0, 0), Applied);
   Check
     (Applied = Settings.Settings_Accepted,
      "the reduction is accepted");
   Expect_Equal
     (Natural (Peer.Header_Table_Size), 0,
      "the peer's HEADER_TABLE_SIZE is recorded as 0");

   declare
      Block : constant Flyology.Bytes.Unbounded_Bytes :=
        Encode_Head
          (Method_Text        => "GET",
           Scheme_Text        => "http",
           Authority          => "localhost",
           Target             => "/",
           Fields             => Fields,
           Has_Content_Length => False,
           Content_Length     => 0,
           Expect_Continue    => False);
      Wire : constant Stream_Element_Array := Flyology.Bytes.To_Array (Block);
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Note
        ("  first field section begins " &
         Hex (Wire (Wire'First .. Stream_Element_Offset'Min
                (Wire'First + 7, Wire'Last))));
      Check
        (Wire'Length > 0
           and then (Wire (Wire'First) and 2#1110_0000#) = 2#0010_0000#,
         "the first field section after the reduction begins with a " &
         "dynamic table size update (2#001xxxxx#)");
      if Wire'Length > 0 then
         Check
           (Wire (Wire'First) = 2#0010_0000#,
            "the signalled maximum is 0, at or below the peer's limit");
      end if;
      --  Leave the exact bytes behind so the pinned python-hpack 4.2.0
      --  decoder can be pointed at them.
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Evidence);
      Ada.Streams.Stream_IO.Write (File, Wire);
      Ada.Streams.Stream_IO.Close (File);
      Note ("  encoded field section written to " & Evidence);
   end;

   Finish;
end Flyology.HTTP.HTTP_2_Requests.Repro_H2_6;
