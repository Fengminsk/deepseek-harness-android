# Android Shell settings choices

The bundled Android Host exposes `shellTimeoutMs` and `shellOutputLimit` as
volatile fields on `android-runtime`, so both are available through the real
Settings descriptor. The original schema allows timeout from 1 to 3,600,000
ms and output from 1,024 to 1,048,576 bytes. The Shell tool samples saved
values when it starts an approved command; changing them does not modify a
command already running.

The Android Tools > Shell secondary page offers bounded, labeled choices for
both fields. A separate field page also accepts another integer within the
Host schema limits. The shared configuration controller stages choices, saves
only changed paths at the observed revision, restores an inherited value with
`unset`, and retains drafts for conflict or uncertain receipt review. Advanced
JSON editing stays accessible for advanced maintenance.

Widget tests cover both choices in one revisioned write, invalid custom input,
and a stale revision. The existing grouped-editor tests cover inherited reset,
conflict review, and uncertain save. A device interaction pass is still needed
when a phone is available.
