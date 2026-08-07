with Flyology.QUIC.Varint_Policy;

--  Internal, proved HTTP/3 mapping of QUIC stream identifiers and types.
private package Flyology.QUIC.HTTP_3_Stream_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Varint_Policy.Value_Type;

   type Endpoint_Role is (Client, Server);

   Control_Stream       : constant Varint_Policy.Value_Type := 16#00#;
   Push_Stream          : constant Varint_Policy.Value_Type := 16#01#;
   QPACK_Encoder_Stream : constant Varint_Policy.Value_Type := 16#02#;
   QPACK_Decoder_Stream : constant Varint_Policy.Value_Type := 16#03#;

   function Is_Client_Initiated
     (Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Global => null;

   function Is_Unidirectional
     (Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Global => null;

   function Is_Peer_Initiated
     (Stream_ID : Varint_Policy.Value_Type;
      Local_Role : Endpoint_Role) return Boolean
   with Global => null;

   function Is_Request_Stream
     (Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Global => null;

   function First_Local_Unidirectional
     (Local_Role : Endpoint_Role) return Varint_Policy.Value_Type
   with
     Global => null,
     Post => Is_Unidirectional (First_Local_Unidirectional'Result)
       and then not Is_Peer_Initiated
         (First_Local_Unidirectional'Result, Local_Role);

   function Next_Unidirectional
     (Stream_ID : Varint_Policy.Value_Type) return Varint_Policy.Value_Type
   with
     Global => null,
     Pre => Is_Unidirectional (Stream_ID)
       and then Stream_ID <= Varint_Policy.Value_Type'Last - 4,
     Post => Next_Unidirectional'Result = Stream_ID + 4
       and then Is_Unidirectional (Next_Unidirectional'Result)
       and then Is_Client_Initiated (Next_Unidirectional'Result) =
         Is_Client_Initiated (Stream_ID);
end Flyology.QUIC.HTTP_3_Stream_Policy;
