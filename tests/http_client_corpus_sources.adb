with Interfaces.C;

package body HTTP_Client_Corpus_Sources is
   use type Ada.Streams.Stream_Element_Offset;
   use type Client.Source_Step_Kind;
   use type Interfaces.C.int;

   overriding function Declared_Length
     (Item : Fault_Source) return Client.Body_Length is
     (Client.Known_Length
        (case Item.Fault is
            when Short_Source => 8,
            when Long_Source => 4,
            when others => 1));

   overriding procedure Read_Now
     (Item   : in out Fault_Source;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Client.Source_Step_Kind) is
   begin
      Data := (others => 0);
      if Item.External_Wake /= null and then not Item.Armed then
         Item.Armed := True;
         Last := Data'First - 1;
         Result := Client.Source_Needs_Read;
         return;
      end if;
      case Item.Fault is
         when Short_Source =>
            if Item.Step = 0 then
               Last := Data'First + 3;
               Result := Client.Source_Progress;
            else
               Last := Data'First - 1;
               Result := Client.Source_Finished;
            end if;
         when Long_Source =>
            Last := Data'First + 4;
            Result := Client.Source_Progress;
         when Zero_Progress_Source =>
            Last := Data'First - 1;
            Result := Client.Source_Progress;
         when Needs_With_Bytes_Source =>
            Last := Data'First;
            Result := Client.Source_Needs_Read;
         when Exceptional_Source =>
            raise Constraint_Error with "corpus source failure";
      end case;
      Item.Step := Item.Step + 1;
   end Read_Now;

   overriding procedure Source_Wait_Source
     (Item        : in out Fault_Source;
      Required    : Client.Source_Wait_Kind;
      Descriptor  : out Flyology.IO.Descriptor;
      Ready_Now   : out Boolean) is
   begin
      pragma Assert (Required = Client.Source_Needs_Read);
      if Item.External_Wake = null then
         Flyology.Wake_Sources.Ensure (Item.Local_Wake);
         Descriptor := Flyology.Wake_Sources.Descriptor (Item.Local_Wake);
      else
         Descriptor := Flyology.Wake_Sources.Descriptor
           (Item.External_Wake.all);
         pragma Assert (Descriptor >= 0);
      end if;
      Ready_Now := False;
   end Source_Wait_Source;

   overriding procedure Release_Source (Item : in out Fault_Source) is
   begin
      if Item.External_Wake = null then
         if Flyology.Wake_Sources.Descriptor (Item.Local_Wake) >= 0 then
            Flyology.Wake_Sources.Release (Item.Local_Wake);
         end if;
      elsif Flyology.Wake_Sources.Descriptor (Item.External_Wake.all) >= 0
      then
         Flyology.Wake_Sources.Release (Item.External_Wake.all);
      end if;
      Item.Releases := Item.Releases + 1;
   end Release_Source;

   function Release_Count (Item : Fault_Source) return Natural is
     (Item.Releases);
end HTTP_Client_Corpus_Sources;
