open Batteries

type ('a, 'id) var_printer = {
  f : 't. 'a IO.output -> ('id, 't) TypedAst.var -> unit
}

val string_of_unop : _ TypedAst.unop -> string
val string_of_binop : _ TypedAst.binop -> string

val print_expression :
  ('a, 'b) var_printer ->
  'a IO.output ->
  ('b, _) TypedAst.expression ->
  unit

val program_var_printer : (_, Sym.t) var_printer
val property_var_printer : (_, Sym.t Context.MaybeThreaded.t) var_printer
