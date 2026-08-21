--  @exclude
private package Flyology.HTTP.Fixed_Response_Policy
  with SPARK_Mode => On
is
   --  Bounded accounting state for one fixed-length response.
   type Tracker is private;

   --  Result of accounting one response-body write.
   --  @enum Accepted The write fits, or the response body is suppressed
   --  @enum Inactive No fixed-length response is active
   --  @enum Overrun The write exceeds the declared response length
   type Write_Result is (Accepted, Inactive, Overrun);

   --  Result of completing one fixed-length response.
   --  @enum Complete The response is exact, or its body is suppressed
   --  @enum Finish_Inactive No fixed-length response is active
   --  @enum Underrun Fewer bytes were written than declared
   type Finish_Result is (Complete, Finish_Inactive, Underrun);

   --  Report whether fixed-length accounting is active.
   --  @param Item Response tracker
   --  @return True when a fixed-length response is active
   function Is_Active (Item : Tracker) return Boolean
   with Global => null;

   --  Return the declared response length.
   --  @param Item Response tracker
   --  @return Declared response length
   function Expected (Item : Tracker) return Body_Size
   with Global => null;

   --  Return the accepted response-body byte count.
   --  @param Item Response tracker
   --  @return Accepted response-body byte count
   function Written (Item : Tracker) return Body_Size
   with Global => null;

   --  Start exact accounting for one response.
   --  @param Item Response tracker to initialize
   --  @param Length Declared response length
   --  @param Suppressed True when protocol semantics suppress the body
   procedure Start
     (Item       : out Tracker;
      Length     : Body_Size;
      Suppressed : Boolean)
   with
     Global => null,
     Post => Is_Active (Item)
       and then Expected (Item) = Length
       and then Written (Item) = 0;

   --  Disable fixed-length accounting.
   --  @param Item Response tracker to reset
   procedure Reset (Item : out Tracker)
   with Global => null,
     Post => not Is_Active (Item);

   --  Account a prospective response-body write before transport I/O.
   --  @param Item Active response tracker
   --  @param Count Prospective write length
   --  @param Result Accounting decision
   procedure Write
     (Item   : in out Tracker;
      Count  : Body_Size;
      Result : out Write_Result)
   with
     Global => null,
     Post =>
       (if Result = Accepted and then Is_Active (Item)
        then Written (Item) <= Expected (Item));

   --  Classify response completion and leave exact responses inactive.
   --  @param Item Response tracker
   --  @param Result Completion decision
   procedure Finish
     (Item   : in out Tracker;
      Result : out Finish_Result)
   with
     Global => null,
     Post => Result = Complete
       or else not Is_Active (Item);

private
   type Phase is (Idle, Active, Failed);

   type Tracker is record
      State       : Phase := Idle;
      Length      : Body_Size := 0;
      Count       : Body_Size := 0;
      Suppressed  : Boolean := False;
   end record
   with Type_Invariant =>
     (if State = Active then Count <= Length);
end Flyology.HTTP.Fixed_Response_Policy;
