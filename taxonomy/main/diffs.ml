open Batteries 
open Utils
open Ref
open Unix
open IO
open Enum
open Str
open String
open List
open Globals
open Treediff

module type DataPoint = 
sig

  type t

  val to_string : t -> string
  val compare : t -> t -> int
  val cost : t -> t -> float
  val distance : t -> t -> float
end

module XYPoint =
struct 
  
  type t =
	  { x : int ;
		y : int ; }

  let to_string p = Printf.sprintf "%d,%d\n" p.x p.y
	
  let create x y = { x=x;y=y;}

  let compare p1 p2 = ((p1.x - p2.x) * (p1.x - p2.x)) + ((p1.y - p2.y) * (p1.y - p2.y))
  let cost p1 p2 = float_of_int ((abs (p1.x - p2.x)) + (abs (p1.y - p2.y)))
  let distance p1 p2 =  sqrt (float_of_int (compare p1 p2))
end

module type Diffs =
sig
  type t
	
  (* Takes the url of an svn repository and a start and end revision
   * number, returns an enumeration of diffs that have to do with
   * "fixes", as specified in the log message *)

  val get_diffs : string -> int -> int -> t Set.t
  val load_from_saved : string -> t Set.t
  val save : t Set.t -> string -> unit

  val to_string : t -> string
  val compare : t -> t -> int

  (* cost and distance should both be normalized, and should involve caching. *)
  val cost : t -> t -> float
  val distance : t -> t -> int
end

let check_comments strs = 
  lfoldl
	(fun (all_comment, unbalanced_beginnings,unbalanced_ends) ->
	   fun (diffstr : string) ->
		 let matches_comment_line = Str.string_match star_regexp diffstr 0 in
		 let matches_end_comment = try ignore(Str.search_forward end_comment_regexp diffstr 0); true with Not_found -> false in
		 let matches_start_comment = try ignore(Str.search_forward start_comment_regexp diffstr 0); true with Not_found -> false in
		   if matches_end_comment && matches_start_comment then 
			 (all_comment, unbalanced_beginnings, unbalanced_ends)
		   else 
			 begin
			   let unbalanced_beginnings,unbalanced_ends = 
				 if matches_end_comment && unbalanced_beginnings > 0 
				 then (unbalanced_beginnings - 1,unbalanced_ends) 
				 else if matches_end_comment then unbalanced_beginnings, unbalanced_ends + 1 
				 else  unbalanced_beginnings, unbalanced_ends
			   in
			   let unbalanced_beginnings = if matches_start_comment then unbalanced_beginnings + 1 else unbalanced_beginnings in 
				 all_comment && matches_comment_line, unbalanced_beginnings,unbalanced_ends
			 end)
	(true, 0,0) strs

module Diffs =
struct

  type t = int

  (* this record type is "private" *)
  type rev = {
	revnum : int;
	logmsg : string;
	files : (string * string list) Enum.t;
  }

  (* diff type and initialization *)

  type diff = {
	id : int;
	rev_num : int;
	fname : string;
	msg : string;
	syntactic : string list;
  }

  let diffid = ref 0

  let new_diff revnum fname msg syntactic = 
	{id=(post_incr diffid);rev_num=revnum;fname=fname;msg=msg;syntactic=syntactic}

  let diff_tbl = ref (hcreate 50)

  let to_string diff = 
	let real_diff = hfind !diff_tbl diff in
	let size = List.length real_diff.syntactic
	in
	  Printf.sprintf "Diff %d, rev_num: %d, size: %d\n" real_diff.id real_diff.rev_num size

  let successful = ref 0
  let failed = ref 0
	(* collect diffs is a helper function for get_diffs *)

  let old_fout = Pervasives.open_out "alloldsfs.txt"
  let new_fout = Pervasives.open_out "allnewsfs.txt"

  let collect_diffs rev url =
	pprintf "collect diffs, rev %d\n" rev.revnum; flush stdout;
	let diffcmd = "svn diff -x -uw -r"^(of_int (rev.revnum-1))^":"^(of_int rev.revnum)^" "^url in
	let innerInput = open_process_in ?autoclose:(Some(true)) ?cleanup:(Some(true)) diffcmd in
	let enumInput =  IO.lines_of innerInput in
	let finfos,(lastname,strs) =
	  efold
		(fun (finfos,(fname,strs)) ->
		   fun str ->
			 if (string_match index_regexp str 0) then 
			   begin
				 let split = Str.split space_regexp str in
				 let fname' = hd (tl split) in
				 let ext = 
				   try
					 let base = Filename.chop_extension fname' in
					   String.sub fname' ((String.length base)+1)
						 ((String.length fname') - ((String.length base)+1))
				   with _ -> "" in
				 let fname' =
				   match String.lowercase ext with
				   | "c" | "i" | ".h" | ".y" -> fname'
				   | _ -> "" in
				   ((fname,strs)::finfos),(fname',[])
			   end 
			 else 
			   if (String.is_empty fname) ||
				 (string_match junk str 0) then
				   (finfos,(fname,strs))
			   else (finfos,(fname,str::strs))
		) ([],("",[])) enumInput
	in
	let finfos = List.enum ((lastname,strs)::finfos) in
	let files = efilt (fun (str,_) -> not (String.is_empty str)) finfos in

	  ignore(close_process_in innerInput);
	  let this_files_diffs =
		emap 
		  (fun (str,diff) -> 
			 let syntactic = List.rev diff in
			   pprintf "syntactic: \n";
			   liter (fun x -> pprintf "\t%s\n" x) syntactic;
			   pprintf "end syntactic\n"; flush stdout;

			   let (frst_old,old_file_strs),(frst_new,new_file_strs) = 
				 lfoldl
				   (fun ((current_old,oldfs),(current_new,newfs)) ->
					  fun str ->
						if Str.string_match at_regexp str 0 then ([],current_old::oldfs),([],current_new::newfs)
						else
						  begin
							if Str.string_match plus_regexp str 0 then (current_old,oldfs),(current_new @ [String.lchop str],newfs)
							else if Str.string_match minus_regexp str 0 then (current_old @ [(String.lchop str)],oldfs),(current_new,newfs)
							else (current_old @ [str],oldfs),(current_new @ [str],newfs)
						  end
				   ) (([],[]),([],[])) syntactic 
			   in
				 (* deal with starting in the middle/ending in the middle of comments.  Hack/best effort *)
			   let old_file_strs : string list list = frst_old::old_file_strs in
			   let new_file_strs : string list list = frst_new::new_file_strs in 

			   let as_strings : (string * string) list = 
				 lmap2
				   (fun (oldf : string list) ->
					  fun (newf : string list) -> 
						(* first, see if this change also references property changes *)
						let oldf',newf' = 
						  let prop_regexp = Str.regexp_string "Property changes on:" in 
							if List.exists (fun str -> try ignore(Str.search_forward prop_regexp str 0); true with Not_found -> false) oldf then begin
							  let oldi,newi = 
								fst (List.findi (fun index -> fun str -> try ignore(Str.search_forward prop_regexp str 0); true with Not_found -> false) oldf),
								fst (List.findi (fun index -> fun str -> try ignore(Str.search_forward prop_regexp str 0); true with Not_found -> false) newf)
							  in
								List.take oldi oldf, List.take newi newf
							end else oldf,newf
						in
						  (* next, deal with starting or ending in the middle of a comment *)
						let all_comment,unbalanced_beginnings_old,unbalanced_ends_old = check_comments oldf in
						let all_comment, unbalanced_beginnings_new,unbalanced_ends_new = check_comments newf in

						let oldf'' = 
						  if unbalanced_beginnings_old > 0 || all_comment then oldf' @ ["*/"] else oldf' in
						let newf'' = 
						  if unbalanced_beginnings_new > 0 || all_comment then newf' @ ["*/"] else newf' in
						let oldf''' = 
						  if unbalanced_ends_old > 0 || all_comment then "/*" :: oldf'' else oldf'' in
						let newf''' = 
						  if unbalanced_ends_new > 0 || all_comment then "/*" :: newf'' else newf'' in
						let oldf'''' = 
						  lfoldl
							(fun accum ->
							   fun str ->
								 accum^"\n"^str) "" oldf''' in
						let newf'''' = 
						  lfoldl
							(fun accum ->
							   fun str ->
								 accum^"\n"^str) "" newf''' in
						  (oldf'''',newf'''')
				   ) old_file_strs new_file_strs
			   in
			   let without_empties : (string * string) list = 
				 lfilt (fun (oldf,newf) -> oldf <> "" && newf <> "") as_strings in 
			   let lst = lmap
				 (fun (old_file_str,new_file_str) ->
					Pervasives.output_string old_fout old_file_str;
					Pervasives.output_string new_fout new_file_str;
					Pervasives.output_string old_fout "\nSEPSEPSEPSEP\n";
					Pervasives.output_string new_fout "\nSEPSEPSEPSEP\n";
					Pervasives.flush old_fout;
					Pervasives.flush new_fout;
					try
					  pprintf "oldf: %s\n" old_file_str;
					  pprintf "newf: %s\n" new_file_str; flush stdout;
					  let old_file_tree,new_file_tree =
						fst (Diffparse.parse_from_string old_file_str),
						fst (Diffparse.parse_from_string new_file_str)
					  in
					  let processed_diff = Treediff.tree_diff old_file_tree new_file_tree (Printf.sprintf "%d" !diffid) in
						incr successful; pprintf "%d successes so far\n" !successful; flush stdout;
						new_diff rev.revnum str rev.logmsg (List.rev diff)
					with e -> begin
					  pprintf "Exception in diff processing: %s\n" (Printexc.to_string e); flush stdout;
					  incr failed;
					  pprintf "%d failures so far\n" !failed; flush stdout;
					  (new_diff rev.revnum "" "" [])
					end
				 ) without_empties
			   in List.enum lst
		  ) files in
		Enum.flatten this_files_diffs

  let get_diffs url startrev endrev =
	let logcmd = "svn log "^url^" -r"^(of_int startrev)^":"^(of_int endrev) in
	let proc = open_process_in ?autoclose:(Some(true)) ?cleanup:(Some(true)) logcmd in
	let log = List.of_enum (IO.lines_of proc) in
	let log = List.enum log in 
	let grouped = egroup (fun str -> string_match dashes_regexp str 0) log in
	let filtered =
	  efilt
		(fun enum ->
		   (not (eexists
				   (fun str -> (string_match dashes_regexp str 0)) enum))
		) grouped in
	let all_revs = 
	  emap 
		(fun one_enum ->
		   let first = Option.get (eget one_enum) in
		   let rev_num = int_of_string (string_after (hd (Str.split space_regexp first)) 1) in
			 ejunk one_enum;
			 let logmsg = efold (fun msg -> fun str -> msg^str) "" one_enum in
			   {revnum=rev_num;logmsg=logmsg;files=(Enum.empty())}
		) filtered in
	let only_fixes = 
	  efilt
		(fun rev ->
		   try
			 ignore(search_forward fix_regexp rev.logmsg 0); true
		   with Not_found -> false) all_revs
	in
	let diffs_with_files = 
	  eflat (emap (fun rev -> collect_diffs rev url) only_fixes) 
	in
	let interesting = efilt (fun diff -> not (String.is_empty diff.fname)) diffs_with_files in
	let rec convert_to_set enum set =
	  try
		let ele = Option.get (Enum.get enum) in
		let set' = Set.add ele set in
		  convert_to_set enum set'
	  with Not_found -> set 
	in
	let set = convert_to_set interesting (Set.empty) in
	  pprintf "printing set:\n"; flush stdout;
	  Set.map
		(fun diff -> 
		   let did = diff.id in
			 hadd !diff_tbl did diff; 
			 hadd !diff_tbl did diff; 
			 pprintf "Diff id: %d, rev_num: %d, fname: %s, log_msg: %s, syntactic_diff: "
			   diff.id diff.rev_num diff.fname diff.msg;
			 liter (fun s -> pprintf "%s\n" s) diff.syntactic; flush stdout;
			 did) set
		
  let testcomments filename = 
	let fin = open_in filename in
	let lines = List.of_enum (IO.lines_of fin) in
	let all_comment,unbalanced_ends,unbalanced_beginnings = check_comments lines in 
	  pprintf "Lines are:\n";
	  liter (fun str -> pprintf "%s\n" str) lines;
	  if all_comment then pprintf "All comment!\n" else pprintf "Not all comment!\n";
	  pprintf "unbalanced ends: %d, unbalanced beginnings: %d\n" unbalanced_ends unbalanced_beginnings; flush stdout
	  
  let save diffset filename = 
	let fout = open_out_bin filename in
	  Marshal.output fout diffset;
	  Marshal.output fout !diff_tbl;
	  close_out fout

  let load_from_saved filename = 
	let fin = open_in_bin filename in 
	let set = Marshal.input fin in
	  diff_tbl := Marshal.input fin;
	  set

  let compare diff1 diff2 = Pervasives.compare diff1 diff2

  let cost_hash = hcreate 10
  let distance_hash = hcreate 10
  let size_hash = hcreate 10

  let cost diff1 diff2 = 
	ht_find cost_hash (diff1,diff2)
	  (fun x ->
		 let size1 = 
		   ht_find size_hash diff1 
			 (fun y -> 
				let real_diff1 = hfind !diff_tbl diff1 in
				List.length real_diff1.syntactic)
		 in
		 let size2 = 
		   ht_find size_hash diff2
			 (fun y -> 
				let real_diff2 = hfind !diff_tbl diff2 in
				List.length real_diff2.syntactic)
		 in
		 float_of_int (abs (size1 - size2))
	  )
	
  let distance diff1 diff2 = 
	ht_find distance_hash (diff1,diff2)
	  (fun x ->
		 let size1 = 
		   ht_find size_hash diff1 
			 (fun y -> 
				let real_diff1 = hfind !diff_tbl diff1 in
				List.length real_diff1.syntactic)
		 in
		 let size2 = 
		   ht_find size_hash diff2
			 (fun y -> 
				let real_diff2 = hfind !diff_tbl diff2 in
				List.length real_diff2.syntactic)
		 in
		   float_of_int (abs(size1 - size2))
	  )
	  

end
