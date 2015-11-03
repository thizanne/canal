open Batteries
open Printf
open Error
open Program
open Util

module L = Location

let add_local_if_absent x env =
  Sym.Map.modify_opt x
    (function
      | None -> Some Local
      | Some typ -> Some typ)
    env

let base_type_var env ({ L.item = var_name; loc = var_loc } as var) =
  let var_type, shared =
    match Sym.Map.Exceptionless.find var_name env with
    | Some Local -> Local, 0
    | Some Shared -> Shared, 1
    | None ->
      type_error var @@
      sprintf "Var %s is not defined"
        (Sym.name var_name)
  in { var_name; var_type }, shared

let rec type_expression type_var { L.item = exp; loc } =
  (* Returns (typed expression, number of present shared variables) *)
  match exp with
  | Int n -> { L.item = Int n; loc }, 0
  | Var v ->
    let var, nb_shared = type_var v in
    {
      L.item = Var { L.item = var; loc = v.L.loc };
      loc = loc;
    }, nb_shared
  | ArithUnop (op, exp1) ->
    let exp1', nb_shared = type_expression type_var exp1 in
    {
      L.item = ArithUnop (op, exp1');
      loc;
    },
    nb_shared
  | ArithBinop (op, exp1, exp2) ->
    let exp1', nb_shared1 = type_expression type_var exp1 in
    let exp2', nb_shared2 = type_expression type_var exp2 in
    {
      L.item = ArithBinop (op, exp1', exp2');
      loc;
    },
    (nb_shared1 + nb_shared2)

let check_shared loc nb_max nb_shared =
  match nb_max with
  | None -> ()
  | Some nb_max ->
    if nb_shared > nb_max
    then type_loc_error loc "Too many shared variables"

let rec type_condition type_var shared_max { L.item = cond; loc } =
  match cond with
  | Bool b -> { L.item = Bool b; loc }
  | LogicUnop (op, c) ->
    let c' = type_condition type_var shared_max c in {
      L.item = LogicUnop (op, c');
      loc;
    }
  | LogicBinop (op, c1, c2) ->
    let c1' = type_condition type_var shared_max c1 in
    let c2' = type_condition type_var shared_max c2 in {
      L.item = LogicBinop (op, c1', c2');
      loc;
    }
  | ArithRel (rel, e1, e2) ->
    let e1', nb_shared1 = type_expression type_var e1 in
    let e2', nb_shared2 = type_expression type_var e2 in
    check_shared loc shared_max (nb_shared1 + nb_shared2);
    {
      L.item = ArithRel (rel, e1', e2');
      loc;
    }

let rec type_body ((env, labels) as info) { L.item = b; loc } =
  match b with
  | Nothing -> { L.item = Nothing; loc }, info
  | Pass -> { L.item = Pass; loc }, info
  | MFence -> { L.item = MFence; loc }, info
  | Label lbl ->
    if Sym.Set.mem lbl.L.item labels
    then name_error lbl "Label already defined on this thread"
    else {
      L.item = Label lbl;
      loc;
    }, (env, Sym.Set.add lbl.L.item labels)
  | Seq (b1, b2) ->
    let b1', info' = type_body info b1 in
    let b2', info'' = type_body info' b2 in
    { L.item = Seq (b1', b2'); loc }, info''
  | Assign ({ L.item = var_name; loc = var_loc }, exp) ->
    let var_type, (exp', nb_shared), env', add_shared =
      match Sym.Map.Exceptionless.find var_name env with
      | Some Local
      | None ->
        Local,
        type_expression (base_type_var env) exp,
        Sym.Map.add var_name Local env,
        0
      | Some Shared ->
        Shared,
        type_expression (base_type_var env) exp,
        env,
        1
    in
    check_shared loc (Some 1) (nb_shared + add_shared);
    let var = { L.item = { var_type; var_name }; loc = var_loc } in
    { L.item = Assign (var, exp'); loc }, (env', labels)
  | If (cond, body) ->
    let cond' = type_condition (base_type_var env) (Some 0) cond in
    let body', info' = type_body info body in
    { L.item = If (cond', body'); loc }, info'
  | While (cond, body) ->
    let cond' = type_condition (base_type_var env) (Some 0) cond in
    let body', info' = type_body info body in
    { L.item = While (cond', body'); loc }, info'
  | For ({ L.item = i_name; loc = i_loc } as i, exp_from, exp_to, body) ->
    let env_i =
      match Sym.Map.Exceptionless.find i_name env with
      | None
      | Some Local ->
        add_local_if_absent i_name env
      | Some Shared ->
        type_error i "For indices must not be shared variables"
    in
    let var_i = {
      L.item = { var_name = i_name; var_type = Local };
      loc = i_loc
    } in
    let exp_from', nb_from = type_expression (base_type_var env_i) exp_from in
    let exp_to', nb_to = type_expression (base_type_var env_i) exp_to in
    check_shared exp_from.L.loc (Some 0) nb_from;
    check_shared exp_to.L.loc (Some 0) nb_to;
    let body', info' = type_body (env_i, labels) body in {
      L.item = For (var_i, exp_from', exp_to', body');
      loc
    }, info'

let check_bound labels bound =
  match bound with
  | None -> ()
  | Some label ->
    if not (Sym.Set.mem label.L.item labels)
    then
      name_error label @@
      sprintf "Label %s undefined"
        (Sym.name label.L.item)

let check_interval labels { Property.initial; final } =
  check_bound labels initial;
  check_bound labels final

let check_thread_zone labels thread_zone =
  List.iter (check_interval labels) thread_zone

let check_zone all_labels zone =
  let tid_found = Array.make (List.length all_labels) false in
  List.iter
    (fun ({ L.item = tid; _ } as tid_loc, thread_zone) ->
       (* Check that each tid is present at most once*)
       if tid_found.(tid)
       then
         type_error tid_loc @@
         sprintf "Thread id %d already present in zone definition" tid
       else tid_found.(tid) <- true;

       (* Check that labels are correct *)
       check_thread_zone (List.nth all_labels tid) thread_zone)
    zone

let type_property all_labels shared_env thread_envs
    { Property.zone; condition } =
  let () = match zone with
    | None -> ()
    | Some zone -> check_zone all_labels zone in

  let typing_env ({ L.item = (tid, var_name); loc } as var_loc) =
    match zone, tid with
    | None, None -> shared_env
    | _, Some tid -> List.nth thread_envs tid
    | Some _, None ->
      type_error var_loc @@
      sprintf
        "Non threaded var %s is not allowed in a zoned property"
        (Sym.name var_name) in

  let type_var ({ L.item = (tid, var_name); loc } as var) =
    let var, _ = base_type_var (typing_env var) { L.item = var_name; loc } in
    create_var_view ~thread_id:(Option.default 0 tid) var,
    -1 (* We don't care if it's shared or not here *) in

  let condition = type_condition type_var None condition in

  { Property.zone; condition }

let type_program ({ initial; threads }, properties) =
  let shared_env = Sym.Map.map (fun _ -> Shared) initial in
  let thread_results =
    List.map
      (fun t -> type_body (shared_env, Sym.Set.empty) t.body)
      threads in

  (* Yup, this is non-optimal. Who cares, it's fast anyway. *)
  let thread_envs = List.map (fst @@@ snd) thread_results in
  let all_labels = List.map (snd @@@ snd) thread_results in
  let bodies = List.map fst thread_results in

  let properties =
    List.map
      (type_property all_labels shared_env thread_envs)
      properties in

  let thread thread_env body = {
    body;
    locals =
      thread_env
      |> Sym.Map.filterv (( = ) Local)
      |> Sym.Map.keys
      |> Sym.Set.of_enum;
  } in

  {
    initial;
    threads = List.map2 thread thread_envs bodies;
  }, properties
