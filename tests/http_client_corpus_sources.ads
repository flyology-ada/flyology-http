with Ada.Streams;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.Wake_Sources;

package HTTP_Client_Corpus_Sources is
   package Client renames Flyology.HTTP.Client;

   type Fault_Kind is
     (Short_Source,
      Long_Source,
      Zero_Progress_Source,
      Needs_With_Bytes_Source,
      Exceptional_Source);

   type Fault_Source
     (Fault : Fault_Kind := Short_Source;
      External_Wake : access Flyology.Wake_Sources.Source := null)
   is limited new
     Client.Operation_Request_Body_Source with private;

   overriding function Declared_Length
     (Item : Fault_Source) return Client.Body_Length;

   overriding procedure Read_Now
     (Item   : in out Fault_Source;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Client.Source_Step_Kind);

   overriding procedure Source_Wait_Source
     (Item        : in out Fault_Source;
      Required    : Client.Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean);

   overriding procedure Release_Source (Item : in out Fault_Source);

   function Release_Count (Item : Fault_Source) return Natural;

private
   type Fault_Source
     (Fault : Fault_Kind := Short_Source;
      External_Wake : access Flyology.Wake_Sources.Source := null)
   is limited new
     Client.Operation_Request_Body_Source with record
      Armed    : Boolean := False;
      Step     : Natural := 0;
      Releases : Natural := 0;
      Local_Wake : Flyology.Wake_Sources.Source;
   end record;
end HTTP_Client_Corpus_Sources;
