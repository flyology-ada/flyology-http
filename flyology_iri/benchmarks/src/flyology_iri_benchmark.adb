with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Flyology_IRI;

procedure Flyology_IRI_Benchmark is
   package CLI renames Ada.Command_Line;
   package Clock renames Ada.Real_Time;
   package Stream_IO renames Ada.Streams.Stream_IO;

   use type Ada.Real_Time.Time;
   use type Flyology_IRI.Error_Kind;

   type Line_Span is record
      First : Positive;
      Last  : Natural;
   end record;

   package Span_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Line_Span);

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function To_NS (Value : Duration) return Long_Long_Integer is
     (Long_Long_Integer (Value * 1_000_000_000.0));

   procedure Run (Data : String; Rounds : Positive) is
      Lines       : Span_Vectors.Vector;
      Start       : Positive := Data'First;
      Accepted    : Long_Long_Integer := 0 with Volatile;
      Href_Bytes  : Long_Long_Integer := 0 with Volatile;
      Began       : Clock.Time;
      Elapsed     : Duration;
      Total       : Long_Long_Integer;
      Value       : Flyology_IRI.Reference;
      Error       : Flyology_IRI.Parse_Error;
      Failure_Counts : array (Flyology_IRI.Error_Kind) of Natural :=
        (others => 0);
   begin
      for Index in Data'Range loop
         if Data (Index) = ASCII.LF then
            if Index > Start then
               Lines.Append (Line_Span'(First => Start, Last => Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      if Start <= Data'Last then
         Lines.Append (Line_Span'(First => Start, Last => Data'Last));
      end if;
      Total := Long_Long_Integer (Lines.Length) * Long_Long_Integer (Rounds);

      Began := Clock.Clock;
      for Round in 1 .. Rounds loop
         for Span of Lines loop
            if Flyology_IRI.Can_Parse
              (Data (Span.First .. Span.Last),
               Flyology_IRI.Web_URL_Syntax,
               Positive'Last)
            then
               Accepted := Accepted + 1;
            end if;
         end loop;
      end loop;
      Elapsed := Clock.To_Duration (Clock.Clock - Began);
      Ada.Text_IO.Put_Line
        ("flyology_iri,can_parse," & Decimal (Long_Long_Integer (Lines.Length))
         & "," & Decimal (Accepted / Long_Long_Integer (Rounds))
         & "," & Decimal (To_NS (Elapsed) / Total));

      Accepted := 0;
      Began := Clock.Clock;
      for Round in 1 .. Rounds loop
         for Span of Lines loop
            Flyology_IRI.Try_Parse
              (Data (Span.First .. Span.Last),
               Value,
               Error,
               Flyology_IRI.Web_URL_Syntax,
               Positive'Last);
            if Error.Kind = Flyology_IRI.No_Error then
               Accepted := Accepted + 1;
               Href_Bytes := Href_Bytes
                 + Long_Long_Integer (Flyology_IRI.Image_Length (Value));
            end if;
         end loop;
      end loop;
      Elapsed := Clock.To_Duration (Clock.Clock - Began);
      Ada.Text_IO.Put_Line
        ("flyology_iri,parse_href," & Decimal (Long_Long_Integer (Lines.Length))
         & "," & Decimal (Accepted / Long_Long_Integer (Rounds))
         & "," & Decimal (To_NS (Elapsed) / Total));
      if Href_Bytes = -1 then
         Ada.Text_IO.Put_Line ("unreachable");
      end if;

      for Span of Lines loop
         Error := Flyology_IRI.Diagnose
           (Data (Span.First .. Span.Last),
            Flyology_IRI.Web_URL_Syntax,
            Positive'Last);
         Failure_Counts (Error.Kind) := Failure_Counts (Error.Kind) + 1;
      end loop;
      for Kind in Flyology_IRI.Error_Kind loop
         if Kind /= Flyology_IRI.No_Error and then Failure_Counts (Kind) > 0 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "# flyology_iri " & Flyology_IRI.Error_Kind'Image (Kind)
               & "=" & Natural'Image (Failure_Counts (Kind)));
         end if;
      end loop;
   end Run;

   File       : Stream_IO.File_Type;
   Rounds     : Positive := 5;
begin
   if CLI.Argument_Count not in 1 .. 2 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "usage: flyology_iri_benchmark CORPUS [ROUNDS]");
      CLI.Set_Exit_Status (CLI.Failure);
      return;
   end if;
   if CLI.Argument_Count = 2 then
      Rounds := Positive'Value (CLI.Argument (2));
   end if;
   Stream_IO.Open (File, Stream_IO.In_File, CLI.Argument (1));
   declare
      use type Ada.Streams.Stream_Element_Offset;
      type Byte_Array_Access is access Ada.Streams.Stream_Element_Array;
      type String_Access is access String;
      Size  : constant Ada.Streams.Stream_Element_Offset :=
        Ada.Streams.Stream_Element_Offset (Stream_IO.Size (File));
      Bytes : constant Byte_Array_Access :=
        new Ada.Streams.Stream_Element_Array (1 .. Size);
      Last  : Ada.Streams.Stream_Element_Offset;
      Text  : constant String_Access := new String (1 .. Natural (Size));
   begin
      Stream_IO.Read (File, Bytes.all, Last);
      Stream_IO.Close (File);
      if Last /= Bytes.all'Last then
         raise Program_Error with "short corpus read";
      end if;
      for Index in Bytes.all'Range loop
         Text (Natural (Index)) := Character'Val (Bytes (Index));
      end loop;
      Run (Text.all, Rounds);
   end;
end Flyology_IRI_Benchmark;
