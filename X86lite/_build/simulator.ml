(* X86lite Simulator *)

(* See the documentation in the X86lite specification, available on the 
   course web pages, for a detailed explanation of the instruction
   semantics.
*)

open X86

(* simulator machine state -------------------------------------------------- *)
let mem_bot = 0x400000L          (* lowest valid address *)
let mem_top = 0x410000L          (* one past the last byte in memory *)
let mem_size = Int64.to_int (Int64.sub mem_top mem_bot)
let nregs = 17                   (* including Rip *)
let ins_size = 8L                (* assume we have a 8-byte encoding *)
let exit_addr = 0xfdeadL         (* halt when m.regs(%rip) = exit_addr *)

(* Your simulator should raise this exception if it tries to read from or
   store to an address not within the valid address space. *)
exception X86lite_segfault


type sbyte = InsB0 of ins       (* 1st byte of an instruction *)
           | InsFrag            (* 2nd - 7th bytes of an instruction *)
           | Byte of char       (* non-instruction byte *)

(* memory maps addresses to symbolic bytes *)
type mem = sbyte array

(* Flags for condition codes *)
(*     mutable: 
				fo := 1
				a := fo
				fo := 0
				=> a = 0 
*)
type flags = { mutable fo : bool    (* rip *)
             ; mutable fs : bool
             ; mutable fz : bool
             }

(* Register files *)
type regs = int64 array

(* Complete machine state *)
type mach = { flags : flags  (*  fo fs fz  *)
            ; regs : regs  (* int64 array  representing registers *)
            ; mem : mem   (* sbyte array,   [ InsB0 (Decq,  [~%Rdi]), InsFrag, InsFrag, InsFrag ] *)
            }

(* simulator helper functions ----------------------------------------------- *)

(* The index of a register in the regs array *)
let rind : reg -> int = function
  | Rip -> 16   (* a virtual register, points to the current instruction *)
  | Rax -> 0    (* general purpose accumulator *) 
  | Rbx -> 1    (* base register, pointer to data *) 
  | Rcx -> 2    (* counter register for strings and loops *) 
  | Rdx -> 3    (* data register for IO *)
  | Rsi -> 4    (* pointer register, string source register *)
  | Rdi -> 5    (* pointer register, string destination register *)
  | Rbp -> 6    (* base pointer, points to the stack frame *)
  | Rsp -> 7    (* stack pointer, points to the top of the stack *)
  | R08 -> 8    (* general purpose register *)
  | R09 -> 9   
  | R10 -> 10 
  | R11 -> 11
  | R12 -> 12 
  | R13 -> 13 
  | R14 -> 14 
  | R15 -> 15

(* Helper functions for reading/writing sbytes *)

(* Convert an int64 to its sbyte representation *)
let sbytes_of_int64 (i:int64) : sbyte list =
  let open Char in 
  let open Int64 in
  List.map (fun n -> Byte (shift_right i n |> logand 0xffL |> to_int |> chr))
           [0; 8; 16; 24; 32; 40; 48; 56]

(* Convert an sbyte representation to an int64 *)
let int64_of_sbytes (bs:sbyte list) : int64 =
  let open Char in
  let open Int64 in
  let f b i = match b with
    | Byte c -> logor (shift_left i 8) (c |> code |> of_int)
    | _ -> 0L
  in
  List.fold_right f bs 0L

(* Convert a string to its sbyte representation *)
let sbytes_of_string (s:string) : sbyte list =
  let rec loop acc = function
    | i when i < 0 -> acc
    | i -> loop (Byte s.[i]::acc) (pred i)
  in
  loop [Byte '\x00'] @@ String.length s - 1

(* Serialize an instruction to sbytes *)
let sbytes_of_ins (op, src:ins) : sbyte list =
  let check = 
   function
    | Imm (Lbl _) 
    | Ind1 (Lbl _) 
    | Ind3 (Lbl _, _) -> invalid_arg "sbytes_of_ins: tried to serialize a label!"
    | o -> ()
  in
    List.iter check src; 
    [InsB0 (op, src); InsFrag; InsFrag; InsFrag; InsFrag; InsFrag; InsFrag; InsFrag]

(* Serialize a data element to sbytes *)
let sbytes_of_data : data -> sbyte list = 
function
  | Quad (Lit i) -> sbytes_of_int64 i
  | Asciz s -> sbytes_of_string s
  | Quad (Lbl _) -> invalid_arg "sbytes_of_data: tried to serialize a label!"


(* It might be useful to toggle printing of intermediate states of your 
   simulator. *)
let debug_simulator = ref false

(* 
		Interpret a condition code with respect to the given flags. 
*)
let interp_cnd {fo; fs; fz} : cnd -> bool = 
	function 
	| Eq -> fz 
	| Neq -> not fz
	| Lt -> (fs <> fo)     
	| Le -> not ((fs == fo) & (not fz))    (*   fs <> fo | fz  *)
	| Gt -> (fs == fo) & (not fz)    (*  not Le  *)
	| Ge ->  (fs == fo) 


(* Maps an X86lite address into Some OCaml array index,
   or None if the address is not within the legal address space. *)
let map_addr (addr:quad) : int option =
	if (addr < mem_top) && (addr >= mem_bot) then Some(Int64.to_int (Int64.sub addr mem_bot))
		else None


(* 
    Simulates one step of the machine:
    - fetch the instruction at %rip
    - compute the source and/or destination information from the operands
    - simulate the instruction semantics
    - update the registers and/or memory appropriately

    - set the condition flags
*)
   

(* let setflagsresultnonzero (m:mach) (result:int64) (condition:bool) : unit =  *)

let setflags (m:mach) (myOpcode:opcode) (srcnum:int64) (destnum:int64): unit =

 begin
   match myOpcode with
    | Addq 
    | Incq ->
      begin
        let result = Int64.add destnum srcnum in
          begin
            match (Int64.equal result 0L) with
            | true -> 
                  m.flags.fz <- true;
                  m.flags.fs <- false;
                  m.flags.fo <- false;

            | false -> 
                  m.flags.fz <- false;

                  begin 
                      match (Int64.compare result 0L) < 0 with
                      | true ->   
                  			m.flags.fs <- true;   
                          if ( Int64.compare srcnum 0L) > 0 &&  ( Int64.compare destnum 0L) > 0
                            then m.flags.fo <- true 
                              else m.flags.fo <- false;

                      | false -> 
                  			m.flags.fs <- false;
                          if ( Int64.compare srcnum 0L) < 0 &&  ( Int64.compare destnum 0L) < 0
                            then m.flags.fo <- true 
                              else m.flags.fo <- false; 
                  end 
          end
        end (* Addq, Incq *)

    | Imulq ->
      begin
        let result = Int64.mul srcnum destnum in
          let twotothesixtythree = (Int64.shift_left 1L 63) in 
            let neg_twotothesixtythree = (Int64.mul twotothesixtythree (-1L)) in 
              let neg_twotothesixtythree_minone = (Int64.add twotothesixtythree (-1L)) in
                let negcond = Int64.compare neg_twotothesixtythree_minone result in
                  if negcond < 0
                    then m.flags.fo <- true
                      else m.flags.fo <- false;
        let twotothesixtyfour = (Int64.shift_left 1L 64) in 
          let poscond = Int64.compare twotothesixtyfour result in
              if poscond > 0
                then m.flags.fo <- true
                  else m.flags.fo <- false;
      end (* Imulq *)

    | Xorq -> 	  
      begin
    		let result = Int64.logxor destnum srcnum in
    		begin
      		match (Int64.equal result 0L) with
            | true -> 
                  m.flags.fz <- true;
                  m.flags.fs <- false;
                  m.flags.fo <- false;

            | false -> 
                  if (Int64.compare result 0L) < 0
                   then m.flags.fs <- true 
                    else m.flags.fs <- false;
                  m.flags.fo <- false;
                  m.flags.fz <- false;

          end
      end  (* Orq *)	

    | Orq -> 
      begin
    		let result = Int64.logor destnum srcnum in
          begin
            match (Int64.equal result 0L) with
            | true -> 
                  m.flags.fz <- true;
                  m.flags.fs <- false;
                  m.flags.fo <- false;

            | false -> 
                  if (Int64.compare result 0L) < 0
                   then m.flags.fs <- true 
                    else m.flags.fs <- false;
                  m.flags.fo <- false;
                  m.flags.fz <- false;

          end
      end  (* Orq *)

    | Andq -> 

      begin
    		let result = Int64.logand destnum srcnum in

          begin
            match (Int64.equal result 0L) with
            | true -> 
                  m.flags.fz <- true;
                  m.flags.fs <- false;
                  m.flags.fo <- false;

            | false -> 
                  if (Int64.compare result 0L) < 0
                   then m.flags.fs <- true 
                    else m.flags.fs <- false;
                  m.flags.fo <- false;
                  m.flags.fz <- false;
          end
      end (* Andq *)


     (* The OF flag is set to 0 if the shift amount is 1 (and is otherwise unaffected).*)     
     | Sarq ->

      begin

        if (Int64.equal srcnum 1L) then m.flags.fo <- false;

        if srcnum != 0L then
          let result = Int64.shift_right destnum (Int64.to_int srcnum) in
            begin
              match (Int64.equal result 0L) with
              | true -> 
                    m.flags.fz <- true;
                    m.flags.fs <- false;

              | false -> 
                    if (Int64.compare result 0L) < 0
                      then m.flags.fs <- true 
                        else m.flags.fs <- false;
                    m.flags.fz <- false;
            end
      end (* Sarq *)


    (* OF is set if the top two bits of DEST are different and the shift amount is 1 *)
    | Shlq -> 
      begin 
        if (Int64.equal srcnum 1L) then 
           let dropfirstmostsigbit = Int64.shift_left destnum 1 in
           let secondmostsigbit = Int64.shift_left dropfirstmostsigbit (Int64.to_int 0xefffffffL) in 
           let mostsigbit = Int64.shift_right_logical destnum (Int64.to_int 0xeffffffL) in
              if not (Int64.equal mostsigbit secondmostsigbit)
                then m.flags.fo <- true;

        (*
           (Int64.equal (Int64.logand 0xc0000000 destnum) 0xc0000000) &&
           (Int64.equal (Int64.logand 0xc0000000 destnum) 0x00000000) 
        *)
        if (not (Int64.equal srcnum 1L)) then
          let result = Int64.shift_left destnum (Int64.to_int srcnum) in
            begin
              match (Int64.equal result 0L) with
              | true -> 
                    m.flags.fz <- true;
                    m.flags.fs <- false;

              | false -> 
                    if (Int64.compare result 0L) < 0
                      then m.flags.fs <- true 
                        else m.flags.fs <- false;
                    m.flags.fz <- false;
            end
      end (* Shlq *)

     
         (* Flags are set as in the shlq instruction, where OF is set to the most-significant 
          bit of the original operand if the shift amount is 1 (and is otherwise unaffected) *)
  
      | Shrq -> 
        begin 
          if (Int64.equal srcnum 1L) 
             then let mostsigbit = Int64.shift_right_logical destnum (Int64.to_int 0xeffffffL) in
                begin
                  if (Int64.equal mostsigbit 1L) 
                    then m.flags.fo <- true
                      else m.flags.fo <- false
                end;

          if (not (Int64.equal srcnum 0L)) then
            begin 

              let result = Int64.shift_right_logical destnum (Int64.to_int srcnum) in
                begin
                  match (Int64.equal result 0L) with
                  | true -> 
                        m.flags.fz <- true;
                        m.flags.fs <- false;

                  | false -> 
                        if (Int64.compare result 0L) < 0
                         then m.flags.fs <- true 
                          else m.flags.fs <- false;
                        m.flags.fz <- false;
                end
            end 
          end (* Shrq *)

    | Notq -> 
  			let result = Int64.neg destnum in
          begin
            match (Int64.equal result 0L) with
            | true -> 
                  m.flags.fz <- true;
                  m.flags.fs <- false;
                  m.flags.fo <- false;

            | false -> 
                  if (Int64.compare result 0L) < 0
                   then m.flags.fs <- true 
                    else m.flags.fs <- false;
                  m.flags.fo <- false;
                  m.flags.fz <- false;

          end (* Notq *)

    | Negq -> 
    		let result = Int64.mul srcnum (-1L) in
          begin
            match (Int64.equal result 0L) with
              | true -> 
                	begin
                    m.flags.fz <- true;
                    m.flags.fs <- false;
                    m.flags.fo <- false;
                  end

		          | false -> 
                  begin 
                    m.flags.fz <- false;

                    if (Int64.compare result 0L) > 0
                      then m.flags.fs <- false
                        else m.flags.fs <- true;

                    if (Int64.equal result Int64.min_int)
                      then m.flags.fo <- true
                        else m.flags.fo <- false;
                  end
	        end (* Negq *)

    | Popq
    | Movq  
    | Leaq -> 
    		let result = srcnum in
          begin
            match (Int64.equal result 0L) with
            | true -> 
           		begin
                m.flags.fz <- true;
                m.flags.fs <- false;
                m.flags.fo <- false;
              end

            | false -> 
            	begin
                if (Int64.compare result 0L) < 0 
                  then m.flags.fs <- true 
                    else m.flags.fs <- false;
                m.flags.fo <- false;
                m.flags.fz <- false;
              end
          end (* Popq, Movq, Leaq *)

  (*Cmp q compares using subtraction and sets flags accordingly but doesn't change destination *)
    | Decq
    | Subq 
    | Cmpq -> 

      let result = Int64.sub destnum srcnum in
        begin
          match (Int64.equal result 0L) with
            | true -> 
           		begin
                m.flags.fz <- true;
                m.flags.fs <- false;
                m.flags.fo <- false;
              end

            | false -> 
            begin
                m.flags.fz <- false;
              	begin 
                  match (Int64.compare result 0L) < 0 with
                  | true ->  
                    begin   
            			    m.flags.fs <- true;
                      if ((Int64.compare srcnum  0L) > 0 && ( Int64.compare destnum 0L) < 0)
                         || (Int64.equal srcnum Int64.min_int)
                      then m.flags.fo <- true 
                      else m.flags.fo <- false;
                    end

                  | false -> 
                    begin
                			m.flags.fs <- false;
                      if ((Int64.compare srcnum 0L) < 0 && ( Int64.compare destnum 0L) > 0)
                         || (Int64.equal srcnum Int64.min_int)
                      then m.flags.fo <- true 
                      else m.flags.fo <- false;
                    end
                end 
            end 
        end (* Decq, Subq, Cmpq *)

	end (* function setflags *)


let mapaddr_toint(num:int64): int =
   let addr = map_addr num in
   begin match addr with | Some z -> z | _ -> failwith "invalid Option Integer" end


let setind1 (m:mach) (lit_n_in_ind1:int64): int64 =
    let sbyte4 = m.mem.(mapaddr_toint lit_n_in_ind1) in 
    (int64_of_sbytes [sbyte4])

let setind2 (m:mach) (ind2:reg): int64 =
    let tmp1 = m.regs.(rind ind2) in 
    let sbyte4 = m.mem.(mapaddr_toint tmp1) in
    (int64_of_sbytes [sbyte4])

let setind3 (m:mach) (n2:int64) (ind3:reg) : int64 = 
    let tmp1 = m.regs.(rind ind3) in 
    let addr = Int64.add tmp1 n2 in
    let intaddr = mapaddr_toint addr in
    let sbyte4 = m.mem.(intaddr) in
    (int64_of_sbytes [sbyte4])

let setopcode (m:mach) (myOpcode:opcode) (srcnum:int64) (destnum:int64) :int64 = 
  begin
    match myOpcode with
    | Movq -> srcnum
    | Addq -> setflags m myOpcode srcnum destnum; Int64.add srcnum destnum 
    | Subq -> setflags m myOpcode srcnum destnum; Int64.sub destnum srcnum
    | Imulq -> setflags m myOpcode srcnum destnum; Int64.mul srcnum destnum
    | Xorq -> setflags m myOpcode srcnum destnum; Int64.logxor srcnum destnum
    | Orq -> setflags m myOpcode srcnum destnum; Int64.logor srcnum destnum
    | Andq -> setflags m myOpcode srcnum destnum; Int64.logand srcnum destnum
    | Shlq -> setflags m myOpcode srcnum destnum; Int64.shift_left destnum (Int64.to_int srcnum)
    | Shrq -> setflags m myOpcode srcnum destnum; 
              Int64.shift_right_logical destnum (Int64.to_int srcnum)
    | Sarq -> setflags m myOpcode srcnum destnum; Int64.shift_right destnum (Int64.to_int srcnum)
    | Incq -> setflags m myOpcode 1L destnum; Int64.add destnum 1L 
    | Decq -> setflags m myOpcode 1L destnum; Int64.sub destnum 1L 
    | Notq -> setflags m myOpcode srcnum destnum; Int64.neg destnum
    | Negq -> setflags m myOpcode srcnum destnum;  Int64.mul srcnum (-1L) 
    | Leaq -> setflags m myOpcode srcnum destnum; srcnum
    | Popq -> setflags m myOpcode srcnum destnum; srcnum
    (*Cmp q compares using subtraction and sets flags accordingly but doesn't change destination *)
    | Cmpq -> setflags m myOpcode srcnum destnum ; destnum
  end


  let rec loop (m:mach)(index:int64)(sl:sbyte list): sbyte list =
  begin
    match sl with
    | head::rst -> 
      begin
        match head with
        | Byte c ->
          (Printf.printf "********* Byte %C\n" c); 
          let intaddr = Int64.to_int index in
            m.mem.(intaddr) <- head;
          loop m (Int64.add index 1L) rst
        | _ -> []
      end
    | [] -> []
  end


let setreg2 (m:mach) (myOpcode:opcode) (num:int64) (dest:operand) : unit =
  begin 
    match dest with
    | Reg regImm -> let finregnum = m.regs.(rind regImm) in 
                      m.regs.(rind regImm) <- setopcode m myOpcode num finregnum  

    | Ind2 ind2 ->  
            let finregnum = setind2 m ind2 in
              let x = setopcode m myOpcode num finregnum in
                let sbytelist = sbytes_of_int64(x) in
                  loop m finregnum sbytelist; ()

    | Ind3 (imm3,reg3) -> 
      begin 
        match imm3 with
        | Lit n3 -> 
                (Printf.printf "********* entered loop \n"); 
                let finregnum = setind3 m n3 reg3 in
                  let x = setopcode m myOpcode num finregnum in
                    let sbytelist = sbytes_of_int64(x) in
                          loop m finregnum sbytelist; ()        

        | Lbl s3 -> failwith "Lbl instead of Lit" 
      end    
    | _ -> failwith "invalid destination" 
  end

let rest (lst: 'a list) : 'a list = 
  match lst with 
  | [] -> []
  | head::rst -> rst


  let head (lst: 'a list) : 'a = 
    match lst with 
    | [] -> []
    | hd::rst -> hd


let dispatchopcode (m:mach) (myOpcode:opcode) (num:int64) (dest:operand) : unit =

  begin
    match myOpcode with
    | Pushq -> m.regs.(rind Rsp) <- Int64.sub m.regs.(rind Rsp) 8L;
               let replacementArray = Array.of_list (sbytes_of_int64 num) in
               Array.blit replacementArray 0 m.mem (Int64.to_int m.regs.(rind Rsp)) 1;

    | Jmp -> m.regs.(rind Rip) <- num;
    (* 
        Callq src
            Pushq rip
            Jmp src
    *)
    | Callq -> m.regs.(rind Rsp) <- Int64.sub m.regs.(rind Rsp) 8L;
               let replacementArray = Array.of_list (sbytes_of_int64 m.regs.(rind Rip)) in
               Array.blit replacementArray 0 m.mem (Int64.to_int m.regs.(rind Rsp)) 1;
               m.regs.(rind Rip) <- num;

    | _ -> setreg2 m myOpcode num dest

  end

        

(*set source for two registered opcodes like moveq, addq, ... *)
let setsrctworegop (m:mach) (myOpcode:opcode) (src:operand) (dest:operand) :unit =

  begin
    match src with
    | Imm imm -> 
      begin
        match imm with
        | Lbl str -> failwith "Lbl instead of Lit" 
        | Lit num -> dispatchopcode m myOpcode num dest
      end
    | Reg reg1 -> 
        let num = m.regs.(rind reg1) in
            dispatchopcode m myOpcode num dest

    | Ind1 imm1 -> 
      begin
        match imm1 with
        | Lbl s4 -> failwith "Lbl instead of Lit" 
        | Lit n4 ->
              let num = setind1 m n4 in
                dispatchopcode m myOpcode num dest     
      end
    | Ind2 reg2 -> 
                  let num = setind2 m reg2 in
                    dispatchopcode m myOpcode num dest

    | Ind3 (imm3, reg3) ->
      begin 
        match imm3 with
         | Lbl s33 -> failwith "Lbl instead of Lit" 
         | Lit n33 ->
              let num = setind3 m n33 reg3 in
                dispatchopcode m myOpcode num dest
      end 
  end

let check_amt_imm_or_rcx_op (m:mach) (myOpcode:opcode) (src:operand) (dest:operand) :unit =

      begin
          match src with
            | Imm imm -> 
              begin
                match imm with
                | Lbl str -> failwith "Lbl instead of Lit" 
                | Lit num -> dispatchopcode m myOpcode num dest
              end
            | Reg reg1 -> 
              if reg1 == Rcx then
                  let num = m.regs.(rind reg1) in
                  dispatchopcode m myOpcode num dest
              else failwith "shift amount wrong register" 

            | Ind1 imm1 -> 
                begin
                  match imm1 with
                  | Lbl s4 -> failwith "Lbl instead of Lit" 
                  | Lit n4 ->
                        let num = setind1 m n4 in
                        dispatchopcode m myOpcode num dest
                          
                end
            | Ind2 reg2 -> 
                if reg2 == Rcx 
                  then let num = setind2 m reg2 in
                        dispatchopcode m myOpcode num dest
                else failwith "shift amount wrong register" 

            | Ind3 (imm3, reg3) ->
              if reg3 == Rcx then
                 begin 
                      match imm3 with
                       | Lbl s33 -> failwith "Lbl instead of Lit" 
                       | Lit n33 ->
                            let num = setind3 m n33 reg3 in
                            dispatchopcode m myOpcode num dest
                  end 
              else failwith "shift amount wrong register" 
      end

let tworeginsupdate (m:mach) (myOpcode:opcode) (src:operand) (dest:operand) : unit = 
  begin
    match myOpcode with
    | Jmp 
    | Callq -> setsrctworegop m myOpcode src dest
    | Popq -> let addr = mapaddr_toint m.regs.(rind Rsp) in
              let sbyte = m.mem.(addr) in 
              let num = int64_of_sbytes [sbyte] in
              setreg2 m myOpcode num dest;
              m.regs.(rind Rsp) <- Int64.add m.regs.(rind Rsp) 8L;
              m.regs.(rind Rip) <- Int64.add m.regs.(rind Rip) 8L;
    | Shlq 
    | Shlq
    | Sarq -> check_amt_imm_or_rcx_op m myOpcode src dest;
              m.regs.(rind Rip) <- (Int64.add m.regs.(rind Rip) 8L);
    | _ -> 
           setsrctworegop m myOpcode src dest;        
           m.regs.(rind Rip) <- (Int64.add m.regs.(rind Rip) 8L);
  end

let step (m:mach): unit =     (*    m.flags    m.regs    m.mem    *)
  let tmp1 = m.regs.(rind Rip) in 
  let intaddr = mapaddr_toint tmp1 in 
  let sbyte4 = m.mem.(intaddr) in
  
  begin
    match sbyte4 with 
    | Byte chara -> m.regs.(rind Rip) <- (Int64.add m.regs.(rind Rip) 8L) 
    | InsFrag -> m.regs.(rind Rip) <- (Int64.add m.regs.(rind Rip) 8L)
    | InsB0 (op, []) -> 

        (***************************   RET DONE  *************************************)
        begin 
          match op with
          | Retq -> tworeginsupdate m Popq (Ind2 Rsp) (Reg Rip)
          | _ -> failwith "invalid sbyte"
        end

    | InsB0 (op, src::[]) -> 
      begin 
        match op with

        (*******************************   PUSH DONE   *******************************)

        | Pushq -> tworeginsupdate m Pushq src src

        (*******************************   POP  DONE  ********************************)

        | Popq -> tworeginsupdate m Popq src src

        (*******************************   Increment DONE  ***************************)

        | Incq -> tworeginsupdate m Incq src src

        (******************************     Decrement DONE    ************************)

        | Decq -> tworeginsupdate m Decq src src
      
        (***********************   One's Complement DONE *****************************)

        | Notq -> tworeginsupdate m Notq src src

        (*******************   Two's Complement  DONE  *******************************)

        | Negq -> tworeginsupdate m Negq src src

        (**************************** JMP DONE   *************************************)
        
        | Jmp -> setsrctworegop m Jmp src src

        (*******************************   CALL DONE  ********************************)

        | Callq -> setsrctworegop m Callq src src

        (****************************   Jump Condition DONE   ************************)

        | J c -> if (interp_cnd m.flags c) 
                  then setsrctworegop m Jmp src src

        (******************************  Jump Condition DONE *************************)

        | Set s -> if (interp_cnd m.flags s) 
                    then dispatchopcode m Movq 1L src
                      else dispatchopcode m Movq 0L src;
               
      end  (*   | InsB0 (op, src::[])  *)

    | InsB0 (op, src::dest::[]) ->  
        
      begin 
        match op with 

        (****************************************   MOV DONE   ***********************************)

        | Movq -> tworeginsupdate m Movq src dest

        (****************************************   LEA DONE   ***********************************)

        | Leaq -> 
          begin
            match src with
              | Imm imm -> 
                begin
                  match imm with
                  | Lbl s -> failwith "Lbl instead of Lit" 
                  | Lit n -> tworeginsupdate m Movq (Ind1 imm) dest
                end

              | Reg reg1 -> tworeginsupdate m Movq (Ind2 reg1) dest
              | Ind1 imm1 -> 
                begin
                  match imm1 with
                  | Lbl s -> failwith "Lbl instead of Lit" 
                  | Lit n -> tworeginsupdate m Movq (Ind1 (Lit (setind1 m n))) dest     
                end

              | Ind2 reg2 -> tworeginsupdate m Movq (Ind1 (Lit (setind2 m reg2))) dest

              | Ind3 (imm3,reg3) -> 
                begin 
                  match imm3 with
                  | Lbl s -> failwith "Lbl instead of Lit" 
                  | Lit n -> tworeginsupdate m Movq (Ind1 (Lit (setind3 m n reg3))) dest
                end 
          end

        (****************************************   ADD DONE   ***********************************)

        | Addq -> tworeginsupdate m Addq src dest

        (****************************************   SUB DONE   ***********************************)

        | Subq -> tworeginsupdate m Subq src dest

        (****************************************   MUL DONE   ***********************************)

        | Imulq -> tworeginsupdate m Imulq src dest

        (****************************************   XOR DONE   ***********************************)

        | Xorq -> tworeginsupdate m Xorq src dest

        (****************************************   OR DONE   ************************************)

        | Orq -> tworeginsupdate m Orq src dest

        (****************************************   AND DONE   ***********************************)

        | Andq -> tworeginsupdate m Andq src dest

        (*****************   Shl (left shift both arithmetic and logical)  DONE  **** ************)

        | Shlq -> tworeginsupdate m Shlq src dest

        (****************************************   Sar DONE   ***********************************)

        | Sarq -> tworeginsupdate m Sarq src dest

        (****************************************  Shr DONE   ************************************)

        | Shrq -> tworeginsupdate m Shrq src dest

        (****************************************   CMP DONE   ***********************************)                                          
      
        | Cmpq -> tworeginsupdate m Cmpq src dest

    end  (* InsB0 (op, src::dest::[]) *)

end  (*   step   *)

(* Runs the machine until the rip register reaches a designated
memory address. *)
let run (m:mach) : int64 = 
  while m.regs.(rind Rip) <> exit_addr do step m done;
  m.regs.(rind Rax)

(* assembling and linking --------------------------------------------------- *)

(* A representation of the executable *)
type exec = 
{ 
    entry    : quad              (* address of the entry point *)
  ; text_pos : quad              (* starting address of the code *)
  ; data_pos : quad              (* starting address of the data *)
  ; text_seg : sbyte list        (* contents of the text segment *)
  ; data_seg : sbyte list        (* contents of the data segment *)
}

(* Assemble should raise this when a label is used but not defined *)
exception Undefined_sym of lbl

(* Assemble should raise this when a label is defined more than once *)
exception Redefined_sym of lbl

(* Convert an X86 program into an object file:
- separate the text and data segments
- compute the size of each segment
Note: the size of an Asciz string section is (1 + the string length)

- resolve the labels to concrete addresses and 'patch' the instructions to 
replace Lbl values with the corresponding Imm values.

- the text segment starts at the lowest address
- the data segment starts after the text segment

HINT: List.fold_left and List.fold_right are your friends.
*)
let assemble (p:prog) : exec =
failwith "assemble unimplemented"

(* Convert an object file into an executable machine state. 
    - allocate the mem array
    - set up the memory state by writing the symbolic bytes to the 
      appropriate locations 
    - create the inital register state
      - initialize rip to the entry point address
      - initializes rsp to the last word in memory 
      - the other registers are initialized to 0
    - the condition code flags start as 'false'

  Hint: The Array.make, Array.blit, and Array.of_list library functions 
  may be of use.
*)
let load {entry; text_pos; data_pos; text_seg; data_seg} : mach = 
failwith "load unimplemented"
