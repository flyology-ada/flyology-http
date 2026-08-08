with Ada.Streams;
with Flyology.QUIC.Connection_State_Policy;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Initial_Receiver;
with Flyology.QUIC.Initial_Sender;
with Flyology.QUIC.Long_Header_Policy;

--  Internal client/server state for the QUIC Initial encryption level.
--
--  The connection derives both directional key sets from the original
--  destination connection ID. Authenticated packet numbers are admitted by a
--  proved replay window before plaintext can be delivered to frame handling.
private package Flyology.QUIC.Initial_Connection is
   use type Ada.Streams.Stream_Element_Array;

   type Endpoint_Role is (Client, Server);

   type Build_Status is
     (Built,
      Packet_Number_Exhausted,
      Packet_Number_Unrepresentable,
      Insufficient_Protected_Payload,
      Packet_Too_Large,
      Output_Too_Small);

   type Build_Result is record
      Status        : Build_Status := Output_Too_Small;
      Number        : Connection_State_Policy.Packet_Number := 0;
      Packet_Length : Natural range 0 .. Initial_Sender.Max_Packet_Length := 0;
      Header_Length : Natural range 0 .. Initial_Sender.Max_Packet_Length := 0;
      Number_Length : Long_Header_Policy.Packet_Number_Length := 1;
   end record;

   type Process_Status is
     (Processed,
      Duplicate,
      Too_Old,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits);

   type Process_Result is record
      Status : Process_Status := Envelope_Rejected;
      Packet : Initial_Receiver.Receive_Result;
   end record;

   type Connection is limited private;

   function Is_Initialized (Item : Connection) return Boolean;

   procedure Initialize
     (Item                    : in out Connection;
      Role                    : Endpoint_Role;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID)
   with
     Pre =>
       not Is_Initialized (Item)
       and then Original_Destination_ID'Length <= 20
       and then Destination.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last
       and then Source.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last,
     Post => Is_Initialized (Item);

   procedure Build_Initial
     (Item      : in out Connection;
      Token     : Ada.Streams.Stream_Element_Array;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Build_Result)
   with
     Pre =>
       Is_Initialized (Item)
       and then Token'Length <= Initial_Sender.Max_Packet_Length
       and then Plaintext'Length <= Initial_Sender.Max_Packet_Length,
     Post =>
       (if Result.Status /= Built then Packet = (Packet'Range => 0)
        else Result.Packet_Length <= Packet'Length);

   procedure Build_Initial_At_Least
     (Item                  : in out Connection;
      Token                 : Ada.Streams.Stream_Element_Array;
      Plaintext             : Ada.Streams.Stream_Element_Array;
      Minimum_Packet_Length : Natural;
      Packet                : out Ada.Streams.Stream_Element_Array;
      Result                : out Build_Result)
   with
     Pre =>
       Is_Initialized (Item)
       and then Token'Length <= Initial_Sender.Max_Packet_Length
       and then Plaintext'Length <= Initial_Sender.Max_Packet_Length
       and then Minimum_Packet_Length <= Packet'Length
       and then Minimum_Packet_Length <= Initial_Sender.Max_Packet_Length,
     Post =>
       (if Result.Status /= Built then Packet = (Packet'Range => 0)
        else Result.Packet_Length in Minimum_Packet_Length .. Packet'Length);

   procedure Process_Initial
     (Item      : in out Connection;
      Packet    : Ada.Streams.Stream_Element_Array;
      Plaintext : out Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   with
     Pre =>
       Is_Initialized (Item)
       and then Packet'Length <= Initial_Sender.Max_Packet_Length
       and then Plaintext'Length >= Packet'Length,
     Post =>
       (if Result.Status /= Processed then
           Plaintext = (Plaintext'Range => 0));
private
   type Connection is limited record
      Backend : Crypto_OpenSSL.Provider;
      Keys    : Crypto_OpenSSL.Initial_Keys :=
        (Client_Secret | Client_Key | Client_IV | Client_HP |
         Server_Secret | Server_Key | Server_IV | Server_HP => (others => 0));
      Role        : Endpoint_Role := Client;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID;
      Send_State    : Connection_State_Policy.Connection_State;
      Receive_State : Connection_State_Policy.Connection_State;
      Initialized   : Boolean := False;
   end record;
end Flyology.QUIC.Initial_Connection;
