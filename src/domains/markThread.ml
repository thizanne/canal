open Batteries

module T = TypedAst
module Ty = Types
module O = Operation
module L = Location
module Dom = Domain

(* TODO: move this in Domain *)
module type ControlAbstraction = sig
  type label = int
  val alpha : Source.thread_id -> Control.Label.t -> label
  val max_alpha : Source.thread_id -> label
end

module Key = struct
  (* TODO: remove this when 4.03 is used. ppx_deriving uses
     [@@ocaml.warning "-A"], which is needed to remove warning 39 and
     not supported in 4.02. *)
  [@@@ocaml.warning "-39"]

  type presence =
    | Zero
    | One
    | MoreThanOne
    [@@ deriving ord]

  let up_presence = function
    | Zero -> One
    | One -> MoreThanOne
    | MoreThanOne -> MoreThanOne

  let down_presence = function
    | Zero -> raise @@ Invalid_argument "down_presence"
    | One -> Zero
    | MoreThanOne -> One

  let presence_is_zero = function
    | Zero -> true
    | One
    | MoreThanOne -> false

  let print_presence output = function
    | Zero -> String.print output "0"
    | One -> String.print output "1"
    | MoreThanOne -> String.print output ">1"

  module M = Sym.Map

  type t = presence M.t

  let compare =
    Sym.Map.compare compare_presence

  let init prog =
    Sym.Map.map
      (fun _init -> Zero)
      prog.T.globals

  let is_consistent =
    M.for_all (fun _sym -> presence_is_zero)

  let get_presence var_sym =
    M.find var_sym

  let down var =
    M.modify var down_presence

  let up var =
    M.modify var up_presence

  let print output =
    M.print ~first:"" ~last:"" ~sep:";" ~kvsep:"→"
      Sym.print print_presence
      output
end

module Make (Inner : Domain.Inner) (C : ControlAbstraction) : Domain.ThreadState = struct

  module M = Map.Make (Key)

  type t = Source.thread_id * Inner.t M.t

  let normalize =
    M.filterv (fun inner -> not (Inner.is_bottom inner))

  let bottom thread_id =
    thread_id, M.empty

  let is_bottom (_, abstr) =
    M.for_all (fun _key inner -> Inner.is_bottom inner) abstr

  let equal_abstr abstr1 abstr2 =
    M.equal Inner.equal (normalize abstr1) (normalize abstr2)

  let equal (tid1, abstr1) (tid2, abstr2) =
    assert (tid1 = tid2);
    equal_abstr abstr1 abstr2

  let print output (_tid, abstr) =
    M.print
      ~first:"" ~last:"" ~kvsep:":\n\n" ~sep:"\n────────\n"
      Key.print Inner.print output abstr

  let inner_var_sym = Sym.namespace ()

  let sym_local tid reg =
    inner_var_sym @@ Printf.sprintf "%d:%s" tid (Sym.name reg)

  let sym_mem var =
    inner_var_sym @@ Printf.sprintf "%s:mem" (Sym.name var)

  let sym_top tid var =
    inner_var_sym @@ Printf.sprintf "%s:top:%d" (Sym.name var) tid

  let sym_bot tid var =
    inner_var_sym @@ Printf.sprintf "%s:bot:%d" (Sym.name var) tid

  let inner_var make_sym var =
    { var with T.var_spec = make_sym var.T.var_sym }

  let inner_var_local tid = inner_var (sym_local tid)

  let inner_var_mem x = inner_var sym_mem x

  let inner_var_top tid = inner_var (sym_top tid)

  let inner_var_bot tid = inner_var (sym_bot tid)

  (* TODO: make Sym able to generate fresh names *)
  let inner_var_tmp var =
    { var with T.var_spec = inner_var_sym "::Mark:tmp::" }

  let add_join bufs inner abstr =
    (* Adds (bufs, inner) as a abstr element, making a join if the
       bufs key is already present *)
    M.modify_def inner bufs (Inner.join inner) abstr

  let initial_thread_locals tid { T.locals; _ } =
    Sym.Map.fold
      (fun var_sym ty (ints, bools) ->
         match ty with
         | Env.Int ->
           let var = {
             T.var_sym;
             var_type = Ty.Int;
             var_spec = sym_local tid var_sym
           } in
           var :: ints, bools
         | Env.Bool ->
           let var = {
             T.var_sym;
             var_type = Ty.Bool;
             var_spec = sym_local tid var_sym
           } in
           ints, var :: bools)
      locals
      ([], [])

  let initial_mem { T.globals; _ } =
    Sym.Map.fold
      (fun var_sym ty (ints, bools) ->
         match ty with
         | Env.Int ->
           let var =
             { T.var_sym; var_type = Ty.Int; var_spec = sym_mem var_sym } in
           var :: ints, bools
         | Env.Bool ->
           let var =
             { T.var_sym; var_type = Ty.Bool; var_spec = sym_mem var_sym } in
           ints, var :: bools)
      globals
      ([], [])

  let top prog thread_id =
    let local_ints, local_bools =
      initial_thread_locals thread_id (List.nth prog.T.threads thread_id) in
    let mem_ints, mem_bools =
      initial_mem prog in
    let max_labels =
      List.mapi (fun tid _ -> C.max_alpha tid) prog.T.threads in
    let initial_inner =
      Inner.init
      |> List.fold_right Inner.add local_ints
      |> List.fold_right Inner.add local_bools
      |> List.fold_right Inner.add mem_ints
      |> List.fold_right Inner.add mem_bools
      |> List.fold_righti Inner.add_label max_labels
    in
    thread_id, M.singleton (Key.init prog) initial_inner

  let inner_of_property key =
    (* Mapper which puts as var_spec the inner symbol of a property
       variable. *)
    let map { T.var_sym; var_type; var_spec } =
      let inner_sym = match var_spec with
        | Source.Local thread_id -> sym_local thread_id var_sym
        | Source.Memory -> sym_mem var_sym
        | Source.View thread_id ->
          match Key.get_presence var_sym key with
          | Key.Zero -> sym_mem var_sym
          | Key.One
          | Key.MoreThanOne -> sym_top thread_id var_sym
      in { T.var_sym; var_type; var_spec = inner_sym }
    in { T.map }

  let inner_of_program thread_id key  =
    (* Mapper which puts as var_spec the inner symbol of a program
       variable. *)
    let map { T.var_sym; var_type; var_spec } =
      let inner_sym = match var_spec with
        | Ty.Local -> sym_local thread_id var_sym
        | Ty.Shared ->
          match Key.get_presence var_sym key with
          | Key.Zero -> sym_mem var_sym
          | Key.One
          | Key.MoreThanOne -> sym_top thread_id var_sym
      in { T.var_sym; var_type; var_spec = inner_sym }
    in { T.map }

  let meet_unsymbolised_cond symbolise cond =
    M.mapi
      (fun key -> Inner.meet_cons @@ T.map_expr (symbolise key) cond)

  let local_assign tid r expr key inner =
    Inner.assign_expr
      (inner_var_local tid r)
      (T.map_expr (inner_of_program tid key) expr)
      inner

  let write tid x expr key inner =
    let x_sym = x.T.var_sym in
    let x_top = inner_var_top tid x in
    let x_bot = inner_var_bot tid x in
    let inner_expr = T.map_expr (inner_of_program tid key) expr in
    match Key.get_presence x.T.var_sym key with
    | Key.Zero ->
      Key.up x_sym key,
      (* x_top := add e *)
      inner
      |> Inner.add x_top
      |> Inner.assign_expr x_top inner_expr
    | Key.One ->
      Key.up x_sym key,
      (* x_bot :=add x_top; x_top := e *)
      inner
      |> Inner.add x_bot
      |> Inner.assign_expr x_bot (T.Var (L.mkdummy x_top))
      |> Inner.assign_expr x_top inner_expr
    | Key.MoreThanOne ->
      (* cf Numeric Domains with Summarized Dimensions, Gopan et al. Tacas04 *)
      let x_tmp = inner_var_tmp x in
      key,
      (* x_bot[*] := x_top; x_top := e *)
      inner
      |> Inner.add x_tmp
      |> Inner.assign_expr x_tmp (T.Var (L.mkdummy x_top))
      |> Inner.fold x_bot x_tmp
      |> Inner.assign_expr x_top inner_expr

  let add_flush_x tid x key inner acc =
    (* Adds to acc the result(s) of one flush of x from tid. If tid
       has no entry for x in its buffer, acc is returned unchanged. *)
    let x_sym = x.T.var_sym in
    let x_mem = inner_var_mem x in
    let x_top = inner_var_top tid x in
    let x_bot = inner_var_bot tid x in
    let x_bot_expr = T.Var (L.mkdummy x_bot) in
    let x_top_expr = T.Var (L.mkdummy x_top) in
    let x_tmp = inner_var_tmp x in
    let x_tmp_expr = T.Var (L.mkdummy x_tmp) in
    match Key.get_presence x_sym key with
    | Key.Zero -> acc
    | Key.One ->
      let key = Key.down x_sym key in
      let inner =
        inner
        |> Inner.assign_expr x_mem x_top_expr
        |> Inner.drop x_top in
      add_join key inner acc
    | Key.MoreThanOne ->
      (* >1 -> >1 => x_mem := x_bot[*] *)
      let inner_gt1 =
        inner
        |> Inner.expand x_bot x_tmp
        |> Inner.assign_expr x_mem x_tmp_expr
        |> Inner.drop x_tmp in
      (* >1 -> 1 => x_mem := x_bot[*]; del x_bot *)
      let key_1 = Key.down x_sym key in
      let inner_1 =
        (* x_tmp is not needed here *)
        inner
        |> Inner.assign_expr x_mem x_bot_expr
        |> Inner.drop x_bot in
      (* Make the joins *)
      acc
      |> add_join key inner_gt1
      |> add_join key_1 inner_1

  let iterate_one_flush tid x abstr =
    (* Does one iteration of flushing one x from each point of abstr if
       possible, adding the results to abstr *)
    M.fold (add_flush_x tid x) abstr abstr

  let rec close_by_flush_wrt_var tid x abstr =
    let abstr' = iterate_one_flush tid x abstr in
    if equal_abstr abstr abstr' then abstr
    else close_by_flush_wrt_var tid x abstr'

  let close_by_flush_wrt_expr tid expr abstr =
    let fold var acc =
      match var.T.var_spec with
      | Ty.Local -> acc
      | Ty.Shared -> close_by_flush_wrt_var tid var acc
    in
    T.fold_expr { T.fold } abstr expr

  let transfer_abstr op tid abstr =
    match op with
    | O.Identity -> abstr
    | O.MFence ->
      M.filter (fun key _ -> Key.is_consistent key) abstr
    | O.Filter cond ->
      abstr
      |> meet_unsymbolised_cond (inner_of_program tid) cond
      |> normalize
    | O.Assign (x, expr) ->
      match x.T.var_spec with
      | Ty.Local ->
        M.mapi (local_assign tid x expr) abstr
        |> close_by_flush_wrt_expr tid expr
      | Ty.Shared ->
        M.Labels.fold
          ~f:(fun ~key ~data:abstr acc ->
              let key', abstr' = write tid x expr key abstr
              in add_join key' abstr' acc)
          ~init:M.empty
          abstr
        |> close_by_flush_wrt_var tid x

  let transfer op (tid, abstr) =
    tid, transfer_abstr op tid abstr

  let meet_cond cond (tid, abstr) =
    (* normalisation is not needed since only a is_bottom will be done
       on the result *)
    tid, normalize @@ meet_unsymbolised_cond inner_of_property cond abstr

  let meet_label label_tid label (tid, abstr) =
    if label_tid = tid
    (* information on tid label is not present in abstr variables, but at
       an outer level *)
    then tid, abstr
    else
      tid,
      normalize @@ M.map
        (fun inner -> Inner.meet_label label_tid (C.alpha label_tid label) inner)
        abstr

  let join (tid1, abstr1) (tid2, abstr2) =
    assert (tid1 = tid2);
    tid1,
    M.merge
      (fun _bufs inner1 inner2 -> match (inner1, inner2) with
         | None, _ -> inner2
         | _, None -> inner1
         | Some inner1, Some inner2 -> Some (Inner.join inner1 inner2))
      abstr1 abstr2

  let widening (tid1, d1) (tid2, d2) =
    assert (tid1 = tid2);
    tid1,
    M.merge
      (fun _key abstr1 abstr2 -> match (abstr1, abstr2) with
         | None, _ -> abstr2
         | _, None -> abstr1
         | Some abstr1, Some abstr2 ->
           Some (Inner.widening abstr1 abstr2))
      d1 d2
end