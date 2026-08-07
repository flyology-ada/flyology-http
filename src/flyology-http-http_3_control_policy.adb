with Flyology.HTTP.HTTP_3_Frame_Policy;

package body Flyology.HTTP.HTTP_3_Control_Policy
  with SPARK_Mode => On
is
   use type HTTP_3_Settings_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Has_Peer_Control (Item : Control_State) return Boolean is
     (Item.Peer_Control_Seen);

   function Has_Peer_Settings (Item : Control_State) return Boolean is
     (Item.Peer_Settings_Seen);

   function Peer_Settings
     (Item : Control_State) return HTTP_3_Settings_Policy.Settings is
       (Item.Settings);

   procedure Register_Peer_Control
     (Item       : in out Control_State;
      Stream_ID  : Varint_Policy.Value_Type;
      Local_Role : HTTP_3_Stream_Policy.Endpoint_Role;
      Status     : out Operation_Status)
   is
   begin
      Status := Stream_Creation_Error;
      if Item.Peer_Control_Seen
        or else not HTTP_3_Stream_Policy.Is_Unidirectional (Stream_ID)
        or else not HTTP_3_Stream_Policy.Is_Peer_Initiated
          (Stream_ID, Local_Role)
      then
         return;
      end if;
      Item.Peer_Control_Seen := True;
      Item.Peer_Control_ID := Stream_ID;
      Status := Accepted;
   end Register_Peer_Control;

   procedure Process_Frame
     (Item       : in out Control_State;
      Frame_Type : Varint_Policy.Value_Type;
      Payload    : Ada.Streams.Stream_Element_Array;
      Status     : out Operation_Status)
   is
      Parsed : HTTP_3_Settings_Policy.Decode_Result;
   begin
      if not Item.Peer_Control_Seen then
         Status := Stream_Creation_Error;
      elsif not Item.Peer_Settings_Seen then
         if Frame_Type /= HTTP_3_Frame_Policy.Settings_Frame then
            Status := Missing_Settings;
            return;
         end if;
         Parsed := HTTP_3_Settings_Policy.Decode (Payload);
         if Parsed.Status /= HTTP_3_Settings_Policy.Decoded then
            Status := Settings_Error;
            return;
         end if;
         Item.Settings := Parsed.Value;
         Item.Peer_Settings_Seen := True;
         Status := Accepted;
      elsif Frame_Type = HTTP_3_Frame_Policy.Settings_Frame
        or else Frame_Type = HTTP_3_Frame_Policy.Data_Frame
        or else Frame_Type = HTTP_3_Frame_Policy.Headers_Frame
        or else Frame_Type = HTTP_3_Frame_Policy.Push_Promise_Frame
      then
         Status := Frame_Unexpected;
      else
         Status := Accepted;
      end if;
   end Process_Frame;

   procedure Peer_Stream_Closed
     (Item      : Control_State;
      Stream_ID : Varint_Policy.Value_Type;
      Status    : out Operation_Status)
   is
   begin
      Status :=
        (if Item.Peer_Control_Seen
           and then Stream_ID = Item.Peer_Control_ID
         then Critical_Stream_Closed
         else Accepted);
   end Peer_Stream_Closed;

   function Build_Local_Preface
     (Settings : HTTP_3_Settings_Policy.Settings) return Preface_Result
   is
      Result  : Preface_Result;
      Payload : constant HTTP_3_Settings_Policy.Encode_Result :=
        HTTP_3_Settings_Policy.Encode (Settings);
   begin
      Result.Data (1) := 0;
      Result.Data (2) := 4;
      Result.Data (3) := Ada.Streams.Stream_Element (Payload.Length);
      for Index in 1 .. Payload.Length loop
         pragma Loop_Invariant (Index + 3 <= Max_Preface_Length);
         pragma Loop_Invariant
           (Result.Data (1) = 0 and then Result.Data (2) = 4);
         Result.Data (Ada.Streams.Stream_Element_Offset (Index + 3)) :=
           Payload.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Result.Length := Payload.Length + 3;
      return Result;
   end Build_Local_Preface;
end Flyology.HTTP.HTTP_3_Control_Policy;
