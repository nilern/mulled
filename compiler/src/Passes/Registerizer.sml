signature REGISTERIZER = sig
    structure Abi : ABI
    structure Env : REGISTER_ENV

    val stmt : Abi.CallingConvention.internal Label.HashTable.hash_table
        -> Abi.RegIsa.Program.Builder.builder -> Label.t -> Env.t -> Abi.Isa.Stmt.t -> Env.t
    val transfer : Abi.CallingConvention.internal Label.HashTable.hash_table
        -> Abi.RegIsa.Program.Builder.builder -> Label.t -> Env.t -> Abi.Isa.Transfer.t -> Env.t
end
