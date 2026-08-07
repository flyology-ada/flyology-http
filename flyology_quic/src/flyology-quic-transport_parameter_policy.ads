with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved QUIC transport-parameter codec.
--
--  The decoder applies the RFC 9000 sender-role, uniqueness, integer, and
--  mandatory-connection-ID rules. Unknown parameters are retained only in
--  the exact duplicate-detection set and otherwise ignored.
private package Flyology.QUIC.Transport_Parameter_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Transport_Parameters : constant := 256;
   Max_Encoded_Length       : constant := 512;

   type Endpoint_Role is (Client, Server);

   subtype Connection_ID_Length is Natural range 0 .. 20;
   subtype Connection_ID_Index is
     Ada.Streams.Stream_Element_Offset range 1 .. 20;

   type Connection_ID_Parameter is record
      Present : Boolean := False;
      Data    : Ada.Streams.Stream_Element_Array (Connection_ID_Index) :=
        (others => 0);
      Length  : Connection_ID_Length := 0;
   end record;

   type Reset_Token_Parameter is record
      Present : Boolean := False;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 16) := (others => 0);
   end record;

   type Integer_Parameter is record
      Present : Boolean := False;
      Value   : Varint_Policy.Value_Type := 0;
   end record;

   type Transport_Parameters is record
      Original_Destination_Connection_ID : Connection_ID_Parameter;
      Max_Idle_Timeout                   : Integer_Parameter;
      Stateless_Reset_Token              : Reset_Token_Parameter;
      Max_UDP_Payload_Size               : Integer_Parameter :=
        (Present => False, Value => 65_527);
      Initial_Max_Data                   : Integer_Parameter;
      Initial_Max_Stream_Data_Bidi_Local : Integer_Parameter;
      Initial_Max_Stream_Data_Bidi_Remote : Integer_Parameter;
      Initial_Max_Stream_Data_Uni        : Integer_Parameter;
      Initial_Max_Streams_Bidi           : Integer_Parameter;
      Initial_Max_Streams_Uni            : Integer_Parameter;
      ACK_Delay_Exponent                 : Integer_Parameter :=
        (Present => False, Value => 3);
      Max_ACK_Delay                      : Integer_Parameter :=
        (Present => False, Value => 25);
      Disable_Active_Migration           : Boolean := False;
      Preferred_Address_Received         : Boolean := False;
      Active_Connection_ID_Limit         : Integer_Parameter :=
        (Present => False, Value => 2);
      Initial_Source_Connection_ID       : Connection_ID_Parameter;
      Retry_Source_Connection_ID         : Connection_ID_Parameter;
   end record;

   type Decode_Status is
     (Decoded,
      Truncated,
      Too_Many_Parameters,
      Duplicate_Parameter,
      Forbidden_Parameter,
      Invalid_Parameter_Value,
      Missing_Mandatory_Parameter);

   type Decode_Result is record
      Status     : Decode_Status := Truncated;
      Parameters : Transport_Parameters;
      Count      : Natural range 0 .. Max_Transport_Parameters := 0;
   end record;

   function Decode
     (Data        : Ada.Streams.Stream_Element_Array;
      Sender_Role : Endpoint_Role) return Decode_Result
   with
     Global => null,
     Pre => Data'Length <= 65_535,
     Post =>
       (if Decode'Result.Status = Decoded then
           Decode'Result.Parameters.Initial_Source_Connection_ID.Present
           and then
             (if Sender_Role = Server then
                 Decode'Result.Parameters
                   .Original_Destination_Connection_ID.Present));

   type Encode_Status is
     (Encoded,
      Invalid_Parameters,
      Encoded_Parameters_Too_Large);

   subtype Encoded_Length is Natural range 0 .. Max_Encoded_Length;

   type Encode_Result is record
      Status : Encode_Status := Invalid_Parameters;
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Encoded_Length) :=
        (others => 0);
      Length : Encoded_Length := 0;
   end record;

   function Encode
     (Parameters  : Transport_Parameters;
      Sender_Role : Endpoint_Role) return Encode_Result
   with Global => null;
end Flyology.QUIC.Transport_Parameter_Policy;
