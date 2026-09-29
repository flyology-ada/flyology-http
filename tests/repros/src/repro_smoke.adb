with Repro_Support;

procedure Repro_Smoke is
   --  Harness self-test.  Unlike a finding spike this one must PASS on
   --  current sources: it proves the build, the runtime, and the verdict
   --  plumbing work before any finding is judged by them.
   use Repro_Support;
   Port : constant Positive := Ephemeral_Port;
begin
   Note ("harness self-test");
   Check (S (B ("abc")) = "abc", "B and S round-trip");
   Expect_Equal (Hex (B ("A" & Character'Val (10))), "41 0a", "Hex");
   Expect_Equal
     (Printable (B ("A" & Character'Val (10))), "A\x0a", "Printable");
   Expect_Equal (CRLF'Length, 2, "CRLF is two characters");
   Check (Port > 1024, "Ephemeral_Port returns an unprivileged port");
   Note ("ephemeral port was" & Port'Image);
   Finish;
end Repro_Smoke;
