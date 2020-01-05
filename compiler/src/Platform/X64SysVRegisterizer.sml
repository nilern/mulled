structure X64SysVRegisterizer = struct
    structure Abi = X64SysVAbi
    structure Isa = Abi.Isa
    structure RegIsa = Abi.RegIsa
    structure Reg = X64Register
    structure Env = RegisterEnvFn(Abi)
    structure Builder = RegIsa.Program.Builder
    structure Stmt = RegIsa.Stmt

    datatype oper = datatype X64RegInstructions.Oper.t
    datatype transfer = datatype X64RegInstructions.Transfer.t

    val op|> = Fn.|>

    fun stmt cconvs builder label env =
        fn Isa.Stmt.Param (target, pLabel, i) => (* FIXME: *)
            (case Env.find env target
             of SOME _ =>
                 let val paramRegs = #args Abi.foreignCallingConvention
                 in Env.freeIn env builder label target (Vector.sub (paramRegs, i))
                 end
              | NONE => env)

         | Isa.Stmt.Def (target, X64Instructions.Oper.CALLd (dest, args)) => (* FIXME: *)
            let val targetReg = Reg.rax
                val env = Env.freeIn env builder label target targetReg
                val target = targetReg
                val env = Env.evacuateCallerSaves env builder label
                val paramRegs = #args Abi.foreignCallingConvention
                val env = Vector.zip (args, paramRegs)
                        |> Vector.foldl (fn ((arg, reg), env) =>
                                             Env.allocateFixed env arg reg)
                                        env
            in Builder.insertStmt builder label (Stmt.Def (target, CALLd (dest, #[])))
             ; env
            end

         | Isa.Stmt.Def (target, expr) =>
            let val (env, targetReg) =
                    case Env.find env target
                    of SOME target => (env, target)
                     | NONE => Env.findOrAllocate env target
                val env = Env.free env target
                val target = targetReg
            in  case expr
                of X64Instructions.Oper.LOAD src =>
                    let val (env, src) = Env.findOrAllocate env src
                    in Builder.insertStmt builder label (Stmt.Def (target, LOAD src))
                     ; env
                    end
                 | X64Instructions.Oper.LOADc n =>
                    ( Builder.insertStmt builder label (Stmt.Def (target, LOADc n))
                    ; env )
                 | X64Instructions.Oper.LOADl lLabel =>
                    ( Builder.insertStmt builder label (Stmt.Def (target, LOADl lLabel))
                    ; env )
                 | _ => env (* FIXME *)
            end
         | Isa.Stmt.Eff expr =>
            (case expr
             of X64Instructions.Oper.STORE (target, src) =>
                 let val (env, target) = Env.findOrAllocate env target
                     val (env, src) = Env.findOrAllocate env src
                 in Builder.insertStmt builder label (Stmt.Eff (STORE (target, src)))
                  ; env
                 end
              | _ => env) (* FIXME *)
         | _ => env (* FIXME *)

    fun transfer cconvs builder label env =
        fn X64Instructions.Transfer.JMP (dest, args) =>
            (case Label.HashTable.find cconvs dest
             of SOME paramRegs =>
                  let val env = Vector.zip (args, paramRegs)
                              |> Vector.foldl (fn ((arg, reg), env) =>
                                                   Env.allocateFixed env arg reg)
                                              env
                  in Builder.setTransfer builder label (JMP (dest, #[]))
                   ; env
                  end)
         | X64Instructions.Transfer.JMPi (dest, args) =>
            let val paramRegs = Abi.escapeeCallingConvention
                val env = Vector.zip (args, paramRegs)
                        |> Vector.foldl (fn ((arg, reg), env) =>
                                             Env.allocateFixed env arg reg)
                                        env
                val (env, dest) = Env.findOrAllocate env dest
            in Builder.setTransfer builder label (JMPi (dest, #[]))
             ; env
            end
end
