structure TypeVars :> sig
    datatype predicativity = Predicative | Impredicative

    exception SetPrivate of Name.t
    exception Reset

    type ('scope, 'kind) ov
    type ('scope, 't) uv
    type ('scope, 't) path

    structure Ov: sig
        val new: 'scope * predicativity * Name.t * 'kind -> ('scope, 'kind) ov
        val scope: ('scope, 'kind) ov -> 'scope
        val name: ('scope, 'kind) ov -> Name.t
    end

    structure Uv: sig
        val new: 'scope * predicativity * Name.t -> ('scope, 't) uv
        val fresh: 'scope * predicativity -> ('scope, 't) uv
        val freshSibling: ('scope, 't) uv * predicativity -> ('scope, 't) uv
        val get: ('scope, 't) uv -> (('scope, 't) uv, 't) Either.t
        val set: ('t -> ('scope, 't) uv option) (* Try to unwrap another uv from provided 't. *)
                 -> ('scope * 'scope -> order) (* scope ordering to preserve scoping invariants *)
                 -> ('scope -> bool) (* Is the required scope available? *)
                 -> ('scope, 't) uv * 't -> unit
        val eq: ('scope, 't) uv * ('scope, 't) uv -> bool
        val name: ('scope, 't) uv -> Name.t
    end

    structure Path: sig
        val new: 't -> ('scope, 't) path
        val face: ('scope, 't) path -> 't
        val get: ('scope -> bool) (* Is the required coercion available? *)
                 -> ('scope, 't) path -> ('t * Name.t option, 't * Name.t) Either.t
        val addScope: ('scope, 't) path * 'scope * Name.t -> unit
        val set: ('t -> Name.t)
                 -> ('scope -> bool) (* Is the required coercion available? *)
                 -> ('scope, 't) path * 't -> unit
        val eq: ('scope, 't) path * ('scope, 't) path -> bool
    end
end = struct
    datatype predicativity = Predicative | Impredicative

    exception SetPrivate of Name.t
    exception Reset

    type 'scope meta = { name: Name.t
                       , scope: 'scope
                       , predicativity: predicativity }

    type ('scope, 'kind) ov = {meta: 'scope meta, kind: 'kind}

    datatype ('scope, 't) link
        = Link of ('scope, 't) uv
        | Root of {meta: 'scope meta, typ: 't option ref, rank: int ref}
    withtype ('scope, 't) uv = ('scope, 't) link ref

    type ('scope, 't) path =
        { face: 't
        , impls: ('scope * {typ: 't option, coercion: Name.t option}) list ref }

    structure Ov = struct
        fun new (scope, predicativity, name, kind) =
            {meta = {name, scope, predicativity}, kind}

        fun scope ({meta = {scope, ...}, ...}: ('scope, 'kind) ov) = scope

        fun name ({meta = {name, ...}, ...}: ('scope, 'kind) ov) = name
    end

    structure Uv = struct
        fun new (scope, predicativity, name) =
            ref (Root { meta = {name, scope, predicativity}
                      , typ = ref NONE
                      , rank = ref 0 })

        fun fresh (scope, predicativity) = new (scope, predicativity, Name.fresh ())


        fun find uv =
            case !uv
            of Link uv' => let val res = find uv'
                           in uv := Link res (* path compression *)
                            ; res
                           end
             | Root _ => uv

        fun root uv =
            case !(find uv)
            of Root root => root
             | Link _ => raise Fail "unreachable"

        fun freshSibling (uv, predicativity) = fresh (#scope (#meta (root uv)), predicativity)

        fun get uv =
            let val uv = find uv
            in case !uv
               of Root {typ, ...} => (case !typ
                                      of SOME t => Either.Right t
                                       | NONE => Either.Left uv)
                | Link _ => raise Fail "unreachable"
            end

        fun assign inScope (uv, t) =
            let val {meta = {scope, name, ...}, typ, ...} = root uv
            in if inScope scope
               then case !typ
                    of SOME _ => raise Reset
                     | NONE => typ := SOME t
               else raise SetPrivate name
            end

        fun newRank (rank, rank') =
            if rank = rank'
            then rank + 1
            else Int.max (rank, rank')

        fun merge scopeCmp inScope (uv, uv') =
            let val uv = find uv
                val uv' = find uv'
            in if uv = uv'
               then ()
               else case (!uv, !uv')
                    of ( Root {meta = {scope, predicativity, name}, rank, ...}
                       , Root { meta = {scope = scope', predicativity = predicativity', name = name'}
                              , rank = rank', ... } ) =>
                        if inScope scope 
                        then if inScope scope'
                             then let val (child, parent, parentRank) =
                                          case scopeCmp (scope, scope')
                                          of LESS => (uv, uv', rank')
                                           | GREATER => (uv', uv, rank)
                                           | EQUAL => (case Int.compare (!rank, !rank')
                                                       of LESS => (uv, uv', rank')
                                                        | GREATER => (uv', uv, rank)
                                                        | EQUAL => (uv, uv', rank'))
                                  in child := Link parent
                                   ; parentRank := newRank (!rank, !rank')
                                  end
                            else raise SetPrivate name'
                        else raise SetPrivate name
                     | _ => raise Fail "unreachable"
            end

        fun set uvFromT scopeCmp inScope (uv, t) =
            case uvFromT t
            of SOME uv' => merge scopeCmp inScope (uv, uv')
             | NONE => assign inScope (uv, t)

        val eq = op=

        fun name uv = #name (#meta (root uv))
    end

    structure Path = struct
        fun new face = {face, impls = ref []}

        val face: ('scope, 't) path -> 't = #face

        fun get inScope {face, impls} =
            case List.find (inScope o #1) (!impls)
            of SOME (_, {typ = SOME t, coercion}) => Either.Right (t, valOf coercion)
             | SOME (_, {typ = NONE, coercion}) => Either.Left (face, coercion)
             | NONE => Either.Left (face, NONE)

        fun addScope ({face, impls}, scope, coercion) =
            impls := (scope, {typ = NONE, coercion = SOME coercion}) :: !impls

        fun set faceName inScope ({face, impls}, t) =
            let val rec loop =
                    fn (scope, impl as {typ, coercion}) :: impls =>
                        if inScope scope
                        then case typ
                             of SOME _ => raise Reset
                              | NONE => (scope, {typ = SOME t, coercion}) :: impls
                        else (scope, impl) :: loop impls
                     | [] => raise SetPrivate (faceName face)
            in impls := loop (!impls)
            end

        fun eq ({impls, ...}: ('scope, 't) path, {impls = impls', ...}: ('scope, 't) path) =
            impls = impls'
   end
end

