type t =
    | Int
    | Array | Cell
    | SingleRep (* = *) | Boxed
    | TypeIn | RowOf

val to_doc : t -> PPrint.document

val eq : t -> t -> bool
