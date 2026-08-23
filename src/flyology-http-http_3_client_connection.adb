with Ada.Characters.Handling;
package body Flyology.HTTP.HTTP_3_Client_Connection is
   use Ada.Streams;
   use type Flyology.HTTP.HTTP_3.Event_Kind;
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   use type QUIC.Stream_ID;

   function Valid_Regular_Response_Name (Name : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      return Name'Length > 0
        and then Name = Lower
        and then Name (Name'First) /= ':'
        and then Lower not in
          "connection" | "keep-alive" | "proxy-connection" | "te" |
          "transfer-encoding" | "upgrade";
   end Valid_Regular_Response_Name;

   procedure Parse_Content_Length
     (Fields  : Flyology.HTTP.Headers.List;
      Present : out Boolean;
      Value   : out Body_Size;
      Valid   : out Boolean)
   is
      Count : constant Natural :=
        Flyology.HTTP.Headers.Count (Fields, "content-length");
   begin
      Present := Count > 0;
      Value := 0;
      Valid := Count <= 1;
      if not Present or else not Valid then
         return;
      end if;
      declare
         Text : constant String :=
           Flyology.HTTP.Headers.Value (Fields, "content-length");
      begin
         if Text'Length = 0 then
            Valid := False;
            return;
         end if;
         for C of Text loop
            if C not in '0' .. '9'
              or else Value >
                (Body_Size'Last - Body_Size
                   (Character'Pos (C) - Character'Pos ('0'))) / 10
            then
               Valid := False;
               return;
            end if;
            Value := Value * 10 +
              Body_Size (Character'Pos (C) - Character'Pos ('0'));
         end loop;
      end;
   end Parse_Content_Length;

   protected body Controller is
      function Valid (Handle : Stream_Handle) return Boolean is
        (Handle.Slot in Streams'Range
           and then Streams (Handle.Slot).Phase /= Free
           and then Streams (Handle.Slot).ID = Handle.ID);

      procedure Wake_Stream (Index : Positive) is
      begin
         Flyology.Wake_Sources.Ensure (Streams (Index).Wake);
         if not Streams (Index).Wake_Signalled then
            Flyology.Wake_Sources.Signal (Streams (Index).Wake);
            Streams (Index).Wake_Signalled := True;
         end if;
      end Wake_Stream;

      procedure Wake_Pump is
      begin
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free then
               Wake_Stream (Index);
            end if;
         end loop;
      end Wake_Pump;

      procedure Open
        (Stream : QUIC.Stream_ID;
         Handle : out Stream_Handle;
         Accepted : out Boolean;
         Head_Request : Boolean) is
      begin
         Handle := No_Stream;
         Accepted := False;
         if Broken or else Draining then
            return;
         end if;
         for Index in Streams'Range loop
            if Streams (Index).Phase = Free then
               Streams (Index).Phase := Open;
               Streams (Index).ID := Stream;
               Streams (Index).Head_Available := False;
               Streams (Index).Head_Delivered := False;
               Streams (Index).Content_First := 1;
               Streams (Index).Content_Count := 0;
               Streams (Index).Remote_End := False;
               Streams (Index).Body_Forbidden := Head_Request;
               Streams (Index).Has_Expected_Length := False;
               Streams (Index).Expected_Length := 0;
               Streams (Index).Received_Length := 0;
               Streams (Index).Response_Observed := False;
               Streams (Index).Outbound_Pending := False;
               Flyology.HTTP.Headers.Clear (Streams (Index).Fields);
               Flyology.HTTP.Headers.Clear (Streams (Index).Trailers);
               Streams (Index).Trailers_Seen := False;
               if Streams (Index).Wake_Signalled then
                  Flyology.Wake_Sources.Consume (Streams (Index).Wake);
                  Streams (Index).Wake_Signalled := False;
               end if;
               Handle := (Slot => Index, ID => Stream);
               Accepted := True;
               return;
            end if;
         end loop;
      end Open;

      procedure Reserve
        (Handle : out Stream_Handle;
         Accepted : out Boolean;
         Head_Request : Boolean) is
      begin
         Open (0, Handle, Accepted, Head_Request);
      end Reserve;

      procedure Bind
        (Handle : in out Stream_Handle; Stream : QUIC.Stream_ID) is
      begin
         if not Valid (Handle) or else Handle.ID /= 0 then
            raise Program_Error with "invalid HTTP/3 stream binding";
         end if;
         Streams (Handle.Slot).ID := Stream;
         Handle.ID := Stream;
      end Bind;

      function Can_Open return Boolean is
      begin
         if Broken or else Draining then
            return False;
         end if;
         for Stream of Streams loop
            if Stream.Phase = Free then
               return True;
            end if;
         end loop;
         return False;
      end Can_Open;

      function Is_Usable return Boolean is (not Broken and not Draining);

      procedure Try_Claim_Pump
        (Handle : Stream_Handle; Claimed : out Boolean) is
         Other_Outbound : Boolean := False;
      begin
         if Valid (Handle) then
            for Index in Streams'Range loop
               if Index /= Handle.Slot
                 and then Streams (Index).Outbound_Pending
               then
                  Other_Outbound := True;
               end if;
            end loop;
         end if;
         Claimed := Valid (Handle) and then not Broken
           and then Pump_Owner in 0 | Handle.Slot
           and then
             (Streams (Handle.Slot).Outbound_Pending
                or else not Other_Outbound);
         if Claimed then
            Pump_Owner := Handle.Slot;
         end if;
      end Try_Claim_Pump;

      function Owns_Pump (Handle : Stream_Handle) return Boolean is
        (Valid (Handle) and then Pump_Owner = Handle.Slot);

      procedure Release_Pump (Handle : Stream_Handle) is
      begin
         if Pump_Owner = Handle.Slot then
            Pump_Owner := 0;
            Wake_Pump;
         end if;
      end Release_Pump;

      procedure Pump_Wait_Source
        (Handle : Stream_Handle;
         FD : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean) is
         Other_Outbound : Boolean := False;
      begin
         if Valid (Handle) then
            for Index in Streams'Range loop
               if Index /= Handle.Slot
                 and then Streams (Index).Outbound_Pending
               then
                  Other_Outbound := True;
               end if;
            end loop;
         end if;
         Ready_Now := not Valid (Handle) or else Broken
           or else
             (Pump_Owner in 0 | Handle.Slot
                and then
                  (Streams (Handle.Slot).Outbound_Pending
                     or else not Other_Outbound));
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Flyology.Wake_Sources.Ensure (Streams (Handle.Slot).Wake);
            FD := Flyology.Wake_Sources.Descriptor
              (Streams (Handle.Slot).Wake);
         end if;
      end Pump_Wait_Source;

      procedure Signal_Outbound (Handle : Stream_Handle) is
      begin
         if not Valid (Handle) then
            return;
         end if;
         Streams (Handle.Slot).Outbound_Pending := True;
         Flyology.Wake_Sources.Ensure (Outbound_Wake);
         if not Outbound_Signalled then
            Flyology.Wake_Sources.Signal (Outbound_Wake);
            Outbound_Signalled := True;
         end if;
      end Signal_Outbound;

      procedure Outbound_Wait_Source
        (FD : out Flyology.IO.Descriptor; Pending : out Boolean) is
      begin
         Pending := False;
         for Stream of Streams loop
            Pending := Pending or else Stream.Outbound_Pending;
         end loop;
         Flyology.Wake_Sources.Ensure (Outbound_Wake);
         if not Pending and then Outbound_Signalled then
            Flyology.Wake_Sources.Consume (Outbound_Wake);
            Outbound_Signalled := False;
         end if;
         FD := Flyology.Wake_Sources.Descriptor (Outbound_Wake);
      end Outbound_Wait_Source;

      procedure Consume_Outbound (Handle : Stream_Handle) is
         Pending : Boolean := False;
      begin
         if Valid (Handle) then
            Streams (Handle.Slot).Outbound_Pending := False;
         end if;
         for Stream of Streams loop
            Pending := Pending or else Stream.Outbound_Pending;
         end loop;
         if not Pending and then Outbound_Signalled then
            Flyology.Wake_Sources.Consume (Outbound_Wake);
            Outbound_Signalled := False;
         end if;
      end Consume_Outbound;

      function Has_Response_Observation
        (Handle : Stream_Handle) return Boolean is
        (Valid (Handle)
           and then Streams (Handle.Slot).Response_Observed);

      procedure Publish
        (Event : H3.Event; Result : out Boolean) is
         Slot : Natural := 0;
      begin
         Result := True;
         if Event.Kind = H3.Goaway_Received then
            Draining := True;
            Wake_Pump;
            return;
         elsif Event.Kind in H3.No_Event | H3.Settings_Received then
            return;
         end if;
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free
              and then Streams (Index).ID = Event.Stream
            then
               Slot := Index;
               exit;
            end if;
         end loop;
         if Slot = 0 then
            --  A late event for a released stream is stream-local and does
            --  not poison concurrent exchanges.
            return;
         end if;
         declare
            Stream : Stream_Record renames Streams (Slot);
         begin
            Stream.Response_Observed := True;
            case Event.Kind is
               when H3.Headers_Received =>
                  if not Stream.Head_Available then
                     declare
                        Code : Natural := 0;
                        Has_Status : Boolean := False;
                        Saw_Regular : Boolean := False;
                     begin
                        Flyology.HTTP.Headers.Clear (Stream.Fields);
                        for Index in 1 .. H3.Header_Count (Event.Headers) loop
                           declare
                              Field : constant H3.Header_Field :=
                                H3.Field_At (Event.Headers, Index);
                              Name : constant String := H3.Field_Name (Field);
                              Value : constant String :=
                                H3.Field_Value (Field);
                           begin
                              if Name = ":status" then
                                 if Saw_Regular or else Has_Status
                                   or else Value'Length /= 3
                                   or else (for some C of Value =>
                                              C not in '0' .. '9')
                                 then
                                    Stream.Phase := Failed;
                                    exit;
                                 end if;
                                 Code := Natural'Value (Value);
                                 Has_Status := True;
                              elsif not Valid_Regular_Response_Name (Name)
                              then
                                 Stream.Phase := Failed;
                                 exit;
                              else
                                 Saw_Regular := True;
                                 begin
                                    Flyology.HTTP.Headers.Add
                                      (Stream.Fields, Name, Value);
                                 exception
                                    when others =>
                                       Stream.Phase := Failed;
                                 end;
                                 exit when Stream.Phase = Failed;
                              end if;
                           end;
                        end loop;
                        if Stream.Phase /= Failed then
                           if not Has_Status
                             or else Code not in 100 .. 599
                             or else Code = 101
                           then
                              Stream.Phase := Failed;
                           elsif Code < 200 then
                              Flyology.HTTP.Headers.Clear (Stream.Fields);
                           else
                              Stream.Status := Status_Code (Code);
                              Stream.Body_Forbidden :=
                                Stream.Body_Forbidden
                                  or else Code in 204 | 205 | 304;
                              declare
                                 Length_Valid : Boolean;
                              begin
                                 Parse_Content_Length
                                   (Stream.Fields,
                                    Stream.Has_Expected_Length,
                                    Stream.Expected_Length,
                                    Length_Valid);
                                 if not Length_Valid
                                   or else
                                     (Code = 204
                                        and then
                                          Stream.Has_Expected_Length)
                                 then
                                    Stream.Phase := Failed;
                                 else
                                    Stream.Head_Available := True;
                                 end if;
                              end;
                           end if;
                        end if;
                     end;
                  else
                     if Stream.Trailers_Seen then
                        Stream.Phase := Failed;
                     else
                        Stream.Trailers_Seen := True;
                        for Index in 1 .. H3.Header_Count
                          (Event.Headers)
                        loop
                           declare
                              Field : constant H3.Header_Field :=
                                H3.Field_At (Event.Headers, Index);
                              Name : constant String := H3.Field_Name (Field);
                           begin
                              if not Valid_Regular_Response_Name (Name)
                              then
                                 Stream.Phase := Failed;
                                 exit;
                              end if;
                              begin
                                 Flyology.HTTP.Headers.Add
                                   (Stream.Trailers, Name,
                                    H3.Field_Value (Field));
                              exception
                                 when others =>
                                    Stream.Phase := Failed;
                              end;
                              exit when Stream.Phase = Failed;
                           end;
                        end loop;
                     end if;
                  end if;
               when H3.Data_Received =>
                  if not Stream.Head_Available
                    or else Stream.Trailers_Seen
                    or else Stream.Body_Forbidden
                    or else
                      (Stream.Has_Expected_Length
                         and then Stream.Received_Length +
                           Body_Size (Event.Data_Length) >
                             Stream.Expected_Length)
                    or else Stream.Content_Count + Event.Data_Length >
                      Response_Buffer_Capacity
                  then
                     Stream.Phase := Failed;
                  elsif Event.Data_Length > 0 then
                     for Offset in 0 .. Event.Data_Length - 1 loop
                        Stream.Content
                          (((Stream.Content_First - 1 +
                             Stream.Content_Count + Offset) mod
                              Response_Buffer_Capacity) + 1) :=
                            Event.Data
                              (Event.Data'First +
                               Stream_Element_Offset (Offset));
                     end loop;
                     Stream.Content_Count :=
                       Stream.Content_Count + Event.Data_Length;
                     Stream.Received_Length := Stream.Received_Length +
                       Body_Size (Event.Data_Length);
                  end if;
               when H3.Stream_Ended =>
                  if Stream.Phase = Failed then
                     null;
                  elsif not Stream.Head_Available
                    or else
                      (Stream.Has_Expected_Length
                         and then not Stream.Body_Forbidden
                         and then Stream.Received_Length /=
                           Stream.Expected_Length)
                  then
                     Stream.Phase := Failed;
                  else
                     Stream.Remote_End := True;
                     Stream.Phase := Complete;
                  end if;
               when H3.Stream_Reset =>
                  Stream.Phase := Failed;
               when H3.No_Event | H3.Settings_Received |
                    H3.Goaway_Received =>
                  null;
            end case;
            Wake_Stream (Slot);
         end;
      end Publish;

      procedure Fail_All is
      begin
         Broken := True;
         for Index in Streams'Range loop
            if Streams (Index).Phase /= Free then
               Streams (Index).Phase := Failed;
               Wake_Stream (Index);
            end if;
         end loop;
         Wake_Pump;
      end Fail_All;

      procedure Poll_Head
        (Handle : Stream_Handle;
         Result : out Head_Result;
         Status : out Status_Code;
         Fields : in out Flyology.HTTP.Headers.List;
         Finished : out Boolean) is
      begin
         Status := 200;
         Finished := False;
         Flyology.HTTP.Headers.Clear (Fields);
         if not Valid (Handle) then
            Result := Head_Stream_Failed;
         elsif Broken then
            Result := Head_Connection_Failed;
         elsif Streams (Handle.Slot).Phase = Failed then
            Result := Head_Stream_Failed;
         elsif Streams (Handle.Slot).Head_Available
           and then not Streams (Handle.Slot).Head_Delivered
         then
            Status := Streams (Handle.Slot).Status;
            Fields := Streams (Handle.Slot).Fields;
            Streams (Handle.Slot).Head_Delivered := True;
            Finished := Streams (Handle.Slot).Remote_End
              and then Streams (Handle.Slot).Content_Count = 0;
            Result := Head_Ready;
         else
            Result := Head_Would_Block;
         end if;
      end Poll_Head;

      procedure Read
        (Handle : Stream_Handle;
         Data : out Stream_Element_Array;
         Last : out Stream_Element_Offset;
         Finished : out Boolean;
         Result : out Body_Result;
         Trailers : in out Flyology.HTTP.Headers.List) is
         Count : Natural := 0;
      begin
         Last := Data'First - 1;
         Finished := False;
         Flyology.HTTP.Headers.Clear (Trailers);
         if not Valid (Handle) then
            Result := Body_Stream_Failed;
         elsif Broken then
            Result := Body_Connection_Failed;
         elsif Streams (Handle.Slot).Phase = Failed then
            Result := Body_Stream_Failed;
         else
            Count := Natural'Min
              (Streams (Handle.Slot).Content_Count,
               Natural (Data'Length));
            if Count > 0 then
               for Offset in 0 .. Count - 1 loop
                  Data (Data'First + Stream_Element_Offset (Offset)) :=
                    Streams (Handle.Slot).Content
                      (((Streams (Handle.Slot).Content_First - 1 + Offset)
                        mod Response_Buffer_Capacity) + 1);
               end loop;
               Last := Data'First + Stream_Element_Offset (Count) - 1;
               Streams (Handle.Slot).Content_First :=
                 (((Streams (Handle.Slot).Content_First - 1 + Count)
                   mod Response_Buffer_Capacity) + 1);
               Streams (Handle.Slot).Content_Count :=
                 Streams (Handle.Slot).Content_Count - Count;
               if Streams (Handle.Slot).Content_Count = 0 then
                  Streams (Handle.Slot).Content_First := 1;
               end if;
            end if;
            Finished := Streams (Handle.Slot).Remote_End
              and then Streams (Handle.Slot).Content_Count = 0;
            if Finished then
               Trailers := Streams (Handle.Slot).Trailers;
               Result := Body_Finished;
            elsif Count > 0 then
               Result := Body_Progress;
            else
               Result := Body_Would_Block;
            end if;
         end if;
      end Read;

      procedure Wait_Source
        (Handle : Stream_Handle;
         FD : out Flyology.IO.Descriptor;
         Ready_Now : out Boolean) is
      begin
         Ready_Now := not Valid (Handle) or else Broken
           or else Streams (Handle.Slot).Phase in Complete | Failed
           or else
             (Streams (Handle.Slot).Head_Available
                and then not Streams (Handle.Slot).Head_Delivered)
           or else Streams (Handle.Slot).Content_Count > 0;
         if Ready_Now then
            FD := Flyology.IO.Invalid_Descriptor;
         else
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Flyology.Wake_Sources.Ensure (Streams (Handle.Slot).Wake);
            FD := Flyology.Wake_Sources.Descriptor
              (Streams (Handle.Slot).Wake);
         end if;
      end Wait_Source;

      procedure Cancel_Stream (Handle : Stream_Handle) is
      begin
         if Valid (Handle) then
            Streams (Handle.Slot).Phase := Failed;
            if Pump_Owner = Handle.Slot then
               Pump_Owner := 0;
               Wake_Pump;
            end if;
            Wake_Stream (Handle.Slot);
         end if;
      end Cancel_Stream;

      procedure Release_Stream (Handle : Stream_Handle) is
      begin
         if Valid (Handle) then
            if Pump_Owner = Handle.Slot then
               Pump_Owner := 0;
               Wake_Pump;
            end if;
            Flyology.HTTP.Headers.Clear (Streams (Handle.Slot).Fields);
            Flyology.HTTP.Headers.Clear (Streams (Handle.Slot).Trailers);
            Streams (Handle.Slot).Trailers_Seen := False;
            Streams (Handle.Slot).Phase := Free;
            Streams (Handle.Slot).ID := 0;
            Streams (Handle.Slot).Content_First := 1;
            Streams (Handle.Slot).Content_Count := 0;
            Streams (Handle.Slot).Remote_End := False;
            Streams (Handle.Slot).Body_Forbidden := False;
            Streams (Handle.Slot).Has_Expected_Length := False;
            Streams (Handle.Slot).Expected_Length := 0;
            Streams (Handle.Slot).Received_Length := 0;
            Streams (Handle.Slot).Response_Observed := False;
            Streams (Handle.Slot).Outbound_Pending := False;
            if Streams (Handle.Slot).Wake_Signalled then
               Flyology.Wake_Sources.Consume (Streams (Handle.Slot).Wake);
               Streams (Handle.Slot).Wake_Signalled := False;
            end if;
            Wake_Pump;
         end if;
      end Release_Stream;
   end Controller;

   procedure Open
     (Item : in out Session; Stream : QUIC.Stream_ID;
      Handle : out Stream_Handle; Accepted : out Boolean;
      Head_Request : Boolean := False) is
   begin
      Item.Streams.Open (Stream, Handle, Accepted, Head_Request);
   end Open;
   procedure Reserve
     (Item : in out Session; Handle : out Stream_Handle;
      Accepted : out Boolean;
      Head_Request : Boolean := False) is
   begin
      Item.Streams.Reserve (Handle, Accepted, Head_Request);
   end Reserve;
   procedure Bind
     (Item : in out Session; Handle : in out Stream_Handle;
      Stream : QUIC.Stream_ID) is
   begin Item.Streams.Bind (Handle, Stream); end Bind;
   function Can_Open (Item : Session) return Boolean is
     (Item.Streams.Can_Open);
   function Is_Usable (Item : Session) return Boolean is
     (Item.Streams.Is_Usable);
   procedure Try_Claim_Pump
     (Item : in out Session; Handle : Stream_Handle; Claimed : out Boolean) is
   begin Item.Streams.Try_Claim_Pump (Handle, Claimed); end Try_Claim_Pump;
   function Owns_Pump
     (Item : Session; Handle : Stream_Handle) return Boolean is
     (Item.Streams.Owns_Pump (Handle));
   procedure Release_Pump
     (Item : in out Session; Handle : Stream_Handle) is
   begin Item.Streams.Release_Pump (Handle); end Release_Pump;
   procedure Pump_Wait_Source
     (Item : in out Session; Handle : Stream_Handle;
      FD : out Flyology.IO.Descriptor; Ready_Now : out Boolean) is
   begin
      Item.Streams.Pump_Wait_Source (Handle, FD, Ready_Now);
   end Pump_Wait_Source;
   procedure Signal_Outbound
     (Item : in out Session; Handle : Stream_Handle) is
   begin Item.Streams.Signal_Outbound (Handle); end Signal_Outbound;
   procedure Outbound_Wait_Source
     (Item : in out Session; FD : out Flyology.IO.Descriptor;
      Pending : out Boolean) is
   begin
      Item.Streams.Outbound_Wait_Source (FD, Pending);
   end Outbound_Wait_Source;
   procedure Consume_Outbound
     (Item : in out Session; Handle : Stream_Handle) is
   begin Item.Streams.Consume_Outbound (Handle); end Consume_Outbound;
   function Has_Response_Observation
     (Item : Session; Handle : Stream_Handle) return Boolean is
     (Item.Streams.Has_Response_Observation (Handle));
   procedure Publish
     (Item : in out Session; Event : H3.Event; Result : out Boolean) is
   begin Item.Streams.Publish (Event, Result); end Publish;
   procedure Fail_All (Item : in out Session) is
   begin Item.Streams.Fail_All; end Fail_All;
   procedure Poll_Head
     (Item : in out Session; Handle : Stream_Handle;
      Result : out Head_Result; Status : out Status_Code;
      Fields : in out Flyology.HTTP.Headers.List; Finished : out Boolean) is
   begin
      Item.Streams.Poll_Head
        (Handle, Result, Status, Fields, Finished);
   end Poll_Head;
   procedure Read
     (Item : in out Session; Handle : Stream_Handle;
      Data : out Stream_Element_Array; Last : out Stream_Element_Offset;
      Finished : out Boolean; Result : out Body_Result;
      Trailers : in out Flyology.HTTP.Headers.List) is
   begin
      Item.Streams.Read
        (Handle, Data, Last, Finished, Result, Trailers);
   end Read;
   procedure Wait_Source
     (Item : in out Session; Handle : Stream_Handle;
      FD : out Flyology.IO.Descriptor; Ready_Now : out Boolean) is
   begin Item.Streams.Wait_Source (Handle, FD, Ready_Now); end Wait_Source;
   procedure Cancel_Stream
     (Item : in out Session; Handle : Stream_Handle) is
   begin Item.Streams.Cancel_Stream (Handle); end Cancel_Stream;
   procedure Release_Stream
     (Item : in out Session; Handle : Stream_Handle) is
   begin Item.Streams.Release_Stream (Handle); end Release_Stream;
   function Identifier (Handle : Stream_Handle) return QUIC.Stream_ID is
     (Handle.ID);
end Flyology.HTTP.HTTP_3_Client_Connection;
