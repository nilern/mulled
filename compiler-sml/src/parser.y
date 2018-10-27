fun lookup "bogus" = 10000
  | lookup s = 0

%%

%name Broom

%pos Pos.t

%term ID of string | NUM of int | PLUS | TIMES | PRINT |
      SEMI | EOF | CARAT | DIV | SUB
%nonterm EXP of int | START of int option

%noshift EOF
%eop EOF

%%

START : PRINT EXP (print (Int.toString EXP);
                   print "\n";
                   SOME EXP)
      | EXP (SOME EXP)
      | (NONE)
EXP : NUM             (NUM)
    | ID              (lookup ID)
    | EXP PLUS EXP    (EXP1+EXP2)
    | EXP TIMES EXP   (EXP1*EXP2)
    | EXP DIV EXP     (EXP1 div EXP2)
    | EXP SUB EXP     (EXP1-EXP2)
    | EXP CARAT EXP   (let fun e (m,0) = 1
                              | e (m,l) = m*e(m,l-1)
                       in  e (EXP1,EXP2)
                       end)
