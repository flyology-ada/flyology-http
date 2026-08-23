with Ada.Streams;
with Flyology.HTTP.Client;

package HTTP_Client_Corpus_Sinks is
   package Client renames Flyology.HTTP.Client;

   type Fault_Kind is (Immediate_Failure, Partial_Failure);

   type Fault_Sink (Fault : Fault_Kind) is new
     Client.Response_Body_Sink with private;

   overriding procedure Write
     (Item : in out Fault_Sink;
      Data : Ada.Streams.Stream_Element_Array);

   function Visible_Bytes (Item : Fault_Sink) return Natural;
   function Write_Count (Item : Fault_Sink) return Natural;

private
   type Fault_Sink (Fault : Fault_Kind) is new
     Client.Response_Body_Sink with record
      Visible : Natural := 0;
      Writes  : Natural := 0;
   end record;
end HTTP_Client_Corpus_Sinks;
