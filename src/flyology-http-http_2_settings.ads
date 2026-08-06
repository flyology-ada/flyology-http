with Ada.Streams;
with Interfaces;
with Flyology.HTTP.HTTP_2_Frames;
with Flyology.HTTP.Headers;

--  Parses peer SETTINGS payloads and retains the connection-wide values used
--  by the HTTP/2 client. Unknown settings are deliberately ignored.
private package Flyology.HTTP.HTTP_2_Settings is

   package Frames renames Flyology.HTTP.HTTP_2_Frames;
   subtype Setting_Value is Interfaces.Unsigned_32;
   Advertised_Header_List_Size : constant Setting_Value :=
     Setting_Value (Flyology.HTTP.Headers.Default_Max_Bytes);
   Advertised_Initial_Window_Size : constant Setting_Value :=
     Setting_Value (16_384);

   type State is record
      Header_Table_Size      : Setting_Value := 4_096;
      Enable_Push            : Boolean := True;
      Maximum_Streams        : Setting_Value := Setting_Value'Last;
      Initial_Window_Size    : Setting_Value := 65_535;
      Maximum_Frame_Size     : Frames.Maximum_Frame_Size :=
        Frames.Default_Maximum_Frame_Size;
      Maximum_Header_List_Size : Setting_Value := Setting_Value'Last;
   end record;

   type Apply_Result is
     (Settings_Accepted,
      Settings_Protocol_Error,
      Settings_Flow_Control_Error);

   --  Apply one non-ACK SETTINGS payload. Payload length must be divisible by
   --  six; frame-header validation normally enforces that before this call.
   procedure Apply
     (Item    : in out State;
      Payload : Ada.Streams.Stream_Element_Array;
      Result  : out Apply_Result;
      Peer_Is_Server : Boolean := True);

   --  Encode the initial client settings: disable server push and advertise
   --  bounded decoded-header and per-stream receive windows.
   function Initial_Payload return Ada.Streams.Stream_Element_Array;

   --  Encode bounded server settings without the client-only ENABLE_PUSH
   --  field.
   function Server_Initial_Payload
     (Maximum_Streams : Positive) return Ada.Streams.Stream_Element_Array;

end Flyology.HTTP.HTTP_2_Settings;
