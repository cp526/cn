(* TODO: BCP: Needs a header explaining what it is *)

module StringSet : Set.S with type elt = string

val io : Cerb_backend.Pipeline.io_helpers

val impl_name : string

val conf
  :  (string * string option) list ->
  string list ->
  string list ->
  bool ->
  Cerb_backend.Pipeline.language list ->
  string option ->
  Cerb_backend.Pipeline.configuration
