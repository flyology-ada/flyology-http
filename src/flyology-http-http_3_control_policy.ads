with Ada.Streams;
with Flyology.HTTP.HTTP_3_Settings_Policy;
with Flyology.HTTP.HTTP_3_Stream_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 control-stream lifecycle policy.
private package Flyology.HTTP.HTTP_3_Control_Policy
  with SPARK_Mode => On
is
   package Varint_Policy renames Flyology.QUIC.Varint_Policy;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   type Control_State is private;

   type Operation_Status is
     (Accepted,
      Stream_Creation_Error,
      Missing_Settings,
      Frame_Unexpected,
      Settings_Error,
      Frame_Error,
      ID_Error,
      Critical_Stream_Closed);

   function Has_Peer_Control (Item : Control_State) return Boolean
   with Global => null;

   function Has_Peer_Settings (Item : Control_State) return Boolean
   with Global => null;

   function Peer_Settings
     (Item : Control_State) return HTTP_3_Settings_Policy.Settings
   with
     Global => null,
     Pre => Has_Peer_Settings (Item);

   function Has_Peer_Goaway (Item : Control_State) return Boolean
   with Global => null;

   function Peer_Goaway_ID
     (Item : Control_State) return Varint_Policy.Value_Type
   with
     Global => null,
     Pre => Has_Peer_Goaway (Item);

   procedure Register_Peer_Control
     (Item       : in out Control_State;
      Stream_ID  : Varint_Policy.Value_Type;
      Local_Role : HTTP_3_Stream_Policy.Endpoint_Role;
      Status     : out Operation_Status)
   with
     Global => null,
     Post =>
       (if Status = Accepted then Has_Peer_Control (Item)
        else Has_Peer_Control (Item) = Has_Peer_Control (Item'Old));

   procedure Process_Frame
     (Item       : in out Control_State;
      Frame_Type : Varint_Policy.Value_Type;
      Payload    : Ada.Streams.Stream_Element_Array;
      Status     : out Operation_Status)
   with
     Global => null,
     Pre => Payload'Length <= HTTP_3_Settings_Policy.Max_Payload_Length,
     Post =>
       (if Status = Accepted
          and then Frame_Type = 16#04#
          and then not Has_Peer_Settings (Item'Old)
        then Has_Peer_Settings (Item))
       and then
         (if Status = Accepted
            and then Frame_Type = 16#07#
          then Has_Peer_Goaway (Item));

   procedure Peer_Stream_Closed
     (Item      : Control_State;
      Stream_ID : Varint_Policy.Value_Type;
      Status    : out Operation_Status)
   with Global => null;

   Max_Preface_Length : constant :=
     HTTP_3_Settings_Policy.Max_Encoded_Length + 3;

   subtype Preface_Length is Natural range 0 .. Max_Preface_Length;

   type Preface_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Preface_Length) :=
        (others => 0);
      Length : Preface_Length := 0;
   end record;

   function Build_Local_Preface
     (Settings : HTTP_3_Settings_Policy.Settings) return Preface_Result
   with
     Global => null,
     Post => Build_Local_Preface'Result.Length in 7 .. Max_Preface_Length
       and then Build_Local_Preface'Result.Data (1) = 0
       and then Build_Local_Preface'Result.Data (2) = 4;
private
   type Control_State is record
      Peer_Control_Seen  : Boolean := False;
      Peer_Settings_Seen : Boolean := False;
      Peer_Control_ID    : Varint_Policy.Value_Type := 0;
      Settings           : HTTP_3_Settings_Policy.Settings;
      Local_Role         : HTTP_3_Stream_Policy.Endpoint_Role :=
        HTTP_3_Stream_Policy.Client;
      Peer_Goaway_Seen   : Boolean := False;
      Peer_Goaway        : Varint_Policy.Value_Type := 0;
      Max_Push_ID_Seen   : Boolean := False;
      Max_Push_ID        : Varint_Policy.Value_Type := 0;
   end record;
end Flyology.HTTP.HTTP_3_Control_Policy;
