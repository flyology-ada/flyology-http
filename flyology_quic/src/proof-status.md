# Proof Status: QUIC stream insertion policies
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

The bounded receive-window invariant and the stream table's successful-
insertion witness prove at full level 1. The complete Flyology QUIC policy
suite widening passed with 2,156 checks proved and no unproved checks.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Flyology QUIC policy suite (level 1, mode all)
  - [x] `Stream_Reassembly_Policy.Insert`
  - [x] Preserve `Highest - Base <= Max_Stream_Data` on every exit
  - [x] `Stream_Table_Policy.Insert`
  - [x] Successful insertion leaves `Find (Item, Stream_ID) /= 0`

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

## Discovered Obligations

- [x] Prove the branch-local receive-window assertions in
  `Stream_Reassembly_Policy.Insert`
- [x] Prove the new-slot and existing-slot `Find` witness assertions in
  `Stream_Table_Policy.Insert`
