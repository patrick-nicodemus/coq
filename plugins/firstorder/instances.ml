(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Unify
open Rules
open CErrors
open Util
open EConstr
open Vars
open Tacmach
open Tactics
open Tacticals
open Proofview.Notations
open Reductionops
open Formula
open Sequent
open Names
open Context.Rel.Declaration

let compare_instance inst1 inst2=
        let cmp c1 c2 = Constr.compare (EConstr.Unsafe.to_constr c1) (EConstr.Unsafe.to_constr c2) in
        match inst1,inst2 with
            Phantom(d1),Phantom(d2)->
              (cmp d1 d2)
          | Real(i1, n1), Real(i2, n2)->
            let (m1, c1) = Unify.Item.repr i1 in
            let (m2, c2) = Unify.Item.repr i2 in
              ((-) =? (-) ==? cmp) m2 m1 n1 n2 c1 c2
          | Phantom _, Real (i, _)-> if Unify.Item.is_ground i then -1 else 1
          | Real (i, _), Phantom _ -> if Unify.Item.is_ground i then 1 else -1

let compare_gr id1 id2 = match id1, id2 with
| GoalId, GoalId -> 0
| GoalId, FormulaId _ -> 1
| FormulaId _, GoalId -> -1
| FormulaId id1, FormulaId id2 -> GlobRef.CanOrd.compare id1 id2

module OrderedInstance=
struct
  type t = Unify.instance * identifier
  let compare (inst1,id1) (inst2,id2)=
    (compare_instance =? compare_gr) inst2 inst1 id2 id1
    (* we want a __decreasing__ total order *)
end

module IS=Set.Make(OrderedInstance)

let make_simple_atoms seq=
  let ratoms=
    match seq.gl with
    | GoalAtom t -> [t]
    | GoalTerm _ -> []
  in {negative=seq.latoms;positive=ratoms}

let do_sequent env sigma setref triv id seq i dom atoms=
  let flag=ref true in
  let phref=ref triv in
  let do_atoms a1 a2 =
    let do_pair t1 t2 =
      match unif_atoms env sigma i dom t1 t2 with
          None->()
        | Some (Phantom _) ->phref:=true
        | Some c ->flag:=false;setref:=IS.add (c,id) !setref in
      List.iter (fun t->List.iter (do_pair t) a2.negative) a1.positive;
      List.iter (fun t->List.iter (do_pair t) a2.positive) a1.negative in
    HP.iter (fun lf->do_atoms atoms lf.atoms) seq.redexes;
    do_atoms atoms (make_simple_atoms seq);
    !flag && !phref

let match_one_quantified_hyp env sigma setref seq lf=
  match lf.pat with
      Left(Lforall(i,dom,triv))|Right(Rexists(i,dom,triv))->
        if do_sequent env sigma setref triv lf.id seq i dom lf.atoms then
          setref:=IS.add ((Phantom dom),lf.id) !setref
    | _ -> anomaly (Pp.str "can't happen.")

let give_instances env sigma lf seq=
  let setref=ref IS.empty in
    List.iter (match_one_quantified_hyp env sigma setref seq) lf;
    IS.elements !setref

(* collector for the engine *)

let rec collect_quantified sigma seq=
  try
    let hd,seq1=take_formula sigma seq in
      (match hd.pat with
           Left(Lforall(_,_,_)) | Right(Rexists(_,_,_)) ->
             let (q,seq2)=collect_quantified sigma seq1 in
               ((hd::q),seq2)
         | _->[],seq)
  with Heap.EmptyHeap -> [],seq

(* open instances processor *)

let dummy_bvid=Id.of_string "x"

let mk_open_instance env sigma id idc c =
  let (m, t) = Item.repr c in
  let var_id =
      let typ = Retyping.get_type_of env sigma idc in
        (* since we know we will get a product,
           reduction is not too expensive *)
      let (nam,_,_) = destProd sigma (whd_all env sigma typ) in
        match nam.Context.binder_name with
        | Name id -> id
        | Anonymous ->  dummy_bvid
  in
  let revt = substl (List.init m (fun i->mkRel (m-i))) t in
  let rec aux n avoid env sigma decls =
    if Int.equal n 0 then sigma, decls else
      let nid = fresh_id_in_env avoid var_id env in
      let (sigma, (c, _)) = Evarutil.new_type_evar env sigma Evd.univ_flexible in
      let decl = LocalAssum (Context.make_annot (Name nid) Sorts.Relevant, c) in
      aux (n-1) (Id.Set.add nid avoid) (EConstr.push_rel decl env) sigma (decl::decls)
  in
  let sigma, decls = aux m Id.Set.empty env sigma [] in
  (sigma, decls, revt)

(* tactics   *)

let left_instance_tac ~flags (inst,id) continue seq=
  let open EConstr in
  Proofview.Goal.enter begin fun gl ->
  let sigma = project gl in
  let env = Proofview.Goal.env gl in
  match inst with
      Phantom dom->
        if lookup env sigma (id,None) seq then
          tclFAIL (Pp.str "already done")
        else
          tclTHENS (cut dom)
            [tclTHENLIST
               [introf;
                (pf_constr_of_global id >>= fun idc ->
                Proofview.Goal.enter begin fun gl ->
                  let id0 = List.nth (pf_ids_of_hyps gl) 0 in
                  generalize [mkApp(idc, [|mkVar id0|])]
                end);
                introf;
                tclSOLVE [wrap ~flags 1 false continue
                            (deepen (record (id,None) seq))]];
            tclTRY assumption]
    | Real (c, _)->
        if lookup env sigma (id,Some c) seq then
          tclFAIL (Pp.str "already done")
        else
          let special_generalize=
            if not @@ Unify.Item.is_ground c then
              (pf_constr_of_global id >>= fun idc ->
                Proofview.Goal.enter begin fun gl->
                  let (evmap, rc, ot) = mk_open_instance (pf_env gl) (project gl) id idc c in
                  let gt=
                    it_mkLambda_or_LetIn
                      (mkApp(idc,[|ot|])) rc in
                  let evmap, _ =
                    try Typing.type_of (pf_env gl) evmap gt
                    with e when CErrors.noncritical e ->
                      user_err Pp.(str "Untypable instance, maybe higher-order non-prenex quantification") in
                  Proofview.tclTHEN (Proofview.Unsafe.tclEVARS evmap)
                    (generalize [gt])
                end)
            else
              pf_constr_of_global id >>= fun idc -> generalize [mkApp(idc,[|snd @@ Item.repr c|])]
          in
            tclTHENLIST
              [special_generalize;
               introf;
               tclSOLVE
                 [wrap ~flags 1 false continue (deepen (record (id,Some c) seq))]]
  end

let right_instance_tac ~flags inst continue seq=
  let open EConstr in
  Proofview.Goal.enter begin fun gl ->
  match inst with
      Phantom dom ->
        tclTHENS (cut dom)
        [tclTHENLIST
           [introf;
            Proofview.Goal.enter begin fun gl ->
              let id0 = List.nth (pf_ids_of_hyps gl) 0 in
              split (Tactypes.ImplicitBindings [mkVar id0])
            end;
            tclSOLVE [wrap ~flags 0 true continue (deepen seq)]];
         tclTRY assumption]
    | Real (c,_) ->
      if Item.is_ground c then
        (tclTHEN (split (Tactypes.ImplicitBindings [snd @@ Item.repr c]))
           (tclSOLVE [wrap ~flags 0 true continue (deepen seq)]))
      else
        tclFAIL (Pp.str "not implemented ... yet")
  end

let instance_tac ~flags (hd, id) = match id with
| GoalId -> right_instance_tac ~flags hd
| FormulaId id -> left_instance_tac ~flags (hd, id)

let quantified_tac ~flags lf backtrack continue seq =
  Proofview.Goal.enter begin fun gl ->
  let env = Proofview.Goal.env gl in
  let insts=give_instances env (project gl) lf seq in
    tclORELSE
      (tclFIRST (List.map (fun inst->instance_tac ~flags inst continue seq) insts))
      backtrack
  end
