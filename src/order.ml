open Util
open Printf
open Syntax
open Syntax.Typed
open Syntax.TypedProgram

type point = {
  regs : (string * int option) list;
  vars : (string * int option) list list;
  buf : string list list;
}

module S = Set.Make (struct type t = point let compare = compare end)

type t = S.t

let empty = S.empty

let union = S.union

let smap f s = S.fold (fun x e -> S.add (f x) e) s S.empty

let get_reg point r =
  List.assoc r point.regs

let set_reg point r n = {
  point with regs = set_assoc r n point.regs
}

let get_value point = function
  | Int n -> Some n.item
  | Var r -> get_reg point r.item

let get_var point t x =
  List.assoc x @@ List.nth point.vars t

let set_var point t x v = {
  point with
  vars =
    set_nth t
      (set_assoc x v @@ List.nth point.vars t) point.vars;
  buf =
    set_nth t (x :: List.nth point.buf t) point.buf;
}


let rec get_expr point = function
  | Val v -> get_value point v.item
  | Op (op, e1, e2) ->
    let e1 = get_expr point e1.item in
    let e2 = get_expr point e2.item in
    begin match (e1, e2) with
      | Some v1, Some v2 -> (fun_of_op op.item) v1 v2
      | _, _ -> None
    end

let nth_buf p t =
  List.nth p.buf t

let is_empty_buffer p t =
  nth_buf p t = []

let older_in_buf p t =
  last @@ nth_buf p t

let is_older_in_buf p t x =
  try
    older_in_buf p t = x
  with Not_found -> false

let x_in_buf p t x =
  List.mem x (nth_buf p t)

let threads_x_older p x =
  0 -- (List.length p.buf - 1)
  |> List.filter (fun t -> is_older_in_buf p t x)

let flush p t =
  let x = older_in_buf p t in
  let n = get_var p t x in
  {
    p with
    vars =
      List.map2
        (fun rt vt ->
           if List.mem x rt
           then set_assoc x n vt
           else vt)
        p.buf p.vars;
    buf =
      set_nth t (first @@ List.nth p.buf t) p.buf;
  }

(*

TODO

all_combi generates duplicates, maybe this could be solved for
a better performance

*)

let rec inser_all_first_pos x = function
  | [] -> [[x]]
  | y :: ys as yss ->
    if x = y
    then [x :: yss]
    else
      (x :: yss) ::
      List.map (fun yy -> y :: yy)
        (inser_all_first_pos x ys)

let rec all_combi = function
  | [] -> [[]]
  | [] :: bufs -> all_combi bufs
  | (t :: ts) :: bufs ->
    let ps = all_combi (ts :: bufs) in
    ps @
    List.fold_left ( @ ) []
      (List.map (inser_all_first_pos t) ps)

let flush_after_mop p x =
  p.buf
  |> List.filter (fun buf -> try last buf = x with Not_found -> false)
  |> List.mapi (fun i buf -> repeat (List.length buf) i)
  |> all_combi
  |> List.map (List.fold_left flush p)

let transfer domain t = function
  | Read (r, x) ->
    let domain =
      domain
      |> S.elements
      |> List.map (fun p -> set_reg p r.item (get_var p t x.item))
      |> List.map (fun p -> flush_after_mop p x.item)
      |> List.fold_left ( @ ) []
    in
    List.fold_right S.add domain S.empty
  | Write (x, v) ->
    let domain =
      domain
      |> S.elements
      |> List.map (fun p -> set_var p t x.item (get_value p v.item))
      |> List.map (fun p -> flush_after_mop p x.item)
      |> List.fold_left ( @ ) []
    in
    List.fold_right S.add domain S.empty
  | RegOp (r, e)  ->
    smap
      (fun p -> set_reg p r.item (get_expr p e.item)) domain
  | Cmp (r, v1, v2) ->
    smap
      (fun p -> set_reg p r.item (
           let v1 = get_value p v1.item in
           let v2 = get_value p v2.item in
           match (v1, v2) with
           | Some n1, Some n2 ->
             Some (
               if n1 < n2 then -1
               else if n1 > n2 then 1
               else 0)
           | _, _ -> None))
      domain
  | Mfence -> S.filter (fun p -> is_empty_buffer p t) domain
  | Label _ -> domain
  | Jnz (_, _) | Jz (_, _) | Jmp _ -> failwith "Jumps not implemented"

let initial_vars program =
    List.map (fun (x, v) -> x, Some v) program.initial

let initial_point program = {
  regs =
    List.fold_left ( @ ) []
      (List.map
         (fun t -> List.map (fun r -> r, None) t.locals)
         program.threads);
  vars =
    (let vars = initial_vars program in
     List.map (fun _ -> vars) program.threads);
  buf =
    List.map (fun _ -> []) program.threads;
}

let init program = S.singleton (initial_point program)

let print_var (x, v) =
  printf "%s → %s" x (str_int_option v)

let print_point {regs; vars; buf} =
  print_list print_var regs;
  print_newline ();
  print_list (print_list print_string) buf;
  print_newline ();
  print_list (print_list print_var) vars;
  print_newline ()

let print =
  S.iter
    (fun p ->
       print_point p; print_newline (); print_newline())

let point_sat_cond (var, value) p =
  try
    begin try
        List.assoc var p.regs = Some value
      with
      | Not_found ->
        List.exists2
          (fun vt bt ->
             bt = [] &&
             List.assoc var vt = Some value)
          p.vars p.buf
    end
  with
  | Not_found -> failwith "point_sat_cond"

let point_sat cond p =
  List.for_all
    (fun c -> point_sat_cond c p)
    cond

let satisfies cond domain =
  S.exists (fun p -> point_sat cond p) domain