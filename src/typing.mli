val type_program :
  UntypedAst.program *
  (Property.zone option *
   (Sym.t * TypedAst.thread_id option) UntypedAst.expression Location.loc)
    list ->

  TypedAst.program *
  Property.t list
