type 'a loc = {
  item : 'a;
  startpos : Lexing.position;
  endpos : Lexing.position;
}

type value =
  | Int of int loc
  | Var of string loc

type expression =
  | Val of value loc
  | Op of char loc * expression loc * expression loc

module Untyped =
struct
  type t  =
    | Affect of string loc * expression loc
    | Cmp of string loc * value loc * value loc
    | Mfence
    | Label of string loc
    | Jnz of string loc * string loc
    | Jz of string loc * string loc
    | Jmp of string loc
end

module Typed =
struct
  type t =
    | Read of string loc * string loc
    | Write of string loc * value loc
    | RegOp of string loc * expression loc
    | Cmp of string loc * value loc * value loc
    | Mfence
    | Label of string loc
    | Jnz of string loc * string loc
    | Jz of string loc * string loc
    | Jmp of string loc
end

module Program (Ins : sig type t end) =
struct
  type thread = {
    locals : string list;
    ins : Ins.t loc list;
  }

  type t = {
    initial : (string * int) list;
    threads : thread list;
  }
end

module UntypedProgram = Program (Untyped)
module TypedProgram = Program (Typed)