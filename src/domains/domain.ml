open Batteries

module T = TypedAst

module type Common = sig
  type t
  val is_bottom : t -> bool
  val equal : t -> t -> bool
  val join : t -> t -> t
  val print : 'a IO.output -> t -> unit
end

module type ProgramState = sig
  include Common
  val bottom : t
  val top : T.program -> t
  val transfer : Source.thread_id -> Operation.t -> t -> t
  val meet_cond : T.property_condition -> t -> t
  val widening : t -> t -> t
end

module type ThreadState = sig
  include Common
  val bottom : Source.thread_id -> t
  val top : T.program -> Source.thread_id -> t (* top but with empty buffers *)
  val transfer : Operation.t -> t -> t
  val meet_cond : T.property_condition -> t -> t
  val widening : t -> t -> t
  val meet_label : Source.thread_id -> Control.Label.t -> t -> t
end

module type Interferences = sig
  type t
  val bottom : t
  val equal : t -> t -> bool
  val join : t -> t -> t
  val widening : t -> t -> t
end

type 't inner_var = ('t, Sym.t) T.var
type 't inner_expression = ('t, Sym.t) T.expression

module type Inner = sig
  include Common
  val init : t (* An element with no constraint and no variable defined *)
  val meet : t -> t -> t
  val meet_cons : bool inner_expression -> t -> t
  val widening : t -> t -> t
  val fold : 't inner_var -> 't inner_var -> t -> t (* dest <- source *)
  val expand : 't inner_var -> 't inner_var -> t -> t (* source -> dest *)
  val drop : _ inner_var -> t -> t
  val add : _ inner_var -> t -> t
  val assign_expr : 't inner_var -> 't inner_expression -> t -> t
  val add_label : Source.thread_id -> int -> t -> t (* int is abstract label max *)
  val set_label : Source.thread_id -> int -> t -> t (* int is abstract label affectation *)
  val meet_label : Source.thread_id -> int -> t -> t (* int is abstract label to meet with *)
end
