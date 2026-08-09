with Flyology.QUIC.Debug_Config;

--  Compile-time QUIC and HTTP/3 diagnostic events. Set
--  FLYOLOGY_QUIC_TRACE=true while building to emit events on standard error.
--  Disabled builds select a dependency-free no-op implementation.
package Flyology.QUIC.Debug is

   --  True only in a trace-enabled library build. Call sites guard diagnostic
   --  argument construction with this static constant.
   Enabled : constant Boolean := Debug_Config.Enabled;

   --  Emit one tagged diagnostic event when tracing is compiled in.
   --  @param Component QUIC or HTTP/3 subsystem producing the event
   --  @param Event Stable short event name
   --  @param Detail Human-readable status and numeric context
   procedure Log (Component, Event, Detail : String);

end Flyology.QUIC.Debug;
