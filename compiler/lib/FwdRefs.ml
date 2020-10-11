open Streaming

module E = Fc.Term.Expr
module S = Fc.Term.Stmt

module Make (IntHashtbl : Hashtbl.S with type key = int) (IntHashSet : CCHashSet.S with type elt = int) = struct

module Support = E.VarSet

type error = AccessUninitialized of Util.span * E.var * E.var

type shape =
    | Values of shape Vector.t
    | Closure of Support.t * shape
    | Scalar
    | Unknown

let rec join shape shape' = match shape with
    | Values shapes -> (match shape' with
        | Values shapes' -> Stream.from (Source.zip_with join
                (Vector.to_source shapes) (Vector.to_source shapes'))
            |> Stream.into (Sink.unzip
                (Vector.sink () |> Sink.map (fun shapes -> Values shapes))
                (Sink.fold (||) false))
        | Unknown -> (shape, false)
        | _ -> failwith "unreachable")
    | Closure (clovers, codomain) -> (match shape' with
        | Closure (clovers', codomain') ->
            let (codomain, codomain_changed) = join codomain codomain' in
            ( Closure (Support.union clovers clovers', codomain)
            , codomain_changed || not (Support.equal clovers clovers') )
        | Unknown -> (shape, false)
        | _ -> failwith "unreachable")
    | Scalar -> (match shape' with
        | Scalar -> (shape, false)
        | Unknown -> (shape, false)
        | _ -> failwith "unreachable")
    | Unknown -> (match shape' with
        | Unknown -> (shape, false)
        | shape' -> (shape', true))

let rec extract_shape_support = function
    | Values shapes -> Stream.from (Vector.to_source shapes)
        |> Stream.map extract_shape_support
        |> Stream.into (Sink.unzip
            (Sink.map (fun shapes -> Values shapes) (Vector.sink ()))
            (Sink.fold Support.union Support.empty))
    | Closure (clovers, codomain) ->
        let (codomain, codomain_support) = extract_shape_support codomain in
        ( Closure (Support.empty, codomain)
        , Support.union clovers codomain_support )
    | (Scalar | Unknown) as shape -> (shape, Support.empty)

type state = Uninitialized | Initialized

type access = Instant of state | Delayed of state

module Shapes : sig
    type t

    val create : unit -> t
    val length : t -> int
    val refine : t -> int -> shape -> bool
    val find : t -> int -> shape
end = struct
    type t = shape IntHashtbl.t

    let create () = IntHashtbl.create 0
    let length = IntHashtbl.length

    let find shapes id =
        IntHashtbl.find_opt shapes id
        |> Option.value ~default: Unknown

    let refine shapes id shape' =
        let shape = find shapes id in
        let (shape, changed) = join shape shape' in
        IntHashtbl.replace shapes id shape;
        changed
end

(* --- *)

type ctx = Naming | Escaping

module Env : sig
    type t

    val empty : t
    val push_fn : t -> ctx -> t
    val push_letrec : t -> S.def Array1.t -> t
    val initialize : t -> int -> unit
    val access : t -> int -> access
end = struct
    type scope =
        | Fn of ctx
        | Rec of state IntHashtbl.t

    type t = scope list

    let empty = []
    let push_fn scopes ctx  = Fn ctx :: scopes

    let push_letrec scopes defs =
        let bindings = IntHashtbl.create (Array1.length defs) in
        Array1.iter (fun (_, ({id; _} : E.var), _) ->
            IntHashtbl.add bindings id Uninitialized
        ) defs;
        Rec bindings :: scopes

    let initialize scopes id =
        let rec initialize = function
            | Fn _ :: scopes -> initialize scopes
            | Rec bindings :: scopes ->
                if IntHashtbl.mem bindings id
                then IntHashtbl.add bindings id Initialized
                else initialize scopes
            | [] -> () in (* NOTE: must be nonrecursively bound, then *)
        initialize scopes

    let access scopes id =
        let rec access state_to_access = function
            | Fn ctx :: scopes ->
                let state_to_access = match ctx with
                    | Escaping -> state_to_access
                    | Naming -> (fun state -> Delayed state) in
                access state_to_access scopes
            | Rec bindings :: scopes -> (match IntHashtbl.find_opt bindings id with
                | Some state -> state_to_access state
                | None -> access state_to_access scopes)
            | [] -> state_to_access Initialized in (* NOTE: must be nonrecursively bound, then *)
        access (fun state -> Instant state) scopes
end

let analyzeStmts stmts =
    let errors = CCVector.create () in
    let report_error = CCVector.push errors in
    let shapes = Shapes.create () in
    let changed = ref true in (* true so that we get at least one iteration *)

    let rec shapeof : Env.t -> ctx -> E.t -> shape * Support.t
    = fun env ctx expr -> match expr.term with
        | Values exprs -> Stream.from (Source.array exprs)
            |> Stream.map (shapeof env ctx)
            |> Stream.into (Sink.unzip
                (Sink.map (fun typs -> Values typs) (Vector.sink ()))
                (Sink.fold Support.union Support.empty))

        | Focus {focusee; index} ->
            let (fshape, support) = shapeof env ctx focusee in
            ( (match fshape with
              | Values shapes -> Vector.get shapes index
              | _ -> Unknown)
            , support )

        | Fn {universals = _; param; body} ->
            let env = Env.push_fn env ctx in
            let (codomain, support) = shapeof env ctx body in
            (match ctx with
            | Naming -> (Closure (support, codomain), Support.empty)
            | Escaping -> (Closure (Support.empty, codomain), support))

        | App {callee; universals = _; arg} ->
            let (callee_shape, callee_support) = shapeof env Escaping callee in
            let (_, arg_support) = shapeof env Escaping arg in
            ( (match callee_shape with
              | Closure (_, codomain) -> codomain
                (* NOTE: ^-- should be empty because context was `Escaping`. *)
              | _ -> Unknown)
            , Support.union callee_support arg_support )

        | PrimApp {op = _; universals = _; arg} ->
            let (_, support) = shapeof env Escaping arg in
            (Unknown, support)

        | Let {def = (_, {id; _}, value); body}
        | Unpack {existentials = _; var = {id; _}; value; body} ->
            let (def_shape, def_support) = shapeof env Naming value in
            (* Need `let changed'` because `&&` is short-circuiting: *)
            let changed' = Shapes.refine shapes id def_shape in
            changed := !changed && changed';
            let (shape, body_support) = shapeof env ctx body in
            (shape, Support.union def_support body_support)

        | Match {matchee; clauses} ->
            let (_, support) = shapeof env Escaping matchee in
            Stream.from (Vector.to_source clauses)
            |> Stream.map (fun ({pat = _; body} : E.clause) -> shapeof env ctx body)
            |> Stream.into (Sink.unzip
                (Sink.fold (fun shape shape' -> fst (join shape shape')) Unknown)
                (Sink.fold Support.union support))

        | Letrec {defs; body} ->
            let env = Env.push_letrec env defs in
            let defs_support = Array1.fold_left (fun support (_, ({id; _} : E.var), expr) ->
                let (shape, def_support) = shapeof env Naming expr in
                (* Need `let changed'` because `&&` is short-circuiting: *)
                let changed' = Shapes.refine shapes id shape in
                changed := !changed && changed';
                Env.initialize env id;
                Support.union support def_support
            ) Support.empty defs in
            let (shape, body_support) = shapeof env ctx body in
            (shape, Support.union defs_support body_support)

        | Use {var; expr = _} ->
            let access (var' : E.var) = match Env.access env var'.id with
                | Delayed Initialized | Instant Initialized -> Support.empty
                | Delayed Uninitialized -> Support.singleton var'
                | Instant Uninitialized ->
                    report_error (AccessUninitialized (expr.pos, var, var'));
                    Support.empty in
            let immediate_support = access var in
            let shape = Shapes.find shapes var.id in
            (match ctx with
            | Escaping ->
                let (shape, shape_support) = extract_shape_support shape in
                ( shape
                , Stream.from (Source.seq (Support.to_seq shape_support))
                    |> Stream.map access
                    |> Stream.into (Sink.fold Support.union immediate_support) )
            | Naming -> (shape, immediate_support))

        | LetType {typedefs = _; body = expr} | Axiom {axioms = _; body = expr}
        | Cast {castee = expr; coercion = _} | Pack {existentials = _; impl = expr} ->
            shapeof env ctx expr

        | Proxy _ | Const _ -> (Scalar, Support.empty)

        | Patchable r -> TxRef.(shapeof env ctx !r) in

    while !changed do
        changed := false;
        CCVector.clear errors;

        let env = Env.empty in
        stmts |> Vector.iter (function
            | S.Expr expr ->
                let (shape, support) = shapeof env Escaping expr in
                ())
    done;

    if CCVector.length errors = 0
    then Ok shapes
    else Error (CCVector.freeze errors)

(* --- *)

module Initialized : sig
    type t

    val create : int -> t
end = struct
    include IntHashSet
end

let emitStmts stmts shapes =
    let ini = Initialized.create (Shapes.length shapes) in

    let emit expr = failwith "TODO" in

    stmts |> Vector.map (function
        | S.Expr expr -> S.Expr (emit expr))

(* --- *)

let convert stmts =
    analyzeStmts stmts
    |> Result.map (emitStmts stmts)

end

