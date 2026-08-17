--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Baselines;
with Flyology_Bench.Metadata;
with Flyology_Bench.Reporters;
with Flyology_IRI;

--  Measures the component-getter and Resolve paths rather than the corpus
--  parse loop flyology_iri_benchmark times. Those two workloads are the ones
--  that read stored components back out of a parsed reference, so they are
--  where the cost of materializing a whole serialized reference per component
--  lands. The corpus benchmark reaches neither: can_parse constructs nothing
--  and parse_href consumes only the stored serialization length.
--
--  The two implementations being compared are two builds of the same library,
--  so they cannot share a process and paired Compare does not apply. Runs are
--  therefore joined through Flyology_Bench.Baselines, whose fingerprint
--  refuses to compare across operating system, architecture, compiler, or
--  build mode. The single exception is the validation pair below, which
--  compares two subprograms that do coexist and so uses Compare directly.
procedure Flyology_IRI_Resolve_Benchmark is
   package Bench renames Flyology_Bench;
   package Baselines renames Flyology_Bench.Baselines;
   package Reporters renames Flyology_Bench.Reporters;
   package IRI renames Flyology_IRI;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Bench.Iteration_Count;
   use type Unbounded.Unbounded_String;

   Usage : constant String :=
     "usage: flyology_iri_resolve_benchmark"
     & " [--format=console|csv]"
     & " [--samples=N] [--measurement-time=SECONDS]"
     & " [--build-mode=NAME] [--quiescence] [--metrics-csv=PATH]"
     & " [--save-baseline=DIRECTORY] [--compare-baseline=DIRECTORY]";

   ----------------------------------------------------------------------
   --  Flat input corpora
   ----------------------------------------------------------------------

   --  Inputs live in one contiguous String addressed by spans so that a timed
   --  loop can hand a reference to the library without allocating anything of
   --  its own. An array of Unbounded_String would charge every iteration for
   --  a To_String that has nothing to do with what is being measured.

   Corpus_Capacity : constant := 64 * 1_024;
   Corpus_Items    : constant := 64;

   type Item_Span is record
      First : Positive := 1;
      Last  : Natural  := 0;
   end record;

   type Item_Span_Array is
     array (Positive range 1 .. Corpus_Items) of Item_Span;

   type String_Corpus is record
      Text  : String (1 .. Corpus_Capacity) := (others => ' ');
      Used  : Natural := 0;
      Spans : Item_Span_Array := (others => (First => 1, Last => 0));
      Count : Natural := 0;
   end record;

   procedure Append (Into : in out String_Corpus; Value : String) is
   begin
      Into.Count := Into.Count + 1;
      Into.Spans (Into.Count) :=
        (First => Into.Used + 1, Last => Into.Used + Value'Length);
      Into.Text (Into.Used + 1 .. Into.Used + Value'Length) := Value;
      Into.Used := Into.Used + Value'Length;
   end Append;

   ----------------------------------------------------------------------
   --  Inputs
   ----------------------------------------------------------------------

   --  RFC 3986 section 5.4 uses this base for its normative resolution
   --  examples, and the crate's own resolution tests already use it.
   Short_Base_Text : constant String := "http://a/b/c/d;p?q";

   --  A base of the size the issue describes. A reference this long is what
   --  separates copying the whole serialization from copying one component;
   --  at eighteen bytes the two are indistinguishable.
   function Long_URL (Leaf : String) return String is
     ("https://reader:secret@documents.archive.example.org:8443"
      & "/collections/2026/quarter-three/regional-filings"
      & "/appendix-b/exhibits/tables/normalized/" & Leaf
      & "?revision=41&format=canonical&include=annotations&trace=off"
      & "#section-4.2.1-table-notes");

   Long_Base_Text : constant String := Long_URL ("index");

   --  A deliberately oversized reference, still inside Default_Max_Length. It
   --  exists to make the component sweep's dependence on reference length
   --  measurable: a getter that copies the whole serialization is O(reference)
   --  and must show here, while one that copies only its component is O(part)
   --  and must not. Without this case a flat short/long result cannot be told
   --  apart from a workload whose copy the optimizer already removed.
   function Huge_URL (Leaf : String) return String is
      Segment : constant String := "/padding-segment-of-known-width";
      Filler  : String (1 .. 60 * Segment'Length);
   begin
      for Index in 1 .. 60 loop
         Filler (Segment'Length * (Index - 1) + 1 .. Segment'Length * Index) :=
           Segment;
      end loop;
      return "https://reader:secret@documents.archive.example.org:8443"
        & Filler & "/" & Leaf
        & "?revision=41&format=canonical&include=annotations&trace=off"
        & "#section-4.2.1-table-notes";
   end Huge_URL;

   subtype Slot_Index is Positive range 1 .. 4;
   type Reference_Array is array (Slot_Index) of IRI.Reference;

   Short_Base : IRI.Reference;
   Long_Base  : IRI.Reference;
   Short_Refs : Reference_Array;
   Long_Refs  : Reference_Array;
   Huge_Refs  : Reference_Array;

   --  Relative references: the RFC 3986 section 5.4 examples plus the shapes
   --  a document with a base-URI directive actually carries.
   Relatives : String_Corpus;

   --  The absolute results those resolutions produce. Resolve validates its
   --  assembled result by parsing it a second time; this corpus is what that
   --  second parse sees.
   Assembled : String_Corpus;

   procedure Build_Inputs is
   begin
      Append (Relatives, "g");
      Append (Relatives, "./g");
      Append (Relatives, "g/");
      Append (Relatives, "/g/h");
      Append (Relatives, "//example.org/x");
      Append (Relatives, "?y");
      Append (Relatives, "g?y");
      Append (Relatives, "#s");
      Append (Relatives, "g#s");
      Append (Relatives, "g?y#s");
      Append (Relatives, ";x");
      Append (Relatives, "g;x?y#s");
      Append (Relatives, "");
      Append (Relatives, ".");
      Append (Relatives, "./");
      Append (Relatives, "..");
      Append (Relatives, "../");
      Append (Relatives, "../g");
      Append (Relatives, "../../g");
      Append (Relatives, "../../../g");
      Append (Relatives, "images/logo.png");
      Append (Relatives, "../styles/site.css");
      Append (Relatives, "/assets/app.js?v=3");
      Append (Relatives, "#anchor");

      Short_Base := IRI.Parse (Short_Base_Text, IRI.URI_Syntax);
      Long_Base  := IRI.Parse (Long_Base_Text, IRI.URI_Syntax);

      Short_Refs :=
        [IRI.Parse ("https://user:pass@example.com:8443/a/b?x=1#frag",
                    IRI.URI_Syntax),
         IRI.Parse ("http://example.org/index.html?q=1#top", IRI.URI_Syntax),
         IRI.Parse ("https://api.example.net:9443/v2/items?limit=20#none",
                    IRI.URI_Syntax),
         IRI.Parse ("http://cdn.example.com/a/b/c/d.png?w=64#x",
                    IRI.URI_Syntax)];

      Long_Refs :=
        [IRI.Parse (Long_URL ("index"), IRI.URI_Syntax),
         IRI.Parse (Long_URL ("summary"), IRI.URI_Syntax),
         IRI.Parse (Long_URL ("appendix"), IRI.URI_Syntax),
         IRI.Parse (Long_URL ("errata"), IRI.URI_Syntax)];

      Huge_Refs :=
        [IRI.Parse (Huge_URL ("index"), IRI.URI_Syntax),
         IRI.Parse (Huge_URL ("summary"), IRI.URI_Syntax),
         IRI.Parse (Huge_URL ("appendix"), IRI.URI_Syntax),
         IRI.Parse (Huge_URL ("errata"), IRI.URI_Syntax)];

      for Slot in 1 .. Relatives.Count loop
         declare
            Span : Item_Span renames Relatives.Spans (Slot);
            Done : constant IRI.Reference :=
              IRI.Resolve
                (Long_Base, Relatives.Text (Span.First .. Span.Last));
         begin
            Append (Assembled, IRI.Image (Done));
         end;
      end loop;
   end Build_Inputs;

   ----------------------------------------------------------------------
   --  Measured batches
   ----------------------------------------------------------------------

   --  Every batch folds something derived from the operation's result into an
   --  accumulator handed out of the timed region, which is what keeps -O3 from
   --  discarding the work. Clobber_Memory is a per-batch compiler barrier
   --  rather than a per-iteration one, so it costs nothing measurable at the
   --  calibrated batch sizes while still preventing stores from sinking past
   --  the loop. Each batch also advances a slot so that consecutive iterations
   --  use different inputs, which denies the optimizer a loop-invariant call.

   --  Reading the last byte as well as the length is precautionary, not
   --  observed to be necessary. Disassembling this body shows all eight getter
   --  calls emitted either way, because the library is a separate project
   --  whose bodies -gnatn2 does not inline here, so -O3 has no way to satisfy
   --  a length-only consumer without producing the bytes. That would change if
   --  the crate were ever built into one project with this harness or with
   --  link-time optimization, and the guard costs within measurement noise.
   function Fold (Value : String) return Long_Long_Integer is
     (if Value'Length = 0 then 0
      else Long_Long_Integer (Value'Length)
           + Character'Pos (Value (Value'Last)));

   procedure Sweep_Components
     (Refs       : Reference_Array;
      Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer)
   is
      Total : Long_Long_Integer := 0;
      Slot  : Slot_Index := Slot_Index'First;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         Total := Total
           + Fold (IRI.Scheme (Refs (Slot)))
           + Fold (IRI.Authority (Refs (Slot)))
           + Fold (IRI.Userinfo (Refs (Slot)))
           + Fold (IRI.Host (Refs (Slot)))
           + Fold (IRI.Port (Refs (Slot)))
           + Fold (IRI.Path (Refs (Slot)))
           + Fold (IRI.Query (Refs (Slot)))
           + Fold (IRI.Fragment (Refs (Slot)));
         Slot :=
           (if Slot = Slot_Index'Last then Slot_Index'First else Slot + 1);
      end loop;
      Bench.Clobber_Memory;
      Value := Total;
   end Sweep_Components;

   procedure Resolve_Corpus
     (Base       : IRI.Reference;
      Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer)
   is
      Total : Long_Long_Integer := 0;
      Slot  : Positive := 1;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         declare
            Span : Item_Span renames Relatives.Spans (Slot);
            Done : constant IRI.Reference :=
              IRI.Resolve (Base, Relatives.Text (Span.First .. Span.Last));
         begin
            Total := Total + Long_Long_Integer (IRI.Image_Length (Done));
         end;
         Slot := (if Slot = Relatives.Count then 1 else Slot + 1);
      end loop;
      Bench.Clobber_Memory;
      Value := Total;
   end Resolve_Corpus;

   --  The serialization-returning Resolve over the same corpus. Folding the
   --  last byte as well as the length matches Sweep_Components, so the two
   --  Resolve forms are consumed identically and the difference between them
   --  is the validation each performs.
   procedure Resolve_String_Corpus
     (Base       : IRI.Reference;
      Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer)
   is
      Total : Long_Long_Integer := 0;
      Slot  : Positive := 1;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         declare
            Span : Item_Span renames Relatives.Spans (Slot);
            Done : constant String :=
              IRI.Resolve (Base, Relatives.Text (Span.First .. Span.Last));
         begin
            Total := Total + Fold (Done);
         end;
         Slot := (if Slot = Relatives.Count then 1 else Slot + 1);
      end loop;
      Bench.Clobber_Memory;
      Value := Total;
   end Resolve_String_Corpus;

   procedure Components_Short_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Sweep_Components (Short_Refs, Iterations, Value);
   end Components_Short_Batch;

   procedure Components_Long_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Sweep_Components (Long_Refs, Iterations, Value);
   end Components_Long_Batch;

   procedure Components_Huge_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Sweep_Components (Huge_Refs, Iterations, Value);
   end Components_Huge_Batch;

   procedure Resolve_Short_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Resolve_Corpus (Short_Base, Iterations, Value);
   end Resolve_Short_Batch;

   procedure Resolve_Long_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Resolve_Corpus (Long_Base, Iterations, Value);
   end Resolve_Long_Batch;

   procedure Resolve_String_Long_Batch
     (Iterations : Bench.Iteration_Count;
      Value      : out Long_Long_Integer) is
   begin
      Resolve_String_Corpus (Long_Base, Iterations, Value);
   end Resolve_String_Long_Batch;

   --  Two paired comparisons. Both sides of each live in this process, so
   --  these are genuine paired Compares rather than baseline joins, and their
   --  answers do not depend on host load the way an independent run does.
   --
   --  The first isolates the validation step: what the serialization form
   --  saves is exactly the second Reference the Reference form builds. The
   --  second measures the two public Resolve forms end to end.
   Validation_Sink : Long_Long_Integer := 0;

   procedure Parse_Assembled (Iterations : Bench.Iteration_Count) is
      Total : Long_Long_Integer := 0;
      Slot  : Positive := 1;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         declare
            Span   : Item_Span renames Assembled.Spans (Slot);
            Parsed : constant IRI.Reference :=
              IRI.Parse
                (Assembled.Text (Span.First .. Span.Last), IRI.URI_Syntax);
         begin
            Total := Total + Long_Long_Integer (IRI.Image_Length (Parsed));
         end;
         Slot := (if Slot = Assembled.Count then 1 else Slot + 1);
      end loop;
      Validation_Sink := Validation_Sink + Total;
      Bench.Clobber_Memory;
   end Parse_Assembled;

   procedure Diagnose_Assembled (Iterations : Bench.Iteration_Count) is
      use type IRI.Error_Kind;
      Total : Long_Long_Integer := 0;
      Slot  : Positive := 1;
   begin
      for Iteration in Bench.Iteration_Count range 1 .. Iterations loop
         declare
            Span  : Item_Span renames Assembled.Spans (Slot);
            Found : constant IRI.Parse_Error :=
              IRI.Diagnose
                (Assembled.Text (Span.First .. Span.Last), IRI.URI_Syntax);
         begin
            Total := Total
              + (if Found.Kind = IRI.No_Error
                 then Long_Long_Integer (Span.Last - Span.First + 1)
                 else 0);
         end;
         Slot := (if Slot = Assembled.Count then 1 else Slot + 1);
      end loop;
      Validation_Sink := Validation_Sink + Total;
      Bench.Clobber_Memory;
   end Diagnose_Assembled;

   procedure Resolve_Reference_Form (Iterations : Bench.Iteration_Count) is
      Total : Long_Long_Integer;
   begin
      Resolve_Corpus (Long_Base, Iterations, Total);
      Validation_Sink := Validation_Sink + Total;
   end Resolve_Reference_Form;

   procedure Resolve_String_Form (Iterations : Bench.Iteration_Count) is
      Total : Long_Long_Integer;
   begin
      Resolve_String_Corpus (Long_Base, Iterations, Total);
      Validation_Sink := Validation_Sink + Total;
   end Resolve_String_Form;

   procedure Keep is new Bench.Do_Not_Optimize (Long_Long_Integer);

   procedure Measure_Components_Short is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Components_Short_Batch);
   procedure Measure_Components_Long is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Components_Long_Batch);
   procedure Measure_Components_Huge is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Components_Huge_Batch);
   procedure Measure_Resolve_Short is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Resolve_Short_Batch);
   procedure Measure_Resolve_Long is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Resolve_Long_Batch);
   procedure Measure_Resolve_String is new Bench.Measure_Result_Batched
     (Element => Long_Long_Integer, Batch => Resolve_String_Long_Batch);
   procedure Compare_Validation is new Bench.Compare_Batched
     (Reference_Batch => Parse_Assembled,
      Contender_Batch => Diagnose_Assembled);
   procedure Compare_Resolve_Forms is new Bench.Compare_Batched
     (Reference_Batch => Resolve_Reference_Form,
      Contender_Batch => Resolve_String_Form);

   ----------------------------------------------------------------------
   --  Command line
   ----------------------------------------------------------------------

   type Output_Format is (Console, CSV);

   Format          : Output_Format := Console;
   Sample_Total    : Bench.Sample_Count := 50;
   Measure_Seconds : Duration := 1.000;
   Build_Mode      : Unbounded.Unbounded_String :=
     Unbounded.To_Unbounded_String ("unstated");
   Save_Directory    : Unbounded.Unbounded_String;
   Compare_Directory : Unbounded.Unbounded_String;
   Metrics_Path      : Unbounded.Unbounded_String;
   Wait_For_Quiet    : Boolean := False;

   --  Metric rows default to standard error so that a plain run keeps its
   --  human summary on standard output. --metrics-csv sends them to a file
   --  instead, which is what a run whose standard error also carries build
   --  chatter needs.
   Metrics_File : Ada.Text_IO.File_Type;
   Metrics_Header_Printed : Boolean := False;

   function Option (Argument, Name : String) return Boolean is
     (Argument'Length > Name'Length
      and then Argument (Argument'First .. Argument'First + Name'Length - 1)
               = Name);

   function Option_Value (Argument, Name : String) return String is
     (Argument (Argument'First + Name'Length .. Argument'Last));

   procedure Read_Arguments is
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--quiescence" then
               Wait_For_Quiet := True;
            elsif Argument = "--format=console" then
               Format := Console;
            elsif Argument = "--format=csv" then
               Format := CSV;
            elsif Option (Argument, "--samples=") then
               Sample_Total :=
                 Bench.Sample_Count'Value
                   (Option_Value (Argument, "--samples="));
            elsif Option (Argument, "--measurement-time=") then
               Measure_Seconds :=
                 Duration'Value
                   (Option_Value (Argument, "--measurement-time="));
            elsif Option (Argument, "--build-mode=") then
               Build_Mode :=
                 Unbounded.To_Unbounded_String
                   (Option_Value (Argument, "--build-mode="));
            elsif Option (Argument, "--metrics-csv=") then
               Metrics_Path :=
                 Unbounded.To_Unbounded_String
                   (Option_Value (Argument, "--metrics-csv="));
            elsif Option (Argument, "--save-baseline=") then
               Save_Directory :=
                 Unbounded.To_Unbounded_String
                   (Option_Value (Argument, "--save-baseline="));
            elsif Option (Argument, "--compare-baseline=") then
               Compare_Directory :=
                 Unbounded.To_Unbounded_String
                   (Option_Value (Argument, "--compare-baseline="));
            else
               raise Constraint_Error with Usage;
            end if;
         end;
      end loop;
   end Read_Arguments;

   ----------------------------------------------------------------------
   --  Reporting
   ----------------------------------------------------------------------

   --  The build mode belongs in the fingerprint because the release profile
   --  suppresses runtime checks in flyology_iri.adb, which is most of what
   --  these workloads execute. The library revision deliberately does not:
   --  that difference is the one being measured.
   function Environment return String is
     (Bench.Metadata.Fingerprint
        ("build_mode=" & Unbounded.To_String (Build_Mode)));

   function Baseline_Path (Directory, Name : String) return String is
     (Directory & "/" & Name & ".baseline");

   procedure Report (Name : String; Result : Bench.Measurement) is
   begin
      case Format is
         when Console =>
            Reporters.Put_Console (Name, Result);
         when CSV =>
            Reporters.Put_CSV (Name, Result);
      end case;

      if Ada.Text_IO.Is_Open (Metrics_File) then
         if not Metrics_Header_Printed then
            Reporters.Put_Metrics_CSV_Header (Metrics_File);
            Metrics_Header_Printed := True;
         end if;
         Reporters.Put_Metrics_CSV (Name, Result, Metrics_File);
      else
         if not Metrics_Header_Printed then
            Reporters.Put_Metrics_CSV_Header (Ada.Text_IO.Standard_Error);
            Metrics_Header_Printed := True;
         end if;
         Reporters.Put_Metrics_CSV (Name, Result, Ada.Text_IO.Standard_Error);
      end if;

      if Save_Directory /= Unbounded.Null_Unbounded_String then
         declare
            Directory : constant String :=
              Unbounded.To_String (Save_Directory);
         begin
            Ada.Directories.Create_Path (Directory);
            Baselines.Save
              (Path        => Baseline_Path (Directory, Name),
               Name        => Name,
               Result      => Result,
               Fingerprint => Environment);
         end;
      end if;

      if Compare_Directory /= Unbounded.Null_Unbounded_String then
         declare
            Directory : constant String :=
              Unbounded.To_String (Compare_Directory);
            Saved : constant Baselines.Baseline :=
              Baselines.Load (Baseline_Path (Directory, Name));
            Change : constant Baselines.Regression :=
              Baselines.Compare
                (Saved                       => Saved,
                 Current                     => Result,
                 Fingerprint                 => Environment,
                 Practical_Threshold_Percent => 1.0,
                 Random_Seed                 => 20_260_817);
         begin
            if not Baselines.Compatible (Change) then
               Ada.Text_IO.Put_Line
                 ("baseline " & Name
                  & ": incompatible environment, no verdict"
                  & " (baseline fingerprint " & Baselines.Fingerprint (Saved)
                  & ", current " & Environment & ")");
            else
               Ada.Text_IO.Put_Line
                 ("baseline " & Name
                  & ": time change" & Long_Float'Image
                      (Baselines.Time_Change_Percent (Change))
                  & "%, speedup" & Long_Float'Image
                      (Baselines.Speedup (Change))
                  & " 95% [" & Long_Float'Image
                      (Baselines.Speedup_Confidence_Low (Change))
                  & "," & Long_Float'Image
                      (Baselines.Speedup_Confidence_High (Change))
                  & " ], verdict " & Bench.Comparison_Verdict'Image
                      (Baselines.Verdict (Change)));
            end if;
         end;
      end if;
   end Report;

   Configuration : Bench.Configuration;
   Result        : Bench.Measurement;
   Validation    : Bench.Comparison;
   Resolve_Forms : Bench.Comparison;
begin
   Read_Arguments;
   if Metrics_Path /= Unbounded.Null_Unbounded_String then
      Ada.Text_IO.Create
        (Metrics_File,
         Ada.Text_IO.Out_File,
         Unbounded.To_String (Metrics_Path));
   end if;
   Build_Inputs;

   --  Linux_Hardware_Metrics would give the low-noise instruction count these
   --  workloads deserve, but its axes come from perf and report
   --  Unsupported_Platform on Darwin. Process_Resource_Metrics is the portable
   --  Darwin/Linux set; the metrics CSV records what each requested axis
   --  actually collected rather than leaving it assumed.
   Configuration :=
     (Bench.Default_Configuration with delta
        Warmup_Time      => 0.200,
        Measurement_Time => Measure_Seconds,
        Samples          => Sample_Total,
        Random_Seed      => 20_260_817,
        Metrics          => Bench.Process_Resource_Metrics,
        CPU_Quiescence   =>
          (Enabled                     => Wait_For_Quiet,
           Maximum_Average_CPU_Percent => 25.0,
           Maximum_Core_CPU_Percent    => 60.0,
           Stable_Time                 => 1.000,
           Poll_Interval               => 0.100,
           Timeout                     => 120.0));

   Ada.Text_IO.Put_Line
     (Ada.Text_IO.Standard_Error, "# environment=" & Environment);

   if Format = CSV then
      Reporters.Put_CSV_Header;
   end if;

   Measure_Components_Short (Configuration, Result);
   Report ("components_short", Result);

   Measure_Components_Long (Configuration, Result);
   Report ("components_long", Result);

   Measure_Components_Huge (Configuration, Result);
   Report ("components_huge", Result);

   Measure_Resolve_Short (Configuration, Result);
   Report ("resolve_short_base", Result);

   Measure_Resolve_Long (Configuration, Result);
   Report ("resolve_long_base", Result);

   Measure_Resolve_String (Configuration, Result);
   Report ("resolve_long_base_string", Result);

   Compare_Validation (Configuration, Validation);
   Compare_Resolve_Forms (Configuration, Resolve_Forms);
   Keep (Validation_Sink);
   case Format is
      when Console =>
         Reporters.Put_Comparison_Console
           ("validate_by_parse", "validate_by_diagnose", Validation);
         Reporters.Put_Comparison_Console
           ("resolve_to_reference", "resolve_to_string", Resolve_Forms);
      when CSV =>
         Reporters.Put_Comparison_CSV_Header;
         Reporters.Put_Comparison_CSV
           ("validate_by_parse", "validate_by_diagnose", Validation);
         Reporters.Put_Comparison_CSV
           ("resolve_to_reference", "resolve_to_string", Resolve_Forms);
   end case;

   if Ada.Text_IO.Is_Open (Metrics_File) then
      Ada.Text_IO.Close (Metrics_File);
   end if;
end Flyology_IRI_Resolve_Benchmark;
