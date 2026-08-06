package body Flyology.HTTP.Server.Applications.Internals is

   function Create
     (Value    : aliased in out Request;
      Backend  : not null access Exchange_Backends.Backend'Class;
      Peer     : Flyology.IO.Sockets.Endpoint;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Exchange
   is
   begin
      return Result : Exchange
        (Request_Handle    => Value'Access,
         Connection_Handle => null,
         Backend_Handle    => Backend,
         Token_Handle      => Token)
      do
         Result.Peer_Value := Peer;
         Result.Deadline_Value := Deadline;
      end return;
   end Create;

end Flyology.HTTP.Server.Applications.Internals;
