open Batteries

type thread_id = int

(* TODO: unify threaded with Location.loc as a context comonad *)

type 'a threaded = {
  thread_id : thread_id;
  elem : 'a [@main];
} [@@deriving create]

let print_threaded print_elem output { thread_id; elem } =
  Printf.fprintf output "%a:%d" print_elem elem thread_id

type arith_unop =
  | Neg

let fun_of_arith_unop = function
  | Neg -> ( ~- )

type logic_unop =
  | Not

let fun_of_logic_unop = function
  | Not -> ( not )

type arith_binop =
  | Add
  | Sub
  | Mul
  | Div

let fun_of_arith_binop = function
  | Add -> ( + )
  | Sub -> ( - )
  | Mul -> ( * )
  | Div -> ( / )

type arith_rel =
  | Eq
  | Neq
  | Lt
  | Gt
  | Le
  | Ge

let fun_of_arith_rel =
  let open Int in
  function
  | Eq -> ( = )
  | Neq -> ( <> )
  | Lt -> ( < )
  | Gt -> ( > )
  | Le -> ( <= )
  | Ge  -> ( >= )

type logic_binop =
  | And
  | Or

let fun_of_logic_binop = function
  | And -> ( && )
  | Or -> ( || )

type var_type =
  | Local
  | Shared

type var = {
  var_type : var_type;
  var_name : Symbol.t;
}

let print_var output x =
  Symbol.print output x.var_name

let local_var var_name = {
  var_name;
  var_type = Local;
}

let shared_var var_name = {
  var_name;
  var_type = Shared;
}

let is_local v =
  v.var_type = Local

let is_shared v =
  v.var_type = Shared

type 'a expression =
  | Int of int Location.loc
  | Var of 'a Location.loc
  | ArithUnop of
      arith_unop Location.loc *
      'a expression Location.loc
  | ArithBinop of
      arith_binop Location.loc *
      'a expression Location.loc *
      'a expression Location.loc

let var v = Var v

let rec shared_in_expr = function
  | Int _ -> []
  | Var v ->
    if is_local v.Location.item
    then []
    else [v.Location.item.var_name]
  | ArithUnop (_, e) ->
    shared_in_expr e.Location.item
  | ArithBinop (_, e1, e2) ->
    shared_in_expr e1.Location.item @
    shared_in_expr e2.Location.item

type 'a condition =
  | Bool of bool Location.loc
  | LogicUnop of
      logic_unop Location.loc *
      'a condition Location.loc
  | LogicBinop of
      logic_binop Location.loc *
      'a condition Location.loc *
      'a condition Location.loc
  | ArithRel of
      arith_rel Location.loc *
      'a expression Location.loc *
      'a expression Location.loc

type body =
  | Nothing
  | Pass
  | MFence
  | Label of Symbol.t Location.loc
  | Seq of
      body Location.loc *
      body Location.loc
  | Assign of
      var Location.loc *
      var expression Location.loc
  | If of
      var condition Location.loc * (* Condition *)
      body Location.loc (* Body *)
  | While of
      var condition Location.loc * (* Condition *)
      body Location.loc (* Body *)
  | For of
      var Location.loc * (* Indice *)
      var expression Location.loc * (* From *)
      var expression Location.loc * (* To *)
      body Location.loc (* Body *)

let seq body1 body2 =
  Location.mk (Seq (body1, body2))
    Location.(body1.loc.startpos)
    Location.(body2.loc.endpos)

module Property = struct
  (* A thread code portion delimited by two labels.
   * No initial label means 0.
   * No final label means the end of the thread.
  *)
  type interval = {
    initial : Symbol.t option;
    final : Symbol.t option;
  }

  let whole_interval = {
    initial = None;
    final = None;
  }

  (* A thread code portion defined as an union of intervals *)
  type thread_zone = interval list

  (* Program states set defined as a conjunction of thread zones.
   * Typing should check that a given thread is present at most once in
   * a zone. *)
  type zone = thread_zone threaded list

  type t = {
    zone : zone option;
    (* None means end of the program, once flushed *)
    condition : var threaded condition;
  }

  let always_true = {
    zone = None;
    condition = Bool (Location.mkdummy true);
  }

  let always_false = {
    zone = None;
    condition = Bool (Location.mkdummy false);
  }
end

type thread = {
  locals : Symbol.Set.t;
  body : body;
}

type t = {
  initial : int Symbol.Map.t;
  threads : thread list;
  properties : Property.t list;
}

module Control : sig
  type program = t

  module Label : sig
    type t
    val initial : t
    val succ : t -> t
    val enum : initial:t -> final:t -> t Enum.t
    val compare : t -> t -> int
    val print : 'a IO.output -> t -> unit
  end

  module State : sig
    type t
    val empty : t
    val add_label : Label.t -> t -> t
    val from_label_list : Label.t list -> t
    val tid_label : t -> thread_id -> Label.t
    val is_initial : t -> bool
    val initial : program -> t
    val compare : t -> t -> int
    val print : 'a IO.output -> t -> unit
  end
end
=
struct
  type program = t

  module Label = struct
    include Int

    let initial = 0

    let enum ~initial ~final =
      initial -- final
  end

  module State = struct
    type t = Label.t list

    let empty = []

    let tid_label = List.nth

    let add_label = List.cons

    let from_label_list labels = labels

    let compare = List.compare Label.compare

    let is_initial =
      List.for_all (( = ) 0)

    let initial program =
      List.map (fun _ -> 0) program.threads

    let print output =
      List.print Int.print ~first:"" ~last:"" output
  end

end
