(*
 *
 * Copyright (c) 2004, 
 *  Jeremy Condit       <jcondit@cs.berkeley.edu>
 *  George C. Necula    <necula@cs.berkeley.edu>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 * IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)
open Cil
open Pretty
module E = Errormsg
module GA = GrowArray
module IH = Inthash

let debug : bool ref = ref false
let verbose : bool ref = ref false
let inferFile : string ref = ref ""

let curFunc : fundec ref = ref dummyFunDec
let curStmt : int ref = ref (-1)

let staticGlobalVars : varinfo list ref = ref []

let exemptLocalVars : varinfo list ref = ref []

(* Assign to each statement a unique ID. *)
let nextStmtId : int ref = ref 0
let assignID (s:stmt) : unit =
  assert (s.sid = -1); (* Make sure that no one else has assigned ID numbers *)
  s.sid <- !nextStmtId;
  incr nextStmtId;
  ()

(* Convert instruction lists into individual statements, and give each
  stmt a unique id. *)
let fixStmt (s:stmt) : unit =
  assignID s;
  match s.skind with 
    Instr [] -> ()
  | Instr [i] -> ()
  | Instr il -> (* Two or more instructions *)
      s.skind <- Block (mkBlock (List.map mkStmtOneInstr il));
      ()      
  | _ -> ()

(* Truncates a list. *)
let rec truncate (l: 'a list) (n: int) : 'a list =
  match l with
  | elt :: rest when n > 0 -> elt :: (truncate rest (n - 1))
  | _ -> []

let rec typeContainsPointers (t: typ) : bool =
  match t with
  | TPtr _
  | TFun _
  | TBuiltin_va_list _ -> true
  | TVoid _
  | TInt _
  | TFloat _
  | TEnum _ -> false
  | TArray (bt, _, _) -> typeContainsPointers bt
  | TNamed (ti, _) -> typeContainsPointers ti.ttype
  | TComp (ci, _) ->
     List.exists typeContainsPointers
      (List.map (fun fld -> fld.ftype) ci.cfields)

(**************************************************************************)

let d_thisloc () : doc = d_loc () !currentLoc

let bug (fmt : ('a,unit,doc,unit) format4) : 'a = 
  let f d =  
    E.hadErrors := true;
    ignore (eprintf "%t: Bug: %a@!" d_thisloc insert d);
    flush !E.logChannel
  in
  Pretty.gprintf f fmt

let error (fmt : ('a,unit,doc,unit) format4) : 'a = 
  let f d =
    E.hadErrors := true;
    ignore (eprintf "%t: Error: %a@!" d_thisloc insert d);
    flush !E.logChannel
  in
  Pretty.gprintf f fmt

let unimp (fmt : ('a,unit,doc,unit) format4) : 'a = 
  let f d =
    E.hadErrors := true;
    ignore (eprintf "%t: Unimplemented: %a@!" d_thisloc insert d);
    flush !E.logChannel
  in
  Pretty.gprintf f fmt

let warn (fmt : ('a,unit,doc,unit) format4) : 'a = 
  let f d =
    ignore (eprintf "%t: Warning: %a@!" d_thisloc insert d);
    flush !E.logChannel
  in
  Pretty.gprintf f fmt

let log (fmt : ('a,unit,doc,unit) format4) : 'a = 
  let f d =
    ignore (eprintf "%t: %a@!" d_thisloc insert d);
    flush !E.logChannel
  in
  Pretty.gprintf f fmt

(**************************************************************************)

type check =
    CNonNull of exp      (** e != 0 *)
  | CEq of exp * exp     (** e1 == e2 *)
  | CNotEq of exp * exp  (** e1 != e2,   e.g. e != hi *)
  | CPositive of exp     (** e > 0 *)
  | CMult of exp * exp   (** e1 * k == e2 for some int k *)
  | COverflow of exp * exp
                         (** e1 + e2 does not overflow (e2 is signed) *)
  | CBounds of exp * exp * exp * exp 
                         (** e1 <= e2+e3 <= e4.  For ptr arith *)
  | CCoerce of exp * exp * exp * exp * exp
                         (** e3 == 0 ||
                             e1 <= e2 <= e3 <= e4 <= e5 *)
  | CCoerceN of exp * exp * exp * exp * exp
                         (** e3 == 0 ||
                             e1 <= e2 <= e3 <= e4 <= (e5 + strlen(e5)) *)
  | CNTWrite of exp * exp * exp
                         (** (e1 == e2) ==> (e3 = 0)   *)
  | CUnsignedLess of exp * exp
                         (** e1 < e2, unsigned *)
  | CNullUnion of lval   (** e = \vec{0} *)
  (* These two are redundant with CNonNull and CEq, but having separate
     checks for unions gives better error messages: *)
  | CSelected of exp     (** e != 0 *)
  | CNotSelected of exp  (** e == 0 *)
(* Other checks will be needed, such as nullterm checks and checks for when
   part of one of the above checks can be proved statically. *)


(* A mapping from stmt ids to checks for that instruction. The list of checks 
   is stored in reverse order.  *)
let allowChecks : bool ref = ref false
let allChecks : check list GA.t = GA.make 200 (GA.Elem [])

(* Add a check for the current statement.
 * When more than one check is added for a statement, they will be executed in
 * the order that addCheck was called.
 * For example, when accessing "**e", call addCheck (CNonNull e)
 * first, then addCheck (CNonNull *e).  Then we'll be sure to check e 
 * before *e, which ensures that the *e check won't segfault. 
 *)
let addCheck (c:check) : unit =
  if !allowChecks then begin
    let id = !curStmt in
    if id < 0 then 
      E.s (bug "addCheck when sid = %d.\n" id);
    let otherChecks = GA.getg allChecks id in
    if not (List.mem c otherChecks) then
      GA.set allChecks id (c::otherChecks)
  end

(* These aren't real variables.  In the output, they'll show up as
   __FILE__ and __LINE__, and gcc will see them as macros.  We use them
   for calling runtime check functions. *)
let fileToken : exp=
  let vi = makeGlobalVar "__FILE__" charPtrType in
  Lval (var vi)
let lineToken : exp=
  let vi = makeGlobalVar "__LINE__" intType in
  Lval (var vi)

let mkFun (name: string) (rt:typ) (args: typ list) : exp = 
  let fdec = emptyFunction name in
  let args = List.map (fun t -> ("", t, [])) args in
  fdec.svar.vtype <- TFun(rt, Some args, false, []);
  Lval (var fdec.svar)
let mkCheckFun (name: string) (n: int) : exp = 
 (* A check function takes n void* parameters, a file name, and a line number*)
  let args = Util.list_init n (fun _ -> voidPtrType) in
  let args' = args @ [charPtrType; intType] in
  mkFun name voidType args'
let cnonnull = mkCheckFun "CNonNull" 1
let ceq = mkCheckFun "CEq" 2
let cnoteq = mkCheckFun "CNotEq" 2
let cpositive = mkCheckFun "CPositive" 1
let cmult = mkCheckFun "CMult" 2
let coverflow = mkCheckFun "COverflow" 3
let cbounds = mkCheckFun "CBounds" 3
let ccoerce = mkCheckFun "CCoerce" 5
let ccoercen = mkCheckFun "CCoerceN" 5
let cntwrite = mkCheckFun "CNTWrite" 5
let cunsignedless = mkCheckFun "CUnsignedLess" 2
let cnullunion = mkCheckFun "CNullUnion" 2
let cselected = mkCheckFun "CSelected" 1
let cnotselected = mkCheckFun "CNotSelected" 1
let memset = mkFun "memset" voidType [voidPtrType; intType; !upointType]

let checkToInstr (c:check) =
  let call f args = Call(None, f,
                         (* Append the file and line to the end of the args *)
                         args @ [fileToken; lineToken],
                         !currentLoc) 
  in
  match c with
    CNonNull (e) -> call cnonnull [e]
  | CEq (e1,e2) -> call ceq [e1;e2]
  | CNotEq (e1,e2) -> call cnoteq [e1;e2]
  | CPositive (e) -> call cpositive [e]
  | CMult (e1,e2) -> call cmult [e1;e2]
  | COverflow (e1,e2) -> call coverflow [e1;e2]
  | CBounds (b,p,off,e) -> let p' = BinOp(PlusPI, p, off, typeOf p) in
                           call cbounds [b;p';e]
  | CCoerce (e1,e2,e3,e4,e5) -> call ccoerce [e1;e2;e3;e4;e5]
  | CCoerceN (e1,e2,e3,e4,e5) -> call ccoercen [e1;e2;e3;e4;e5]
  | CNTWrite (p,hi,what) -> call cntwrite [p;hi;what]
  | CUnsignedLess (e1,e2) -> call cunsignedless [e1;e2]
  | CNullUnion (lv) -> 
      let sz = sizeOf (typeOfLval lv) in
      call cnullunion [mkAddrOf lv; sz]
  | CSelected (e) -> call cselected [e]
  | CNotSelected (e) -> call cnotselected [e]


let postPassVisitor1 = object (self)
  inherit nopCilVisitor

  (* Turn the check datastructure into explicit checks, so that they show up
     in the output. *)
  method vstmt s = 
    let postProcessStmt (s: stmt) : stmt =
      let checks = GA.getg allChecks s.sid in
      if checks <> [] then begin
        let checks' = List.rev checks in (* put them back in the right order *)
        let checks'' : instr list = List.map checkToInstr checks' in
        self#queueInstr checks''
      end;
      s
    in
    ChangeDoChildrenPost (s, postProcessStmt)
end

let postPassVisitor2 = object (self)
  inherit nopCilVisitor

  (* Remove any "bounds" or "fancybounds" annotations. *)
  method vattr a =
    match a with
    | Attr(("bounds" | "fancybounds" | "nullterm" | "trusted"
            | "when" | "fancywhen"), _) ->
        ChangeTo []
    | _ -> DoChildren

end

(**************************************************************************)

(* Keyword in bounds attributes representing the current value *)
let thisKeyword = "__this"

let countAttr (a: attrparam) : attribute =
  Attr ("bounds", [ACons (thisKeyword, []);
                   ABinOp (PlusPI, ACons (thisKeyword, []), a)])

let safeAttr : attribute = countAttr (AInt 1)

(* remember complicated bounds expressions *)
let boundsTable : exp Inthash.t = IH.create 13
let boundsTableCtr : int ref = ref 0

let addBoundsExp (e: exp) : int =
  incr boundsTableCtr;
  if !verbose then
    E.log "%a:   fancybounds(%d) = %a.\n" d_loc !currentLoc
      !boundsTableCtr d_exp e;
  IH.add boundsTable !boundsTableCtr e;
  !boundsTableCtr

let getBoundsExp (n: int) : exp =
  try
    IH.find boundsTable n
  with Not_found ->
    E.s (bug "Couldn't look up expression in bounds table")

let clearBoundsTable () : unit =
  Inthash.clear boundsTable;
  boundsTableCtr := 0

(* remember complicated WHEN expressions. For each union in each context,
   we have a whenMap, which maps fields to the expanded when condition for that
   field in the context.  *)
type whenMap = (fieldinfo * exp) list
let whenTable : whenMap Inthash.t = IH.create 13
let whenTableCtr : int ref = ref 0
let d_whenMap: unit -> whenMap -> doc =
  docList ~sep:(text ";  ") 
    (fun (f,e) -> text f.fname ++ text ": " ++ d_exp () e)

let addWhenMap (wm:whenMap) : int =
  incr whenTableCtr;
  if !verbose then
    E.log "%a:   fancywhen(%d) = [%a].\n" d_loc !currentLoc
      !whenTableCtr d_whenMap wm;
  IH.add whenTable !whenTableCtr wm;
  !whenTableCtr

let getWhenMap (n: int) : whenMap =
  try
    IH.find whenTable n
  with Not_found ->
    E.s (E.bug "couldn't look up %d in when table\n" n)

let rec getDeps (a: attrparam) : string list =
  match a with 
  | AInt k -> []
  | ASizeOf t -> []
  | ACons(name, []) -> [name]
  | ABinOp (_, e1, e2) -> (getDeps e1) @ (getDeps e2)
  | _ -> E.s (error "Cannot get dependencies for %a" d_attrparam a)

let rec depsOfAttrs (a: attributes) : string list = 
  let checkrest rest =
    if hasAttribute "bounds" rest ||
       hasAttribute "fancybounds" rest then
      E.s (error "Type has duplicate bounds attributes")
  in
  match a with
  | Attr ("bounds", [lo; hi]) :: rest ->
      checkrest rest;
      (getDeps lo) @ (getDeps hi)
  | Attr ("bounds", _) :: rest ->
      E.s (error "Illegal bounds annotations.")
  | Attr ("fancybounds", _) :: rest ->
      E.s (error "Can't get dependencies for fancybounds annotations.")
  | Attr _ :: rest -> 
      depsOfAttrs rest
  | [] -> 
      E.s (bug "Missing bounds information")

let depsOfType (t: typ) : string list =
  match t with
  | TPtr (_, a) -> depsOfAttrs a
  | _ -> []

let rec getWhen (a: attributes) : attrparam =
  let checkrest rest =
    if hasAttribute "when" rest then
      E.s (error "Type has duplicate when attributes")
  in
  match a with
  | Attr ("when", [e]) :: rest ->
      checkrest rest;
      e
  | Attr ("when", _) :: rest ->
      E.s (error "Illegal when annotations.")
  | Attr _ :: rest -> 
      getWhen rest
  | [] -> 
      raise Not_found

let depsOfWhenAttrs (a: attributes) : string list = 
  let w = getWhen a in
  getDeps w

(* Determine whether other variables/fields depend on a given name. *)
let hasExternalDeps (lv: lval) : bool =
  let hasDeps (n: string) (vars: (string * typ) list) : bool =
    List.fold_left
      (fun acc (name, t) ->
         acc || (name <> n && List.mem n (depsOfType t)))
      false
      vars
  in
  let lv', off = removeOffsetLval lv in
  match off with
  | NoOffset ->
      begin
        match fst lv with
        | Var vi ->
            let env =
              if not vi.vglob then
                !curFunc.slocals @ !curFunc.sformals
              else if vi.vglob && vi.vstorage = Static then
                !staticGlobalVars
              else
                [vi]
            in
            let vars = List.map (fun vi -> vi.vname, vi.vtype) env in
            hasDeps vi.vname vars
        | Mem e ->
            false
      end
  | Field (fld, NoOffset) ->
      let vars =
        List.map (fun fld -> fld.fname, fld.ftype) fld.fcomp.cfields
      in
      hasDeps fld.fname vars
  | Index (_, NoOffset) ->
      (* No one depends on array elements.  
         FIXME: what about arrays inside null-terminated arrays? *)
      false
  | _ -> E.s (bug "Unexpected result from removeOffset")

(* mapping from variable/field names to expressions representing 
   the runtime value. *)
type context = (string * exp) list

let isPointer e: bool =
  isPointerType (typeOf e)

let isNullterm (t: typ) : bool =
  match unrollType t with
  | TPtr (_, a) -> hasAttribute "nullterm" a
  | _ -> E.s (error "Expected pointer type")

let isTrusted (t: typ) : bool =
  hasAttribute "trusted" (typeAttrs t)

let isTrustedComp (ci: compinfo) : bool =
  hasAttribute "trusted" ci.cattr

(** The dependent types are expressed using attributes. We compile an 
 * attribute given a mapping from names to lvals.  Returns the names of
 * meta values that this annotation depends on, and the expression.
 *  
 * This is a helper for both fields and formals. *)
let compileAttribute 
  (ctx: context) (* Should include a mapping for thisKeyword *)
  (a: attrparam) 
  : string list * exp = 
  let rec compile (a: attrparam) = 
    match a with 
      AInt k -> [], integer k
    | ASizeOf t -> [], SizeOf t
    | ACons(name, []) -> begin
        try 
          let e = List.assoc name ctx in 
          [name], e
        with Not_found -> 
          E.s (error 
               ("Cannot compile the dependency %a: " ^^
                "Cannot find %s in the context.\n  Choices are: %a.")
               d_attrparam a
               name
               (docList (fun (s, _) -> text s)) ctx)
    end
    | ABinOp (bop, e1, e2) -> 
        let lv1', e1' = compile e1 in
        let lv2', e2' = compile e2 in
        (* now that we know the types of these expressions,
           fix any MinusA/PlusA that should be pointer arithmetic. *)
        let bop' = match bop, isPointer e1', isPointer e2' with
            MinusA, true, true -> MinusPP
          | MinusA, true, false -> MinusPI
          | PlusA, true, false -> PlusPI
          | _ -> bop
        in
        lv1' @ lv2', BinOp(bop', e1', e2', intType)
    | _ -> E.s (error "Cannot compile the dependency %a" d_attrparam a)
  in
  compile a

type bounds =
| BSimple of attrparam * attrparam
| BFancy of exp * exp

let rec getBounds (a: attributes) : bounds =
  let checkrest rest =
    if hasAttribute "bounds" rest ||
       hasAttribute "fancybounds" rest then
      E.s (error "Type has duplicate bounds attributes")
  in
  match a with
  | Attr ("bounds", [lo; hi]) :: rest ->
      checkrest rest;
      BSimple (lo, hi)
  | Attr ("fancybounds", [AInt lo; AInt hi]) :: rest ->
      checkrest rest;
      BFancy (getBoundsExp lo, getBoundsExp hi)
  | Attr _ :: rest -> 
      getBounds rest
  | [] -> 
      E.s (bug "Missing bounds information")

let boundsOfAttrs (ctx: context) (a: attributes) : exp * exp = 
  match getBounds a with
  | BSimple (lo, hi) ->
      (* Compile lo, hi into expressions *)
      let lodeps, lo' = compileAttribute ctx lo in
      let hideps, hi' = compileAttribute ctx hi in
      lo', hi'
  | BFancy _ ->
      E.s (error "Found fancybounds instead of bounds annotations")

let fancyBoundsOfAttrs (a: attributes) : exp * exp = 
  match getBounds a with
  | BSimple (lo, hi) ->
      E.s (error "Found bounds instead of fancybounds annotations")
  | BFancy (lo, hi) ->
      lo, hi

let fancyBoundsOfType (t: typ) : exp * exp =
  if !verbose then
    E.log "%a: fancyBoundsOfType %a\n" d_loc !currentLoc d_type t;
  match unrollType t with
  | TPtr (_, a) -> fancyBoundsOfAttrs a
  | _ -> E.s (error "Expected pointer type")

let makeFancyBoundsAttr (lo: exp) (hi: exp) : attribute =
  Attr ("fancybounds", [AInt (addBoundsExp lo); AInt (addBoundsExp hi)])

let makeFancyPtrType ?(nullterm:bool=false) (bt: typ) (lo: exp) (hi: exp) 
  : typ =
  let bounds_attr = [makeFancyBoundsAttr lo hi] in
  let attrs = if nullterm then 
    addAttribute (Attr("nullterm",[])) bounds_attr
  else
    bounds_attr
  in
  TPtr (bt, attrs)

let whenOfAttrs (ctx: context) (a: attributes) : exp =
  let w = getWhen a in
  let deps, e = compileAttribute ctx w in
  e

let makeFancyWhenAttr (wm: whenMap) : attribute =
  Attr ("fancywhen", [AInt (addWhenMap wm)])

let fancyWhenOfType (t: typ) : whenMap =
  match unrollType t with
  | TComp (_, a) -> begin
      match filterAttributes "fancywhen" a with
        [Attr("fancywhen", [AInt i])] -> getWhenMap i
      | _ -> E.s (bug "missing (or malformed) fancywhen: %a" d_attrlist a)
    end
  | _ -> E.s (E.bug "Expected union type.")

(* Replace the names in type t with the corresponding expressions in ctx *)
let substType (ctx: context) (t: typ) : typ =
  if !verbose then
    E.log "%a: substType %a\n" d_loc !currentLoc d_type t;
  match unrollType t with
  | TPtr (bt, a) ->
      let lo, hi = boundsOfAttrs ctx a in
      let a' = addAttribute (makeFancyBoundsAttr lo hi) 
                 (dropAttribute "bounds" a) in
      TPtr (bt, a')
  | TComp (ci, a) when not ci.cstruct && not (isTrustedComp ci) ->
      (* a union. Create a fancywhen attr for the when clauses of each field.*)
      let doField (acc:whenMap) (fld:fieldinfo) : whenMap =
        try 
          let e : exp = whenOfAttrs ctx fld.fattr in (* may raise Not_found *)
          (fld, e) :: acc
        with Not_found ->
          if typeContainsPointers fld.ftype then begin
            E.s (bug "Missing WHEN annotation on field %s.\n" fld.fname)
          end else
            (* Allow missing WHEN clauses for scalars. *)
            acc
      in
      let wm = List.fold_left doField [] ci.cfields in
      let a' = addAttribute (makeFancyWhenAttr wm) a in
      TComp (ci, a')
  | _ ->
      t

let emptyContext : context = []

(* Add to the current context a binding for "__this" *)
let addThisBinding (ctx:context) (e:exp) : context =
  (thisKeyword, e)::ctx

(* Add to the current context a binding from name to e *)
let addBinding (ctx:context) (name:string) (e:exp) : context =
  (name, e)::ctx

(* Check whether a binding exists. *)
let hasBinding (ctx:context) (name:string) : bool =
  List.exists (fun (n, _) -> n = name) ctx
let hasBindings (ctx:context) (names : string list) : bool =
  List.for_all (hasBinding ctx) names

(* The context of local and formal variables. *)
let localsContext (f:fundec) : context =
  List.fold_left
    (fun acc v -> (v.vname, Lval (var v)) :: acc)
    []
    (f.sformals @ f.slocals)

let globalsContext () : context =
  List.fold_left
    (fun acc v -> (v.vname, Lval (var v)) :: acc)
    []
    !staticGlobalVars

let structContext (lv: lval) (ci: compinfo) : context =
  List.fold_left
    (fun acc fld ->
       (fld.fname, Lval (addOffsetLval (Field (fld, NoOffset)) lv)) :: acc)
    []
    ci.cfields

(**************************************************************************)

let compareTypes (t1 : typ) (t2 : typ) : bool =
  let typeSigNC (t : typ) : typsig =
    let attrFilter (attr : attribute) : bool =
      match attr with
      | Attr ("const", [])
      | Attr ("volatile", [])
      | Attr ("always_inline", []) -> false
      | _ -> true
    in
    typeSigWithAttrs (List.filter attrFilter) t
  in
  (typeSigNC t1) = (typeSigNC t2)

let isAllocator (t: typ) : bool =
  let attrs = typeAttrs t in
  hasAttribute "dmalloc" attrs || hasAttribute "dcalloc" attrs

let isMemset (t: typ) : bool =
  hasAttribute "dmemset" (typeAttrs t)

let isMemcpy (t: typ) : bool =
  hasAttribute "dmemcpy" (typeAttrs t)

let rec expToAttr (e: exp) : attrparam option =
  match e with
  | Lval (Var vi, NoOffset) -> Some (ACons (vi.vname, []))
  | CastE (t, e') -> expToAttr e' (* TODO: check type? *)
  | Const _ ->
      begin
        match isInteger e with
        | Some i -> Some (AInt (Int64.to_int i))
        | None -> None
      end
  | BinOp ((MinusA | PlusA) as op, e1, e2, _) ->
      begin
        match expToAttr e1, expToAttr e2 with
        | Some a1, Some a2 -> Some (ABinOp (op, a1, a2))
        | _ -> None
      end
  | _ -> None

let getAllocationType (retType: typ) (fnType: typ) (args: exp list) : typ =
  let fnAttrs = typeAttrs fnType in
  let numElts, baseType =
    if hasAttribute "dcalloc" fnAttrs then
      match args with
      | [SizeOf t'; e] -> e, t'
      | _ -> E.s (error "Unrecognized allocation function")
    else if hasAttribute "dmalloc" fnAttrs then
      match args with
      | e :: _ ->
        begin
          match stripCasts e with
          | BinOp (Mult, e', SizeOf t, _)
          | BinOp (Mult, SizeOf t, e', _) -> e', t
          | BinOp (Mult, e', SizeOfE et, _)
          | BinOp (Mult, SizeOfE et, e', _) -> e', typeOf et
          | SizeOf t -> integer 1, t
          | SizeOfE et -> integer 1, typeOf et
          | _ -> e, charType
        end
      | _ -> E.s (error "Unrecognized allocation function")
    else
      E.s (error "Unrecognized allocation function")
  in
  let retBaseType =
    match unrollType retType with
    | TPtr (bt, _) -> bt
    | _ -> E.s (error "Return type of allocation is not a pointer")
  in
  if not (compareTypes baseType retBaseType) then
    E.s (error "Type mismatch: alloc type %a and return type %a differ"
               d_type baseType d_type retBaseType);
  match expToAttr numElts with
  | Some a -> typeAddAttributes [countAttr a]
                (typeRemoveAttributes ["bounds"] retType)
  | None -> E.s (error "Cannot convert alloc expression to type: %a"
                 d_exp numElts)

(* Check that two types are the same. *)
let checkSameType (t1 : typ) (t2 : typ) : unit =
  if !verbose then
    E.log "%a: checkSameType on %a and %a\n" 
      d_loc !currentLoc
      d_type t1 d_type t2;
    match unrollType t1, unrollType t2 with
    | t1, t2 when isTrusted t1 || isTrusted t2 ->
        ()
    | TPtr (bt1, a1), TPtr (bt2, a2) ->
        if not (compareTypes bt1 bt2) then
          E.s (error "Base type mismatch: %a and %a" d_type t1 d_type t2);
        (* Make sure the bounds are the same.
           We can use the empty context, because these should only contain 
           fancybounds *)
        let lo1, hi1 = fancyBoundsOfAttrs a1 in
        let lo2, hi2 = fancyBoundsOfAttrs a2 in
        (* Checking CIL expressions for equality statically is tricky.
           Do it dynamically: *)
        addCheck (CEq(lo1,lo2));
        addCheck (CEq(hi1,hi2))
    | TInt _, TInt _ when (bitsSizeOf t1) = (bitsSizeOf t2) ->
        (* ignore signed/unsigned differences.  FIXME: is this safe? *)
        ()
    | _ -> 
        if not (compareTypes t1 t2) then
          E.s (error "Type mismatch: %a and %a" d_type t1 d_type t2)

let checkUnionWhen (ctx:context) (fld:fieldinfo) : bool =
  isTrustedComp fld.fcomp ||
  try 
    let deps = depsOfWhenAttrs fld.fattr in (* may raise Not_found *)
    hasBindings ctx deps
  with Not_found ->
    if typeContainsPointers fld.ftype then begin
      E.log "Missing WHEN annotation on field %s in union %s.\n"
        fld.fname fld.fcomp.cname;
      false
    end else
      (* Allow missing WHEN clauses for scalars. *)
      true

(* Determine whether a type is well-formed. *)
let rec checkType (ctx: context) (t: typ) : bool =
  let ctxThis = addThisBinding emptyContext zero in
  match t with
  | TPtr (bt, a) ->
      (* TODO: check whether base types for bounds match? *)
      checkType ctxThis bt &&
      (hasBindings ctx (depsOfAttrs a))
  | TArray (bt, _, _) ->
      checkType ctxThis bt
  | TFun (ret, argInfo, _, _) ->
      let ctxFun =
        List.fold_left
          (fun acc (name, _, _) -> addBinding acc name zero)
          ctxThis
          (argsToList argInfo)
      in
      checkType ctxThis ret &&
      List.fold_left
        (fun acc (_, t, _) -> acc && checkType ctxFun t)
        true
        (argsToList argInfo)
  | TComp (ci, _) when not ci.cstruct ->   (* union *)
      List.fold_left
        (fun acc fld -> 
           (* Check union fields in the context ["__this"; fieldname].
              These are redundant ... I'm only including the field
              name because that's how we did it in the paper. *)
           let ctxField = addBinding ctxThis fld.fname zero in
           if not (checkType ctxField fld.ftype) then
             E.s (E.error "%a: field %s of union %s is ill-formed\n"
                    d_loc !currentLoc fld.fname ci.cname);
           (* now check the when clause *)
           acc && (checkUnionWhen ctx fld) )
      true
      ci.cfields
      
  (* Structs and typedefs are checked when defined. *)
  | TComp _
  | TNamed _
  (* The following types are always well-formed. *)
  | TVoid _
  | TInt _
  | TFloat _
  | TEnum _
  | TBuiltin_va_list _ -> true

(* Add checks for a coercion of e from tfrom to tto.
   Both tfrom and tto must have fancy bounds. *)
let coerceType (e:exp) ~(tfrom : typ) ~(tto : typ) : unit =
  if !verbose then
    E.log "%a: coercing exp %a from %a to %a\n"
          d_loc !currentLoc d_exp e d_type tfrom d_type tto;
  match unrollType tfrom, unrollType tto with
  | t1, t2 when isTrusted t1 || isTrusted t2 ->
      ()
  | TPtr(bt1, _), TPtr(bt2, _) when compareTypes bt1 bt2 ->
      if isNullterm tto && not (isNullterm tfrom) then
        E.s (error "Cast to NULLTERM from an ordinary pointer");
      let lo_from, hi_from = fancyBoundsOfType tfrom in
      let lo_to, hi_to = fancyBoundsOfType tto in
      if isNullterm tfrom then begin
        if bitsSizeOf bt2 <> 8 then
          E.s (unimp "nullterm buffer that's not a char*.\n");
        addCheck (CCoerceN(lo_from, lo_to, e, hi_to, hi_from))
      end
      else
        addCheck (CCoerce(lo_from, lo_to, e, hi_to, hi_from));
      ()
  | (TEnum _ | TPtr _), TInt _ ->
      (* Coerce pointer/enum to integer. *)
      ()
  | TInt _, TEnum _ ->
      (* Coerce integer to enum. *)
      ()
  | (TInt _ | TPtr _), TPtr _ when isZero e ->
      (* Coerce NULL to pointer.  Do we need to do any well-formedness checks
         here? *)
      ()
  | TInt _, TInt _ when (bitsSizeOf tfrom) = (bitsSizeOf tto) ->
      (* ignore signed/unsigned differences.  FIXME: is this safe? *)
      ()
  | TInt _, TInt _ ->
      (* ignore signed/unsigned differences.  FIXME: is this safe? *)
      warn "Allowing integer cast with different sizes";
      ()
  | TComp (ci, _), TComp (ci', _) when ci == ci' && not ci.cstruct ->
      (* Make sure unions have been zeroed. *)
      (* FIXME: only do this if the maps are different (i.e. the union
         depends on the value being changed. *)
      let lv = match e with Lval lv -> lv 
        | _ -> E.s (bug "union expression must be an lval.")
      in
      addCheck (CNullUnion lv)
  | _ -> 
    if not (compareTypes tfrom tto) then
      E.s (error "Type mismatch: coercion from %a to %a"
                 d_type tfrom d_type tto)
        
type whyLval=
    ForRead          (* Reading this lval. *)
  | ForAddrOf        (* Taking the address of this lval *)
  | ForWrite of exp  (* writing the specified value. Call checkExp on
                        this exp before calling checkLval *)
  | ForCall          (* Assigning the result of a call.
                        We don't have an expression representing the new value,
                        so we have to be more conservative *)

(* Calls checkExp e, then calls coerceType to make sure that
   e can be coerced to tto.  tto must have fancy bounds. *)
let rec coerceExp (e:exp) (tto : typ) : unit =
  coerceType e ~tfrom:(checkExp e) ~tto
        

and checkExp (e : exp) : typ =
  if !verbose then
    E.log "%a: checking exp %a\n" d_loc !currentLoc d_exp e;
  match e with
  | UnOp (op, e', t) -> coerceExp e' t; t
  | BinOp ((PlusPI | IndexPI | MinusPI) as op, e1, e2, t) ->
      let t1 = checkExp e1 in
      (* FIXME: __this can appear in t, so we ignore it for now.
         At some point, we should check it! *)
      (* coerceExp e1 (substType ... t); *)
      coerceExp e2 intType;
      if not (isTrusted t1) then begin
        let lo, hi = fancyBoundsOfType t1 in
        let e2' =
          match op with
          | MinusPI -> UnOp (Neg, e2, typeOf e2)
          | PlusPI | IndexPI -> e2
          | _ -> E.s (bug "Unexpected operation")
        in
        addCheck (CNonNull e1);
        addCheck (COverflow (e1, e2'));
        addCheck (CBounds (lo, e1, e2', hi))
      end;
      t1
  | BinOp (MinusPP, e1, e2, t) ->
      ignore (checkExp e1);
      ignore (checkExp e2);
      t
  | BinOp (op, e1, e2, t) ->
      coerceExp e1 t;
      coerceExp e2 t;
      t
  | Lval lv -> checkLval ForRead lv
  | CastE (t1, AddrOf (Mem (CastE (t2, z)), Field (f, NoOffset)))
        when isIntegralType t1 && isZero z ->
      t1
  | CastE (t, e') ->
      let ctx = addThisBinding (localsContext !curFunc) e in
      let t' = substType ctx t in
      coerceExp e' t';
      t'
  | SizeOfE _
  | AlignOfE _ ->
      (* We don't check the inner expr because it doesn't get executed. *)
      unrollType (typeOf e)
  | AddrOf lv ->
      ignore (checkLval ForAddrOf lv);
      let ctxThis = addThisBinding emptyContext zero in
      let bt = typeOfLval lv in
      if not (checkType ctxThis bt) then
        E.s (error "Cannot take address of lval that has dependencies");
      if hasExternalDeps lv then
        E.s (error "Cannot take address of lval with external dependencies");
      let lo = AddrOf lv in
      let hi = BinOp (PlusPI, lo, one, typeOf lo) in
      makeFancyPtrType bt lo hi
  | StartOf lv ->
      let bt, len, attrs =
        match unrollType (checkLval ForAddrOf lv) with
        | TArray (bt, Some e, attrs) ->
            let nt = hasAttribute "nullterm" attrs in
            let e' = if nt then BinOp (MinusA, e, one, typeOf e) else e in
            bt, e', attrs
        | TArray (_, None, _) -> E.s (error "Array type has no length")
        | _ -> E.s (bug "Expected array type")
      in
      let lo = StartOf lv in
      let hi = BinOp (PlusPI, lo, len, typeOf lo) in
      typeAddAttributes (filterAttributes "nullterm" attrs)
                        (makeFancyPtrType bt lo hi)
  | Const (CStr s) -> (* String literal *)
      let len = String.length s in
      let lo = e in
      let hi = BinOp (PlusPI, lo, integer len, typeOf lo) in
      makeFancyPtrType ~nullterm:true charType lo hi
  | Const _
  | SizeOf _
  | SizeOfStr _
  | AlignOf _ -> unrollType (typeOf e)

and checkLval (why: whyLval) (lv: lval) : typ =
  if !verbose then
    E.log "%a: checking lvalue %a\n" d_loc !currentLoc d_lval lv;
  begin
    match lv with
      Mem e, off -> begin
        let ptrTy = checkExp e in
        let lo, hi = fancyBoundsOfType ptrTy in
        addCheck (CNonNull e);
        match why with
          ForRead ->
            if not (isNullterm ptrTy) then
              addCheck (CNotEq(e,hi))
        | ForAddrOf ->
            (* check e != hi even if this is nullterm, because
               otherwise we could create a pointer with bounds hi,hi+1. *)
            addCheck (CNotEq(e,hi))
        | ForCall ->
            (* Conservatively forbid assignment of a call result when e=hi. *)
            addCheck (CNotEq(e,hi))
        | ForWrite what ->
            if isNullterm ptrTy then
              addCheck (CNTWrite(e,hi,what))
            else
              addCheck (CNotEq(e,hi))
      end
    | Var vi, off -> ()
  end;
  let lv', off = removeOffsetLval lv in
  let checkRest ():typ = (* returns the type of lv' *)
    let why' = match why with
        ForRead -> ForRead
      | _ ->  (* If we are going to e.g. write, forbid any access to the 
               * terminating null. *) 
          ForAddrOf (* conservative *)
    in
    unrollType (checkLval why' lv')
  in
  match off with
  | NoOffset ->
      let ctx =
        match fst lv with
        | Var vi ->
            if not vi.vglob then
              localsContext !curFunc
            else if vi.vglob && vi.vstorage = Static then
              globalsContext ()
            else
              addBinding emptyContext vi.vname (Lval (var vi))
        | Mem e -> emptyContext
      in
      let ctx' = addThisBinding ctx (Lval lv) in
      substType ctx' (typeOfLval lv)
  | Field (fld, NoOffset) ->
      let compType = checkRest () in
      begin
        match compType with
        | TComp (ci, _) when ci == fld.fcomp -> ()
        | t ->
            E.s (error "Bad field offset %s on type %a" fld.fname d_type t)
      end;
      if fld.fcomp.cstruct then begin
        let ctx = structContext lv' fld.fcomp in
        let ctx' = addThisBinding ctx (Lval lv) in
        substType ctx' fld.ftype
      end else begin (* Union *)
        (* check the field access *)
        if not (isTrustedComp fld.fcomp) then
          checkUnionAccess why compType fld;
        (* now do the type of the field itself *)
        let value = Lval lv in
        let ctx  = addBinding emptyContext fld.fname value in
        let ctx' = addThisBinding ctx value in
        substType ctx' fld.ftype
      end
  | Index (index, NoOffset) ->
      coerceExp index intType;
      begin
        match checkRest () with 
        | TArray (bt, Some len, a) ->
            addCheck (CUnsignedLess (index, len));
            if hasAttribute "nullterm" a then begin
              match why with
              | ForWrite what ->
                  let base = StartOf lv' in
                  let t = typeOf base in
                  let e = BinOp (PlusPI, base, index, t) in
                  let hi =
                    BinOp (MinusPI, BinOp (PlusPI, base, len, t), one, t)
                  in
                  addCheck (CNTWrite (e, hi, what))
              | _ -> ()
            end;
            let ctx = addThisBinding emptyContext (Lval lv) in
            substType ctx bt
        | t -> E.s (error "Expecting an array, got %a" d_type t)
      end
  | _ -> E.s (bug "Unexpected result from removeOffset")

and checkUnionAccess (why:whyLval) (compType: typ) (fld:fieldinfo): unit =
  if (why = ForAddrOf) then
    E.s (error "Can't take the address of a union field.");
  let wm = fancyWhenOfType compType in
  if !verbose then
    E.log "%a:  Read from %s.  Using fancywhen [%a]\n" 
      d_loc !currentLoc fld.fname d_whenMap wm;
  (* Check the selector for the current field. *)
  (try
     let s = List.assq fld wm in
     addCheck (CSelected s)
   with Not_found -> () (* a scalar field without a WHEN *)
  );
  if why <> ForRead then begin
    (* Check that the other selectors are 0 *)
    List.iter
      (fun (f,s) -> if f != fld then
         addCheck (CNotSelected s))
      wm
  end;  
  ()

let checkCall (lvo: lval option) (fnType: typ) (args: exp list) : unit =
  if !verbose then
    E.log "%a: checking call\n" d_loc !currentLoc;
  match fnType with
  | TFun (returnType, argInfo, varargs, _) ->
      if varargs then
        warn "Varargs were not checked";
      (match lvo with
       | Some lv -> 
           (* TODO: let the return type depend on formals *)
           if hasExternalDeps lv then
             E.s (error "Return lval has external dependencies");
           let lvType = checkLval ForCall lv in
           (* replace __this in the return type with lv, and make sure the
              result equals the type of lv: *)
           let returnCtx = addThisBinding emptyContext (Lval lv) in
           let returnType' = substType returnCtx returnType in
           checkSameType returnType' lvType
       | None -> ()
      );
      (* CIL's casts don't make sense with dependent types, so remove them. *)
      let formals = argsToList argInfo in
      let actuals = truncate (List.map stripCasts args) (List.length formals) in
      begin
        try
          let ctxCall =
            List.fold_left2
              (fun ctxAcc (argName, _, _) arg ->
                 if argName <> "" then
                   addBinding ctxAcc argName arg
                 else
                   ctxAcc)
              emptyContext
              formals
              actuals
          in
          List.iter2
            (fun (argName, argType, _) arg ->
               let ctxCall' = addThisBinding ctxCall arg in
               let argType' = substType ctxCall' argType in
               coerceExp arg argType')
            formals
            actuals
        with Invalid_argument _ ->
          E.s (bug "Different number of formal and actual args")
      end
  | _ -> E.log "%a: calling non-function type\n" d_loc !currentLoc

(*
let checkAlloc (lv: lval) (bt:typ) (e: exp) : unit =
  if !verbose then
    E.log "%a: checking alloc of %a %a\n" d_loc !currentLoc d_exp e d_type bt;
  if hasExternalDeps lv then
    E.s (error "Return lval has external dependencies");
  coerceExp e intType;
  addCheck (CPositive e);
  let lvType = checkLval ForCall lv in
  let nullterm = isNullterm lvType in
  let len = 
    if nullterm then 
      BinOp(MinusPI, e, one, intType)
    else 
      e
  in
  let lo = Lval lv in
  let hi = BinOp(PlusPI, lo, len, TPtr(bt, [])) in (* FIXME: overflow *)
  let rt = makeFancyPtrType bt lo hi in
  checkSameType rt lvType;
  ()
*)

let checkAlloc () : unit =
  (* TODO: check all args *)
  ()

let checkMemset (lvo: lval option) (e1: exp) (e2: exp) (e3: exp) : unit =
  if !verbose then
    E.log "%a: checking memset\n" d_loc !currentLoc;
  coerceExp e2 intType;
  coerceExp e3 intType;
  let e1Type = checkExp e1 in
  let e1BaseType =
    match unrollType e1Type with
    | TPtr (bt, _) -> bt
    | _ -> E.s (error "First arg to memset is not a pointer")
  in
  let lo, hi = fancyBoundsOfType e1Type in
  let e1' = CastE (charPtrType, e1) in
  addCheck (CNonNull e1);
  addCheck (COverflow (e1', e3));
  addCheck (CBounds (lo, e1', e3, hi));
  if typeContainsPointers e1BaseType then begin
    addCheck (CEq (e2, zero));
    addCheck (CMult (SizeOf e1BaseType, e3))
  end;
  begin
    match lvo with
    | Some lv -> checkSameType (checkLval (ForWrite e1) lv) e1Type
    | None -> ()
  end

let checkMemcpy (lvo: lval option) (e1: exp) (e2: exp) (e3: exp) : unit =
  if !verbose then
    E.log "%a: checking memcpy\n" d_loc !currentLoc;
  coerceExp e3 intType;
  let e1Type = checkExp e1 in
  let e2Type = checkExp e2 in
  let e1BaseType =
    match unrollType e1Type with
    | TPtr (bt, _) -> bt
    | _ -> E.s (error "First arg to memcpy is not a pointer")
  in
  let e2BaseType =
    match unrollType e2Type with
    | TPtr (bt, _) -> bt
    | _ -> E.s (error "Second arg to memcpy is not a pointer")
  in
  let lo1, hi1 = fancyBoundsOfType e1Type in
  let e1' = CastE (charPtrType, e1) in
  addCheck (CNonNull e1);
  addCheck (COverflow (e1', e3));
  addCheck (CBounds (lo1, e1', e3, hi1));
  let lo2, hi2 = fancyBoundsOfType e2Type in
  let e2' = CastE (charPtrType, e2) in
  addCheck (CNonNull e2);
  addCheck (COverflow (e2', e3));
  addCheck (CBounds (lo2, e2', e3, hi2));
  if typeContainsPointers e1BaseType then begin
    checkSameType e1BaseType e2BaseType;
    addCheck (CMult (SizeOf e1BaseType, e3))
  end(*;
  begin
    match lvo with
    | Some lv -> checkSameType (checkLval (ForWrite e1) lv) e1Type
    | None -> ()
  end*)

let checkSetEnv (ctx: context) (x: 'a) (e: exp) (env: 'a list) (expOf: 'a -> exp)
                (nameOf: 'a -> string) (typeOf: 'a -> typ) : unit =
  List.iter
    (fun y ->
       let yExp = expOf y in
       let ySubst = if (nameOf x) <> (nameOf y) then yExp else e in
       let ctx' = addBinding (addThisBinding ctx ySubst) (nameOf x) e in
       coerceExp ySubst (substType ctx' (typeOf y)))
    env

let checkSet (lv: lval) (e: exp) : unit =
  let lvType = checkLval (ForWrite e) lv in
  let off1, off2 = removeOffset (snd lv) in
  begin
    match off2 with
    | NoOffset ->
        begin
          match fst lv with
          | Var x ->
              let ctx, env =
                if not x.vglob then
                  localsContext !curFunc, !curFunc.slocals @ !curFunc.sformals
                else if x.vglob && x.vstorage = Static then
                  globalsContext (), !staticGlobalVars
                else
                  addBinding emptyContext x.vname (Lval (var x)), [x]
              in
              checkSetEnv ctx x e env
                       (fun vi -> Lval (var vi))
                       (fun vi -> vi.vname)
                       (fun vi -> vi.vtype)
          | Mem addr ->
              coerceExp e lvType
        end
    | Field (x, NoOffset) when x.fcomp.cstruct -> (* struct *)
        let baseLval = fst lv, off1 in
        let ctx = structContext baseLval x.fcomp in
        let env = x.fcomp.cfields in
        checkSetEnv ctx x e env
                 (fun fi -> Lval (addOffsetLval (Field (fi, NoOffset)) baseLval))
                 (fun fi -> fi.fname)
                 (fun fi -> fi.ftype)
    | Field (x, NoOffset) ->   (* Union *)
        (* union fields don't depend on each other. *)
        ()
    | Index (_, NoOffset) ->
        (* No dependencies to array elements. 
           FIXME: what about arrays inside null-terminated arrays?  *)
        ()
    | _ -> E.s (bug "Unexpected result from removeOffset")
  end

let checkInstr (instr : instr) : unit =
  currentLoc := get_instrLoc instr;
  if !verbose then
    E.log "%a: checking instr %a\n" d_loc !currentLoc d_instr instr;
  match instr with
  | Call (lvo, fn, args, _) ->
      let fnType = checkExp fn in
      (* TODO: check remaining args for memset, memcpy, alloc *)
      if isAllocator fnType then
        checkAlloc ()
      else if isMemset fnType then
        match args with
        | [e1; e2; e3] -> checkMemset lvo (stripCasts e1) e2 e3
        | _ -> E.s (error "Expected three args to memset")
      else if isMemcpy fnType then
        match args with
        | [e1; e2; e3] -> checkMemcpy lvo (stripCasts e1) (stripCasts e2) e3
        | _ -> E.s (error "Expected three args to memcpy")
      else
        checkCall lvo fnType args
  | Set ((Var vi, NoOffset), _, _) when List.memq vi !exemptLocalVars ->
      ()
  | Set (lv, e, _) ->
      checkSet lv e
  | Asm _ ->
      warn "Ignoring asm"

let checkReturn (eo : exp option) : unit =
  let returnType =
    match !curFunc.svar.vtype with
    | TFun (returnType, _, _, _) -> returnType
    | _ -> E.s (bug "Expected function type")
  in
  match eo with
  | Some e ->
      if !verbose then
        E.log "%a: checking return %a\n" d_loc !currentLoc d_exp e;
      (* CIL's casts don't make sense with dependent types, so remove them. *)
      let e' = stripCasts e in
      let ctx = addThisBinding emptyContext e' in
      coerceExp e' (substType ctx returnType)
  | None ->
      if !verbose then
        E.log "%a: checking return\n" d_loc !currentLoc;
      checkSameType returnType voidType

let rec checkStmt (s : stmt) : unit =
  fixStmt s;
  curStmt := s.sid;
  currentLoc := get_stmtLoc s.skind;
  match s.skind with
  | Instr instrs ->
      List.iter checkInstr instrs
  | Return (eo, _) ->
      checkReturn eo
  | If (e, b1, b2, _) ->
      coerceExp e intType;
      checkBlock b1;
      checkBlock b2;
  | Switch (e, b, _, _) ->
      coerceExp e intType;
      checkBlock b
  | Loop (b, _, _, _)
  | Block b -> checkBlock b
  | Goto _
  | Break _
  | Continue _ -> ()
  | TryFinally _
  | TryExcept _ -> E.s (E.unimp "exceptions not supported\n")

and checkBlock (b : block) : unit =
  List.iter checkStmt b.bstmts

let checkTypedef (ti: typeinfo) : unit =
  let ctxThis = addThisBinding emptyContext zero in
  if not (checkType ctxThis ti.ttype) then
    E.s (error "Type of typedef %s is ill-formed" ti.tname)

let checkStruct (ci: compinfo) : unit =
  let ctx =
    List.fold_left
      (fun acc fld -> addBinding acc fld.fname zero)
      (addThisBinding emptyContext zero)
      ci.cfields
  in
  List.iter
    (fun fld ->
       if not (checkType ctx fld.ftype) then
         E.s (error "Field %s of struct %s is ill-formed" fld.fname ci.cname))
    ci.cfields

let checkVar (vi: varinfo) (init: initinfo) : unit =
  let ctxThis = addThisBinding (globalsContext ()) zero in
  if not (checkType ctxThis vi.vtype) then
    E.s (error "Type of global %s is ill-formed" vi.vname);
  if init.init <> None then
    warn "Global variable initializer was not checked"

let checkFundec (fd : fundec) (loc:location) : unit =
  if !verbose then
    E.log "Doing function %s.\n" fd.svar.vname;
  curFunc := fd;
  clearBoundsTable ();
  let ctx = localsContext fd in
  let ctxThis = addThisBinding ctx zero in
  List.iter
    (fun vi ->
       if not (checkType ctxThis vi.vtype) then
         E.s (error "Type of variable %s is ill-formed" vi.vname))
    (fd.slocals @ fd.sformals);
  checkBlock fd.sbody;
  curFunc := dummyFunDec;
  curStmt := -1;
  (* Initialize all locals to 0.  Do this after adding checks *)
  let init: instr list =
    List.map
      (fun vi ->
         let t = unrollType vi.vtype in
         match t with
           TInt _
         | TEnum _
         | TPtr _ ->
             Set(var vi, zero, loc)
         | TFloat _ -> 
             Set(var vi, Const(CReal(0.0, FFloat, None)), loc)
         | TComp _ 
         | TArray _ ->
             Call(None, memset,
                  [mkAddrOf (var vi); zero; SizeOf t],
                  loc)
         | _ -> E.s(bug "Unexpected type %a for local var %s." 
                      d_type t vi.vname))
      fd.slocals
  in
  let init' = mkStmt(Instr init) in
  assignID init';
  fd.sbody.bstmts <- init'::fd.sbody.bstmts;
  ()

(**************************************************************************)

let inferVisitor = object (self)
  inherit nopCilVisitor

  val varBounds : (string, varinfo * varinfo) Hashtbl.t =
    Hashtbl.create 7

  method vtype t =
    let postProcessType (t: typ) =
      if isPointerType t && not (hasAttribute "bounds" (typeAttrs t)) then
        typeAddAttributes [safeAttr] t
      else
        t
    in
    ChangeDoChildrenPost (t, postProcessType)

  method vstmt s =
    (* Make sure each statement contains one instruction only. *)
    begin
      match s.skind with
      | Instr [] -> ()
      | Instr [_] -> ()
      | Instr instrs ->
          s.skind <- Block (mkBlock (List.map mkStmtOneInstr instrs))
      | _ -> ()
    end;
    (* Process individual instructions.  We do this at the statement level
     * because conditionals need to be introduced. *)
    let postProcessStmt (s: stmt) : stmt =
      match s.skind with
      | Instr [] -> s
      | Instr [instr] ->
          begin
            match instr with
            | Set ((Var vi, NoOffset), e, l)
                  when Hashtbl.mem varBounds vi.vname ->
                if !verbose then
                  E.log "%a: inferring for instr %a\n" d_loc l dn_instr instr;
                let baseVar, endVar = Hashtbl.find varBounds vi.vname in
                let t = checkExp e in
                let lo, hi =
                  if isPointerType t then
                    fancyBoundsOfType t
                  else
                    Lval (var vi), Lval (var vi)
                in
                let zeroBlock =
                  mkBlock [mkStmt (Instr [Set (var vi, zero, l);
                                          Set (var baseVar, zero, l);
                                          Set (var endVar, zero, l)])]
                in
                let nonZeroBlock =
                  mkBlock [mkStmt (Instr [Set (var vi, zero, l);
                                          Set (var baseVar, lo, l);
                                          Set (var endVar, hi, l);
                                          instr])]
                in
                if isZero e then
                  mkStmt (Block zeroBlock)
                else
                  mkStmt (If (e, nonZeroBlock, zeroBlock, l))
            | _ ->
                s
          end
      | Instr _ ->
          E.s (bug "Expected one-instruction statements only")
      | _ -> s
    in
    ChangeDoChildrenPost (s, postProcessStmt)
          

  method vfunc fd =
    Hashtbl.clear varBounds;
    curFunc := fd;
    List.iter
      (fun vi ->
         match vi.vtype with
         | TPtr (bt, a) when not (hasAttribute "bounds" a) ->
             let makeBoundVar (suffix: string) : varinfo =
               let boundName = vi.vname ^ suffix in
               let boundParam = ACons (boundName, []) in
               let boundAttr = Attr ("bounds", [boundParam; boundParam]) in
               let boundType = TPtr (bt, boundAttr :: a) in
               makeLocalVar fd boundName boundType
             in
             let baseVar = makeBoundVar "__b" in
             let endVar = makeBoundVar "__e" in
             let boundAttr =
               Attr ("bounds", [ACons (baseVar.vname, []);
                                ACons (endVar.vname, [])])
             in
             vi.vtype <- TPtr (bt, boundAttr :: a);
             Hashtbl.add varBounds vi.vname (baseVar, endVar)
         | _ -> ())
      fd.slocals;
    let cleanup x =
      Hashtbl.clear varBounds;
      curFunc := dummyFunDec;
      x
    in
    ChangeDoChildrenPost (fd, cleanup)

end

(**************************************************************************)

let stripSomeCasts (t: typ) (e: exp) : exp =
  match e with
  | CastE (t', e') ->
      if compareTypes t t' &&
         (compareTypes (typeRemoveAttributes ["bounds"] t')
                       (typeRemoveAttributes ["bounds"] (typeOf e')) || 
          (isPointerType t' && isZero e)) then
        e'
      else
        e
  | _ -> e

let rec expRefersToVar (name: string) (e: exp) : bool =
  match e with
  | Lval lv -> lvalRefersToVar name lv
  | AddrOf lv -> lvalRefersToVar name lv
  | StartOf lv -> lvalRefersToVar name lv
  | SizeOfE e' -> expRefersToVar name e'
  | AlignOfE e' -> expRefersToVar name e'
  | UnOp (_, e', _) -> expRefersToVar name e'
  | BinOp (_, e1, e2, _) -> expRefersToVar name e1 || expRefersToVar name e2
  | CastE (_, e') -> expRefersToVar name e'
  | Const _
  | SizeOf _
  | SizeOfStr _
  | AlignOf _ -> false

and lvalRefersToVar (name: string) ((host, offset): lval) : bool =
  let rec offsetRefersToVar (offset: offset) =
    match offset with
    | Field (fld, offset') -> offsetRefersToVar offset'
    | Index (e, offset') -> expRefersToVar name e || offsetRefersToVar offset'
    | NoOffset -> false
  in
  match host with
  | Var vi -> vi.vname = name || offsetRefersToVar offset
  | Mem e -> expRefersToVar name e || offsetRefersToVar offset

let preProcessVisitor = object (self)
  inherit nopCilVisitor

  method vexpr e =
    match e with
    | Const (CStr str) when !curFunc != dummyFunDec ->
        let t =
          TPtr (charType, [Attr ("nullterm", []);
                           Attr ("bounds", [ACons ("__this", []);
                                            ACons ("__this", [])])])
        in
        let tmp = makeTempVar !curFunc t in
        exemptLocalVars := tmp :: !exemptLocalVars;
        self#queueInstr [Set (var tmp, e, locUnknown)];
        ChangeTo (Lval (var tmp))
    | _ -> DoChildren

  method vinst i = 
    let postProcessInstr (instrs: instr list) : instr list =
      List.fold_right
        (fun instr acc ->
           match instr with
           | Call (ret, fn, args, l) when isAllocator (typeOf fn) ->
               let lv =
                 match ret with
                 | Some lv -> lv
                 | None -> E.s (error "Allocation has no return")
               in
               let t = getAllocationType (typeOfLval lv) (typeOf fn) args in
               let tmp = makeTempVar !curFunc t in
               Call (Some (var tmp), fn, args, l) ::
                 Set (lv, Lval (var tmp), l) ::
                 Set (var tmp, zero, l) ::
                 acc
           | Call (Some (Var vi, NoOffset), fn, args, l) ->
               let rt =
                 match typeOf fn with
                 | TFun (rt, _, _, _) ->
                     if isPointerType rt &&
                        not (hasAttribute "bounds" (typeAttrs rt)) then
                       typeAddAttributes [safeAttr] rt
                     else
                       rt
                 | _ ->
                     E.s (bug "Expected function type")
               in
               let tmp = makeTempVar !curFunc rt in
               Call (Some (var tmp), fn, args, l) ::
                 Set (var vi, Lval (var tmp), l) ::
                 Set (var tmp, zero, l) ::
                 acc
           | Set ((Var vi, NoOffset), e, l) when expRefersToVar vi.vname e ->
               let e' = stripSomeCasts vi.vtype e in
               let t = typeOf e' in
               let tmp = makeTempVar !curFunc t in
               Set (var tmp, e', l) ::
                 Set (var vi, Lval (var tmp), l) ::
                 Set (var tmp, zero, l) ::
                 acc
           | Set (lv, e, l) ->
               Set (lv, stripSomeCasts (typeOfLval lv) e, l) :: acc
           | _ ->
               instr :: acc)
        instrs
        []
    in
    ChangeDoChildrenPost ([i], postProcessInstr)

  method vfunc fd =
    curFunc := fd;
    let cleanup x =
      curFunc := dummyFunDec;
      x
    in
    ChangeDoChildrenPost (fd, cleanup)

end

(**************************************************************************)

let rec getBaseOffset (e: exp) : exp * int =
  match e with
  | BinOp ((PlusPI | IndexPI | MinusPI) as op, e', off, _) ->
      begin
        match getBaseOffset e', isInteger (constFold false off), op with
        | (b, n1), Some n2, (PlusPI | IndexPI) -> b, n1 + (Int64.to_int n2)
        | (b, n1), Some n2, MinusPI -> b, n1 - (Int64.to_int n2)
        | (b, n), _, _ -> e, 0
      end
  | _ -> e, 0

let rec compareExp (e1: exp) (e2: exp) : bool =
  e1 == e2 ||
  match e1, e2 with
  | Lval lv1, Lval lv2
  | StartOf lv1, StartOf lv2
  | AddrOf lv1, AddrOf lv2 -> compareLval lv1 lv2
  | _ -> false

and compareLval (lv1: lval) (lv2: lval) : bool =
  let rec compareOffset (off1: offset) (off2: offset) : bool =
    match off1, off2 with
    | Field (fld1, off1'), Field (fld2, off2') ->
        fld1 == fld2 && compareOffset off1' off2'
    | Index (e1, off1'), Index (e2, off2') ->
        compareExp e1 e2 && compareOffset off1' off2'
    | NoOffset, NoOffset -> true
    | _ -> false
  in
  lv1 == lv2 ||
  match lv1, lv2 with
  | (Var vi1, off1), (Var vi2, off2) ->
      vi1 == vi2 && compareOffset off1 off2
  | (Mem e1, off1), (Mem e2, off2) ->
      compareExp e1 e2 && compareOffset off1 off2
  | _ -> false

let proveLeWithBounds (e1: exp) (e2: exp) : bool =
  let getVarBounds (vi: varinfo) : string option * string option =
    let getBoundString (a: attrparam) : string option =
      match a with
      | ACons (s, []) -> Some s
      | _ -> None
    in
    match getBounds (typeAttrs vi.vtype) with
    | BSimple (lo, hi) -> getBoundString lo, getBoundString hi
    | _ -> None, None
  in
  match e1, e2 with
  | Lval (Var vi1, NoOffset), Lval (Var vi2, NoOffset) ->
      (snd (getVarBounds vi1) = Some vi2.vname) ||
      (fst (getVarBounds vi2) = Some vi1.vname)
  | _ -> false

let proveLe (e1: exp) (e2: exp) : bool =
  let b1, off1 = getBaseOffset e1 in
  let b2, off2 = getBaseOffset e2 in
  (compareExp b1 b2 && off1 <= off2) ||
  (proveLeWithBounds b1 b2 && off1 = 0 && off2 = 0)

let optimizeCheck (c: check) : check list =
  match c with
  | CCoerce (e1, e2, e3, e4, e5)
  | CCoerceN (e1, e2, e3, e4, e5) ->
      if proveLe e1 e2 && proveLe e2 e3 &&
         proveLe e3 e4 && proveLe e4 e5 then
        []
      else
        [c]
  | CBounds (e1, e2, e3, e4) ->
      let e = BinOp (PlusPI, e2, e3, typeOf e2) in
      if proveLe e1 e && proveLe e e4 then
        []
      else
        [c]
  | _ -> [c]

let optimizeVisitor = object (self)
  inherit nopCilVisitor

  method vstmt s =
    let checks = GA.getg allChecks s.sid in
    GA.setg allChecks s.sid (List.flatten (List.map optimizeCheck checks));
    DoChildren

  method vfunc fd =
    curFunc := fd;
    let cleanup x =
      curFunc := dummyFunDec;
      x
    in
    ChangeDoChildrenPost (fd, cleanup)

end


(**************************************************************************)

let checkFile (f: file) : unit =
  List.iter
    (fun global ->
       match global with
       | GVar (vi, _, _) when vi.vstorage = Static ->
           assert vi.vglob;
           staticGlobalVars := vi :: !staticGlobalVars
       | _ -> ())
    f.globals;
  visitCilFileSameGlobals preProcessVisitor f;
  visitCilFileSameGlobals inferVisitor f;
  if !inferFile <> "" then begin
    try
      let inferChannel = open_out !inferFile in
      dumpFile defaultCilPrinter inferChannel !inferFile f;
      close_out inferChannel
    with Sys_error _ ->
      E.s (E.error "Error dumping inference results to %s\n" !inferFile)
  end;
  allowChecks := true;
  List.iter
    (fun global ->
       currentLoc := get_globalLoc global;
       match global with
       | GType (ti, _) -> checkTypedef ti
       | GCompTag (ci, _) when ci.cstruct -> checkStruct ci
       | GVar (vi, init, _) -> checkVar vi init
       | GFun (fd, loc) ->
           checkFundec fd loc;
           ignore (visitCilFunction optimizeVisitor fd)
       | _ -> ())
    f.globals;
  (* Turn the check datastructure into explicit checks, so that they show up
     in the output. *)
  visitCilFileSameGlobals postPassVisitor1 f;
  visitCilFileSameGlobals postPassVisitor2 f;
  f.globals <- (GText "#include <deputy/checks.h>\n\n")::f.globals;
  (* Tell CIL to put comments around the bounds attributes. *)
  print_CIL_Input := false;
  ()

let feature : featureDescr = 
  { fd_name = "Deputy";
    fd_enabled = ref false;
    fd_description = "Typecheck and instrument the program using Deputy.";
    fd_extraopt = [
      "--deputyverbose", Arg.Set verbose,
                         "Enable verbose output for Deputy";
      "--deputyinferout", Arg.Set_string inferFile,
                          "File in which to place Deputy inference results";
    ];
    fd_doit = checkFile;
    fd_post_check = true;
  } 