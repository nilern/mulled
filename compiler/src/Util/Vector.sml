structure Vector = struct
    open Vector

    fun zip (xs, ys) =
        let val len = Int.min (Vector.length xs, Vector.length ys)
            val {update, done, ...} = MLton.Vector.create len
            fun loop i =
                if i < len
                then ( update (i, (Vector.sub (xs, i), Vector.sub (ys, i)))
                     ; loop (i + 1) )
                else ()
        in loop 0
         ; done ()
        end
end
