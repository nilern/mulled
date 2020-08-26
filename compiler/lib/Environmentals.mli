module T = Fc.Type

val reabstract : Env.t -> T.abs -> T.ov Vector.t * T.locator * T.t
val instantiate_abs : Env.t -> T.abs -> T.uv Vector.t * T.locator * T.t
val instantiate_arrow : Env.t -> T.binding Vector.t -> T.locator -> T.t -> T.t -> T.abs
    -> T.uv Vector.t * T.locator * T.t * T.t * T.abs
