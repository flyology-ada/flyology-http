with Ada.Streams;

package Repro_Support is
   --  Shared helpers for bug reproduction programs.  Convention: a program
   --  asserts the CORRECT behaviour.  On current sources it prints
   --  "BUG REPRODUCED" and exits with status 1; after a fix it prints "PASS"
   --  and exits 0.  A hang is reported as exit 124 by the run.sh timeout
   --  wrapper.
   --
   --  This package deliberately depends only on the Ada standard library and
   --  GNAT.Sockets, so that a spike for any area can with it without dragging
   --  in an unrelated part of the tree.  A spike that needs an in-memory
   --  server transport, a client testing seam, or a QUIC test connection
   --  declares it locally, mirroring the nearest program under tests/.

   procedure Check (Condition : Boolean; Description : String);
   --  Record a failed expectation when Condition is False.  A failed Check
   --  is what makes the program report BUG REPRODUCED.

   procedure Note (Text : String);
   --  Print an informational line.  Never affects the verdict.

   procedure Expect_Equal (Actual, Expected : String; Description : String);
   --  Check equality and print both sides when they differ.

   procedure Expect_Equal
     (Actual, Expected : Integer; Description : String);

   procedure Finish;
   --  Print the verdict and set the process exit status: 0 with no failed
   --  Check, 1 otherwise.

   function Failures return Natural;

   --  Byte helpers ---------------------------------------------------------

   subtype Byte_Array is Ada.Streams.Stream_Element_Array;

   function B (Text : String) return Byte_Array;
   --  Latin-1 String to bytes.

   function S (Data : Byte_Array) return String;
   --  Bytes to String, one character per byte.

   function Hex (Data : Byte_Array) return String;
   --  Space-separated two-digit hexadecimal, for evidence lines.

   function Printable (Data : Byte_Array) return String;
   --  Bytes with every non-printable byte shown as \xNN, for evidence lines.

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   --  Port helpers ---------------------------------------------------------

   function Ephemeral_Port return Positive;
   --  Bind an IPv4 loopback socket to port 0, read the port the kernel
   --  assigned, close it, and return that port.  Spikes must use this rather
   --  than a fixed port: the maintained suites bind fixed loopback ports and
   --  a spike run beside one would collide.

end Repro_Support;
