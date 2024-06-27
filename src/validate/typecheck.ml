(* SPDX-License-Identifier: AGPL-3.0-or-later *)
(* Copyright © 2021-2024 OCamlPro *)
(* Written by the Owi programmers *)

open Types
open Binary
open Syntax
open Format

type typ =
  | Num_type of num_type
  | Ref_type of binary heap_type
  | Any
  | Something

let pp_typ fmt = function
  | Num_type t -> pp_num_type fmt t
  | Ref_type t -> pp_heap_type fmt t
  | Any -> pp_string fmt "any"
  | Something -> pp_string fmt "something"

let pp_typ_list fmt l = pp_list ~pp_sep:pp_space pp_typ fmt l

let typ_of_val_type = function
  | Types.Ref_type (_null, t) -> Ref_type t
  | Num_type t -> Num_type t

let typ_of_pt pt = typ_of_val_type @@ snd pt

module Index = struct
  module M = Int
  module Map = Map.Make (Int)
  include M
end

module Env = struct
  type t =
    { locals : typ Index.Map.t
    ; mem : (mem, limits) Runtime.t Named.t
    ; globals : (global, binary global_type) Runtime.t Named.t
    ; result_type : binary result_type
    ; funcs : (binary func, binary block_type) Runtime.t Named.t
    ; blocks : typ list list
    ; tables : (binary table, binary table_type) Runtime.t Named.t
    ; elems : elem Named.t
    ; refs : (int, unit) Hashtbl.t
    }

  let local_get i env = match Index.Map.find i env.locals with v -> v

  let global_get i env =
    let value = Indexed.get_at_exn i env.globals.values in
    let _mut, typ =
      match value with Local { typ; _ } -> typ | Runtime.Imported t -> t.desc
    in
    typ

  let func_get i env =
    let value = Indexed.get_at_exn i env.funcs.values in
    match value with
    | Local { type_f; _ } ->
      let (Bt_raw ((None | Some _), t)) = type_f in
      t
    | Runtime.Imported t ->
      let (Bt_raw ((None | Some _), t)) = t.desc in
      t

  let block_type_get i env =
    match List.nth_opt env.blocks i with
    | None -> Error `Unknown_label
    | Some bt -> Ok bt

  let table_type_get_from_module i (modul : Binary.modul) =
    let value = Indexed.get_at_exn i modul.table.values in
    match value with
    | Local table -> snd (snd table)
    | Runtime.Imported t -> snd t.desc

  let table_type_get i env =
    let value = Indexed.get_at_exn i env.tables.values in
    match value with
    | Local table -> snd (snd table)
    | Runtime.Imported t -> snd t.desc

  let elem_type_get i env =
    let value = Indexed.get_at_exn i env.elems.values in
    value.typ

  let make ~params ~locals ~mem ~globals ~funcs ~result_type ~tables ~elems
    ~refs =
    let l = List.mapi (fun i v -> (i, v)) (params @ locals) in
    let locals =
      List.fold_left
        (fun locals (i, (_, typ)) ->
          let typ = typ_of_val_type typ in
          Index.Map.add i typ locals )
        Index.Map.empty l
    in
    { locals
    ; mem
    ; globals
    ; result_type
    ; funcs
    ; tables
    ; elems
    ; blocks = []
    ; refs
    }
end

type env = Env.t

type stack = typ list

let i32 = Num_type I32

let i64 = Num_type I64

let f32 = Num_type F32

let f64 = Num_type F64

let i31 = Ref_type I31_ht

let any = Any

let itype = function S32 -> i32 | S64 -> i64

let ftype = function S32 -> f32 | S64 -> f64

let arraytype _modul _i = (* TODO *) assert false

module Stack : sig
  type t = typ list

  val drop : t -> t Result.t

  val pop : t -> t -> t Result.t

  val push : t -> t -> t Result.t

  val pop_push : binary block_type -> t -> t Result.t

  val pop_ref : t -> t Result.t

  val equal : t -> t -> bool

  val match_ref_type : binary heap_type -> binary heap_type -> bool

  val match_types : typ -> typ -> bool

  val pp : formatter -> t -> unit

  val match_prefix : prefix:t -> stack:t -> t option
end = struct
  type t = typ list

  let pp fmt (s : stack) = pp fmt "[%a]" pp_typ_list s

  let match_num_type (required : num_type) (got : num_type) =
    match (required, got) with
    | I32, I32 -> true
    | I64, I64 -> true
    | F32, F32 -> true
    | F64, F64 -> true
    | _, _ -> false

  let match_ref_type required got =
    match (required, got) with
    | Any_ht, _ -> true
    | None_ht, None_ht -> true
    | Eq_ht, Eq_ht -> true
    | I31_ht, I31_ht -> true
    | Struct_ht, Struct_ht -> true
    | Array_ht, Array_ht -> true
    | No_func_ht, No_func_ht -> true
    | Func_ht, Func_ht -> true
    | Extern_ht, Extern_ht -> true
    | No_extern_ht, No_extern_ht -> true
    | _ ->
      (* TODO: complete this *)
      false

  let match_types required got =
    match (required, got) with
    | Something, _ | _, Something -> true
    | Any, _ | _, Any -> true
    | Num_type required, Num_type got -> match_num_type required got
    | Ref_type required, Ref_type got -> match_ref_type required got
    | Num_type _, Ref_type _ | Ref_type _, Num_type _ -> false

  let rec equal s s' =
    match (s, s') with
    | [], s | s, [] -> List.for_all (( = ) Any) s
    | Any :: tl, Any :: tl' -> equal tl s' || equal s tl'
    | Any :: tl, hd :: tl' | hd :: tl', Any :: tl ->
      equal tl (hd :: tl') || equal (Any :: tl) tl'
    | hd :: tl, hd' :: tl' -> match_types hd hd' && equal tl tl'

  let ( ||| ) l r = match (l, r) with None, v | v, None -> v | _l, r -> r

  let rec match_prefix ~prefix ~stack =
    match (prefix, stack) with
    | [], stack -> Some stack
    | _hd :: _tl, [] -> None
    | _hd :: tl, Any :: tl' ->
      match_prefix ~prefix ~stack:tl' ||| match_prefix ~prefix:tl ~stack
    | hd :: tl, hd' :: tl' ->
      if match_types hd hd' then match_prefix ~prefix:tl ~stack:tl' else None

  let pop required stack =
    match match_prefix ~prefix:required ~stack with
    | None -> Error (`Type_mismatch "pop")
    | Some stack -> Ok stack

  let pop_ref = function
    | (Something | Ref_type _) :: tl -> Ok tl
    | Any :: _ as stack -> Ok stack
    | _ -> Error (`Type_mismatch "pop_ref")

  let drop stack =
    match stack with
    | [] -> Error (`Type_mismatch "drop")
    | Any :: _ -> Ok [ Any ]
    | _ :: tl -> Ok tl

  let push t stack = ok @@ t @ stack

  let pop_push (Bt_raw ((None | Some _), (pt, rt))) stack =
    let pt, rt = (List.rev_map typ_of_pt pt, List.rev_map typ_of_val_type rt) in
    let* stack = pop pt stack in
    push rt stack
end

let rec typecheck_instr (env : env) (stack : stack) (instr : binary instr) :
  stack Result.t =
  let check_mem memarg_align align =
    if List.length env.mem.values < 1 then Error (`Unknown_memory 0)
    else if memarg_align >= align then Error `Alignment_too_large
    else Ok ()
  in
  match instr with
  | Nop -> Ok stack
  | Drop -> Stack.drop stack
  | Return ->
    let+ _stack =
      Stack.pop (List.rev_map typ_of_val_type env.result_type) stack
    in
    [ any ]
  | Unreachable -> Ok [ any ]
  | I32_const _ -> Stack.push [ i32 ] stack
  | I64_const _ -> Stack.push [ i64 ] stack
  | F32_const _ -> Stack.push [ f32 ] stack
  | F64_const _ -> Stack.push [ f64 ] stack
  | I_unop (s, _op) ->
    let t = itype s in
    let* stack = Stack.pop [ t ] stack in
    Stack.push [ t ] stack
  | I_binop (s, _op) ->
    let t = itype s in
    let* stack = Stack.pop [ t; t ] stack in
    Stack.push [ t ] stack
  | F_unop (s, _op) ->
    let t = ftype s in
    let* stack = Stack.pop [ t ] stack in
    Stack.push [ t ] stack
  | F_binop (s, _op) ->
    let t = ftype s in
    let* stack = Stack.pop [ t; t ] stack in
    Stack.push [ t ] stack
  | I_testop (nn, _) ->
    let* stack = Stack.pop [ itype nn ] stack in
    Stack.push [ i32 ] stack
  | I_relop (nn, _) ->
    let t = itype nn in
    let* stack = Stack.pop [ t; t ] stack in
    Stack.push [ i32 ] stack
  | F_relop (nn, _) ->
    let t = ftype nn in
    let* stack = Stack.pop [ t; t ] stack in
    Stack.push [ i32 ] stack
  | Local_get (Raw i) -> Stack.push [ Env.local_get i env ] stack
  | Local_set (Raw i) ->
    let t = Env.local_get i env in
    Stack.pop [ t ] stack
  | Local_tee (Raw i) ->
    let t = Env.local_get i env in
    let* stack = Stack.pop [ t ] stack in
    Stack.push [ t ] stack
  | Global_get (Raw i) ->
    Stack.push [ typ_of_val_type @@ Env.global_get i env ] stack
  | Global_set (Raw i) ->
    let t = Env.global_get i env in
    Stack.pop [ typ_of_val_type t ] stack
  | If_else (_id, block_type, e1, e2) ->
    let* stack = Stack.pop [ i32 ] stack in
    let* stack_e1 = typecheck_expr env e1 ~is_loop:false block_type ~stack in
    let+ _stack_e2 = typecheck_expr env e2 ~is_loop:false block_type ~stack in
    stack_e1
  | I_load8 (nn, _, memarg) ->
    let* () = check_mem memarg.align 1l in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ itype nn ] stack
  | I_load16 (nn, _, memarg) ->
    let* () = check_mem memarg.align 2l in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ itype nn ] stack
  | I_load (nn, memarg) ->
    let max_allowed = match nn with S32 -> 4l | S64 -> 8l in
    let* () = check_mem memarg.align max_allowed in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ itype nn ] stack
  | I64_load32 (_, memarg) ->
    let* () = check_mem memarg.align 4l in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ i64 ] stack
  | I_store8 (nn, memarg) ->
    let* () = check_mem memarg.align 1l in
    Stack.pop [ itype nn; i32 ] stack
  | I_store16 (nn, memarg) ->
    let* () = check_mem memarg.align 2l in
    Stack.pop [ itype nn; i32 ] stack
  | I_store (nn, memarg) ->
    let max_allowed = match nn with S32 -> 4l | S64 -> 8l in
    let* () = check_mem memarg.align max_allowed in
    Stack.pop [ itype nn; i32 ] stack
  | I64_store32 memarg ->
    let* () = check_mem memarg.align 4l in
    Stack.pop [ i64; i32 ] stack
  | F_load (nn, memarg) ->
    let max_allowed = match nn with S32 -> 4l | S64 -> 8l in
    let* () = check_mem memarg.align max_allowed in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ ftype nn ] stack
  | F_store (nn, memarg) ->
    let max_allowed = match nn with S32 -> 4l | S64 -> 8l in
    let* () = check_mem memarg.align max_allowed in
    Stack.pop [ ftype nn; i32 ] stack
  | I_reinterpret_f (inn, fnn) ->
    let* stack = Stack.pop [ ftype fnn ] stack in
    Stack.push [ itype inn ] stack
  | F_reinterpret_i (fnn, inn) ->
    let* stack = Stack.pop [ itype inn ] stack in
    Stack.push [ ftype fnn ] stack
  | F32_demote_f64 ->
    let* stack = Stack.pop [ f64 ] stack in
    Stack.push [ f32 ] stack
  | F64_promote_f32 ->
    let* stack = Stack.pop [ f32 ] stack in
    Stack.push [ f64 ] stack
  | F_convert_i (fnn, inn, _) ->
    let* stack = Stack.pop [ itype inn ] stack in
    Stack.push [ ftype fnn ] stack
  | I_trunc_f (inn, fnn, _) | I_trunc_sat_f (inn, fnn, _) ->
    let* stack = Stack.pop [ ftype fnn ] stack in
    Stack.push [ itype inn ] stack
  | I32_wrap_i64 ->
    let* stack = Stack.pop [ i64 ] stack in
    Stack.push [ i32 ] stack
  | I_extend8_s nn | I_extend16_s nn ->
    let t = itype nn in
    let* stack = Stack.pop [ t ] stack in
    Stack.push [ t ] stack
  | I64_extend32_s ->
    let* stack = Stack.pop [ i64 ] stack in
    Stack.push [ i64 ] stack
  | I64_extend_i32 _ ->
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ i64 ] stack
  | Memory_grow ->
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ i32 ] stack
  | Memory_size -> Stack.push [ i32 ] stack
  | Memory_copy | Memory_init _ | Memory_fill ->
    Stack.pop [ i32; i32; i32 ] stack
  | Block (_, bt, expr) -> typecheck_expr env expr ~is_loop:false bt ~stack
  | Loop (_, bt, expr) -> typecheck_expr env expr ~is_loop:true bt ~stack
  | Call_indirect (_, bt) ->
    let* stack = Stack.pop [ i32 ] stack in
    Stack.pop_push bt stack
  | Call (Raw i) ->
    let pt, rt = Env.func_get i env in
    let* stack = Stack.pop (List.rev_map typ_of_pt pt) stack in
    Stack.push (List.rev_map typ_of_val_type rt) stack
  | Call_ref _t ->
    let+ stack = Stack.pop_ref stack in
    (* TODO:
       let bt = Env.type_get t env in
         Stack.pop_push (Some bt) stack
    *)
    stack
  | Return_call (Raw i) ->
    let pt, rt = Env.func_get i env in
    if
      not
        (Stack.equal
           (List.rev_map typ_of_val_type rt)
           (List.rev_map typ_of_val_type env.result_type) )
    then Error (`Type_mismatch "return_call")
    else
      let+ _stack = Stack.pop (List.rev_map typ_of_pt pt) stack in
      [ any ]
  | Return_call_indirect (_, Bt_raw ((None | Some _), (pt, rt))) ->
    if
      not
        (Stack.equal
           (List.rev_map typ_of_val_type rt)
           (List.rev_map typ_of_val_type env.result_type) )
    then Error (`Type_mismatch "return_call_indirect")
    else
      let* stack = Stack.pop [ i32 ] stack in
      let+ _stack = Stack.pop (List.rev_map typ_of_pt pt) stack in
      [ any ]
  | Return_call_ref (Bt_raw ((None | Some _), (pt, rt))) ->
    if
      not
        (Stack.equal
           (List.rev_map typ_of_val_type rt)
           (List.rev_map typ_of_val_type env.result_type) )
    then Error (`Type_mismatch "return_call_ref")
    else
      let* stack = Stack.pop_ref stack in
      let+ _stack = Stack.pop (List.rev_map typ_of_pt pt) stack in
      [ any ]
  | Data_drop _i -> Ok stack
  | Table_init (Raw ti, Raw ei) ->
    let table_typ = Env.table_type_get ti env in
    let elem_typ = Env.elem_type_get ei env in
    if not @@ Stack.match_ref_type (snd table_typ) (snd elem_typ) then
      Error (`Type_mismatch "table_init")
    else Stack.pop [ i32; i32; i32 ] stack
  | Table_copy (Raw i, Raw i') ->
    let typ = Env.table_type_get i env in
    let typ' = Env.table_type_get i' env in
    if typ <> typ' then Error (`Type_mismatch "table_copy")
    else Stack.pop [ i32; i32; i32 ] stack
  | Table_fill (Raw i) ->
    let _null, t = Env.table_type_get i env in
    Stack.pop [ i32; Ref_type t; i32 ] stack
  | Table_grow (Raw i) ->
    let _null, t = Env.table_type_get i env in
    let* stack = Stack.pop [ i32; Ref_type t ] stack in
    Stack.push [ i32 ] stack
  | Table_size _ -> Stack.push [ i32 ] stack
  | Ref_is_null ->
    let* stack = Stack.pop_ref stack in
    Stack.push [ i32 ] stack
  | Ref_null rt -> Stack.push [ Ref_type rt ] stack
  | Elem_drop _ -> Ok stack
  | Select t ->
    let* stack = Stack.pop [ i32 ] stack in
    begin
      match t with
      | None -> begin
        match stack with
        | Ref_type _ :: _tl -> Error (`Type_mismatch "select implicit")
        | Any :: _ -> Ok [ Something; Any ]
        | hd :: Any :: _ -> ok @@ (hd :: [ Any ])
        | hd :: hd' :: tl when Stack.match_types hd hd' -> ok @@ (hd :: tl)
        | _ -> Error (`Type_mismatch "select")
      end
      | Some t ->
        let t = List.map typ_of_val_type t in
        let* stack = Stack.pop t stack in
        let* stack = Stack.pop t stack in
        Stack.push t stack
    end
  | Ref_func (Raw i) ->
    if not @@ Hashtbl.mem env.refs i then Error `Undeclared_function_reference
    else Stack.push [ Ref_type Func_ht ] stack
  | Br (Raw i) ->
    let* jt = Env.block_type_get i env in
    let* _stack = Stack.pop jt stack in
    Ok [ any ]
  | Br_if (Raw i) ->
    let* stack = Stack.pop [ i32 ] stack in
    let* jt = Env.block_type_get i env in
    let* stack = Stack.pop jt stack in
    Stack.push jt stack
  | Br_table (branches, Raw i) ->
    let* stack = Stack.pop [ i32 ] stack in
    let* default_jt = Env.block_type_get i env in
    let* _stack = Stack.pop default_jt stack in
    let* () =
      array_iter
        (fun (Raw i : binary indice) ->
          let* jt = Env.block_type_get i env in
          if not (List.length jt = List.length default_jt) then
            Error (`Type_mismatch "br_table")
          else
            let* _stack = Stack.pop jt stack in
            Ok () )
        branches
    in
    Ok [ any ]
  | Table_get (Raw i) ->
    let _null, t = Env.table_type_get i env in
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ Ref_type t ] stack
  | Table_set (Raw i) ->
    let _null, t = Env.table_type_get i env in
    Stack.pop [ Ref_type t; i32 ] stack
  | Array_len ->
    (* TODO: fixme, Something is not right *)
    let* stack = Stack.pop [ Something ] stack in
    Stack.push [ i32 ] stack
  | Ref_i31 ->
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ i31 ] stack
  | I31_get_s | I31_get_u ->
    let* stack = Stack.pop [ i31 ] stack in
    Stack.push [ i32 ] stack
  | ( Array_new_data _ | Array_new _ | Array_new_default _ | Array_new_elem _
    | Array_new_fixed _ | Array_get _ | Array_get_u _ | Array_set _
    | Struct_get _ | Struct_get_s _ | Struct_set _ | Struct_new _
    | Struct_new_default _ | Extern_externalize | Extern_internalize
    | Ref_as_non_null | Ref_cast _ | Ref_test _ | Br_on_non_null _
    | Br_on_null _ | Br_on_cast _ | Br_on_cast_fail _ | Ref_eq ) as i ->
    Log.debug2 "TODO (typecheck instr) %a" pp_instr i;
    assert false

and typecheck_expr env expr ~is_loop (block_type : binary block_type option)
  ~stack:previous_stack : stack Result.t =
  let pt, rt =
    Option.fold ~none:([], [])
      ~some:(fun (Bt_raw ((None | Some _), (pt, rt)) : binary block_type) ->
        (List.rev_map typ_of_pt pt, List.rev_map typ_of_val_type rt) )
      block_type
  in
  let jump_type = if is_loop then pt else rt in
  let env = { env with blocks = jump_type :: env.blocks } in
  let* stack = list_fold_left (typecheck_instr env) pt expr in
  if not (Stack.equal rt stack) then Error (`Type_mismatch "typecheck_expr 1")
  else
    match Stack.match_prefix ~prefix:pt ~stack:previous_stack with
    | None ->
      Error
        (`Type_mismatch
          (Format.asprintf "expected a prefix of %a but stack has type %a"
             Stack.pp pt Stack.pp previous_stack ) )
    | Some stack_to_push -> Stack.push rt stack_to_push

let typecheck_function (modul : modul) func refs =
  match func with
  | Runtime.Imported _ -> Ok ()
  | Local func ->
    let (Bt_raw ((None | Some _), (params, result))) = func.type_f in
    let env =
      Env.make ~params ~funcs:modul.func ~locals:func.locals ~mem:modul.mem
        ~globals:modul.global ~result_type:result ~tables:modul.table
        ~elems:modul.elem ~refs
    in
    let* stack =
      typecheck_expr env func.body ~is_loop:false
        (Some (Bt_raw (None, ([], result))))
        ~stack:[]
    in
    let required = List.rev_map typ_of_val_type result in
    if not @@ Stack.equal required stack then
      Error (`Type_mismatch "typecheck_function")
    else Ok ()

let typecheck_const_instr (modul : modul) refs stack = function
  | I32_const _ -> Stack.push [ i32 ] stack
  | I64_const _ -> Stack.push [ i64 ] stack
  | F32_const _ -> Stack.push [ f32 ] stack
  | F64_const _ -> Stack.push [ f64 ] stack
  | Ref_null t -> Stack.push [ Ref_type t ] stack
  | Ref_func (Raw i) ->
    Hashtbl.add refs i ();
    Stack.push [ Ref_type Func_ht ] stack
  | Global_get (Raw i) ->
    let value = Indexed.get_at_exn i modul.global.values in
    let* _mut, typ =
      match value with
      | Local _ -> Error `Unknown_global
      | Imported t -> Ok t.desc
    in
    Stack.push [ typ_of_val_type typ ] stack
  | I_binop (t, _op) ->
    let t = itype t in
    let* stack = Stack.pop [ t; t ] stack in
    Stack.push [ t ] stack
  | Array_new t ->
    let t = arraytype modul t in
    let* stack = Stack.pop [ i32; t ] stack in
    Stack.push [ Ref_type Array_ht ] stack
  | Array_new_default _i -> assert false
  | Ref_i31 ->
    let* stack = Stack.pop [ i32 ] stack in
    Stack.push [ i31 ] stack
  | _ -> assert false

let typecheck_const_expr (modul : modul) refs =
  list_fold_left (typecheck_const_instr modul refs) []

let typecheck_global (modul : modul) refs
  (global : (global, binary global_type) Runtime.t Indexed.t) =
  match Indexed.get global with
  | Imported _ -> Ok ()
  | Local { typ; init; _ } -> (
    let* real_type = typecheck_const_expr modul refs init in
    match real_type with
    | [ real_type ] ->
      let expected = typ_of_val_type @@ snd typ in
      if expected <> real_type then Error (`Type_mismatch "typecheck global 1")
      else Ok ()
    | _whatever -> Error (`Type_mismatch "typecheck_global 2") )

let typecheck_elem modul refs (elem : elem Indexed.t) =
  let elem = Indexed.get elem in
  let _null, expected_type = elem.typ in
  let* () =
    list_iter
      (fun init ->
        let* real_type = typecheck_const_expr modul refs init in
        match real_type with
        | [ real_type ] ->
          if Ref_type expected_type <> real_type then
            Error (`Type_mismatch "typecheck_elem 1")
          else Ok ()
        | _whatever -> Error (`Type_mismatch "typecheck elem 2") )
      elem.init
  in
  match elem.mode with
  | Elem_passive | Elem_declarative -> Ok ()
  | Elem_active (None, _e) -> assert false
  | Elem_active (Some tbl_i, e) -> (
    let _null, tbl_type = Env.table_type_get_from_module tbl_i modul in
    if tbl_type <> expected_type then Error (`Type_mismatch "typecheck elem 3")
    else
      let* t = typecheck_const_expr modul refs e in
      match t with
      | [ Ref_type t ] ->
        if t <> tbl_type then Error (`Type_mismatch "typecheck_elem 4")
        else Ok ()
      | [ _t ] -> Ok ()
      | _whatever -> Error (`Type_mismatch "typecheck_elem 5") )

let typecheck_data modul refs (data : data Indexed.t) =
  let data = Indexed.get data in
  match data.mode with
  | Data_passive -> Ok ()
  | Data_active (_i, e) -> (
    let* t = typecheck_const_expr modul refs e in
    match t with
    | [ _t ] -> Ok ()
    | _whatever -> Error (`Type_mismatch "typecheck_data") )

let modul (modul : modul) =
  Log.debug0 "typechecking ...@\n";
  let refs = Hashtbl.create 512 in
  let* () = list_iter (typecheck_global modul refs) modul.global.values in
  let* () = list_iter (typecheck_elem modul refs) modul.elem.values in
  let* () = list_iter (typecheck_data modul refs) modul.data.values in
  List.iter
    (fun (export : export) -> Hashtbl.add refs export.id ())
    modul.exports.func;
  Named.fold
    (fun _index func acc ->
      let* () = acc in
      typecheck_function modul func refs )
    modul.func (Ok ())
