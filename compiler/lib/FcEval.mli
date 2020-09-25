type 'a with_pos = 'a Util.with_pos
type expr = Fc.Term.Expr.t
type stmt = Fc.Term.Stmt.t

module Env : sig
    type t

    val eval : unit -> t
    val interactive : unit -> t
end

module Value : sig
    type t =
        | Tuple of t Vector.t
        | Fn of ((t -> t) -> t -> t)
        | Record of t Name.Map.t
        | Proxy
        | Int of int

    val to_doc : t -> PPrint.document
end

module Error : sig
    type t

    val to_doc : t -> PPrint.document
end

val interpret : Env.t -> expr with_pos -> (Value.t, Error.t) Result.t
val run : Env.t -> stmt -> (Value.t, Error.t) Result.t
