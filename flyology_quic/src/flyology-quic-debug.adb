#if FLYOLOGY_QUIC_TRACE then
with Ada.Text_IO;
#end if;

package body Flyology.QUIC.Debug is

   procedure Log (Component, Event, Detail : String) is
   begin
#if FLYOLOGY_QUIC_TRACE then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "[flyology." & Component & "] " & Event & " " & Detail);
#else
      pragma Unreferenced (Component, Event, Detail);
      null;
#end if;
   end Log;

end Flyology.QUIC.Debug;
