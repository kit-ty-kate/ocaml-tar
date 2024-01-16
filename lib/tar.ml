(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 * Copyright (C)      2012 Thomas Gazagnaire <thomas@ocamlpro.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type error = [ `Checksum_mismatch | `Corrupt_pax_header | `Zero_block | `Unmarshal of string ]

let pp_error ppf = function
  | `Checksum_mismatch -> Format.fprintf ppf "checksum mismatch"
  | `Corrupt_pax_header -> Format.fprintf ppf "corrupt PAX header"
  | `Zero_block -> Format.fprintf ppf "zero block"
  | `Unmarshal e -> Format.fprintf ppf "unmarshal %s" e

let ( let* ) = Result.bind

(** Process and create tar file headers *)
module Header = struct
  (** Map of field name -> (start offset, length) taken from wikipedia:
      http://en.wikipedia.org/w/index.php?title=Tar_%28file_format%29&oldid=83554041 *)

  let trim_numerical s =
    String.(trim (map (function '\000' -> ' ' | x -> x) s))

  (** Unmarshal an integer field (stored as 0-padded octal) *)
  let unmarshal_int ~off ~len x =
    let tmp = "0o0" ^ (trim_numerical (String.sub x off len)) in
    try
      Ok (int_of_string tmp)
    with Failure msg ->
      Error (`Unmarshal (Printf.sprintf "%s: failed to parse integer %S" msg tmp))

  (** Unmarshal an int64 field (stored as 0-padded octal) *)
  let unmarshal_int64 ~off ~len x =
    let tmp = "0o0" ^ (trim_numerical (String.sub x off len)) in
    try
      Ok (Int64.of_string tmp)
    with Failure msg ->
      Error (`Unmarshal (Printf.sprintf "%s: failed to parse int64 %S" msg tmp))

  (** Unmarshal a string *)
  let unmarshal_string ?(off = 0) ?len x =
    let len = Option.value ~default:(String.length x - off) len in
    try
      let first_0 = String.index_from x off '\000' in
      if first_0 - off < len then
        Ok (String.sub x off (first_0 - off))
      else
        raise Not_found
    with Not_found ->
      Ok (String.sub x off len)

  (** Marshal an integer field of size 'n' *)
  let marshal_int x n =
    let octal = Printf.sprintf "%0*o" (n - 1) x in
    octal ^ "\000" (* space or NULL allowed *)

  (** Marshal an int64 field of size 'n' *)
  let marshal_int64 x n =
    let octal = Printf.sprintf "%0*Lo" (n - 1) x in
    octal ^ "\000" (* space or NULL allowed *)

  (** Marshal an string field of size 'n' *)
  let marshal_string x n =
    if String.length x < n then
      let bytes = Bytes.make n '\000' in
      Bytes.blit_string x 0 bytes 0 (String.length x);
      Bytes.unsafe_to_string bytes
    else
      x

  (** Unmarshal a pax Extended Header File time
      It can contain a <period> ( '.' ) for sub-second granularity, that we ignore.
      https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html#tag_20_92_13_05 *)
  let unmarshal_pax_time x =
    try
      match String.split_on_char '.' x with
      | [seconds] -> Ok (Int64.of_string seconds)
      | [seconds; _subseconds] -> Ok (Int64.of_string seconds)
      | _ -> raise (Failure "Wrong pax Extended Header File time format (at most one . allowed)")
    with Failure msg ->
      Error (`Unmarshal (Printf.sprintf "Failed to parse pax time %S (%s)" x msg))

  let hdr_file_name_off = 0
  let sizeof_hdr_file_name = 100

  let hdr_file_mode_off = 100
  let sizeof_hdr_file_mode = 8

  let hdr_user_id_off = 108
  let sizeof_hdr_user_id = 8

  let hdr_group_id_off = 116
  let sizeof_hdr_group_id  = 8

  let hdr_file_size_off = 124
  let sizeof_hdr_file_size = 12

  let hdr_mod_time_off = 136
  let sizeof_hdr_mod_time = 12

  let hdr_chksum_off = 148
  let sizeof_hdr_chksum = 8

  let hdr_link_indicator_off = 156

  let hdr_link_name_off = 157
  let sizeof_hdr_link_name = 100

  let hdr_magic_off = 257
  let sizeof_hdr_magic = 6

  let hdr_version_off = 263
  let sizeof_hdr_version = 2

  let hdr_uname_off = 265
  let sizeof_hdr_uname = 32

  let hdr_gname_off = 297
  let sizeof_hdr_gname = 32

  let hdr_devmajor_off = 329
  let sizeof_hdr_devmajor = 8

  let hdr_devminor_off = 337
  let sizeof_hdr_devminor = 8

  let hdr_prefix_off = 345
  let sizeof_hdr_prefix = 155

  let get_hdr_file_name buf =
    unmarshal_string ~off:hdr_file_name_off ~len:sizeof_hdr_file_name buf
  let set_hdr_file_name buf v =
    let v = marshal_string v sizeof_hdr_file_name in
    Bytes.blit_string v 0 buf hdr_file_name_off sizeof_hdr_file_name

  let get_hdr_file_mode buf =
    unmarshal_int ~off:hdr_file_mode_off ~len:sizeof_hdr_file_mode buf
  let set_hdr_file_mode buf v =
    let v = marshal_int v sizeof_hdr_file_mode in
    Bytes.blit_string v 0 buf hdr_file_mode_off sizeof_hdr_file_mode

  let get_hdr_user_id buf =
    unmarshal_int ~off:hdr_user_id_off ~len:sizeof_hdr_user_id buf
  let set_hdr_user_id buf v =
    let v = marshal_int v sizeof_hdr_user_id in
    Bytes.blit_string v 0 buf hdr_user_id_off sizeof_hdr_user_id

  let get_hdr_group_id buf =
    unmarshal_int ~off:hdr_group_id_off ~len:sizeof_hdr_group_id buf
  let set_hdr_group_id buf v =
    let v = marshal_int v sizeof_hdr_group_id in
    Bytes.blit_string v 0 buf hdr_group_id_off sizeof_hdr_group_id

  let get_hdr_file_size buf =
    unmarshal_int64 ~off:hdr_file_size_off ~len:sizeof_hdr_file_size buf
  let set_hdr_file_size buf v =
    let v = marshal_int64 v sizeof_hdr_file_size in
    Bytes.blit_string v 0 buf hdr_file_size_off sizeof_hdr_file_size

  let get_hdr_mod_time buf =
    unmarshal_int64 ~off:hdr_mod_time_off ~len:sizeof_hdr_mod_time buf
  let set_hdr_mod_time buf v =
    let v = marshal_int64 v sizeof_hdr_mod_time in
    Bytes.blit_string v 0 buf hdr_mod_time_off sizeof_hdr_mod_time

  let get_hdr_chksum buf =
    unmarshal_int64 ~off:hdr_chksum_off ~len:sizeof_hdr_chksum buf
  let set_hdr_chksum buf v =
    let v = marshal_int64 v sizeof_hdr_chksum in
    Bytes.blit_string v 0 buf hdr_chksum_off sizeof_hdr_chksum

  let get_hdr_link_indicator buf = String.get buf hdr_link_indicator_off
  let set_hdr_link_indicator buf v =
    Bytes.set buf hdr_link_indicator_off v

  let get_hdr_link_name buf =
    unmarshal_string ~off:hdr_link_name_off ~len:sizeof_hdr_link_name buf
  let set_hdr_link_name buf v =
    let v = marshal_string v sizeof_hdr_link_name in
    Bytes.blit_string v 0 buf hdr_link_name_off sizeof_hdr_link_name

  let get_hdr_magic buf =
    unmarshal_string ~off:hdr_magic_off ~len:sizeof_hdr_magic buf
  let set_hdr_magic buf v =
    let v = marshal_string v sizeof_hdr_magic in
    Bytes.blit_string v 0 buf hdr_magic_off sizeof_hdr_magic

  let _get_hdr_version buf =
    unmarshal_string ~off:hdr_version_off ~len:sizeof_hdr_version buf
  let set_hdr_version buf v =
    let v = marshal_string v sizeof_hdr_version in
    Bytes.blit_string v 0 buf hdr_version_off sizeof_hdr_version

  let get_hdr_uname buf =
    unmarshal_string ~off:hdr_uname_off ~len:sizeof_hdr_uname buf
  let set_hdr_uname buf v =
    let v = marshal_string v sizeof_hdr_uname in
    Bytes.blit_string v 0 buf hdr_uname_off sizeof_hdr_uname

  let get_hdr_gname buf =
    unmarshal_string ~off:hdr_gname_off ~len:sizeof_hdr_gname buf
  let set_hdr_gname buf v =
    let v = marshal_string v sizeof_hdr_gname in
    Bytes.blit_string v 0 buf hdr_gname_off sizeof_hdr_gname

  let get_hdr_devmajor buf =
    unmarshal_int ~off:hdr_devmajor_off ~len:sizeof_hdr_devmajor buf
  let set_hdr_devmajor buf v =
    let v = marshal_int v sizeof_hdr_devmajor in
    Bytes.blit_string v 0 buf hdr_devmajor_off sizeof_hdr_devmajor

  let get_hdr_devminor buf =
    unmarshal_int ~off:hdr_devminor_off ~len:sizeof_hdr_devminor buf
  let set_hdr_devminor buf v =
    let v = marshal_int v sizeof_hdr_devminor in
    Bytes.blit_string v 0 buf hdr_devminor_off sizeof_hdr_devminor

  let get_hdr_prefix buf =
    unmarshal_string ~off:hdr_prefix_off ~len:sizeof_hdr_prefix buf
  let set_hdr_prefix buf v =
    let v = marshal_string v sizeof_hdr_prefix in
    Bytes.blit_string v 0 buf hdr_prefix_off sizeof_hdr_prefix

  type compatibility =
    | OldGNU
    | GNU
    | V7
    | Ustar
    | Posix

  let compatibility_level = ref V7

  let get_level = function
    | None -> !compatibility_level
    | Some level -> level

  module Link = struct
    type t =
      | Normal
      | Hard
      | Symbolic
      | Character
      | Block
      | Directory
      | FIFO
      | GlobalExtendedHeader
      | PerFileExtendedHeader
      | LongLink
      | LongName

    (* Strictly speaking, v7 supports Normal (as \0) and Hard only *)
    let to_char ?level =
      let level = get_level level in function
        | Normal                -> if level = V7 then '\000' else '0'
        | Hard                  -> '1'
        | Symbolic              -> '2'
        | Character             -> '3'
        | Block                 -> '4'
        | Directory             -> '5'
        | FIFO                  -> '6'
        | GlobalExtendedHeader  -> 'g'
        | PerFileExtendedHeader -> 'x'
        | LongLink              -> 'K'
        | LongName              -> 'L'

    let of_char = function
      | '1' -> Hard
      | '2' -> Symbolic
      | 'g' -> GlobalExtendedHeader
      | 'x' -> PerFileExtendedHeader
      | 'K' -> LongLink
      | 'L' -> LongName
      | '3' -> Character
      | '4' -> Block
      | '5' -> Directory
      | '6' -> FIFO
      | _ -> Normal (* if value is malformed, treat as a normal file *)

    let to_string = function
      | Normal -> "Normal"
      | Hard -> "Hard"
      | Symbolic -> "Symbolic"
      | Character -> "Character"
      | Block -> "Block"
      | Directory -> "Directory"
      | FIFO -> "FIFO"
      | GlobalExtendedHeader -> "GlobalExtendedHeader"
      | PerFileExtendedHeader -> "PerFileExtendedHeader"
      | LongLink -> "LongLink"
      | LongName -> "LongName"
  end

  module Extended = struct
    type t = {
      access_time: int64 option;
      charset: string option;
      comment: string option;
      group_id: int option;
      gname: string option;
      header_charset: string option;
      link_path: string option;
      mod_time: int64 option;
      path: string option;
      file_size: int64 option;
      user_id: int option;
      uname: string option;
    }
    (** Represents a "Pax" extended header *)

    let make ?access_time ?charset ?comment ?group_id ?gname ?header_charset
      ?link_path ?mod_time ?path ?file_size ?user_id ?uname () =
      { access_time; charset; comment; group_id; gname; header_charset;
        link_path; mod_time; path; file_size; user_id; uname }

    (** Pretty-print the header record *)
    let to_detailed_string (x: t) =
      let opt f = function None -> "" | Some v -> f v in
      let table = [ "access_time",    opt Int64.to_string x.access_time;
                    "charset",        opt Fun.id x.charset;
                    "comment",        opt Fun.id x.comment;
                    "group_id",       opt string_of_int x.group_id;
                    "gname",          opt Fun.id x.gname;
                    "header_charset", opt Fun.id x.header_charset;
                    "link_path",      opt Fun.id x.link_path;
                    "mod_time",       opt Int64.to_string x.mod_time;
                    "path",           opt Fun.id x.path;
                    "file_size",      opt Int64.to_string x.file_size;
                    "user_id",        opt string_of_int x.user_id;
                    "uname",          opt Fun.id x.uname;
                  ] in
      "{\n\t" ^ (String.concat "\n\t" (List.map (fun (k, v) -> k ^ ": " ^ v) table)) ^ "}"

    let marshal t =
      let pairs =
        (match t.access_time    with None -> [] | Some x -> [ "atime", Int64.to_string x ])
      @ (match t.charset        with None -> [] | Some x -> [ "charset", x ])
      @ (match t.comment        with None -> [] | Some x -> [ "comment", x ])
      @ (match t.group_id       with None -> [] | Some x -> [ "gid", string_of_int x ])
      @ (match t.gname          with None -> [] | Some x -> [ "group_name", x ])
      @ (match t.header_charset with None -> [] | Some x -> [ "hdrcharset", x ])
      @ (match t.link_path      with None -> [] | Some x -> [ "linkpath", x ])
      @ (match t.mod_time       with None -> [] | Some x -> [ "mtime", Int64.to_string x ])
      @ (match t.path           with None -> [] | Some x -> [ "path", x ])
      @ (match t.file_size      with None -> [] | Some x -> [ "size", Int64.to_string x ])
      @ (match t.user_id        with None -> [] | Some x -> [ "uid", string_of_int x ])
      @ (match t.uname          with None -> [] | Some x -> [ "uname", x ]) in
      String.concat "" (List.map (fun (k, v) ->
          let length = 8 + 1 + (String.length k) + 1 + (String.length v) + 1 in
          Printf.sprintf "%08d %s=%s\n" length k v
        ) pairs)

    let merge global extended =
      match global with
      | Some g ->
         let merge g e = match e with None -> g | Some _ ->  e in
         let access_time = merge g.access_time extended.access_time
         and charset = merge g.charset extended.charset
         and comment = merge g.comment extended.comment
         and group_id = merge g.group_id extended.group_id
         and gname = merge g.gname extended.gname
         and header_charset = merge g.header_charset extended.header_charset
         and link_path = merge g.link_path extended.link_path
         and mod_time = merge g.mod_time extended.mod_time
         and path = merge g.path extended.path
         and file_size = merge g.file_size extended.file_size
         and user_id = merge g.user_id extended.user_id
         and uname = merge g.uname extended.uname
         in
         { access_time; charset; comment; group_id; gname;
           header_charset; link_path; mod_time; path; file_size;
           user_id; uname }
      | None -> extended

    let decode_int x =
      try
        Ok (int_of_string x)
      with Failure msg ->
        Error (`Unmarshal (Printf.sprintf "%s: failed to parse integer %S" msg x))

    let decode_int64 x =
      try
        Ok (Int64.of_string x)
      with Failure msg ->
        Error (`Unmarshal (Printf.sprintf "%s: failed to parse integer %S" msg x))

    let unmarshal ~(global: t option) c =
      (* "%d %s=%s\n", <length>, <keyword>, <value> with constraints that
         - the <keyword> cannot contain an equals sign
         - the <length> is the number of octets of the record, including \n
        *)
      let find start char =
        try Ok (String.index_from c start char)
        with Not_found -> Error (`Unmarshal "Failed to decode pax extended header record")
      in
      let slen = String.length c in
      let rec loop acc idx =
        if idx >= slen
        then Ok (List.rev acc)
        else begin
          (* Find the space, then decode the length *)
          let* i = find idx ' ' in
          let* length =
            try Ok (int_of_string (String.sub c idx (i - idx))) with
              Failure _ -> Error (`Unmarshal "Failed to decode pax extended header record")
          in
          let* j = find i '=' in
          let keyword = String.sub c (i + 1) (j - i - 1) in
          let v = String.sub c (j + 1) (length - (j - idx) - 2) in
          loop ((keyword, v) :: acc) (idx + length)
        end
      in
      let* pairs = loop [] 0 in
      let option name f =
        if List.mem_assoc name pairs then
          let* v = f (List.assoc name pairs) in
          Ok (Some v)
        else
          Ok None
      in
      (* integers are stored as decimal, not octal here *)
      let* access_time    = option "atime" unmarshal_pax_time in
      let* charset        = option "charset" unmarshal_string in
      let* comment        = option "comment" unmarshal_string in
      let* group_id       = option "gid" decode_int in
      let* gname          = option "group_name" unmarshal_string in
      let* header_charset = option "hdrcharset" unmarshal_string in
      let* link_path      = option "linkpath" unmarshal_string in
      let* mod_time       = option "mtime" unmarshal_pax_time in
      let* path           = option "path" unmarshal_string in
      let* file_size      = option "size" decode_int64 in
      let* user_id        = option "uid" decode_int in
      let* uname          = option "uname" unmarshal_string in
      let g =
        { access_time; charset; comment; group_id; gname;
          header_charset; link_path; mod_time; path; file_size;
          user_id; uname }
      in
      Ok (merge global g)

  end

  (** Represents a standard (non-USTAR) archive (note checksum not stored) *)
  type t = { file_name: string;
             file_mode: int;
             user_id: int;
             group_id: int;
             file_size: int64;
             mod_time: int64;
             link_indicator: Link.t;
             link_name: string;
             uname: string;
             gname: string;
             devmajor: int;
             devminor: int;
             extended: Extended.t option;
           }

  (** Helper function to make a simple header *)
  let make ?(file_mode=0o400) ?(user_id=0) ?(group_id=0) ?(mod_time=0L) ?(link_indicator=Link.Normal) ?(link_name="") ?(uname="") ?(gname="") ?(devmajor=0) ?(devminor=0) file_name file_size =
    (* If some fields are too big, we must use a pax header *)
    let need_pax_header =
      Int64.unsigned_compare file_size 0o077777777777L > 0
       || user_id  > 0x07777777
       || group_id > 0x07777777 in
    let extended =
      if need_pax_header
      then Some (Extended.make ~file_size ~user_id ~group_id ())
      else None in
    { file_name;
      file_mode;
      user_id;
      group_id;
      file_size;
      mod_time;
      link_indicator;
      link_name;
      uname;
      gname;
      devmajor;
      devminor;
      extended }

  (** Length of a header block *)
  let length = 512

  (** A blank header block (two of these in series mark the end of the tar) *)
  let zero_block = String.make length '\000'

  (** Pretty-print the header record *)
  let to_detailed_string (x: t) =
    let table = [ "file_name",      x.file_name;
                  "file_mode",      string_of_int x.file_mode;
                  "user_id",        string_of_int x.user_id;
                  "group_id",       string_of_int x.group_id;
                  "file_size",      Int64.to_string x.file_size;
                  "mod_time",       Int64.to_string x.mod_time;
                  "link_indicator", Link.to_string x.link_indicator;
                  "link_name",      x.link_name ] in
    "{\n\t" ^ (String.concat "\n\t" (List.map (fun (k, v) -> k ^ ": " ^ v) table)) ^ "}"

  (** From an already-marshalled block, compute what the checksum should be *)
  let checksum x : int64 =
    (* Sum of all the byte values of the header with the checksum field taken
       as 8 ' ' (spaces) *)
    let result = ref 0 in
    let in_checksum_range i =
      i >= hdr_chksum_off && i < hdr_chksum_off + sizeof_hdr_chksum
    in
    for i = 0 to String.length x - 1 do
      let v =
        if in_checksum_range i then
          int_of_char ' '
        else
          int_of_char (String.get x i)
      in
      result := !result + v
    done;
    Int64.of_int !result

  (** Unmarshal a header block, returning None if it's all zeroes *)
  let unmarshal ?(extended = Extended.make ()) c
    : (t, [>`Zero_block | `Checksum_mismatch]) result =
    if String.length c <> length then Error (`Unmarshal "buffer is not of block size")
    else if String.equal zero_block c then Error `Zero_block
    else
      let* chksum = get_hdr_chksum c in
      if checksum c <> chksum then Error `Checksum_mismatch
      else let* ustar =
             let* magic = get_hdr_magic c in
             (* GNU tar and Posix differ in interpretation of the character following ustar. For Posix, it should be '\0' but GNU tar uses ' ' *)
             Ok (String.length magic >= 5 && (String.sub magic 0 5 = "ustar")) in
        let* prefix = if ustar then get_hdr_prefix c else Ok "" in
        let* file_name = match extended.Extended.path with
          | Some path -> Ok path
          | None ->
            let* file_name = get_hdr_file_name c in
            if file_name = "" then Ok prefix
            else if prefix = "" then Ok file_name
            else Ok (Filename.concat prefix file_name) in
        let* file_mode = get_hdr_file_mode c in
        let* user_id = match extended.Extended.user_id with
          | None -> get_hdr_user_id c
          | Some x -> Ok x in
        let* group_id = match extended.Extended.group_id with
          | None -> get_hdr_group_id c
          | Some x -> Ok x in
        let* file_size = match extended.Extended.file_size with
          | None -> get_hdr_file_size c
          | Some x -> Ok x in
        let* mod_time = match extended.Extended.mod_time with
          | None -> get_hdr_mod_time c
          | Some x -> Ok x in
        let link_indicator = Link.of_char (get_hdr_link_indicator c) in
        let* uname = match extended.Extended.uname with
          | None -> if ustar then get_hdr_uname c else Ok ""
          | Some x -> Ok x in
        let* gname = match extended.Extended.gname with
          | None -> if ustar then get_hdr_gname c else Ok ""
          | Some x -> Ok x in
        let* devmajor  = if ustar then get_hdr_devmajor c else Ok 0 in
        let* devminor  = if ustar then get_hdr_devminor c else Ok 0 in

        let* link_name = match extended.Extended.link_path with
          | Some link_path -> Ok link_path
          | None -> get_hdr_link_name c in
        Ok (make ~file_mode ~user_id ~group_id ~mod_time ~link_indicator
           ~link_name ~uname ~gname ~devmajor ~devminor file_name file_size)

  (** Marshal a header block, computing and inserting the checksum *)
  let marshal ?level c (x: t) =
    let level = get_level level in
    (* The caller (e.g. write_block) is expected to insert the extra ././@LongLink header *)
    let* () =
      if String.length x.file_name > sizeof_hdr_file_name && level <> GNU then
        if level = Ustar then
          if String.length x.file_name > 256 then
            Error (`Msg "file_name too long")
          else
            let* (prefix, file_name) =
              let is_directory = if x.file_name.[String.length x.file_name - 1] = '/' then "/" else "" in
              let rec split prefix file_name =
                if String.length file_name > sizeof_hdr_file_name then
                  Error (`Msg "file_name can't be split")
                else if String.length prefix > sizeof_hdr_prefix then
                  split (Filename.dirname prefix) (Filename.concat (Filename.basename prefix) file_name ^ is_directory)
                else Ok (prefix, file_name)
              in
              split (Filename.dirname x.file_name) (Filename.basename x.file_name ^ is_directory)
            in
            set_hdr_file_name c file_name;
            set_hdr_prefix c prefix;
            Ok ()
        else Error (`Msg "file_name too long")
      else (set_hdr_file_name c x.file_name; Ok ())
    in
    (* This relies on the fact that the block was initialised to null characters *)
    let* () =
      if level = Ustar || (level = GNU && x.devmajor = 0 && x.devminor = 0) then begin
        if level = Ustar then begin
          set_hdr_magic c "ustar";
          set_hdr_version c "00";
        end else begin
          (* OLD GNU MAGIC: use "ustar " as magic, and another " " in the version *)
          set_hdr_magic c "ustar ";
          set_hdr_version c " ";
        end;
        set_hdr_uname c x.uname;
        set_hdr_gname c x.gname;
        if level = Ustar then begin
          set_hdr_devmajor c x.devmajor;
          set_hdr_devminor c x.devminor;
        end;
        Ok ()
      end else
        if x.devmajor <> 0 then Error (`Msg "devmajor not supported in this format")
        else if x.devminor <> 0 then Error (`Msg "devminor not supported in this format")
        else if x.uname <> "" then Error (`Msg "uname not supported in this format")
        else if x.gname <> "" then Error (`Msg "gname not supported in this format")
        else Ok ()
    in
    set_hdr_file_mode c x.file_mode;
    set_hdr_user_id c x.user_id;
    set_hdr_group_id c x.group_id;
    set_hdr_file_size c x.file_size;
    set_hdr_mod_time c x.mod_time;
    set_hdr_link_indicator c (Link.to_char ~level x.link_indicator);
    (* The caller (e.g. write_block) is expected to insert the extra ././@LongLink header *)
    let* () =
      if String.length x.link_name > sizeof_hdr_link_name && level <> GNU then
        Error (`Msg "link_name too long")
      else
        Ok ()
    in
    set_hdr_link_name c x.link_name;
    (* Finally, compute the checksum *)
    let chksum = checksum (Bytes.unsafe_to_string c) in
    set_hdr_chksum c chksum;
    Ok ()

  (** Compute the amount of zero-padding required to round up the file size
      to a whole number of blocks *)
  let compute_zero_padding_length (x: t) : int =
    (* round up to next whole number of block lengths *)
    let last_block_size = Int64.to_int (Int64.rem x.file_size (Int64.of_int length)) in
    if last_block_size = 0 then 0 else length - last_block_size

  (** Return the required zero-padding as a string *)
  let zero_padding (x: t) =
    let zero_padding_len = compute_zero_padding_length x in
    String.sub zero_block 0 zero_padding_len

  let to_sectors (x: t) =
    Int64.(div (add (pred (of_int length)) x.file_size) (of_int length))
end

module type ASYNC = sig
  type 'a t
  val ( >>= ): 'a t -> ('a -> 'b t) -> 'b t
  val return: 'a -> 'a t
end

module type READER = sig
  type in_channel
  type 'a io
  val really_read: in_channel -> bytes -> unit io
  val skip: in_channel -> int -> unit io
end

module type WRITER = sig
  type out_channel
  type 'a io
  val really_write: out_channel -> string -> unit io
end

module type HEADERREADER = sig
  type in_channel
  type 'a io
  val read : global:Header.Extended.t option -> in_channel ->
    (Header.t * Header.Extended.t option, [ `Eof | `Fatal of [ `Checksum_mismatch | `Corrupt_pax_header | `Unmarshal of string ] ]) result io
end

module type HEADERWRITER = sig
  type out_channel
  type 'a io
  val write : ?level:Header.compatibility -> Header.t -> out_channel -> (unit, [> `Msg of string ]) result io
  val write_global_extended_header : Header.Extended.t -> out_channel -> (unit, [> `Msg of string ]) result io
end

let longlink = "././@LongLink"

module HeaderReader(Async: ASYNC)(Reader: READER with type 'a io = 'a Async.t) = struct
  open Async
  open Reader

  type in_channel = Reader.in_channel
  type 'a io = 'a t

  (* This is not a bind, but more a lift and bind combined. *)
  let ( let^* ) x f =
    match x with
    | Ok x -> f x
    | Error _ as e -> return e

  let fix_link_indicator x =
    (* For backward compatibility we treat normal files ending in slash as
       directories. Because [Link.of_char] treats unrecognized link indicator
       values as normal files we check directly. This is not completely correct
       as [Header.Link.of_char] turns unknown link indicators into
       [Header.Link.Normal]. Ideally, it should only be done for '0' and
       '\000'. *)
    if String.length x.Header.file_name > 0
    && x.file_name.[String.length x.file_name - 1] = '/'
    && x.link_indicator = Header.Link.Normal then
      { x with link_indicator = Header.Link.Directory }
    else
      x

  let read ~global (ifd: Reader.in_channel) : (Header.t * Header.Extended.t option, [ `Eof | `Fatal of [ `Checksum_mismatch | `Corrupt_pax_header | `Unmarshal of string ] ]) result t =
    (* We might need to read 2 headers at once if we encounter a Pax header *)
    let buffer = Bytes.make Header.length '\000' in
    let real_header_buf = Bytes.make Header.length '\000' in

    let next_block global () =
      really_read ifd buffer >>= fun () ->
      return (Header.unmarshal ?extended:global (Bytes.unsafe_to_string buffer))
    in

    let rec get_hdr ~next_longname ~next_longlink global () : (Header.t * Header.Extended.t option, [> `Eof | `Fatal of [ `Checksum_mismatch | `Corrupt_pax_header | `Unmarshal of string ] ]) result t =
      next_block global () >>= function
      | Ok x when x.Header.link_indicator = Header.Link.GlobalExtendedHeader ->
        let extra_header_buf = Bytes.make (Int64.to_int x.Header.file_size) '\000' in
        really_read ifd extra_header_buf >>= fun () ->
        skip ifd (Header.compute_zero_padding_length x) >>= fun () ->
        (* unmarshal merges the previous global (if any) with the
           discovered global (if any) and returns the new global. *)
        let^* global =
          Result.map_error
            (fun e -> `Fatal e)
            (Header.Extended.unmarshal ~global (Bytes.unsafe_to_string extra_header_buf))
        in
        get_hdr ~next_longname ~next_longlink (Some global) ()
      | Ok x when x.Header.link_indicator = Header.Link.PerFileExtendedHeader ->
        let extra_header_buf = Bytes.make (Int64.to_int x.Header.file_size) '\000' in
        really_read ifd extra_header_buf >>= fun () ->
        skip ifd (Header.compute_zero_padding_length x) >>= fun () ->
        let^* extended =
          Result.map_error
            (fun e -> `Fatal e)
            (Header.Extended.unmarshal ~global (Bytes.unsafe_to_string extra_header_buf))
        in
        really_read ifd real_header_buf >>= fun () ->
        let^* x =
          Result.map_error
            (fun _ -> `Fatal `Corrupt_pax_header)
            (Header.unmarshal ~extended (Bytes.unsafe_to_string real_header_buf))
        in
        let x = fix_link_indicator x in
        return (Ok (x, global))
      | Ok ({ Header.link_indicator = Header.Link.LongLink | Header.Link.LongName; _ } as x) when x.Header.file_name = longlink ->
        let extra_header_buf = Bytes.create (Int64.to_int x.Header.file_size) in
        really_read ifd extra_header_buf >>= fun () ->
        skip ifd (Header.compute_zero_padding_length x) >>= fun () ->
        let name = String.sub (Bytes.unsafe_to_string extra_header_buf) 0 (Bytes.length extra_header_buf - 1) in
        let next_longlink = if x.Header.link_indicator = Header.Link.LongLink then Some name else next_longlink in
        let next_longname = if x.Header.link_indicator = Header.Link.LongName then Some name else next_longname in
        get_hdr ~next_longname ~next_longlink global ()
      | Ok x ->
        (* XXX: unclear how/if pax headers should interact with gnu extensions *)
        let x = match next_longname with
          | None -> x
          | Some file_name -> { x with file_name }
        in
        let x = match next_longlink with
          | None -> x
          | Some link_name -> { x with link_name }
        in
        let x = fix_link_indicator x in
        return (Ok (x, global))
      | Error `Zero_block ->
        begin
          next_block global () >>= function
          | Ok x -> return (Ok (x, global))
          | Error `Zero_block -> return (Error `Eof)
          | Error ((`Checksum_mismatch | `Unmarshal _) as e) -> return (Error (`Fatal e))
        end
      | Error ((`Checksum_mismatch | `Unmarshal _) as e) ->
        return (Error (`Fatal e))
    in
    get_hdr ~next_longname:None ~next_longlink:None global ()

end

module HeaderWriter(Async: ASYNC)(Writer: WRITER with type 'a io = 'a Async.t) = struct
  open Async
  open Writer

  type out_channel = Writer.out_channel
  type 'a io = 'a t

  let write_unextended ?level header fd =
    let level = Header.get_level level in
    let blank = {Header.file_name = longlink; file_mode = 0; user_id = 0; group_id = 0; mod_time = 0L; file_size = 0L; link_indicator = Header.Link.LongLink; link_name = ""; uname = "root"; gname = "root"; devmajor = 0; devminor = 0; extended = None} in
    (if level = Header.GNU then begin
        begin
          if String.length header.Header.link_name > Header.sizeof_hdr_link_name then begin
            let file_size = String.length header.Header.link_name + 1 in
            let blank = {blank with Header.file_size = Int64.of_int file_size} in
            let buffer = Bytes.make Header.length '\000' in
            match
              Header.marshal ~level buffer { blank with link_indicator = Header.Link.LongLink }
            with
            | Error _ as e -> return e
            | Ok () ->
              really_write fd (Bytes.unsafe_to_string buffer) >>= fun () ->
              let payload = header.Header.link_name ^ "\000" in
              really_write fd payload >>= fun () ->
              really_write fd (Header.zero_padding blank) >>= fun () ->
              return (Ok ())
          end else
            return (Ok ())
        end >>= function
        | Error _ as e -> return e
        | Ok () ->
          begin
            if String.length header.Header.file_name > Header.sizeof_hdr_file_name then begin
              let file_size = String.length header.Header.file_name + 1 in
              let blank = {blank with Header.file_size = Int64.of_int file_size} in
              let buffer = Bytes.make Header.length '\000' in
              match
                Header.marshal ~level buffer { blank with link_indicator = Header.Link.LongName }
              with
              | Error _ as e -> return e
              | Ok () ->
                really_write fd (Bytes.unsafe_to_string buffer) >>= fun () ->
                let payload = header.Header.file_name ^ "\000" in
                really_write fd payload >>= fun () ->
                really_write fd (Header.zero_padding blank) >>= fun () ->
                return (Ok ())
            end else
              return (Ok ())
          end >>= function
          | Error _ as e -> return e
          | Ok () -> return (Ok ())
      end else
       return (Ok ())) >>= function
    | Error _ as e -> return e
    | Ok () ->
      let buffer = Bytes.make Header.length '\000' in
      match Header.marshal ~level buffer header with
      | Error _  as e -> return e
      | Ok () ->
        really_write fd (Bytes.unsafe_to_string buffer) >>= fun () ->
        return (Ok ())

  let write_extended ?level ~link_indicator hdr fd =
    let link_indicator_name = match link_indicator with
      | Header.Link.PerFileExtendedHeader -> "paxheader"
      | Header.Link.GlobalExtendedHeader -> "pax_global_header"
      | _ -> assert false
    in
    let pax_payload = Header.Extended.marshal hdr in
    let pax = Header.make ~link_indicator link_indicator_name
                (Int64.of_int @@ String.length pax_payload) in
    write_unextended ?level pax fd >>= function
    | Error _ as e -> return e
    | Ok () ->
      really_write fd pax_payload >>= fun () ->
      really_write fd (Header.zero_padding pax) >>= fun () ->
      return (Ok ())

  let write ?level header fd =
    ( match header.Header.extended with
      | None -> return (Ok ())
      | Some e ->
        write_extended ?level ~link_indicator:Header.Link.PerFileExtendedHeader e fd )
    >>= function
    | Error _ as e -> return e
    | Ok () -> write_unextended ?level header fd

  let write_global_extended_header global fd =
    write_extended ~link_indicator:Header.Link.GlobalExtendedHeader global fd
end
