with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Exchange_Backends;
with Flyology.IO.Sockets;

--  Internal constructors used by protocol engines. Applications should create
--  exchanges only through the server and routing adapters.
package Flyology.HTTP.Server.Applications.Internals is

   function Create
     (Value    : aliased in out Request;
      Backend  : not null access Exchange_Backends.Backend'Class;
      Peer     : Flyology.IO.Sockets.Endpoint;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Scheme   : Origin_Scheme := Plain_HTTP) return Exchange;

end Flyology.HTTP.Server.Applications.Internals;
