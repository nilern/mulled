structure X64SysVCpsConvert = CpsConvertFn(X64SysVAbi)
structure X64SysVClosureConvert = ClosureConvertFn(X64SysVAbi)
structure X64RegIsaLabelUses = IsaLabelUsesFn(X64SysVAbi.RegIsa)
structure X64Linearize = LinearizeFn(struct
    structure LabelUses = X64RegIsaLabelUses
    structure SeqIsa = X64SeqIsa
end)

structure Main :> sig
    val main: string * string list -> OS.Process.status
end = struct
    val op|> = Fn.|>
    val op<> = PPrint.<>
    val op<+> = PPrint.<+>
    val text = PPrint.text
    datatype either = datatype Either.t
    datatype flag_arity = datatype CLIParser.flag_arity
    type input = Parser.input
    datatype stmt = datatype FAst.Term.stmt
    exception TypeError = TypeError.TypeError

    fun lexstreamFromInStream instream n =
        if TextIO.endOfStream instream
        then ""
        else TextIO.inputN (instream, n)

    datatype command
        = Build of { debug: bool, lint: bool, asm: bool, input: input, output: string option
                   , home: string }
        | Repl

    val cmdSpecs =
        List.foldl CLIParser.FlagSpecs.insert' CLIParser.FlagSpecs.empty
                   [ ("build", List.foldl CLIParser.FlagSpecs.insert' CLIParser.FlagSpecs.empty
                                          [ ("debug", Nullary)
                                          , ("lint", Nullary)
                                          , ("o", Unary)
                                          , ("S", Nullary) ])
                   , ("repl", CLIParser.FlagSpecs.empty)]

    val parser = CLIParser.subcommandsParser cmdSpecs

    fun parseArgs argv =
        Either.map (fn ("build", flaggeds, positionals) =>
                        Build { debug = isSome (CLIParser.Flaggeds.find (flaggeds, "debug"))
                              , lint = isSome (CLIParser.Flaggeds.find (flaggeds, "lint"))
                              , asm = isSome (CLIParser.Flaggeds.find (flaggeds, "S"))
                              , input = case positionals
                                        of [] => { instream = TextIO.stdIn
                                                 , sourcemap = Pos.mkSourcemap () }
                                         | [filename] => { instream = TextIO.openIn filename
                                                         , sourcemap = Pos.mkSourcemap' filename }
                                         | _ => raise Fail "Multiple input files unimplemented"
                              , output = case CLIParser.Flaggeds.find (flaggeds, "o")
                                         of SOME (SOME outfilename) => SOME outfilename
                                          | NONE => NONE
                              , home = case OS.Process.getEnv "BROOM_HOME"
                                       of SOME home => home }
                     | ("repl", _, _) => Repl
                     | (cmd, _, _) => raise Fail ("Unreachable code; unknown subcommand " ^ cmd))
                   (parser argv)

    fun printErr str = TextIO.output (TextIO.stdErr, str)

    fun logger debug str = if debug then TextIO.output (TextIO.stdErr, str) else ()

    fun build {debug, lint, asm, input = input as {sourcemap, instream = _}, output, home} =
        let val log = logger debug
        in  case Parser.parse input
            of Right program =>
                let val _ = log (PPrint.pretty 80 (Cst.Term.beginToDoc program) ^ "\n")
                    val _ = log "# Typechecking...\n\n"
                    val tenv = TypecheckingEnv.default sourcemap
                in case Typechecker.elaborateProgram tenv program
                   of Right (program, _) =>
                       let val program = ExitTypechecker.programToF tenv program
                           do if lint
                              then case FAstTypechecker.typecheckProgram tenv program
                                   of SOME err => raise Fail "Lint failed"
                                   | NONE => ()
                              else ()
                       in  case WellFounded.elaborate program
                           of Right program =>
                               ( log (PPrint.pretty 80 (FAst.Term.programToDoc tenv program) ^ "\n")
                               ; log "# CPS converting...\n\n"
                               ; if lint
                                 then case FAstTypechecker.typecheckProgram tenv program
                                      of SOME err => raise Fail "Lint failed"
                                       | NONE => ()
                                 else ()
                               ; let val program = PatternMatching.implement program
                                     do if lint
                                        then case FAstTypechecker.typecheckProgram tenv program
                                             of SOME err => raise Fail "Lint failed"
                                              | NONE => ()
                                        else ()
                                     val program = X64SysVCpsConvert.cpsConvert program
                                     val _ = log (PPrint.pretty 80 (Cps.Program.toDoc program) ^ "\n")
                                     do if lint
                                        then case CpsTypechecker.checkProgram program
                                             of Right () => ()
                                              | Left err => raise Fail "CPS lint failed"
                                        else ()
                                     do log "# Closure converting...\n\n"
                                     val program = X64SysVClosureConvert.convert program
                                     val _ = log (PPrint.pretty 80 (Cps.Program.toDoc program) ^ "\n")
                                     do if lint
                                        then case CpsTypechecker.checkProgram program
                                             of Right () => ()
                                              | Left err => raise Fail (PPrint.pretty 80 (CpsTypechecker.errorToDoc err))
                                        else ()
                                    do log "# Selecting instructions...\n\n"
                                    val program = X64InstrSelection.selectInstructions program
                                    do log (PPrint.pretty 80 (X64Isa.Program.toDoc program) ^ "\n")
                                    do log "# Allocating registers...\n\n"
                                    val allocated as {program, maxSlotCount} = X64SysVRegisterAllocation.allocate program
                                    do log (PPrint.pretty 80 (X64RegIsa.Program.toDoc program) ^ "\n")
                                    do log "# Inserting logues...\n\n"
                                    val program = X64InsertLogues.insert allocated
                                    do log (PPrint.pretty 80 (X64RegIsa.Program.toDoc program) ^ "\n")
                                    do log "# Linearizing...\n\n"
                                    val program = X64Linearize.linearize program
                                    do log (PPrint.pretty 80 (X64SeqIsa.Program.toDoc program) ^ "\n")
                                    do log "# Emitting assembly...\n\n"
                                    (* FIXME: Error handling: *)
                                 in case output
                                    of SOME output =>
                                        let val asmFilename = output ^ ".s"
                                            val asmStream = TextIO.openOut asmFilename
                                        in GasX64SysVAbiEmit.emit asmStream {program, maxSlotCount, sourcemap}
                                         ; TextIO.closeOut asmStream
                                         ; if asm
                                           then ()
                                           else ( OS.Process.system ( "cc -o " ^ output ^ " "
                                                                    ^ asmFilename ^ " "
                                                                    ^ "-L" ^ home ^ " "
                                                                    (* FIXME: Not portable and maybe too many: *)
                                                                    ^ "-lbroom_runtime -lrt -lpthread -ldl" )
                                                ; OS.FileSys.remove asmFilename )
                                        end
                                     | NONE => (* HACK: Handy for debugging but unconventional: *)
                                        GasX64SysVAbiEmit.emit TextIO.stdOut {program, maxSlotCount, sourcemap}
                                  ; OS.Process.success
                                 end )
                            | Left errors =>
                               ( Vector.app (printErr o PPrint.pretty 80 o WellFounded.errorToDoc sourcemap)
                                            errors
                               ; OS.Process.failure )
                       end
                    | Left (program, _, errors) =>
                       ( List.app (fn err => printErr (PPrint.pretty 80 (TypeError.toDoc tenv err)))
                                  errors
                       ; OS.Process.failure )
                end
             | Left (_, repairs) =>
                ( List.app (fn repair => printErr (Parser.repairToString sourcemap repair ^ "\n"))
                           repairs
                ; OS.Process.failure )
        end

    val prompt = "broom> "

    fun rep (tenv, venv) line =
        let val input as {sourcemap, ...} =
                {instream = TextIO.openString line, sourcemap = Pos.mkSourcemap ()}
        in  case Parser.parse input
            of Right stmts =>
                (case Typechecker.elaborateProgram tenv stmts
                 of Right (program, tenv) =>
                     let val program = ExitTypechecker.programToF tenv program
                     in  case WellFounded.elaborate program
                         of Right program =>
                             let val program as {code = (_, stmts, _), ...} = PatternMatching.implement program
                             in Vector1.app (fn stmt as (Val (_, {var, typ, ...}, _)) =>
                                                let val v = FAstEval.interpret tenv venv stmt
                                                in print ( Name.toString var ^ " = "
                                                         ^ FAstEval.Value.toString tenv v ^ " : "
                                                         ^ FAst.Type.Concr.toString tenv typ ^ "\n" )
                                                end
                                              | stmt as (Expr _) => ignore (FAstEval.interpret tenv venv stmt))
                                           stmts
                              ; (tenv, venv)
                             end
                          | Left errors =>
                             ( Vector.app (printErr o PPrint.pretty 80 o WellFounded.errorToDoc sourcemap)
                                          errors
                             ; (tenv, venv) )
                     end
                  | Left (_, _, errors) =>
                     ( List.app (fn err => printErr (PPrint.pretty 80 (TypeError.toDoc tenv err)))
                                errors
                     ; (tenv, venv) ))
             | Left (_, repairs) =>
                ( List.app (fn repair => printErr (Parser.repairToString sourcemap repair ^ "\n"))
                           repairs
                ; (tenv, venv) )
        end

    fun rtp tenv line =
        let val input as {sourcemap, ...} =
                {instream = TextIO.openString line, sourcemap = Pos.mkSourcemap ()}
        in  case Parser.parse input
            of Right stmts =>
                (case Typechecker.elaborateProgram tenv stmts
                 of Right (program, tenv) =>
                     let val program = ExitTypechecker.programToF tenv program
                     in  case WellFounded.elaborate program
                         of Right program =>
                             ( print (PPrint.pretty 80 (FAst.Term.programToDoc tenv program))
                             ; tenv )
                          | Left errors =>
                             ( Vector.app (printErr o PPrint.pretty 80 o WellFounded.errorToDoc sourcemap)
                                          errors
                             ; tenv )
                     end
                  | Left (_, _, errors) =>
                     ( List.app (fn err => printErr (PPrint.pretty 80 (TypeError.toDoc tenv err)))
                                errors
                     ; tenv ))
             | Left (_, repairs) =>
                ( List.app (fn repair => printErr (Parser.repairToString sourcemap repair ^ "\n"))
                           repairs
                ; tenv )
        end

    fun repl () =
        let val topVals = FAstEval.newToplevel ()
            fun loop tenv venv =
                let val _ = print prompt
                in case TextIO.inputLine TextIO.stdIn
                   of SOME line =>
                       (let val (tenv, venv) =
                                if String.isPrefix ":t " line (* TODO: Allow leading whitespace. *)
                                then (rtp tenv (String.extract (line, 2, NONE)), venv)
                                else rep (tenv, venv) line
                        in loop tenv venv
                        end
                        (* FIXME: 
                        handle Parser.ParseError => loop tenv venv
                             | TypeError err => 
                                ( printErr (PPrint.pretty 80 (TypeError.toDoc err))
                                ; loop tenv venv ) *))
                    | NONE => ()
                end
        in loop (TypecheckingEnv.default (AntlrStreamPos.mkSourcemap ())) (FAstEval.newToplevel ())
        end

    fun main (name, args) =
        (case parseArgs args
         of Either.Right cmd =>
             (case cmd
              of Build args => 
                  let val status = build args
                  in TextIO.closeIn (#instream (#input args))
                   ; status
                  end
               | Repl =>
                  ( repl ()
                  ; OS.Process.success ))
          | Either.Left errors =>
             ( List.app (fn error => print (error ^ ".\n")) errors
             ; OS.Process.failure ))
        handle exn =>
            ( print ("unhandled exception: " ^ exnMessage exn ^ "\n")
            ; List.app (fn s => print ("\t" ^ s ^ "\n")) (SMLofNJ.exnHistory exn)
            ; OS.Process.failure )
end

