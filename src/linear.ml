open Batteries
open Util
open Syntax
open Syntax.Typed
open Syntax.TypedProgram

module Make (D : Domain.Domain) = struct

  let rec state_pred = function
    | [] -> []
    | i :: is ->
      ((pred i) :: is) ::
      List.map (fun s -> i :: s) (state_pred is)

  let init_result program =
    let n_threads = Array.length program.threads in
    let n_ins = Array.map (fun t -> Array.length t.ins) program.threads in
    let result = Hashtbl.create (Array.fold_left ( * ) 1 n_ins) in
    Hashtbl.add result (repeat n_threads 0) (D.init program);
    result

  let analyze program =

    let result = init_result program in

    let analyze_from_pred t s =
      if List.mem (-1) s then D.bottom
      else
        let i = List.nth s t in
        D.transfer
          (Hashtbl.find result s) t
          (nth_ins program t i).item in

    let rec analyze_state s =
      let pred = state_pred s in
      List.iter
        (fun s' ->
           if not (List.mem (-1) s') then
             try ignore (Hashtbl.find result s') with
               Not_found -> analyze_state s')
        pred;
      List.mapi analyze_from_pred pred
      |> List.fold_left D.join D.bottom
      |> Hashtbl.add result s in

    analyze_state (Array.map (fun t -> Array.length t.ins) program.threads |> Array.to_list);
    result

  let print result =
    Hashtbl.fold (fun k v li -> (k, v) :: li) result []
    |> List.sort Pervasives.compare
    |> List.iter
      (fun (s, p) ->
         print_string "############\n";
         print_list print_int s;
         print_string " :\n\n";
         D.print IO.stdout p;
         print_newline ())

end
