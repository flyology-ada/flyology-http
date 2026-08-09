with Ada.Text_IO;

package body Flyology.QUIC.Debug is

   procedure Log (Component, Event, Detail : String) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "[flyology." & Component & "] " & Event & " " & Detail);
   end Log;

end Flyology.QUIC.Debug;
