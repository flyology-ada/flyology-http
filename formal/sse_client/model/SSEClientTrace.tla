--------------------------- MODULE SSEClientTrace ----------------------------
EXTENDS Naturals

\* The witness uses integer milliseconds, matching the production conversion.

VARIABLES phase, lastEventId, eventIdBuffer, sentLastEventId, retryDelay,
          waitDelay, pc, lastAction

vars == <<phase, lastEventId, eventIdBuffer, sentLastEventId, retryDelay,
          waitDelay, pc, lastAction>>

Phases == {"Connecting", "Open", "Waiting", "Stopped", "Failed"}
Actions ==
  {"Init", "ConnectionAccepted", "ReceiveRetry", "ReceiveIDOne",
   "DispatchEvent", "EndOfBody", "ReconnectWaitElapsed",
   "ReceiveIDTwo", "ConnectionNoContent"}

Init ==
  /\ phase = "Connecting"
  /\ lastEventId = "None"
  /\ eventIdBuffer = "None"
  /\ sentLastEventId = "None"
  /\ retryDelay = 1
  /\ waitDelay = 1
  /\ pc = 0
  /\ lastAction = "Init"

ConnectionAccepted ==
  /\ pc \in {0, 6}
  /\ phase = "Connecting"
  /\ phase' = "Open"
  /\ eventIdBuffer' = "None"
  /\ pc' = pc + 1
  /\ lastAction' = "ConnectionAccepted"
  /\ UNCHANGED <<lastEventId, sentLastEventId, retryDelay, waitDelay>>

ReceiveRetry ==
  /\ pc = 1
  /\ phase = "Open"
  /\ retryDelay' = 2
  /\ pc' = 2
  /\ lastAction' = "ReceiveRetry"
  /\ UNCHANGED <<phase, lastEventId, eventIdBuffer, sentLastEventId,
                 waitDelay>>

ReceiveIDOne ==
  /\ pc = 2
  /\ phase = "Open"
  /\ eventIdBuffer' = "One"
  /\ pc' = 3
  /\ lastAction' = "ReceiveIDOne"
  /\ UNCHANGED <<phase, lastEventId, sentLastEventId, retryDelay, waitDelay>>

FirstDispatchEvent ==
  /\ pc = 3
  /\ phase = "Open"
  /\ lastEventId' = eventIdBuffer
  /\ pc' = 4
  /\ lastAction' = "DispatchEvent"
  /\ UNCHANGED <<phase, eventIdBuffer, sentLastEventId, retryDelay, waitDelay>>

FirstEndOfBody ==
  /\ pc = 4
  /\ phase = "Open"
  /\ phase' = "Waiting"
  /\ waitDelay' = retryDelay
  /\ pc' = 5
  /\ lastAction' = "EndOfBody"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId, retryDelay>>

FirstReconnect ==
  /\ pc = 5
  /\ phase = "Waiting"
  /\ phase' = "Connecting"
  /\ sentLastEventId' = lastEventId
  /\ pc' = 6
  /\ lastAction' = "ReconnectWaitElapsed"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, retryDelay, waitDelay>>

ReceiveIDTwo ==
  /\ pc = 7
  /\ phase = "Open"
  /\ eventIdBuffer' = "Two"
  /\ pc' = 8
  /\ lastAction' = "ReceiveIDTwo"
  /\ UNCHANGED <<phase, lastEventId, sentLastEventId, retryDelay, waitDelay>>

SecondDispatchEvent ==
  /\ pc = 8
  /\ phase = "Open"
  /\ lastEventId' = eventIdBuffer
  /\ pc' = 9
  /\ lastAction' = "DispatchEvent"
  /\ UNCHANGED <<phase, eventIdBuffer, sentLastEventId, retryDelay, waitDelay>>

SecondEndOfBody ==
  /\ pc = 9
  /\ phase = "Open"
  /\ phase' = "Waiting"
  /\ waitDelay' = retryDelay
  /\ pc' = 10
  /\ lastAction' = "EndOfBody"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId, retryDelay>>

SecondReconnect ==
  /\ pc = 10
  /\ phase = "Waiting"
  /\ phase' = "Connecting"
  /\ sentLastEventId' = lastEventId
  /\ pc' = 11
  /\ lastAction' = "ReconnectWaitElapsed"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, retryDelay, waitDelay>>

ConnectionNoContent ==
  /\ pc = 11
  /\ phase = "Connecting"
  /\ phase' = "Stopped"
  /\ pc' = 12
  /\ lastAction' = "ConnectionNoContent"
  /\ UNCHANGED <<lastEventId, eventIdBuffer, sentLastEventId,
                 retryDelay, waitDelay>>

Next ==
  \/ ConnectionAccepted
  \/ ReceiveRetry
  \/ ReceiveIDOne
  \/ FirstDispatchEvent
  \/ FirstEndOfBody
  \/ FirstReconnect
  \/ ReceiveIDTwo
  \/ SecondDispatchEvent
  \/ SecondEndOfBody
  \/ SecondReconnect
  \/ ConnectionNoContent

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ phase \in {"Connecting", "Open", "Waiting", "Stopped", "Failed"}
  /\ lastEventId \in {"None", "One", "Two"}
  /\ eventIdBuffer \in {"None", "One", "Two"}
  /\ sentLastEventId \in {"None", "One", "Two"}
  /\ retryDelay \in 1..2
  /\ waitDelay \in 1..2
  /\ pc \in 0..12
  /\ lastAction \in
       {"Init", "ConnectionAccepted", "ReceiveRetry", "ReceiveIDOne",
        "DispatchEvent", "EndOfBody", "ReconnectWaitElapsed",
        "ReceiveIDTwo", "ConnectionNoContent"}

HarnessInputType == [id : {"None", "One", "Two"}, delay : 0..2]
HarnessOutcomeType == [accepted : BOOLEAN]

WitnessPending == pc < 12

Alias == [
  action |-> lastAction,
  role |-> "lifecycle",
  input |-> [
    id |-> IF lastAction = "ReceiveIDOne" THEN "One"
            ELSE IF lastAction = "ReceiveIDTwo" THEN "Two" ELSE "None",
    delay |-> IF lastAction = "ReceiveRetry" THEN 2 ELSE 0
  ],
  outcome |-> [accepted |-> TRUE],
  state |-> [
    phase |-> phase,
    lastEventId |-> lastEventId,
    eventIdBuffer |-> eventIdBuffer,
    sentLastEventId |-> sentLastEventId,
    retryDelay |-> retryDelay,
    waitDelay |-> waitDelay,
    pc |-> pc,
    lastAction |-> lastAction
  ],
  model_source |-> lastAction
]

=============================================================================
