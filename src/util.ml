(*
  Option
*)

let str_int_option = function
  | None -> "∅"
  | Some x -> string_of_int x

(*
  List
*)

let set_assoc k v li =
  List.map
    (fun (k', v') -> k', if k' = k then v else v') li

let set_nth n v li =
  List.mapi (fun i x -> if i = n then v else x) li

let repeat n v =
  let rec aux acc n =
    if n = 0 then acc
    else aux (v :: acc) (pred n)
  in aux [] n

let rec print_list p = function
  | [] -> ()
  | [x] -> p x
  | x :: xs -> p x; print_string "; "; print_list p xs

let rec last = function
  | [] -> raise Not_found
  | [x] -> x
  | _ :: xs -> last xs

let rec first = function
  | [] -> failwith "first"
  | [x] -> []
  | x :: xs -> x :: first xs

let rec ( -- ) init final =
  if init > final then []
  else init :: (succ init -- final)

let ( --^ ) init final =
  init -- pred final

let rec inser_all_pos x = function
  | [] -> [[x]]
  | y :: ys ->
    (x :: y :: ys) ::
    List.map (fun yy -> y :: yy) (inser_all_pos x ys)

let rec ordered_parts = function
  | [] -> [[]]
  | x :: xs ->
    let xs = ordered_parts xs in
    List.fold_left ( @ ) xs @@
    List.map (inser_all_pos x) xs

(*
  Misc
*)

let fun_of_op op x y = match op with
  | '+' -> Some (x + y)
  | '-' -> Some (x - y)
  | '*' -> Some (x * y)
  | '/' -> if y = 0 then None else Some (x / y)
  | _ -> failwith "fun_of_op"