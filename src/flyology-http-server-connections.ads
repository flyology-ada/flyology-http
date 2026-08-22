with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.Operations;

--  Adapts an owned plain Flyology connection to the HTTP transport boundary.
package Flyology.HTTP.Server.Connections is

   --  Borrowing adapter. Channel remains the sole closing owner and must
   --  outlive this object and every HTTP.Server.Connection that refers to it.
   --  The discriminant is the borrowed plain connection.
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection)
   is limited new Flyology.HTTP.Server.Operation_Transport with private;

   --  Forward a receive through the owned plain connection.
   --  @param Item Plain HTTP transport
   --  @param Data Destination buffer
   --  @param Last Last received byte or close sentinel
   --  @param Timeout Operation deadline
   --  @param Token Optional cancellation source
   overriding procedure Receive
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   --  Forward a complete send through the owned plain connection.
   --  @param Item Plain HTTP transport
   --  @param Data Source bytes
   --  @param Timeout Operation deadline
   --  @param Token Optional cancellation source
   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   --  Start one bounded connection-driver acquisition.
   --  @param Item Plain HTTP transport
   --  @param Operation HTTP operation that owns readiness
   --  @param Timeout Shared acquisition and transport deadline
   --  @param Token Optional cancellation source
   --  @param Result Immediate acquisition result
   overriding procedure Start_IO
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Timeout   : Duration;
      Token     : access Flyology.Cancellation.Token;
      Result    : out
        Flyology.IO.Connections.Drivers.Acquisition_Result);

   --  Poll an armed connection-driver acquisition.
   --  @param Item Plain HTTP transport
   --  @param Result Immediate acquisition result
   overriding procedure Poll_IO
     (Item   : in out Connection_Transport;
      Result : out Flyology.IO.Connections.Drivers.Acquisition_Result);

   --  Arm the HTTP operation for connection-lease readiness.
   --  @param Item Plain HTTP transport
   --  @param Operation HTTP operation that owns readiness
   overriding procedure Arm_IO_Acquisition
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class);

   --  Perform one immediate bounded receive step.
   --  @param Item Plain HTTP transport
   --  @param Data Destination buffer
   --  @param Last Last received byte or no-progress sentinel
   --  @param Result Progress, required readiness, or peer closure
   overriding procedure Receive_IO
     (Item   : in out Connection_Transport;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Flyology.IO.Connections.Drivers.Step_Result);

   --  Perform one immediate bounded send step.
   --  @param Item Plain HTTP transport
   --  @param Data Source buffer
   --  @param Last Last sent byte or no-progress sentinel
   --  @param Result Progress, required readiness, or peer closure
   overriding procedure Send_IO
     (Item   : in out Connection_Transport;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Flyology.IO.Connections.Drivers.Step_Result);

   --  Arm the HTTP operation for the readiness required by an I/O step.
   --  @param Item Plain HTTP transport
   --  @param Operation HTTP operation that owns readiness
   --  @param Required Need_Read or Need_Write from the preceding step
   overriding procedure Arm_IO_Transport
     (Item      : in out Connection_Transport;
      Operation : in out Flyology.Operations.Operation'Class;
      Required  : Flyology.IO.Connections.Drivers.Step_Result);

   --  Release the connection-driver capability before terminal publication.
   --  @param Item Plain HTTP transport
   overriding procedure Release_IO (Item : in out Connection_Transport);

private
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection)
   is limited new Flyology.HTTP.Server.Operation_Transport with record
      IO : Flyology.IO.Connections.Drivers.Capability;
   end record;

end Flyology.HTTP.Server.Connections;
