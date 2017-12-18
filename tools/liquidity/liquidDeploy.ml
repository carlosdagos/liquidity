(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017 - OCamlPro SAS                                   *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open LiquidTypes


module Network = struct
  open Curl
  let writer_callback a d =
    Buffer.add_string a d;
    String.length d

  let initialize_connection host path =
    let url = Printf.sprintf "%s%s" host path in
    let r = Buffer.create 16384
    and c = Curl.init () in
    Curl.set_timeout c 30;      (* Timeout *)
    Curl.set_sslverifypeer c false;
    Curl.set_sslverifyhost c Curl.SSLVERIFYHOST_EXISTENCE;
    Curl.set_writefunction c (writer_callback r);
    Curl.set_tcpnodelay c true;
    Curl.set_verbose c false;
    Curl.set_post c false;
    Curl.set_url c url; r,c

  let post ?(content_type = "application/json") host path data =
    let r, c = initialize_connection host path in
    Curl.set_post c true;
    Curl.set_httpheader c [ "Content-Type: " ^ content_type ];
    Curl.set_postfields c data;
    Curl.set_postfieldsize c (String.length data);
    Curl.perform c;
    let rc = Curl.get_responsecode c in
    Curl.cleanup c;
    rc, (Buffer.contents r)
end


exception RequestError of string

let request ?(data="{}") path =
  let host = !LiquidOptions.tezos_node in
  if !LiquidOptions.verbosity > 0 then
    Printf.eprintf "\nRequest to %s%s:\n--------------\n%s\n%!"
      host path
      (* data; *)
      (Ezjsonm.to_string ~minify:false (Ezjsonm.from_string data));
  try
    let (status, json) = Network.post host path data in
    if status <> 200 then
      raise (RequestError (
          Printf.sprintf "'%d' : curl failure %s%s" status host path)) ;
    if !LiquidOptions.verbosity > 0 then
      Printf.eprintf "\nNode Response %d:\n------------------\n%s\n%!"
        status
        (Ezjsonm.to_string ~minify:false (Ezjsonm.from_string json));
    json
  with Curl.CurlException (code, i, s) (* as exn *) ->
    raise (RequestError
             (Printf.sprintf "[%d] [%s] Curl exception: %s\n%!"
                i host s))
    (* raise exn *)


type from =
  | From_string of string
  | From_file of string

let compile_liquid liquid =
  let ocaml_ast = match liquid with
    | From_string s -> LiquidFromOCaml.structure_of_string s
    | From_file f -> LiquidFromOCaml.read_file f
  in
  let syntax_ast, syntax_init, env =
    LiquidFromOCaml.translate "buffer" ocaml_ast in
  let typed_ast = LiquidCheck.typecheck_contract
      ~warnings:true env syntax_ast in
  let encoded_ast, to_inline =
    LiquidEncode.encode_contract ~annot:!LiquidOptions.annotmic env typed_ast in
  let live_ast = LiquidSimplify.simplify_contract encoded_ast to_inline in
  let pre_michelson = LiquidMichelson.translate live_ast in
  let pre_michelson =
    if !LiquidOptions.peephole then
      LiquidPeephole.simplify pre_michelson
    else
      pre_michelson
  in
  let pre_init = match syntax_init with
    | None -> None
    | Some syntax_init ->
      let inputs_infos = fst syntax_init in
      Some (
        LiquidInit.compile_liquid_init env syntax_ast syntax_init,
        inputs_infos)
  in

  ( env, syntax_ast, pre_michelson, pre_init )

let raise_request_error r msg =
  try
    let err = Ezjsonm.find r ["error"] in
    (* let err_s = Ezjsonm.to_string ~minify:false (Data_encoding_ezjsonm.to_root err) in *)
    let l = Ezjsonm.get_list (fun err ->
        let kind = Ezjsonm.find err ["kind"] in
        let id = Ezjsonm.find err ["id"] in
        (* let err_s = Ezjsonm.to_string ~minify:false (Data_encoding_ezjsonm.to_root err) in *)
        Data_encoding_ezjsonm.to_string kind ^" : "^
        Data_encoding_ezjsonm.to_string id
      ) err in
    let err_s = "In "^msg^", "^ String.concat "\n" l in
    raise (RequestError err_s)
  with Not_found ->
    raise (RequestError ("Bad response for "^msg))


let mk_json_obj fields =
  fields
  |> List.map (fun (f,v) -> "\"" ^ f ^ "\":" ^ v)
  |> String.concat ","
  |> fun fs -> "{" ^ fs ^ "}"

let mk_json_arr l = "[" ^ String.concat "," l ^ "]"


let run_pre env syntax_contract pre_michelson input storage =
  let c = LiquidToTezos.convert_contract ~expand:true pre_michelson in
  let input_m = LiquidToTezos.convert_const input in
  let storage_m = LiquidToTezos.convert_const storage in
  let contract_json = LiquidToTezos.json_of_contract c in
  let input_json = LiquidToTezos.json_of_const input_m in
  let storage_json = LiquidToTezos.json_of_const storage_m in
  let run_fields = [
      "script", contract_json;
      "input", input_json;
      "storage", storage_json;
      "amount", !LiquidOptions.amount;
  ] @ (match !LiquidOptions.source with
      | None -> []
      | Some source -> ["contract", Printf.sprintf "%S" source]
    )
  in
  let run_json = mk_json_obj run_fields in
  let r =
    request ~data:run_json "/blocks/prevalidation/proto/helpers/run_code"
    |> Ezjsonm.from_string
  in
  try
    let storage_r = Ezjsonm.find r ["ok"; "storage"] in
    let result_r = Ezjsonm.find r ["ok"; "output"] in
    let storage_expr = LiquidToTezos.const_of_ezjson storage_r in
    let result_expr = LiquidToTezos.const_of_ezjson result_r in
    let env = LiquidTezosTypes.empty_env env.filename in
    let storage =
      LiquidFromTezos.convert_const_type env storage_expr
        syntax_contract.storage
    in
    let result =
      LiquidFromTezos.convert_const_type env result_expr syntax_contract.return
    in
    (result, storage)
  with Not_found ->
    raise_request_error r "run"


let run liquid input_string storage_string =
  let env, syntax_ast, pre_michelson, _ = compile_liquid liquid in
  let input =
    LiquidData.translate { env with filename = "input" }
      syntax_ast input_string pre_michelson.parameter
  in
  let storage =
    LiquidData.translate { env with filename = "storage" }
      syntax_ast storage_string pre_michelson.storage
  in
  run_pre env syntax_ast pre_michelson input storage


let get_counter source =
  let r =
    request
      (Printf.sprintf "/blocks/prevalidation/proto/context/contracts/%s/counter"
         source)
    |> Ezjsonm.from_string
  in
  try
    Ezjsonm.find r ["ok"] |> Ezjsonm.get_int
  with Not_found ->
    raise_request_error r "get_counter"


let get_head_hash () =
  let r = request "/blocks/head" |> Ezjsonm.from_string in
  try
    Ezjsonm.find r ["hash"] |> Ezjsonm.get_string
  with Not_found ->
    raise_request_error r "get_head_hash"

type head = {
  head_hash : string;
  head_netId : string;
}

let get_head () =
  let r = request "/blocks/head" |> Ezjsonm.from_string in
  try
    let head_hash = Ezjsonm.find r ["hash"] |> Ezjsonm.get_string in
    let head_netId = Ezjsonm.find r ["net_id"] |> Ezjsonm.get_string in
    { head_hash; head_netId }
  with Not_found ->
    raise_request_error r "get_head"

let get_predecessor () =
  let r = request "/blocks/prevalidation/predecessor" |> Ezjsonm.from_string in
  try
    Ezjsonm.find r ["predecessor"] |> Ezjsonm.get_string
  with Not_found ->
    raise_request_error r "get_predecessor"


let forge_deploy ?head ?source liquid init_params_strings =
  let source = match source, !LiquidOptions.source with
    | Some source, _ | _, Some source -> source
    | None, None -> raise (RequestError "get_counter: Missing source")
  in
  let env, syntax_ast, pre_michelson, pre_init_infos = compile_liquid liquid in
  let pre_init, init_infos = match pre_init_infos with
    | None -> raise (RequestError "forge_deploy: Missing init")
    | Some pre_init_infos -> pre_init_infos
  in
  let init_storage = match pre_init with
    | LiquidInit.Init_constant c ->
      if init_params_strings <> [] then
        raise (RequestError "forge_deploy: Constant storage, no inputs needed");
      c
    | LiquidInit.Init_code (syntax_c, c) ->
      let init_params =
        try
          List.map2 (fun input_str (input_name,_, input_ty) ->
            LiquidData.translate { env with filename = input_name }
              syntax_ast input_str input_ty
            ) init_params_strings init_infos
        with Invalid_argument _ ->
          raise
            (RequestError
               (Printf.sprintf
                  "forge_deploy: init storage needs %d arguments, but was given %d"
                  (List.length init_infos) (List.length init_params_strings)
               ))
      in
      let eval_init_storage = CUnit in
      let eval_init_input = CTuple init_params in
      let eval_init_result, _ =
        run_pre env syntax_c c eval_init_input eval_init_storage
      in
      Printf.eprintf "Evaluated initial storage:\n\
                      --------------------------\n\
                      %s\n%!"
        (LiquidPrinter.Liquid.string_of_const eval_init_result);
      LiquidEncode.encode_const env syntax_ast eval_init_result
  in

  let head = match head with
    | Some head -> head
    | None -> get_head_hash ()
  in
  let counter = get_counter source + 1 in
  let c = LiquidToTezos.convert_contract ~expand:true pre_michelson in
  let init_storage_m = LiquidToTezos.convert_const init_storage in
  let contract_json = LiquidToTezos.json_of_contract c in
  let init_storage_json = LiquidToTezos.json_of_const init_storage_m in

  let script_json = [
    "code", contract_json;
    "storage", init_storage_json
  ] |> mk_json_obj
  in
  let origination_json = [
    "kind", "\"origination\"";
    "managerPubkey", Printf.sprintf "%S" source;
    "balance", !LiquidOptions.amount;
    "spendable", "false";
    "delegatable", "false";
    "script", script_json;
  ] |> mk_json_obj
  in
  let data = [
    "branch", Printf.sprintf "%S" head;
    "source", Printf.sprintf "%S" source;
    "fee", !LiquidOptions.fee;
    "counter", string_of_int counter;
    "operations", mk_json_arr [origination_json];
  ] |> mk_json_obj
  in
  let r =
    request ~data "/blocks/prevalidation/proto/helpers/forge/operations"
    |> Ezjsonm.from_string
  in
  try
    Ezjsonm.find r ["ok"; "operation"] |> Ezjsonm.get_string
  with Not_found ->
    raise_request_error r "forge_deploy"


let deploy liquid init_params_strings =
  let sk = match !LiquidOptions.private_key with
    | None -> raise (RequestError "deploy: Missing private key")
    | Some sk -> match Ed25519.Secret_key.of_b58check sk with
      | Ok sk -> sk
      | Error _ -> raise (RequestError "deploy: Bad private key")
  in
  let head = get_head () in
  let pred = get_predecessor () in
  let op =
    forge_deploy ~head:head.head_hash liquid init_params_strings
  in
  let op_b = MBytes.of_string (Hex_encode.hex_decode op) in
  let signature_b = Ed25519.sign sk op_b in
  let signature = Ed25519.Signature.to_b58check signature_b in
  let signed_op_b = MBytes.concat op_b signature_b in
  let signed_op = Hex_encode.hex_encode (MBytes.to_string signed_op_b) in
  let op_hash = Hash.Operation_hash.to_b58check @@
    Hash.Operation_hash.hash_bytes [ signed_op_b ] in

  let contract_id =
    let data = [
      "pred_block", Printf.sprintf "%S" pred;
      "operation_hash", Printf.sprintf "%S" op_hash;
      "forged_operation", Printf.sprintf "%S" op;
      "signature", Printf.sprintf "%S" signature;
    ] |> mk_json_obj
    in
    let r =
      request ~data "/blocks/prevalidation/proto/helpers/apply_operation"
      |> Ezjsonm.from_string
    in
    try
      Ezjsonm.find r ["ok"; "contracts"] |> Ezjsonm.get_list Ezjsonm.get_string
      |> function [c] -> c | _ -> raise Not_found
    with Not_found ->
      raise_request_error r "deploy (apply_operation)"
  in

  let injected_op_hash =
    let data = [
      "signedOperationContents", Printf.sprintf "%S" signed_op;
      "net_id", Printf.sprintf "%S" head.head_netId;
      "force", "true";
    ] |> mk_json_obj
    in
    let r =
      request ~data "/inject_operation"
      |> Ezjsonm.from_string
    in
    try
      Ezjsonm.find r ["ok"; "injectedOperation"] |> Ezjsonm.get_string
    with Not_found ->
      raise_request_error r "deploy (inject_operation)"
  in
  assert (injected_op_hash = op_hash);

  (injected_op_hash, contract_id)


(* Withoud optional argument head *)
let forge_deploy liquid init_params_strings =
  forge_deploy liquid init_params_strings