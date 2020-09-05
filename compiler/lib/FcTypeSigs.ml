module type TYPE = sig
    type uv
    type subst

    type kind
        = ArrowK of kind Vector1.t * kind
        | TypeK

    type bv = {depth : int; sibli : int}

    (* The level of a type variable is the number of skolem-binding scopes in the
       typing environment at its creation site. Kind of like syntactic closures, but
       type inference is (scoping-wise) much simpler than hygienic macroexpansion so
       the required information can be compressed to this one small integer. *)
    type level = int

    type binding = Name.t * kind

    type ov = binding * level

    and abs = Exists of kind Vector.t * locator * t

    and t =
        | Pi of kind Vector.t * (locator * t) Vector.t * t * abs
        | Record of t
        | With of {base : t; label : Name.t; field : t}
        | EmptyRow
        | Type of abs
        | Fn of t
        | App of t * t Vector1.t
        | Bv of bv
        | Use of binding
        | Ov of ov
        | Uv of uv
        | Prim of Prim.t

    and locator =
        | PiL of int * locator
        | RecordL of locator
        | WithL of {base : locator; label : Name.t; field : locator}
        | TypeL of t
        | Hole

    and 'a field = {label : string; typ : 'a}

    and coercion =
        | Refl of typ
        | Symm of coercion
        | Trans of coercion * coercion
        | Comp of coercion * coercion Vector1.t
        | Inst of coercion * typ Vector1.t
        | AUse of Name.t
        | TypeCo of coercion
        | Patchable of coercion ref

    and typ = t
    and template = locator

    val kind_to_doc : kind -> PPrint.document
    val binding_to_doc : binding -> PPrint.document
    val abs_to_doc : subst -> abs -> PPrint.document
    val universal_to_doc : kind Vector.t -> PPrint.document -> PPrint.document
    val to_doc : subst -> t -> PPrint.document
    val coercion_to_doc : subst -> coercion -> PPrint.document
    val locator_to_doc : subst -> locator -> PPrint.document

    val to_abs : t -> abs

    val freshen : binding -> binding
    val sibling : subst -> uv -> uv
end

module type UV = sig
    type typ
    type level

    type subst
    
    type t

    type v =
        | Unassigned of Name.t * level
        | Assigned of typ

    val new_subst : unit -> subst
   
    val make : subst -> v -> t
    val get : subst -> t -> v
    val set : subst -> t -> v -> unit
end

