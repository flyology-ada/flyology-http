with Ada.Real_Time;
with Ada.Streams;
with Flyology.Cancellation;

--  Internal protocol-engine boundary used by application exchanges that are
--  not backed by the HTTP/1.x Connection object. Implementations preserve the
--  synchronous public API while retaining sole ownership of their wire I/O.
package Flyology.HTTP.Server.Exchange_Backends is
   --  @exclude Internal protocol-engine interface.

   --  @exclude
   type Backend is limited interface;

   --  @exclude
   --  @param Item Backend state
   --  @return True after response framing starts
   function Response_Started (Item : Backend) return Boolean is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Deadline Earlier deadline
   procedure Narrow_Deadline
     (Item : in out Backend; Deadline : Ada.Real_Time.Time) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @return True after the complete request body arrives
   function Body_Complete (Item : Backend) return Boolean is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @return Request body bytes received
   function Body_Bytes (Item : Backend) return Body_Size is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @return Physical trailer count
   function Trailer_Count (Item : Backend) return Natural is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Name Trailer field name
   --  @return Physical occurrence count
   function Trailer_Count
     (Item : Backend; Name : String) return Natural is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Index One-based physical trailer index
   --  @return Trailer field name
   function Trailer_Name
     (Item : Backend; Index : Positive) return String is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Index One-based physical trailer index
   --  @return Trailer field value
   function Trailer_Value
     (Item : Backend; Index : Positive) return String is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Name Trailer field name
   --  @param Occurrence One-based physical occurrence
   --  @return Trailer field value or an empty string
   function Trailer
     (Item       : Backend;
      Name       : String;
      Occurrence : Positive) return String is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Maximum New request body limit
   procedure Narrow_Body_Limit
     (Item : in out Backend; Maximum : Body_Size) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Data Destination buffer
   --  @param Last Last byte read
   --  @param Finished True at end of stream
   --  @param Token Cancellation token
   procedure Read_Body
     (Item     : in out Backend;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Token Cancellation token
   procedure Accept_Body
     (Item  : in out Backend;
      Token : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Value Request receiving retained body bytes
   --  @param Token Cancellation token
   procedure Buffer_Body
     (Item  : in out Backend;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Token Cancellation token
   procedure Discard_Body
     (Item  : in out Backend;
      Token : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Status Response status
   --  @param Content_Type Response media type
   --  @param Payload Response body
   --  @param Extra_Headers Serialized application fields
   --  @param Close Ignored HTTP/1.x close policy
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Respond
     (Item          : in out Backend;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Status Response status
   --  @param Content_Type Response media type
   --  @param Extra_Headers Serialized application fields
   --  @param Close Ignored HTTP/1.x close policy
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Begin_Response_Stream
     (Item          : in out Backend;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Status Response status
   --  @param Content_Type Response media type
   --  @param Content_Length Declared representation length
   --  @param Extra_Headers Serialized application fields
   --  @param Close Ignored HTTP/1.x close policy
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Begin_Response_Stream
     (Item           : in out Backend;
      Status         : Positive;
      Content_Type   : String;
      Content_Length : Body_Size;
      Extra_Headers  : String;
      Close          : Boolean;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Data Response bytes
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Write_Response_Chunk
     (Item    : in out Backend;
      Data    : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Data Response bytes
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Write_Response_Chunk
     (Item    : in out Backend;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure End_Response_Stream
     (Item    : in out Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Extra_Headers Serialized application fields
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Begin_SSE
     (Item          : in out Backend;
      Extra_Headers : String;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Data Event data
   --  @param Event Event name
   --  @param Id Event identifier
   --  @param Retry Retry interval
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   --  @param Include_Id Whether to emit Id
   --  @param Include_Retry Whether to emit Retry
   procedure Send_Event
     (Item          : in out Backend;
      Data          : String;
      Event         : String;
      Id            : String;
      Retry         : Natural;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Include_Id    : Boolean;
      Include_Retry : Boolean) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Comment Comment text
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure Send_SSE_Comment
     (Item    : in out Backend;
      Comment : String;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   --  @param Timeout Operation deadline interval
   --  @param Token Cancellation token
   procedure End_SSE
     (Item    : in out Backend;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is abstract;

   --  @exclude
   --  @param Item Backend state
   procedure Mark_Failed (Item : in out Backend) is abstract;

end Flyology.HTTP.Server.Exchange_Backends;
