with Ada.Streams;
with Flyology.HTTP.Headers;
with Flyology.HTTP.HTTP_3;
with Flyology.IO;
with Flyology.QUIC.Connections;
with Flyology.Wake_Sources;

--  Bounded, task-free coordination for multiplexed owner-driven HTTP/3
--  client streams. The caller serializes QUIC and HTTP/3 state transitions
--  by claiming the pump, then publishes decoded events here.
private package Flyology.HTTP.HTTP_3_Client_Connection is

   Maximum_Concurrent_Streams : constant Positive := 32;

   type Session is limited private;

   type Stream_Handle is private;
   No_Stream : constant Stream_Handle;

   type Head_Result is
     (Head_Ready, Head_Would_Block, Head_Connection_Failed,
      Head_Stream_Failed);
   type Body_Result is
     (Body_Progress, Body_Would_Block, Body_Finished,
      Body_Connection_Failed, Body_Stream_Failed);

   procedure Open
     (Item     : in out Session;
      Stream   : Flyology.QUIC.Connections.Stream_ID;
      Handle   : out Stream_Handle;
      Accepted : out Boolean;
      Head_Request : Boolean := False);

   procedure Reserve
     (Item : in out Session;
      Handle : out Stream_Handle;
      Accepted : out Boolean;
      Head_Request : Boolean := False);

   procedure Bind
     (Item : in out Session;
      Handle : in out Stream_Handle;
      Stream : Flyology.QUIC.Connections.Stream_ID);

   function Can_Open (Item : Session) return Boolean;
   function Is_Usable (Item : Session) return Boolean;

   procedure Try_Claim_Pump
     (Item : in out Session; Handle : Stream_Handle; Claimed : out Boolean);
   function Owns_Pump
     (Item : Session; Handle : Stream_Handle) return Boolean;
   procedure Release_Pump
     (Item : in out Session; Handle : Stream_Handle);
   procedure Pump_Wait_Source
     (Item : in out Session;
      Handle : Stream_Handle;
      FD : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean);

   --  Wake a pump currently blocked in UDP receive because this stream has
   --  request output ready to commit.
   procedure Signal_Outbound
     (Item : in out Session; Handle : Stream_Handle);
   procedure Outbound_Wait_Source
     (Item : in out Session;
      FD : out Flyology.IO.Descriptor;
      Pending : out Boolean);
   procedure Consume_Outbound
     (Item : in out Session; Handle : Stream_Handle);

   function Has_Response_Observation
     (Item : Session; Handle : Stream_Handle) return Boolean;

   --  Route one event obtained while holding the pump. This copies only
   --  bounded response metadata/body state and wakes the affected stream.
   procedure Publish
     (Item   : in out Session;
      Event  : Flyology.HTTP.HTTP_3.Event;
      Result : out Boolean);
   procedure Fail_All (Item : in out Session);

   procedure Poll_Head
     (Item : in out Session;
      Handle : Stream_Handle;
      Result : out Head_Result;
      Status : out Status_Code;
      Fields : in out Flyology.HTTP.Headers.List;
      Finished : out Boolean);

   procedure Read
     (Item : in out Session;
      Handle : Stream_Handle;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Result : out Body_Result;
      Trailers : in out Flyology.HTTP.Headers.List);

   procedure Wait_Source
     (Item : in out Session;
      Handle : Stream_Handle;
      FD : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean);

   procedure Cancel_Stream
     (Item : in out Session; Handle : Stream_Handle);
   procedure Release_Stream
     (Item : in out Session; Handle : Stream_Handle);

   function Identifier
     (Handle : Stream_Handle) return Flyology.QUIC.Connections.Stream_ID;

private
   Response_Buffer_Capacity : constant Positive := 65_535;
   type Response_Storage is array (Positive range 1 ..
     Response_Buffer_Capacity) of Ada.Streams.Stream_Element;
   type Stream_Phase is (Free, Open, Complete, Failed);
   type Stream_Record is limited record
      Phase          : Stream_Phase := Free;
      ID             : Flyology.QUIC.Connections.Stream_ID := 0;
      Head_Available : Boolean := False;
      Head_Delivered : Boolean := False;
      Status         : Status_Code := 200;
      Fields         : Flyology.HTTP.Headers.List;
      Trailers       : Flyology.HTTP.Headers.List;
      Trailers_Seen  : Boolean := False;
      Content        : Response_Storage;
      Content_First  : Positive := 1;
      Content_Count  : Natural range 0 .. Response_Buffer_Capacity := 0;
      Remote_End     : Boolean := False;
      Body_Forbidden : Boolean := False;
      Has_Expected_Length : Boolean := False;
      Expected_Length : Body_Size := 0;
      Received_Length : Body_Size := 0;
      Response_Observed : Boolean := False;
      Wake           : Flyology.Wake_Sources.Source;
      Wake_Signalled : Boolean := False;
      Outbound_Pending : Boolean := False;
   end record;
   type Stream_Array is array (Positive range 1 ..
     Maximum_Concurrent_Streams) of Stream_Record;

   type Stream_Handle is record
      Slot : Natural := 0;
      ID   : Flyology.QUIC.Connections.Stream_ID := 0;
   end record;
   No_Stream : constant Stream_Handle := (Slot => 0, ID => 0);

   protected type Controller is
      procedure Open
        (Stream : Flyology.QUIC.Connections.Stream_ID;
         Handle : out Stream_Handle;
         Accepted : out Boolean;
         Head_Request : Boolean);
      procedure Reserve
        (Handle : out Stream_Handle;
         Accepted : out Boolean;
         Head_Request : Boolean);
      procedure Bind
        (Handle : in out Stream_Handle;
         Stream : Flyology.QUIC.Connections.Stream_ID);
      function Can_Open return Boolean;
      function Is_Usable return Boolean;
      procedure Try_Claim_Pump
        (Handle : Stream_Handle; Claimed : out Boolean);
      function Owns_Pump (Handle : Stream_Handle) return Boolean;
      procedure Release_Pump (Handle : Stream_Handle);
      procedure Pump_Wait_Source
        (Handle : Stream_Handle;
         FD : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean);
      procedure Signal_Outbound (Handle : Stream_Handle);
      procedure Outbound_Wait_Source
        (FD : out Flyology.IO.Descriptor; Pending : out Boolean);
      procedure Consume_Outbound (Handle : Stream_Handle);
      function Has_Response_Observation
        (Handle : Stream_Handle) return Boolean;
      procedure Publish
        (Event : Flyology.HTTP.HTTP_3.Event; Result : out Boolean);
      procedure Fail_All;
      procedure Poll_Head
        (Handle : Stream_Handle;
         Result : out Head_Result;
         Status : out Status_Code;
         Fields : in out Flyology.HTTP.Headers.List;
         Finished : out Boolean);
      procedure Read
        (Handle : Stream_Handle;
         Data : out Ada.Streams.Stream_Element_Array;
         Last : out Ada.Streams.Stream_Element_Offset;
         Finished : out Boolean;
         Result : out Body_Result;
         Trailers : in out Flyology.HTTP.Headers.List);
      procedure Wait_Source
        (Handle : Stream_Handle;
         FD : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean);
      procedure Cancel_Stream (Handle : Stream_Handle);
      procedure Release_Stream (Handle : Stream_Handle);
   private
      Streams          : Stream_Array;
      Broken           : Boolean := False;
      Draining         : Boolean := False;
      Pump_Owner       : Natural := 0;
      Outbound_Wake    : Flyology.Wake_Sources.Source;
      Outbound_Signalled : Boolean := False;
   end Controller;

   type Session is limited record
      Streams : Controller;
   end record;
end Flyology.HTTP.HTTP_3_Client_Connection;
