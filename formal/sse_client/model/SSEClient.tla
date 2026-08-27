------------------------------ MODULE SSEClient ------------------------------
EXTENDS Naturals

CONSTANTS Ids, Delays, EnableCorruption

ASSUME /\ Ids # {}
       /\ "" \in Ids
       /\ Delays # {}
       /\ Delays \subseteq Nat
       /\ EnableCorruption \in BOOLEAN

Phases == {"Connecting", "Open", "Waiting", "Stopped", "Failed"}
TerminalPhases == {"Stopped", "Failed"}

VARIABLES phase, lastEventId, eventIdBuffer, sentLastEventId, retryDelay,
          waitDelay

vars == <<phase, lastEventId, eventIdBuffer, sentLastEventId, retryDelay,
          waitDelay>>

TypeOK ==
  /\ phase \in Phases
  /\ lastEventId \in Ids
  /\ eventIdBuffer \in Ids
  /\ sentLastEventId \in Ids
  /\ retryDelay \in Delays
  /\ waitDelay \in Delays

Init ==
  /\ phase = "Connecting"
  /\ lastEventId = ""
  /\ eventIdBuffer = ""
  /\ sentLastEventId = ""
  /\ retryDelay \in Delays
  /\ waitDelay = retryDelay

ConnectionAccepted ==
  /\ phase = "Connecting"
  /\ phase' = "Open"
  /\ eventIdBuffer' = ""
  /\ UNCHANGED <<lastEventId, sentLastEventId, retryDelay, waitDelay>>

ConnectionNoContent ==
  /\ phase = "Connecting"
  /\ phase' = "Stopped"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId,
                 retryDelay, waitDelay>>

ConnectionRecoverableFailure ==
  /\ phase \in {"Connecting", "Open"}
  /\ phase' = "Waiting"
  /\ waitDelay' = retryDelay
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId, retryDelay>>

ConnectionFatalFailure ==
  /\ phase \in {"Connecting", "Open"}
  /\ phase' = "Failed"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId,
                 retryDelay, waitDelay>>

ReceiveID(id) ==
  /\ phase = "Open"
  /\ id \in Ids
  /\ eventIdBuffer' = id
  /\ UNCHANGED <<phase, lastEventId, sentLastEventId, retryDelay, waitDelay>>

ReceiveRetry(delay) ==
  /\ phase = "Open"
  /\ delay \in Delays
  /\ retryDelay' = delay
  /\ UNCHANGED <<phase, lastEventId, eventIdBuffer, sentLastEventId,
                 waitDelay>>

DispatchEvent ==
  /\ phase = "Open"
  /\ lastEventId' = eventIdBuffer
  /\ UNCHANGED <<phase, eventIdBuffer, sentLastEventId, retryDelay, waitDelay>>

EndOfBody ==
  /\ phase = "Open"
  /\ phase' = "Waiting"
  /\ waitDelay' = retryDelay
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId, retryDelay>>

ReconnectWaitElapsed ==
  /\ phase = "Waiting"
  /\ phase' = "Connecting"
  /\ sentLastEventId' = lastEventId
  /\ UNCHANGED <<lastEventId, eventIdBuffer, retryDelay, waitDelay>>

Stop ==
  /\ phase \notin TerminalPhases
  /\ phase' = "Stopped"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId,
                 retryDelay, waitDelay>>

TerminalIdle ==
  /\ phase \in TerminalPhases
  /\ UNCHANGED vars

CorruptReconnectId ==
  /\ EnableCorruption
  /\ phase = "Waiting"
  /\ \E wrong \in Ids \ {lastEventId}:
       /\ phase' = "Connecting"
       /\ sentLastEventId' = wrong
       /\ UNCHANGED <<lastEventId, eventIdBuffer, retryDelay, waitDelay>>

ConnectionResolution ==
  ConnectionAccepted \/ ConnectionNoContent \/
  ConnectionRecoverableFailure \/ ConnectionFatalFailure

Next ==
  \/ ConnectionResolution
  \/ \E id \in Ids : ReceiveID(id)
  \/ \E delay \in Delays : ReceiveRetry(delay)
  \/ DispatchEvent
  \/ EndOfBody
  \/ ReconnectWaitElapsed
  \/ Stop
  \/ TerminalIdle
  \/ CorruptReconnectId

ReconnectCarriesLatestId ==
  phase = "Connecting" => sentLastEventId = lastEventId

WaitUsesLatestDelay ==
  phase = "Waiting" => waitDelay = retryDelay

Safety == TypeOK /\ ReconnectCarriesLatestId /\ WaitUsesLatestDelay

WaitingProgress ==
  phase = "Waiting" ~> phase \in {"Connecting", "Stopped", "Failed"}

ConnectingProgress ==
  phase = "Connecting" ~> phase \in {"Open", "Waiting", "Stopped", "Failed"}

Spec ==
  Init /\ [][Next]_vars /\ WF_vars(ReconnectWaitElapsed) /\
  WF_vars(ConnectionResolution)

=============================================================================
