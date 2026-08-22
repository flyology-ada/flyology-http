package body Flyology.HTTP.Server.Connections is

   package Drivers renames Flyology.IO.Connections.Drivers;

   overriding procedure Receive
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Flyology.IO.Connections.Receive
        (Item.Channel.all, Data, Last, Timeout => Timeout, Token => Token);
   end Receive;

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Flyology.IO.Connections.Send_All
        (Item.Channel.all, Data, Timeout => Timeout, Token => Token);
   end Send_All;

   overriding procedure Start_IO
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Timeout   : Duration;
      Token     : access Flyology.Cancellation.Token;
      Result    : out Drivers.Acquisition_Result)
   is
   begin
      Drivers.Start (Item.IO, Item.Channel, Result, Timeout, Token);
      Drivers.Arm_Deadline (Item.IO, Operation);
   end Start_IO;

   overriding procedure Poll_IO
     (Item   : in out Connection_Transport;
      Result : out Drivers.Acquisition_Result) is
   begin
      Drivers.Poll_Acquisition (Item.IO, Result);
   end Poll_IO;

   overriding procedure Arm_IO_Acquisition
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class) is
   begin
      Drivers.Arm_Acquisition (Item.IO, Operation);
   end Arm_IO_Acquisition;

   overriding procedure Receive_IO
     (Item   : in out Connection_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Drivers.Step_Result) is
   begin
      Drivers.Receive (Item.IO, Data, Last, Result);
   end Receive_IO;

   overriding procedure Send_IO
     (Item   : in out Connection_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Drivers.Step_Result) is
   begin
      Drivers.Send (Item.IO, Data, Last, Result);
   end Send_IO;

   overriding procedure Arm_IO_Transport
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Drivers.Step_Result) is
   begin
      Drivers.Arm_Transport (Item.IO, Operation, Required);
   end Arm_IO_Transport;

   overriding procedure Release_IO (Item : in out Connection_Transport) is
   begin
      Drivers.Release (Item.IO);
   end Release_IO;

end Flyology.HTTP.Server.Connections;
