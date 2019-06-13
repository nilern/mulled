signature ID = sig
    eqtype t

    val fresh: unit -> t
    val hash: t -> word
    val compare: t * t -> order
    val toString: t -> string

    structure HashKey: HASH_KEY where type hash_key = t
    structure OrdKey: ORD_KEY where type ord_key = t

    structure HashTable: MONO_HASH_TABLE where type Key.hash_key = t
end

structure Id :> ID = struct
    type t = word

    local val counter = ref 0w0
    in fun fresh () = let val res = !counter
                      in counter := res + 0w1
                       ; res
                      end
    end

    val hash = Fn.identity
    
    val compare = Word.compare

    val toString = Int.toString o Word.toInt

    structure HashKey = struct
        type hash_key = t

        val hashVal = hash
        val sameKey = op=
    end

    structure OrdKey = struct
        type ord_key = t

        val compare = compare
    end

    structure HashTable = HashTableFn(HashKey)
end

