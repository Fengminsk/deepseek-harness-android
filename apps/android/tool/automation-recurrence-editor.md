# Android automation recurrence editor

English | [中文](automation-recurrence-editor.zh.md)

The Android automation detail reads and updates the original Host Schedule record. [DSH Schedule](../../../packages/client/ui-schedule/README.md) uses a staged rule editor; the Android Repeat row now opens a secondary choice page for Once, Every day, Monday to Friday, Weekly, Fixed interval, and Custom cron. Monday to Friday submits the original weekly selector with weekdays 1–5. Weekly opens a secondary weekday page; at least one day must remain selected.

Fixed interval opens a separate amount and unit page. The saved rule remains `every_seconds`: whole hours, minutes, and seconds are display and input choices, and the page accepts only a total of at least 60 and at most 9,007,199,254,740,991 seconds. An invalid stored interval remains visible for repair instead of crashing the detail page. Changing a unit changes the preview; Done stages the resulting seconds on the detail page. Back from a secondary editor discards changes on that page. No Schedule call occurs until Save task on the detail page.

Save retains the Host compare-and-update request and uses its acknowledged committed record even if the immediately refreshed catalog still returns an older row. Conflicts and uncertain results retain the local draft for review. These controls have Flutter widget evidence; phone interaction and process-restart behavior still need device acceptance.
