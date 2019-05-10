structure ExitTypechecker :> sig
    val toF: TypecheckingCst.expr ref -> FixedFAst.Term.expr
end = struct
    structure Env :> sig
        type ('t, 'v) t

        val empty: ('t, 'v) t 
        val insertVal: ('t, 'v) t -> Name.t * 'v -> ('t, 'v) t
        val insertType: ('t, 'v) t -> Name.t * 't -> ('t, 'v) t
        val lookupVal: ('t, 'v) t * Name.t -> 'v
        val lookupType: ('t, 'v) t * Name.t -> 't
    end = struct
        type ('t, 'v) t = {types: 't NameSortedMap.map, vals: 'v NameSortedMap.map}

        val empty = {types = NameSortedMap.empty, vals = NameSortedMap.empty}

        fun insertVal {types, vals} (k, v) = {types, vals = NameSortedMap.insert (vals, k, v)}
        fun insertType {types, vals} (k, v) = {types = NameSortedMap.insert (types, k, v), vals}

        (* Unlike `NameSortedMap.lookup`, provide the missing name when compiler bugs out: *)
        fun lookup (map, name) = case NameSortedMap.find (map, name)
                                 of SOME v => v
                                  | NONE => raise Fail ("Not found: " ^ Name.toString name)

        fun lookupVal ({types = _, vals}, name) = lookup (vals, name)
        fun lookupType ({types, vals = _}, name) = lookup (types, name)
    end

    structure TC = TypecheckingCst
    datatype tc_typ = datatype TC.typ
    datatype tc_expr = datatype TC.expr
    structure FFType = FixedFAst.Type
    datatype typ = datatype FAst.Type.typ
    structure FFTerm = FixedFAst.Term
    datatype expr = datatype FAst.Term.expr
    datatype stmt = datatype FAst.Term.stmt
    datatype either = datatype Either.t

    type env = (FFType.def, FFType.typ FFTerm.def) Env.t

    fun pushTypes env types =
        let fun step (var, {binder = {kind, typ = _}, shade = _}, env) =
                Env.insertType env (var, {var, kind})
        in NameHashTable.foldi step env types
        end

    fun typeToUnFixedF (env: env) (typ: TC.typ): FFType.typ FAst.Type.typ =
        case typ
        of OutputType typ =>
            (case typ
             of ForAll (pos, {var, ...}, body) =>
                 ForAll (pos, Env.lookupType (env, var), typRefToF env body)
              | Arrow (pos, {domain, codomain}) =>
                 Arrow (pos, {domain = typRefToF env domain, codomain = typRefToF env codomain})
              | Record (pos, row) => Record (pos, typRefToF env row)
              | RowExt (pos, {field = (label, fieldt), ext}) =>
                 RowExt (pos, {field = (label, typRefToF env fieldt), ext = typRefToF env ext})
              | EmptyRow pos => EmptyRow pos
              | FFType.Type (pos, typ) => FFType.Type (pos, typRefToF env typ)
              | UseT (pos, {var, ...}) => UseT (pos, Env.lookupType (env, var))
              | Prim (pos, p) => Prim (pos, p))
         | InputType _ => raise Fail "unreachable"
         | ScopeType {typ, types, parent = _} => typeToUnFixedF (pushTypes env types) (!typ)
         | OVar (_, ov) => UseT (Pos.default "FIXME", Env.lookupType (env, TypeVars.ovName ov))
         | UVar (_, uv) => (case TypeVars.uvGet uv
                               of Right t => typeToUnFixedF env t
                                | Left _ => Prim (Pos.default "FIXME", FFType.Prim.Unit))

    and typeToF (env: env) (typ: TC.typ): FFType.typ = FFType.Fix (typeToUnFixedF env typ)

    and typRefToF (env: env) (typ: TC.typ ref): FFType.typ = typeToF env (!typ)

    fun pushVals env vals =
        let fun step (var, {binder = {typ, value = _}, shade = _}, env) =
                Env.insertVal env (var, {var, typ = typeToF env (valOf (!typ))})
        in NameHashTable.foldi step env vals
        end

    fun toUnfixedF (env: env) (expr: TC.expr ref): (FFType.typ, FFTerm.expr) FAst.Term.expr =
        case !expr
        of OutputExpr expr =>
            (case expr
             of Fn (pos, {var, typ = _}, body) =>
                 Fn (pos, Env.lookupVal (env, var), exprToF env body)
              | TFn (pos, {var, ...}, body) =>
                 TFn (pos, Env.lookupType (env, var), exprToF env body)
              | Extend (pos, typ, fields, record) =>
                 Extend ( pos, typRefToF env typ
                        , Vector.map (Pair.second (exprToF env)) fields
                        , Option.map (exprToF env) record)
              | Let (pos, stmts, body) =>
                 Let (pos, Vector.map (stmtToF env) stmts, exprToF env body)
              | App (pos, typ, {callee, arg}) =>
                 App (pos, typRefToF env typ, {callee = exprToF env callee, arg = exprToF env arg})
              | TApp (pos, typ, {callee, arg}) =>
                 TApp (pos, typRefToF env typ, {callee = exprToF env callee, arg = typRefToF env arg})
              | Field (pos, typ, expr, label) =>
                 Field (pos, typRefToF env typ, exprToF env expr, label)
              | Type (pos, typ) => Type (pos, typRefToF env typ)
              | Use (pos, {var, ...}) => Use (pos, Env.lookupVal (env, var))
              | Const (pos, c) => Const (pos, c))
         | ScopeExpr {expr, vals, parent = _} => toUnfixedF (pushVals env vals) expr
         | InputExpr _ => raise Fail "unreachable"

    and exprToF (env: env) (expr: TC.expr ref): FFTerm.expr = FFTerm.Fix (toUnfixedF env expr)

    and stmtToF (env: env) stmt =
        case stmt
        of Val (pos, {var, typ = _}, expr) => Val (pos, Env.lookupVal (env, var), exprToF env expr)
         | Expr expr => Expr (exprToF env expr)

    val toF = exprToF Env.empty
end

