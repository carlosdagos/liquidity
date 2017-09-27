(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017       .                                          *)
(*    Fabrice Le Fessant, OCamlPro SAS <fabrice@lefessant.net>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module StringMap = Map.Make(String)
module StringSet = Set.Make(String)

type const =
  | CUnit
  | CBool of bool
  | CInt of string
  | CNat of string
  | CTez of string
  | CString of string
  | CKey of string
  | CSignature of string
  | CTuple of const list
  | CNone
  | CSome of const

  (* Map [ key_x_value_list ] or (Map [] : ('key,'value) map) *)
  | CMap of (const * const) list
  | CList of const list
  | CSet of const list

and datatype =
  | Tunit
  | Tbool
  | Tint
  | Tnat
  | Ttez
  | Tstring
  | Ttimestamp
  | Tkey
  | Tsignature

  | Ttuple of datatype list

  | Toption of datatype
  | Tlist of datatype
  | Tset of datatype

  | Tmap of datatype * datatype
  | Tcontract of datatype * datatype
  | Tor of datatype * datatype
  | Tlambda of datatype * datatype

  | Tfail
  | Ttype of string * datatype


type 'exp contract = {
    parameter : datatype;
    storage : datatype;
    return : datatype;
    code : 'exp;
  }

type location = {
    loc_file : string;
    loc_pos : ( (int * int) * (int*int) ) option;
  }

exception Error of location option * string

(* `variant` is the only parameterized type authorized in Liquidity.
   Its constructors, `Left` and `Right` must be constrained with type
   annotations, for the correct types to be propagated in the sources.
*)
type constructor =
  Constr of string
| Left of datatype
| Right of datatype
| Source of datatype * datatype

type 'ty exp = {
    desc : 'ty exp_desc;
    ty : 'ty;
    bv : StringSet.t;
    fail : bool;
  }

and 'ty exp_desc =
  | Let of string * location * 'ty exp * 'ty exp
  | Var of string * location * string list
  | SetVar of string * location * string list * 'ty exp
  | Const of datatype * const
  | Apply of string * location * 'ty exp list
  | If of 'ty exp * 'ty exp * 'ty exp
  | Seq of 'ty exp * 'ty exp
  | LetTransfer of (* storage *) string * (* result *) string
                                 * location
                   * (* contract_ *) 'ty exp
                   * (* tez_ *) 'ty exp
                   * (* storage_ *) 'ty exp
                   * (* arg_ *) 'ty exp
                   * 'ty exp (* body *)
  | MatchOption of 'ty exp  (* argument *)
                     * location
                     * 'ty exp  (* ifnone *)
                     * string * 'ty exp (*  ifsome *)
  | MatchList of 'ty exp  (* argument *)
                 * location
                 * string * string * 'ty exp * (* ifcons *)
                       'ty exp (*  ifnil *)
  | Loop of string * location
              * 'ty exp  (* body *)
              * 'ty exp (*  arg *)

  | Lambda of string * datatype * location * 'ty exp * datatype
   (* final datatype is inferred during typechecking *)

  | Record of location * (string * 'ty exp) list
  | Constructor of location * constructor * 'ty exp

  | MatchVariant of 'ty exp
                    * location
                    * (string * string list * 'ty exp) list

type syntax_exp = unit exp
type typed_exp = datatype exp
type live_exp = (datatype * datatype StringMap.t) exp




type michelson_exp =
  | M_INS of string
  | M_INS_CST of string * datatype * const
  | M_INS_EXP of string * datatype list * michelson_exp list

type pre_michelson =
  | SEQ of pre_michelson list
  | DIP of int * pre_michelson
  | IF of pre_michelson * pre_michelson
  | IF_NONE of pre_michelson * pre_michelson
  | IF_CONS of pre_michelson * pre_michelson
  | IF_LEFT of pre_michelson * pre_michelson
  | LOOP of pre_michelson

  | LAMBDA of datatype * datatype * pre_michelson
  | EXEC

  | DUP of int
  | DIP_DROP of int * int
  | DROP
  | CAR
  | CDR
  | CDAR of int
  | CDDR of int
  | PUSH of datatype * const
  | PAIR
  | COMPARE
  | LE | LT | GE | GT | NEQ | EQ
  | FAIL
  | NOW
  | TRANSFER_TOKENS
  | ADD
  | SUB
  | BALANCE
  | SWAP
  | GET
  | UPDATE
  | SOME
  | CONCAT
  | MEM
  | MAP
  | REDUCE

  | SELF
  | AMOUNT
  | STEPS_TO_QUOTA
  | MANAGER
  | CREATE_ACCOUNT
  | CREATE_CONTRACT
  | H
  | CHECK_SIGNATURE

  | CONS
  | OR
  | XOR
  | AND
  | NOT

  | INT
  | ABS
  | NEG
  | MUL

  | LEFT of datatype
  | RIGHT of datatype

  | EDIV
  | LSL
  | LSR

  | SOURCE of datatype * datatype

  | SIZE
  | DEFAULT_ACCOUNT

  (* obsolete *)
  | MOD
  | DIV

type type_kind =
  | Type_record of datatype list * int StringMap.t
  | Type_variant of
      (string
       * datatype (* final type *)
       * datatype (* left type *)
       * datatype (* right type *)
      ) list

type env = {
    filename : string;
    mutable types : (datatype * type_kind) StringMap.t;
    mutable labels : (string * int * datatype) StringMap.t;
    mutable constrs : (string * datatype) StringMap.t;
    vars : (string * datatype * int ref) StringMap.t;
  }


(* decompilation *)

type node = {
    num : int;
    mutable kind : node_kind;
    mutable args : node list; (* dependencies *)

    mutable next : node option;
    mutable prevs : node list;
  }

 and node_kind =
   | N_UNKNOWN of string
   | N_VAR of string
   | N_START
   | N_IF of node * node
   | N_IF_RESULT of node * int
   | N_IF_THEN of node
   | N_IF_ELSE of node
   | N_IF_END of node * node
   | N_IF_END_RESULT of node * node option * int
   | N_IF_NONE of node
   | N_IF_SOME of node * node
   | N_IF_NIL of node
   | N_IF_CONS of node * node * node
   | N_IF_LEFT of node * node
   | N_IF_RIGHT of node * node
   | N_TRANSFER of node * node
   | N_TRANSFER_RESULT of int
   | N_CONST of datatype * const
   | N_PRIM of string
   | N_FAIL
   | N_LOOP of node * node
   | N_LOOP_BEGIN of node
   | N_LOOP_ARG of node * int
   | N_LOOP_RESULT of (* N_LOOP *) node
                                   * (* N_LOOP_BEGIN *) node * int
   | N_LOOP_END of (* N_LOOP *) node
                                * (* N_LOOP_BEGIN *) node
                                * (* final_cond *) node
   | N_LAMBDA of node * node * datatype * datatype
   | N_LAMBDA_BEGIN
   | N_LAMBDA_END of node
   | N_END
   | N_LEFT of datatype
   | N_RIGHT of datatype
   | N_SOURCE of datatype * datatype

type node_exp = node * node

type warning =
  | Unused of string
