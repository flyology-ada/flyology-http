with Flyology.QUIC.Varint_Policy;

package body Flyology.HTTP.HTTP_3_Stream_Policy
  with SPARK_Mode => On
is
   use type Varint_Policy.Value_Type;

   function Is_Client_Initiated
     (Stream_ID : Varint_Policy.Value_Type) return Boolean is
       ((Stream_ID and 1) = 0);

   function Is_Unidirectional
     (Stream_ID : Varint_Policy.Value_Type) return Boolean is
       ((Stream_ID and 2) /= 0);

   function Is_Peer_Initiated
     (Stream_ID : Varint_Policy.Value_Type;
      Local_Role : Endpoint_Role) return Boolean is
       (Is_Client_Initiated (Stream_ID) = (Local_Role = Server));

   function Is_Request_Stream
     (Stream_ID : Varint_Policy.Value_Type) return Boolean is
       (Is_Client_Initiated (Stream_ID)
        and then not Is_Unidirectional (Stream_ID));

   function First_Local_Unidirectional
     (Local_Role : Endpoint_Role) return Varint_Policy.Value_Type is
       (if Local_Role = Client then 2 else 3);

   function Next_Unidirectional
     (Stream_ID : Varint_Policy.Value_Type) return Varint_Policy.Value_Type is
       (Stream_ID + 4);
end Flyology.HTTP.HTTP_3_Stream_Policy;
