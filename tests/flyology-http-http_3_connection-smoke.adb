with Flyology.QUIC.Test_Connections;

procedure Flyology.HTTP.HTTP_3_Connection.Smoke is
   use type QUIC.Stream_ID;

   Client_Transport, Server_Transport : QUIC.Connection;
   Client, Server : Connection;
   Settings : HTTP_3_Settings_Policy.Settings;
   Client_Control, Server_Control : QUIC.Datagram;
   Client_Event, Server_Event : Event;
   Client_Status, Server_Status : Operation_Status;
begin
   Flyology.QUIC.Test_Connections.Connect
     (Client_Transport, Server_Transport);
   Initialize (Client, HTTP_3_Connection.Client, Settings);
   Initialize (Server, HTTP_3_Connection.Server, Settings);

   Start
     (Client, Client_Transport, Now => 1_000,
      Packet => Client_Control, Status => Client_Status);
   Start
     (Server, Server_Transport, Now => 1_000,
      Packet => Server_Control, Status => Server_Status);
   pragma Assert
     (Client_Status = Succeeded and then Server_Status = Succeeded);

   Flyology.QUIC.Test_Connections.Deliver
     (Client_Control, Server_Transport);
   Flyology.QUIC.Test_Connections.Deliver
     (Server_Control, Client_Transport);

   Poll (Server, Server_Transport, Server_Event, Server_Status);
   Poll (Client, Client_Transport, Client_Event, Client_Status);
   pragma Assert
     (Server_Status = Succeeded
      and then Server_Event.Kind = Settings_Received
      and then Server_Event.Stream = 2
      and then Has_Peer_Settings (Server));
   pragma Assert
     (Client_Status = Succeeded
      and then Client_Event.Kind = Settings_Received
      and then Client_Event.Stream = 3
      and then Has_Peer_Settings (Client));
end Flyology.HTTP.HTTP_3_Connection.Smoke;
