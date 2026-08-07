procedure Flyology.HTTP.HTTP_3_Stream_Policy.Smoke is
begin
   pragma Assert (Is_Request_Stream (0));
   pragma Assert (Is_Request_Stream (4));
   pragma Assert (not Is_Request_Stream (1));
   pragma Assert (not Is_Request_Stream (2));
   pragma Assert (First_Local_Unidirectional (Client) = 2);
   pragma Assert (First_Local_Unidirectional (Server) = 3);
   pragma Assert (Is_Peer_Initiated (2, Server));
   pragma Assert (not Is_Peer_Initiated (2, Client));
   pragma Assert (Is_Peer_Initiated (3, Client));
   pragma Assert (Next_Unidirectional (2) = 6);
   pragma Assert (Next_Unidirectional (3) = 7);
end Flyology.HTTP.HTTP_3_Stream_Policy.Smoke;
