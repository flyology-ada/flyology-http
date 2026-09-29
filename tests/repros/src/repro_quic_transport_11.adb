with Ada.Exceptions;
with Ada.Streams;
with Flyology.QUIC.Connections;
with Repro_Support;

procedure Repro_Quic_Transport_11 is
   --  QUIC-TRANSPORT-11 (raised during verification; the discovery entry
   --  lists it as an uncounted observation): the public Connections
   --  operations split into two groups.  The query functions guard the null
   --  backend, but every packet-driven operation dereferences it.
   --
   --  Flyology.QUIC.Connections.Operation_Status documents
   --  "@enum Invalid_State The operation is not valid in the current phase",
   --  and State returns Uninitialized for a fresh Connection, so a caller
   --  has every reason to expect Invalid_State rather than a language-level
   --  check failure.

   package QUIC renames Flyology.QUIC.Connections;

   use Repro_Support;
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;

   Item   : QUIC.Connection;
   Output : QUIC.Datagram_Batch;
   Status : QUIC.Operation_Status := QUIC.Succeeded;
   Datagram : constant Ada.Streams.Stream_Element_Array (1 .. 64) :=
     (others => 0);
   Raised : Boolean := False;

begin
   Check (QUIC.State (Item) = QUIC.Uninitialized,
          "a fresh Connection reports Uninitialized");
   Check (not QUIC.Is_Connected (Item),
          "Is_Connected guards the null backend");
   Check (not QUIC.Has_Recovery_Timeout (Item),
          "Has_Recovery_Timeout guards the null backend");

   begin
      QUIC.Process_Datagram (Item, Datagram, Output, Status);
      Note ("Process_Datagram returned "
            & QUIC.Operation_Status'Image (Status));
   exception
      when Error : others =>
         Raised := True;
         Note ("Process_Datagram raised "
               & Ada.Exceptions.Exception_Name (Error)
               & ": " & Ada.Exceptions.Exception_Message (Error));
   end;

   Check (not Raised and then Status = QUIC.Invalid_State,
          "Process_Datagram on an uninitialized connection reports"
          & " Invalid_State instead of raising");

   Finish;
end Repro_Quic_Transport_11;
