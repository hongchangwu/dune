(** String with variables of the form ${...} or $(...)

    Variables cannot contain "${", "$(", ")" or "}". For instance in "$(cat
    ${x})", only "${x}" will be considered a variable, the rest is text. *)

open Import

type t
(** A sequence of text and variables. *)

val t : t Sexp.Of_sexp.t
(** [t ast] takes an [ast] sexp and returns a string-with-vars.  This
    function distinguishes between unquoted variables — such as ${@} —
    and quoted variables — such as "${@}". *)

val loc : t -> Loc.t
(** [loc t] returns the location of [t] — typically, in the jbuild file. *)

val syntax_version : t -> Syntax.Version.t

val sexp_of_t : t -> Sexp.t

(** [t] generated by the OCaml code. The first argument should be
    [__POS__]. The second is either a string to parse, a variable name
    or plain text.  [quoted] says whether the string is quoted ([false]
    by default). Those functions expect jbuild syntax. *)
val virt       : ?quoted: bool -> (string * int * int * int) -> string -> t
val virt_var   : ?quoted: bool -> (string * int * int * int) -> string -> t
val virt_text  : (string * int * int * int) -> string -> t
val make_text  : ?quoted: bool -> Loc.t -> string -> t

val is_var : t -> name:string -> bool

(** If [t] contains no variable, returns the contents of [t]. *)
val text_only : t -> string option

module Mode : sig
  type 'a t =
    | Single : Value.t t
    | Many : Value.t list t
end

module Partial : sig
  type nonrec 'a t =
    | Expanded of 'a
    | Unexpanded of t
end

module Var : sig
  type t

  val sexp_of_t : t -> Sexp.t

  val name : t -> string
  val loc : t -> Loc.t
  val full_name : t -> string
  val payload : t -> string option

  val with_name : t -> name:string -> t

  val is_macro : t -> bool

  (** Describe what this variable is *)
  val describe : t -> string
end

type 'a expander = Var.t -> Syntax.Version.t -> 'a

val expand
  :  t
  -> mode:'a Mode.t
  -> dir:Path.t
  -> f:(Value.t list option expander)
  -> 'a

val partial_expand
  :  t
  -> mode:'a Mode.t
  -> dir:Path.t
  -> f:(Value.t list option expander)
  -> 'a Partial.t
