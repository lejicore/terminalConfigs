;;; brain.el --- Mac-serialized canonical Org commits for Brain v1 -*- lexical-binding: t; -*-

;;; Commentary:

;; Brain v1 (design t_0511a7c7) makes the running Emacs main event loop the one
;; sequencer for managed canonical Org.  This module is the Mac half of that
;; boundary (chunk B3).  It owns:
;;
;;   * `brain-commit-file', the single enforcement point for every managed
;;     canonical write: human saves and remote installs both go through it;
;;   * a durable local journal (`journal/journal.jsonl'), a rebuildable heads
;;     cache (`heads.json') and startup reconciliation;
;;   * the remote install algorithm: verify the immutable object and parse the
;;     semantic projection from those exact bytes in a temporary non-visiting
;;     buffer, then a synchronous non-yielding check-to-install section;
;;   * the node-local IPC client (length-prefixed JSON frames to
;;     `ipc/node.sock'), a durable outbox and the bounded dispatcher;
;;   * snapshots and the paged inventory;
;;   * dirty-generation leases, recovery markers and the alternate route guards
;;     (write-region / rename / delete / save-as / Babel / auto-revert);
;;   * a quiet structured status.
;;
;; Two honest limitations are recorded here instead of being papered over:
;;
;; 1. Emacs Lisp has no fsync primitive.  The journal append, the published
;;    object and the canonical rename are made durable by `sync PATH' AFTER the
;;    non-yielding section returns, and a commit is only reported "committed"
;;    once that call succeeded.  Nothing inside the section waits on a process,
;;    so the check-to-install interval cannot be re-entered by a first edit.
;; 2. The no-yield guarantee covers one Emacs main event loop in one daemon.  A
;;    second daemon or a direct external writer is detected as a disk/head
;;    mismatch and fails into `attention'; it is not prevented by hooks.
;;
;; Activation is configuration-driven: with `brain-id' and `brain-writer-id'
;; unset the module loads and does nothing.  The reviewed cutover (B7) sets both
;; and restarts the daemon.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'nadvice)

(declare-function org-mode "org" (&optional arg))
(declare-function org-with-wide-buffer "org-macs" (&rest body))
(declare-function org-element-at-point "org-element" (&optional pom cached))
(declare-function org-entry-get "org" (pom property &optional inherit with-property))
(declare-function org-element-property "org-element" (property element))
(declare-function org-element-type "org-element" (element))
(declare-function ucs-normalize-NFC-string "ucs-normalize" (string))
(declare-function org-agenda-files "org" (&optional arg))

;; The Org configuration the query profile exports (§4).  These are declared with
;; `defvar' so they are SPECIAL variables: `brain' does not `require' Org at load
;; time (it is loaded by the user's configuration and is inert until configured),
;; so without the declarations a reference under `lexical-binding' would be a
;; lexical free variable and a caller's `let'-binding of `org-todo-keywords' would
;; silently not be seen.  `defvar' with no value only marks the symbol special; it
;; does not define or override Org's own default, which is why this is safe even
;; when Org is loaded later.
(defvar org-todo-keywords)
(defvar org-agenda-files)
(defvar org-agenda-start-on-weekday)
(defvar org-deadline-warning-days)
(defvar calendar-week-start-day)
(defvar org-done-keywords)

(defgroup brain nil
  "Mac-serialized canonical Org commits for Brain v1."
  :group 'org
  :prefix "brain-")

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defcustom brain-id nil
  "Configured Brain v1 identity (UUID).
Nil leaves the module inert: nothing is guarded, journaled or connected."
  :type '(choice (const :tag "Unconfigured" nil) string))

(defcustom brain-writer-id nil
  "This Mac writer's stable UUID.  It is the only allocator of revision seq."
  :type '(choice (const :tag "Unconfigured" nil) string))

(defcustom brain-peer-id "mac"
  "This peer's configured identity on the Brain stream."
  :type 'string)

(defcustom brain-state-directory (expand-file-name "~/.local/share/emacs-brain/")
  "Private local Brain state: journal, heads cache and the IPC directory.
It is never synced and never inside a managed root."
  :type 'directory)

(defcustom brain-managed-roots '(("org-files" . "~/org/org-files")
                                 ("org-roam" . "~/org/org-roam"))
  "Managed canonical roots as (ROOT-NAME . DIRECTORY).
Only regular `.org' files beneath these directories are managed."
  :type '(repeat (cons string directory)))

(defcustom brain-transport-directory nil
  "Directory of the immutable object share.
Objects live at TRANSPORT/objects/<producer>/<sha256>.org.
Nil means `transport/' beneath `brain-state-directory'."
  :type '(choice (const :tag "Default" nil) directory))

(defcustom brain-node-socket nil
  "Node-local IPC endpoint.  Nil means ipc/node.sock under the state directory."
  :type '(choice (const :tag "Default" nil) string))

(defcustom brain-object-max-bytes (* 8 1024 1024)
  "Maximum size of one immutable Org object (8 MiB)."
  :type 'integer)

(defcustom brain-frame-max-bytes (* 64 1024)
  "Maximum node IPC frame body (64 KiB)."
  :type 'integer)

(defcustom brain-projection-max-bytes 4096
  "Maximum serialised semantic projection (contract limit)."
  :type 'integer)

(defcustom brain-projection-max-headings 200
  "Maximum number of Org headings carried by one semantic projection."
  :type 'integer)

(defcustom brain-sync-program (or (executable-find "sync") "sync")
  "Program used to fsync a file or directory (Emacs Lisp has no fsync)."
  :type 'string)

(defcustom brain-fsync-enabled t
  "When non-nil, durably flush journal/object/canonical paths with `sync'."
  :type 'boolean)

(defcustom brain-dispatch-interval 0.25
  "Seconds between inbound dispatcher runs.

The dispatcher is a REGULAR timer, not an idle one: a repeating idle timer runs
at most once per idle period (Emacs re-arms it inactive and only real input
makes it eligible again), so an unattended client -- a daemon driven by
`emacsclient', which is not input -- would never dispatch.  See
`brain--start-dispatch'."
  :type 'number)

(defcustom brain-reconnect-interval 2.0
  "Seconds between bounded reconnect attempts while the node endpoint is absent.
A node restart (or any IPC close) must not leave Emacs offline until a manual
`brain-disable'/`brain-enable': the client resubscribes with its epoch, which is
the design's `Emacs subscribes with epoch after recovery' requirement."
  :type 'number)

(defcustom brain-mode-line-indicator nil
  "When non-nil, the mode line shows the quiet Brain state string."
  :type 'boolean)

(defconst brain-protocol-version 1)

;;; ---------------------------------------------------------------------------
;;; Errors
;;; ---------------------------------------------------------------------------

(define-error 'brain-invalid-path "Not a managed Brain path")
(define-error 'brain-alternate-route "Refused alternate managed write route")
(define-error 'brain-locked "Brain commit already in progress for this file")
;; E9c: a journal append or flush that did not complete leaves the record's
;; durability unknown.  The module must stop rather than continue with an
;; identity it may or may not own, so the failure is an explicit error and not a
;; swallowed log line (`brain-dispatch-once' used to hide it).
(define-error 'brain-journal-fault "Brain journal is not durable")
(define-error 'brain-journal-corrupt "Brain journal failed validation" 'brain-journal-fault)

;;; ---------------------------------------------------------------------------
;;; Runtime state
;;; ---------------------------------------------------------------------------

(defvar brain--journal nil
  "In-memory journal records, oldest first.  The durable copy is the journal file.")

(defvar brain--journal-seq 0
  "Last durable local journal sequence number.")

(defvar brain--heads (make-hash-table :test #'equal)
  "file_id -> revision plist (:writer-id :seq :sha256).")

(defvar brain--dirty (make-hash-table :test #'equal)
  "file_id -> dirty lease plist (:generation :base :operation-id :epoch).")

(defvar brain--generations (make-hash-table :test #'equal)
  "file_id -> last allocated dirty generation.")

(defvar brain--attention (make-hash-table :test #'equal)
  "file_id -> attention reason.  Present means installs are refused.")

(defvar brain--deferred (make-hash-table :test #'equal)
  "file_id -> plist (:reason :operation-id :revision) for a deferred projection.
A projection that overflows the contract bound or fails to parse is deferred
here instead of being dropped: it is durable in the journal, visible in
`brain-status' and never turns a committed install into an attention result.")

(defvar brain--identities (make-hash-table :test #'equal)
  "Case-folded alias key -> file_id, used to refuse collapsing identities.")

(defvar brain--results (make-hash-table :test #'equal)
  "operation/attempt id -> durable install result plist.")

(defvar brain--recovered nil
  "Non-nil once startup reconciliation finished.")

(defvar brain--enabled nil
  "Non-nil while the guards, dispatcher and IPC client are installed.")

(defvar brain--locked nil
  "List of file_ids currently inside the commit critical section.")

(defvar brain--inhibit-guards nil
  "Non-nil while Brain itself performs a managed filesystem operation.")

(defvar brain--locked-buffers nil
  "Buffers temporarily read-only for the duration of one commit.")

(defvar brain--in-critical nil
  "Non-nil inside the non-yielding check-to-install section.")

(defvar brain--ipc nil
  "Node IPC process, or nil.")

(defvar brain--ipc-bytes ""
  "Partial inbound frame bytes.")

(defvar brain--reconnect-timer nil
  "The one bounded reconnect timer, or nil when Brain is disabled.")

(defvar brain--dispatch-timer nil
  "The one inbound dispatcher timer, or nil when Brain is disabled.")

(defvar brain--inbox nil
  "Validated inbound frames waiting for the dispatcher.")

(defvar brain--outbox nil
  "Durable events not yet acknowledged by the gateway, in wire order.")

(defvar brain--wire-seq 0
  "Last allocated outbound event sequence number (distinct from revision seq).")

;; E9c: the journal fault latch.  A failed append or flush means this writer no
;; longer knows which identities it owns, so every later journal-dependent
;; action is refused until a reload validates a complete, consistent file.  The
;; latch is deliberately a plain variable, not a buffer or a file: it must
;; survive a failed dispatch and be visible to `brain-status'.
(defvar brain--journal-fault nil
  "Non-nil when a journal append or flush failed: (:reason :detail :local-seq).")

(defvar brain--acked-seq 0)

(defvar brain--epoch 0
  "Integer connection epoch reported by `emacs.online' (contract: positive int).")

(defvar brain--client-epoch nil
  "UUID identifying this visitor process in per-file payloads (`client_epoch').")

(defvar brain--reconciled nil
  "Non-nil once recovery/snapshot reconciliation finished and installs are allowed.")

(defvar brain--dispatching nil)

(defvar brain--commit-count 0
  "Number of committed installs in this process (diagnostics/tests).")

;; --- identity lifecycle state (design §3) -----------------------------------
;;
;; Declared here, with the other runtime state, because the commit primitive
;; consults `brain--retired' at its final install guard: a definition that only
;; appears further down the file would be a free variable there.

(defcustom brain-missing-retire-interval 60
  "Minimum seconds between the two complete inventories that may retire a path.
§3: \"absence must occur in TWO complete inventories at least 60 seconds apart\"."
  :type 'number)

(defvar brain--retired (make-hash-table :test #'equal)
  "file_id -> (:generation N :head REV).  Retired paths keep their retained head.")

(defvar brain--lifecycle-generations (make-hash-table :test #'equal)
  "file_id -> last lifecycle generation bound to that path (§3).")

(defvar brain--lifecycle-seq 0
  "Last lifecycle generation allocated in this journal.  Separate from revisions.")

(defvar brain--missing-observations (make-hash-table :test #'equal)
  "file_id -> list of float times, most recent first, of COMPLETE inventories
that did not contain the path.  See `brain--note-inventory-membership'.")

(defvar brain--corpus-observed nil
  "Non-nil once a corpus-mode request proved corpus-v1 live on this session.
Set only by `brain--handle-snapshot-request'; reset on recovery, because a new
session has to prove the negotiation again.")

;;; ---------------------------------------------------------------------------
;;; Small utilities
;;; ---------------------------------------------------------------------------

(defun brain--nfc (string)
  "Return STRING normalised to NFC (identity for ASCII paths)."
  (if (fboundp 'ucs-normalize-NFC-string)
      (ucs-normalize-NFC-string string)
    string))

;;; ---------------------------------------------------------------------------
;;; Unicode case folding (design t_c52859ca v2 §3)
;;; ---------------------------------------------------------------------------
;;
;; §3 requires the alias key to be "NFC plus Unicode casefold, identical
;; cross-language fixtures".  This Emacs has no casefold primitive -- measured on
;; the target build: `string-casefold', `casefold' and
;; `ucs-normalize-CaseFold-string' are all unbound, and no `casefold' appears in
;; the installed Lisp tree -- and `downcase' is NOT a substitute.  Measured over
;; all 136,189 code points that are letters or have a case mapping, `downcase'
;; differs from Unicode casefold on 298 of them: `ß' does not become `ss', `ς'
;; does not become `σ', `ﬁ' does not become `fi', `µ' does not become `μ', and
;; the Cherokee lowercase block does not fold to the uppercase block.  A
;; downcase-only Mac would therefore disagree with the Python store's
;; `str.casefold()' on real, non-ASCII note names.
;;
;; `brain--casefold-table' is generated, never hand-written:
;; `tools/gen_casefold.py' measures this exact Emacs and emits one entry for
;; every code point whose `downcase' is not its casefold, asserting that
;; `table-or-downcase == casefold' for every measured code point before writing.
;; Regenerate it when the Emacs build changes; a stale table can only ever be
;; too small, and the cross-language fixture test fails loudly when it is.
;;
;; Folding is applied PER CHARACTER, never over a whole string: Emacs `downcase'
;; is context-sensitive for final sigma ("ΣΟΦΟΣ" -> "σοφος" with a final ς),
;; while casefold is not, so a whole-string `downcase' would fold "ΣΟΦΟΣ" and
;; "σοφοσ" to different keys.

(defconst brain--casefold-table
  (let ((table (make-hash-table :test #'eql)))
    (dolist (cell '((#x00B5 . "μ") (#x00DF . "ss") (#x0149 . "ʼn") (#x017F . "s")
                    (#x01F0 . "ǰ") (#x0345 . "ι") (#x0390 . "ΐ") (#x03B0 . "ΰ")
                    (#x03C2 . "σ") (#x03D0 . "β") (#x03D1 . "θ") (#x03D5 . "φ")
                    (#x03D6 . "π") (#x03F0 . "κ") (#x03F1 . "ρ") (#x03F5 . "ε")
                    (#x0587 . "եւ") (#x13F8 . "Ꭰ") (#x13F9 . "Ꭱ") (#x13FA . "Ꭲ")
                    (#x13FB . "Ꭳ") (#x13FC . "Ꭴ") (#x13FD . "Ꭵ") (#x1C80 . "в")
                    (#x1C81 . "д") (#x1C82 . "о") (#x1C83 . "с") (#x1C84 . "т")
                    (#x1C85 . "т") (#x1C86 . "ъ") (#x1C87 . "ѣ") (#x1C88 . "ꙋ")
                    (#x1E96 . "ẖ") (#x1E97 . "ẗ") (#x1E98 . "ẘ") (#x1E99 . "ẙ")
                    (#x1E9A . "aʾ") (#x1E9B . "ṡ") (#x1E9E . "ss") (#x1F50 . "ὐ")
                    (#x1F52 . "ὒ") (#x1F54 . "ὔ") (#x1F56 . "ὖ")
                    (#x1F80 . "ἀι") (#x1F81 . "ἁι") (#x1F82 . "ἂι") (#x1F83 . "ἃι")
                    (#x1F84 . "ἄι") (#x1F85 . "ἅι") (#x1F86 . "ἆι") (#x1F87 . "ἇι")
                    (#x1F88 . "ἀι") (#x1F89 . "ἁι") (#x1F8A . "ἂι") (#x1F8B . "ἃι")
                    (#x1F8C . "ἄι") (#x1F8D . "ἅι") (#x1F8E . "ἆι") (#x1F8F . "ἇι")
                    (#x1F90 . "ἠι") (#x1F91 . "ἡι") (#x1F92 . "ἢι") (#x1F93 . "ἣι")
                    (#x1F94 . "ἤι") (#x1F95 . "ἥι") (#x1F96 . "ἦι") (#x1F97 . "ἧι")
                    (#x1F98 . "ἠι") (#x1F99 . "ἡι") (#x1F9A . "ἢι") (#x1F9B . "ἣι")
                    (#x1F9C . "ἤι") (#x1F9D . "ἥι") (#x1F9E . "ἦι") (#x1F9F . "ἧι")
                    (#x1FA0 . "ὠι") (#x1FA1 . "ὡι") (#x1FA2 . "ὢι") (#x1FA3 . "ὣι")
                    (#x1FA4 . "ὤι") (#x1FA5 . "ὥι") (#x1FA6 . "ὦι") (#x1FA7 . "ὧι")
                    (#x1FA8 . "ὠι") (#x1FA9 . "ὡι") (#x1FAA . "ὢι") (#x1FAB . "ὣι")
                    (#x1FAC . "ὤι") (#x1FAD . "ὥι") (#x1FAE . "ὦι") (#x1FAF . "ὧι")
                    (#x1FB2 . "ὰι") (#x1FB3 . "αι") (#x1FB4 . "άι") (#x1FB6 . "ᾶ")
                    (#x1FB7 . "ᾶι") (#x1FBC . "αι") (#x1FBE . "ι") (#x1FC2 . "ὴι")
                    (#x1FC3 . "ηι") (#x1FC4 . "ήι") (#x1FC6 . "ῆ") (#x1FC7 . "ῆι")
                    (#x1FCC . "ηι") (#x1FD2 . "ῒ") (#x1FD3 . "ΐ") (#x1FD6 . "ῖ")
                    (#x1FD7 . "ῗ") (#x1FE2 . "ῢ") (#x1FE3 . "ΰ") (#x1FE4 . "ῤ")
                    (#x1FE6 . "ῦ") (#x1FE7 . "ῧ") (#x1FF2 . "ὼι") (#x1FF3 . "ωι")
                    (#x1FF4 . "ώι") (#x1FF6 . "ῶ") (#x1FF7 . "ῶι") (#x1FFC . "ωι")
                    (#x212A . "k") (#xFB00 . "ff") (#xFB01 . "fi") (#xFB02 . "fl")
                    (#xFB03 . "ffi") (#xFB04 . "ffl") (#xFB05 . "st") (#xFB06 . "st")
                    (#xFB13 . "մն") (#xFB14 . "մե") (#xFB15 . "մի") (#xFB16 . "վն")
                    (#xFB17 . "մխ")))
      (puthash (car cell) (cdr cell) table))
    ;; The Cherokee lowercase block folds to the uppercase block, one to one.
    (let ((small #xAB70) (capital #x13A0))
      (while (<= small #xABBF)
        (puthash small (string capital) table)
        (setq small (1+ small) capital (1+ capital))))
    table)
  "Code point -> its Unicode casefold, for the code points `downcase' gets wrong.
Generated by `tools/gen_casefold.py' against this Emacs build; see the comment
above for why a table is needed at all.")

(defun brain--casefold (string)
  "Return STRING folded with Unicode casefold, per character. This is the Mac
  half of the one alias-key definition in design §3; the Python half is
  `str.casefold()' and `tests/fixtures/eligibility.json' pins the keys both
  must produce.  `downcase' is applied per character on purpose: its
  final-sigma rule is context-sensitive, while casefold is not."
  (if (not (multibyte-string-p string))
      string
    (let ((out nil) (index 0) (length (length string)))
      (while (< index length)
        (let* ((character (aref string index))
               (special (and (> character 127)
                             (gethash character brain--casefold-table))))
          (push (or special (downcase (string character))) out))
        (setq index (1+ index)))
      (apply #'concat (nreverse out)))))

(defun brain--uuid ()
  "Return a fresh UUID string (version 4 shaped)."
  (let ((hex (secure-hash 'sha256 (format "%s/%s/%s/%s" (float-time) (emacs-pid)
                                          (random most-positive-fixnum) (gensym)))))
    (format "%s-%s-4%s-%s%s-%s"
            (substring hex 0 8) (substring hex 8 12) (substring hex 13 16)
            (nth (random 4) '("8" "9" "a" "b")) (substring hex 17 20)
            (substring hex 20 32))))

(defun brain--derived-uuid (name)
  "Return a deterministic UUID derived from NAME.
`brain--uuid' mints a FRESH id, which is right for a new operation and wrong for
a fact that must keep one identity forever.  This one is a pure function of its
input, so the same durable fact yields the same id on every request and after
every restart."
  (let ((hex (secure-hash 'sha256 (concat "brain/v1/" name))))
    (format "%s-%s-5%s-%s%s-%s"
            (substring hex 0 8) (substring hex 8 12) (substring hex 13 16)
            (nth (logand (string-to-number (substring hex 16 17) 16) 3)
                 '("8" "9" "a" "b"))
            (substring hex 17 20)
            (substring hex 20 32))))

(defun brain--sha256 (object)
  "Return the sha256 hex digest of OBJECT (string or buffer)."
  (secure-hash 'sha256 object))

(defun brain--sha256-file (path)
  "Return the sha256 of PATH's exact bytes, or nil when it cannot be read."
  (when (and path (file-regular-p path))
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally path)
          (brain--sha256 (current-buffer)))
      (error nil))))

(defun brain--jsonify (value)
  "Convert VALUE into the shape `json-serialize' accepts.
Objects are string-keyed alists in this protocol, so they become hash tables
(whose keys may be strings).  A list whose elements are themselves objects is
ambiguous, so arrays of objects are marked with a leading `:json-array'."
  (cond
   ((and (consp value) (eq (car value) :json-array))
    (vconcat (mapcar #'brain--jsonify (cdr value))))
   ((and (consp value) (consp (car value)) (stringp (caar value)))
    (let ((table (make-hash-table :test #'equal)))
      (dolist (cell value)
        (puthash (car cell) (brain--jsonify (cdr cell)) table))
      table))
   ((consp value) (vconcat (mapcar #'brain--jsonify value)))
   ;; A nil is JSON `null', never `{}'.  `json-serialize' reads a Lisp nil as the empty alist
   ;; (nil is both the empty list and the empty object), so a nil that reaches it is written
   ;; `{}'.  That spelling is not the absent value the gateway's contract reads: it refused a
   ;; journalled, pre-epoch `client_epoch' as `invalid_field: client_epoch must be a UUID string'
   ;; live on 2026-10-31, because the reloaded frame carries plain nil and the encoder re-spelled
   ;; it `{}'.  `:null' is the object the serialiser writes as `null'.
   ((null value) :null)
   (t value)))

(defun brain--json-encode (object)
  "Serialise OBJECT as compact JSON with null/false objects."
  (json-serialize (brain--jsonify object) :null-object :null :false-object :false))

(defun brain--json-keyify (value)
  "Return VALUE with JSON object keys as strings.
`json-parse-string' yields symbol keys for alists; the protocol vocabulary is
string-keyed, so objects are normalised here once."
  (cond
   ((and (consp value) (consp (car value)) (symbolp (caar value)))
    (mapcar (lambda (cell)
              (cons (symbol-name (car cell)) (brain--json-keyify (cdr cell))))
            value))
   ((consp value) (mapcar #'brain--json-keyify value))
   (t value)))

(defun brain--json-decode (string)
  "Parse one JSON object into an alist with string keys."
  (brain--json-keyify
   (json-parse-string string :object-type 'alist :array-type 'list
                      :null-object nil :false-object :false)))

(defun brain--fsync (&rest paths)
  "Flush PATHS to stable storage.  Returns non-nil when the state is durable.
This is the only durability primitive available to Emacs Lisp; it runs a
synchronous `sync', so it is never called from the no-yield section.  When
flushing is disabled the call is a no-op success."
  (if (not brain-fsync-enabled)
      t
    (let ((paths (seq-filter (lambda (path) (and path (file-exists-p path)))
                             (flatten-tree paths))))
      (cond
       ((null paths) t)
       (t (condition-case nil
              (eq 0 (apply #'call-process brain-sync-program nil nil nil paths))
            (error nil)))))))

(defun brain--state-dir ()
  (file-name-as-directory (expand-file-name brain-state-directory)))

(defun brain--transport-dir ()
  (file-name-as-directory
   (expand-file-name (or brain-transport-directory
                         (expand-file-name "transport/" (brain--state-dir))))))

(defun brain--journal-dir ()
  (file-name-as-directory (expand-file-name "journal/" (brain--state-dir))))

(defun brain--ipc-dir ()
  (file-name-as-directory (expand-file-name "ipc/" (brain--state-dir))))

(defun brain--journal-file ()
  (expand-file-name "journal.jsonl" (brain--journal-dir)))

(defun brain--heads-file ()
  (expand-file-name "heads.json" (brain--state-dir)))

(defun brain--socket-path ()
  (if brain-node-socket
      (expand-file-name brain-node-socket)
    (expand-file-name "ipc/node.sock" (brain--state-dir))))

(defun brain--object-path (producer digest)
  "Absolute path of the immutable object PRODUCER/DIGEST.org.
Objects live under the shared transport directory's `objects/' namespace, the
same layout the gateway's `ObjectStore' uses
(`<state_root>/transport/objects/<producer>/<sha>.org'): both sides must name
one file for one digest or Syncthing delivers bytes neither side can read."
  (expand-file-name (concat "objects/" producer "/" digest ".org") (brain--transport-dir)))

(defun brain--log (format-string &rest args)
  "Append one diagnostic line to log/brain.log.  Never signals, never messages."
  (condition-case nil
      (let ((file (expand-file-name "log/brain.log" (brain--state-dir)))
            (brain--inhibit-guards t)
            (coding-system-for-write 'utf-8-unix))
        (make-directory (file-name-directory file) t)
        (write-region (format "%s %s\n" (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                             (apply #'format format-string args))
                      nil file 'append 'no-message))
    (error nil)))

;;; ---------------------------------------------------------------------------
;;; Revisions
;;; ---------------------------------------------------------------------------

(defun brain--rev (seq digest)
  "Build a revision plist for this writer."
  (list :writer-id brain-writer-id :seq seq :sha256 digest))

(defun brain--rev-seq (rev) (plist-get rev :seq))
(defun brain--rev-sha (rev) (plist-get rev :sha256))

(defun brain--rev->json (rev)
  (when rev
    (list (cons "writer_id" (plist-get rev :writer-id))
          (cons "seq" (plist-get rev :seq))
          (cons "sha256" (plist-get rev :sha256)))))

(defun brain--rev<-json (object)
  (when object
    (list :writer-id (alist-get "writer_id" object nil nil #'equal)
          :seq (alist-get "seq" object nil nil #'equal)
          :sha256 (alist-get "sha256" object nil nil #'equal))))

(defun brain--rev-equal (a b)
  (and (eq (null a) (null b))
       (or (null a)
           (and (equal (plist-get a :writer-id) (plist-get b :writer-id))
                (equal (plist-get a :seq) (plist-get b :seq))
                (equal (plist-get a :sha256) (plist-get b :sha256))))))

(defun brain--rev-valid-p (rev)
  (and (listp rev)
       (stringp (plist-get rev :writer-id))
       (integerp (plist-get rev :seq))
       (>= (plist-get rev :seq) 0)
       (stringp (plist-get rev :sha256))
       (= (length (plist-get rev :sha256)) 64)))

;;; ---------------------------------------------------------------------------
;;; File identity and safe path resolution
;;; ---------------------------------------------------------------------------

(defun brain--root-dir (root)
  "Return the directory configured for ROOT, or nil."
  (let ((cell (assoc root brain-managed-roots)))
    (when cell (file-name-as-directory (expand-file-name (cdr cell))))))

;;; ---------------------------------------------------------------------------
;;; The one eligibility predicate (design t_c52859ca v2 §3)
;;; ---------------------------------------------------------------------------
;;
;; §3 requires "one documented eligibility predicate ... implemented equivalently
;; on both sides and tested with shared fixtures", with "authoritative filesystem
;; enforcement ... at Mac snapshot/commit/lifecycle use, not the earlier listing".
;; So this function is PURE: it decides from the identity text alone and touches
;; no filesystem.  Whether the path is really a regular non-symlink UTF-8 file is
;; a separate fact, checked at actual use (`brain--resolve' lstats every
;; component; the census skips symlinks and non-regular entries as it walks).
;;
;; The category vocabulary is the cross-language contract, and
;; `tests/fixtures/eligibility.json' pins every case.  A Python exception type or
;; message is explicitly NOT part of it: E4 reports the same category strings.
;;
;; Precedence is part of the contract, because one path can match several classes
;; (`.git/x.org~' is both an excluded directory and a backup).  The order below is
;; the documented one and the fixture pins it: the more specific structural
;; refusal wins over the more general one, and the root is decided before the
;; segments.  Nothing here is a heuristic: every class is an explicit name or
;; extension rule from §3, and §3 forbids excluding names merely because they
;; contain "test", "temp" or "latex".

(defconst brain--excluded-directories
  '(".git" ".hg" ".svn" ".cache" ".trash" "tmp" "temp" "build" "dist"
    "generated" "exports" "auto-save-list")
  "Directory names §3 excludes at any depth.  Compared exactly, never by prefix.")

(defconst brain--swap-suffixes '(".swp" ".swo")
  "Editor swap suffixes §3 excludes.")

(defun brain--eligibility (root relative)
  "Return nil when ROOT/RELATIVE is eligible, else a refusal category.
  Categories, in precedence order: unknown_root, absolute, backslash,
  sync_conflict, dot_hash, hash_bracket, backup_tilde, swap, not_org,
  excluded_directory, traversal, empty_segment, control, segment_too_long,
  path_too_long, not_nfc. The value is a string from that closed vocabulary;
  the same strings are what the Python side reports, so a test can compare two
  implementations without comparing two languages' exception types.

  The structural name classes come BEFORE the extension check on purpose:
  `#x.org#' is an auto-save file and `x.org~' is a backup, and neither ends in
  `.org' -- so an extension-first order would report them as merely \"not an
  Org file\" and lose the fact that matters.  The extension check then catches
  everything else that is simply not Org."
  (let ((segments (and (stringp relative) (split-string relative "/"))))
    (cond
     ((not (member root '("org-files" "org-roam"))) "unknown_root")
     ((not (stringp relative)) "empty_segment")
     ((string-prefix-p "/" relative) "absolute")
     ((string-search "\\" relative) "backslash")
     ((string-search ".sync-conflict-" relative) "sync_conflict")
     ;; A component that starts with ".#" is an Emacs lock file.
     ((seq-find (lambda (segment) (string-prefix-p ".#" segment)) segments) "dot_hash")
     ;; A component enclosed in "#" is an auto-save file.
     ((seq-find (lambda (segment)
                  (and (> (length segment) 1)
                       (string-prefix-p "#" segment)
                       (string-suffix-p "#" segment)))
                segments)
      "hash_bracket")
     ((seq-find (lambda (segment) (string-suffix-p "~" segment)) segments) "backup_tilde")
     ((seq-find (lambda (segment)
                  (seq-find (lambda (suffix) (string-suffix-p suffix segment))
                            brain--swap-suffixes))
                segments)
      "swap")
     ((not (string-suffix-p ".org" relative)) "not_org")
     ;; Only DIRECTORY components count: a file legitimately named "build.org" is
     ;; not inside a "build" directory.  The last segment is the file itself.
     ((seq-find (lambda (segment) (member segment brain--excluded-directories))
                (butlast segments))
      "excluded_directory")
     ((seq-find (lambda (segment) (member segment '("." ".."))) segments) "traversal")
     ((seq-find #'string-empty-p segments) "empty_segment")
     ((seq-find (lambda (segment)
                  (seq-find (lambda (character) (or (< character 32) (= character 127)))
                            segment))
                segments)
      "control")
     ((seq-find (lambda (segment) (> (length segment) 255)) segments) "segment_too_long")
     ((> (length relative) 1024) "path_too_long")
     ((not (string= (brain--nfc relative) relative)) "not_nfc")
     (t nil))))

(defun brain--eligible-p (root relative)
  "Non-nil when ROOT/RELATIVE is eligible.  See `brain--eligibility'."
  (null (brain--eligibility root relative)))

(defun brain--check-relative-path (relative)
  "Signal `brain-invalid-path' unless RELATIVE is an admissible relative path.
This is the identity guard every existing caller already used; it now delegates
the decision to the one predicate, so a path cannot be admissible here and
ineligible there."
  (let ((category (brain--eligibility "org-files" relative)))
    (when category
      (signal 'brain-invalid-path (list relative category))))
  relative)

(defun brain--make-file-id (root relative)
  "Return ROOT/RELATIVE after validating both parts."
  (unless (brain--root-dir root)
    (signal 'brain-invalid-path (list root)))
  (concat root "/" (brain--check-relative-path relative)))

(defun brain--split-file-id (file-id)
  "Split FILE-ID into (ROOT . RELATIVE) after validating it."
  (unless (and (stringp file-id) (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" file-id))
    (signal 'brain-invalid-path (list file-id)))
  (let ((root (match-string 1 file-id))
        (relative (match-string 2 file-id)))
    (brain--make-file-id root relative)
    (cons root relative)))

(defun brain--alias-key (file-id)
  "Case-folded alias key of FILE-ID, to refuse collapsing identities. The key is
  NFC plus Unicode casefold (§3), the same definition the Python store uses for
  `files.alias_key'.  It was `downcase' before E2, which is a different
  function on 298 code points: two paths that the store collapses (`Straße.org'
  and `STRASSE.org') did not collapse here, so the Mac would accept an identity
  the gateway then refuses."
  (let* ((split (brain--split-file-id file-id)))
    (concat (car split) "/" (brain--casefold (brain--nfc (cdr split))))))

(defun brain--register-identity (file-id)
  "Register FILE-ID, refusing an alias of a different identity."
  (let* ((alias (brain--alias-key file-id))
         (known (gethash alias brain--identities)))
    (cond
     ((null known) (puthash alias file-id brain--identities) file-id)
     ((equal known file-id) file-id)
     (t (signal 'brain-alternate-route (list file-id known))))))

(defun brain--identity-for-path (path)
  "Return the managed file_id for PATH, or nil when unmanaged."
  (when (and (stringp path) (string-match-p "\\.org\\'" path))
    (let ((absolute (expand-file-name path)))
      (cl-loop for (root . directory) in brain-managed-roots
               for root-dir = (file-name-as-directory (expand-file-name directory))
               when (string-prefix-p root-dir absolute)
               return (ignore-errors
                        (brain--make-file-id root (substring absolute (length root-dir))))))))

(defun brain--resolve (file-id)
  "Resolve FILE-ID to a plist :status ok|absent|unsafe, :path and :reason.
Every component is lstat'ed from the configured root down; a symlink, a
non-regular file or a root that escapes its configuration is unsafe."
  (condition-case err
      (let* ((split (brain--split-file-id file-id))
             (root (car split))
             (relative (cdr split))
             (root-dir (brain--root-dir root)))
        (cond
         ((null root-dir)
          (list :status "unsafe" :reason "unknown_root" :file-id file-id))
         ((file-symlink-p (directory-file-name root-dir)))
         (t
          (let* ((root-abs (directory-file-name (expand-file-name root-dir)))
                 (target (expand-file-name relative (file-name-as-directory root-abs)))
                 (current root-abs)
                 (unsafe nil)
                 (absent nil))
            (unless (string-prefix-p (file-name-as-directory root-abs) target)
              (setq unsafe "path_escape"))
            (dolist (segment (split-string relative "/"))
              (unless unsafe
                (setq current (expand-file-name segment (file-name-as-directory current)))
                (let* ((attributes (file-attributes current 'string))
                       (type (car attributes)))
                  (cond
                   ((null attributes) (setq absent t))
                   ((stringp type) (setq unsafe "symlink_component"))
                   ((and (eq t type) (not (string= current target)))
                    (setq unsafe "unexpected_intermediate_file"))
                   ((and (not (eq t type)) (string= current target) type)
                    (setq unsafe "not_a_regular_file"))
                   ((and (eq t type) (string= current target))
                    (setq unsafe "not_a_regular_file"))))))
            (cond
             (unsafe (list :status "unsafe" :reason unsafe :file-id file-id))
             (absent (list :status "absent" :path target :file-id file-id))
             (t (list :status "ok" :path target :file-id file-id)))))))
    (brain-invalid-path (list :status "unsafe" :reason "invalid_path" :file-id file-id))
    (error (list :status "unsafe" :reason (format "resolve_error:%s" (car err))
                 :file-id file-id))))

(defun brain--file-path (file-id)
  (plist-get (brain--resolve file-id) :path))

;;; ---------------------------------------------------------------------------
;;; Journal and heads cache
;;; ---------------------------------------------------------------------------

(defconst brain--revision-fields
  '("prev_revision" "new_revision" "base_revision" "revision" "current_revision"
    ;; §3 lifecycle: the retained head of a retired source, and the canonical
    ;; revision a relocation or reactivation gives its destination.  Adding a name
    ;; here only teaches the record encoder/decoder to spell that field as a
    ;; revision object; no pre-existing record uses these names.
    "source_revision" "destination_revision" "destination_predecessor")
  "Record fields whose value is a revision object rather than a plain value.")

(defun brain--record->json (record)
  "Convert RECORD (a plist with keyword keys) to a JSON-ready alist."
  (let ((out nil)
        (rest record))
    (while (consp rest)
      (let* ((key (car rest))
             (value (car (cdr rest)))
             (name (string-remove-prefix ":" (symbol-name key))))
        (push (cons name (if (member name brain--revision-fields)
                             (brain--rev->json value)
                           value))
              out))
      (setq rest (cdr (cdr rest))))
    (nreverse out)))

(defun brain--json->record (object)
  "Convert one JSON alist back to a record plist."
  (let ((out nil))
    (dolist (cell object)
      (let ((name (car cell)) (value (cdr cell)))
        (push (intern (concat ":" name)) out)
        (push (if (member name brain--revision-fields)
                  (brain--rev<-json value)
                value)
              out)))
    (nreverse out)))

(defun brain--journal-append (kind &rest fields)
  "Append one durable journal record of KIND, flush it, return its sequence."
  (brain--journal-write nil kind fields))

(defun brain--journal-append-nofsync (kind &rest fields)
  "Append KIND without flushing; the caller fsyncs after the critical section."
  (brain--journal-write t kind fields))

(defun brain--journal-size ()
  "Current byte length of the journal file, or 0 when it does not exist."
  (let ((attributes (file-attributes (brain--journal-file))))
    (if attributes (file-attribute-size attributes) 0)))

(defun brain--journal-latch-fault (reason detail local-seq)
  "Latch the journal fault.  The first reason wins; every one is logged."
  (unless brain--journal-fault
    (setq brain--journal-fault
          (list :reason reason :detail detail :local-seq local-seq)))
  (brain--log "journal fault (%s) at local-seq %S: %S" reason local-seq detail))

(defun brain--journal-write (no-fsync kind fields)
  "Append one durable journal record of KIND; return its sequence.

E9c: the identity is allocated TENTATIVELY and published only after the append
succeeded.  The reviewed writer incremented `brain--journal-seq' first and wrote
second, so a failed append burned a sequence number and left no record in the
file, in `brain--journal' or in `brain--outbox' — which is exactly how 656
contiguous records vanished from the live journal while their `ack' neighbours
survived.  Two failure shapes are distinguished by measurement, not by guessing:

* the file is byte-identical after the failure — the append wrote nothing, so
  identity is unspent and the caller may retry it;
* the file grew — a partial line may be on disk, so the fault is latched and no
  further record is written until a reload validates the file.

A failed flush keeps the identity (the bytes may be durable) and latches the
fault: reusing a possibly-written identity is worse than stopping."
  (when brain--journal-fault
    (signal 'brain-journal-fault
            (list (plist-get brain--journal-fault :reason))))
  (let* ((next (1+ brain--journal-seq))
         (at (round (float-time)))
         (record (append (list :local-seq next :kind kind :at at) fields))
         (line (concat (brain--json-encode (brain--record->json record)) "\n"))
         (file (brain--journal-file))
         (brain--inhibit-guards t)
         (coding-system-for-write 'utf-8-unix)
         (before (brain--journal-size)))
    (make-directory (file-name-directory file) t)
    (condition-case err
        (write-region line nil file 'append 'no-message)
      (error
       (if (= before (brain--journal-size))
           (progn
             ;; Zero-byte failure: nothing reached the file, so nothing was
             ;; published and the identity stays available for the retry.
             (brain--log "journal append wrote nothing: %S" err)
             (signal 'brain-journal-fault
                     (list (format "journal append failed: %S" err))))
         (brain--journal-latch-fault "append_partial" err next)
         (signal 'brain-journal-fault
                 (list (format "journal append damaged the tail: %S" err))))))
    ;; The record is in the file: its identity is now published.
    (setq brain--journal-seq next)
    (setq brain--journal (append brain--journal (list record)))
    (unless no-fsync
      (unless (brain--fsync file)
        (brain--journal-latch-fault "fsync" nil next)
        (signal 'brain-journal-fault (list "journal flush failed"))))
    brain--journal-seq))

(defun brain--journal-decode-line (line number)
  "Decode one journal LINE (unibyte bytes) as UTF-8 text, or signal.

The journal is written with `coding-system-for-write' `utf-8-unix', so a line is
UTF-8 BYTES, not characters.  Inserting those bytes into a multibyte buffer
without decoding them turns every byte of a non-ASCII character into a separate
raw-byte character, and the line then fails to parse as JSON: a perfectly valid
journal containing `café' or an emoji was refused as corrupt by both the reload
and the exporter, which would stop the writer on restart.  So the bytes are
decoded here, and only here.

Decoding must not become leniency.  `decode-coding-string' maps an invalid byte
sequence to raw-byte characters (#x3FFF80..#x3FFFFF); those are refused, because
a journal this writer cannot read is damage, not content.  Valid UTF-8 decodes to
no raw-byte character at all, so the test is exact in both directions."
  (let ((text (decode-coding-string line 'utf-8)))
    (when (seq-some (lambda (char) (and (>= char #x3FFF80) (<= char #x3FFFFF)))
                    (string-to-list text))
      (signal 'brain-journal-corrupt
              (list (format "journal line %d is not valid UTF-8" number))))
    text))

(defun brain--journal-check-envelope (record number)
  "Refuse an event RECORD whose journal identity and envelope disagree.

The reviewed writer journals `:wire_seq', `:event_kind' and `:file_id' beside the
envelope it is about to send, so the two spellings of one identity must agree.
A record claiming `wire_seq 1' while its envelope says `seq 9' is not a record
this writer produced; accepting it would let a damaged file certify a writer
identity it does not have, which is exactly what the strict reload exists to
prevent."
  (let* ((payload (plist-get record :payload))
         (wire (plist-get record :wire_seq))
         (kind (plist-get record :event_kind))
         (record-file (plist-get record :file_id))
         (payload-seq (and (consp payload) (alist-get "seq" payload nil nil #'equal)))
         (payload-kind (and (consp payload) (alist-get "kind" payload nil nil #'equal)))
         (payload-body (and (consp payload) (alist-get "payload" payload nil nil #'equal)))
         (payload-file (and (consp payload-body)
                            (alist-get "file_id" payload-body nil nil #'equal))))
    (unless (equal wire payload-seq)
      (signal 'brain-journal-corrupt
              (list (format "journal line %d: wire_seq %S is not the envelope seq %S"
                            number wire payload-seq))))
    (when (and kind (not (equal kind payload-kind)))
      (signal 'brain-journal-corrupt
              (list (format "journal line %d: event_kind %S is not the envelope kind %S"
                            number kind payload-kind))))
    (when (and record-file payload-file (not (equal record-file payload-file)))
      (signal 'brain-journal-corrupt
              (list (format "journal line %d: file_id %S is not the envelope file_id %S"
                            number record-file payload-file))))
    record))

(defun brain--journal-parse (bytes)
  "Parse BYTES as a journal and return its records, or signal.

One reader for both the reload and the evidence exporter: evidence that accepted
a file the writer refuses would prove nothing.  Every line must be valid UTF-8
and parse as JSON, `local-seq' must be strictly increasing, no event may repeat
a `wire_seq' or an `event_id', and every event's journal identity must agree with
its own envelope.  Nothing is repaired here."
  (let ((records nil)
        (last-local 0)
        (wire (make-hash-table :test #'eql))
        (events (make-hash-table :test #'equal)))
    (when bytes
      ;; Split on the byte level: the offsets a hash covers are byte offsets, and
      ;; decoding the whole file first would move them.
      (let ((lines (split-string bytes "\n"))
            (number 0))
        ;; A file that does not end in a newline carries a partial last record.
        ;; It is not repaired: the writer that produced it must be investigated.
        (unless (or (= (length bytes) 0) (eq (aref bytes (1- (length bytes))) ?\n))
          (signal 'brain-journal-corrupt (list "journal does not end in a newline")))
        (dolist (line lines)
          (setq number (1+ number))
          (unless (string-empty-p (string-trim line))
            (let* ((text (brain--journal-decode-line line number))
                   (decoded (condition-case nil
                                (brain--json-decode text)
                              (error
                               (signal 'brain-journal-corrupt
                                       (list (format "journal line %d is not valid JSON"
                                                     number))))))
                   (record (brain--json->record decoded))
                   (local (plist-get record :local-seq)))
              (unless (and (integerp local) (> local last-local))
                (signal 'brain-journal-corrupt
                        (list (format "journal local-seq %S is not strictly increasing"
                                      local))))
              (setq last-local local)
              (when (equal (plist-get record :kind) "event")
                (brain--journal-check-envelope record number)
                (let ((seq (plist-get record :wire_seq))
                      (event-id (alist-get "event_id"
                                           (plist-get record :payload) nil nil #'equal)))
                  (when (and (integerp seq) (> (gethash seq wire 0) 0))
                    (signal 'brain-journal-corrupt
                            (list (format "journal wire_seq %S is duplicated" seq))))
                  (when (integerp seq) (puthash seq 1 wire))
                  (when (and (stringp event-id) (gethash event-id events))
                    (signal 'brain-journal-corrupt
                            (list (format "journal event_id %s is duplicated" event-id))))
                  (when (stringp event-id) (puthash event-id t events))))
              (push record records))))))
    (nreverse records)))

(defun brain--journal-load ()
  "Load the durable journal into `brain--journal'.

E9c: the file is validated strictly before it is trusted.  A reload is the only
way out of `brain--journal-fault', so it must not paper over damage.  Nothing is
truncated, renumbered or repaired here — a damaged journal stays damaged and the
fault stays latched, which is what makes the loss visible instead of silently
re-baselining it."
  (setq brain--journal nil
        brain--journal-seq 0)
  (let* ((file (brain--journal-file))
         (bytes (when (file-regular-p file)
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (let ((coding-system-for-read 'utf-8-unix))
                      (insert-file-contents file))
                    (buffer-string))))
         (records (brain--journal-parse bytes)))
    (setq brain--journal records)
    (setq brain--journal-seq
          (or (cl-loop for record in records maximize (or (plist-get record :local-seq) 0))
              0)))
  ;; Only a complete, consistent file clears the latch.
  (setq brain--journal-fault nil)
  brain--journal-seq)

(defun brain--journal-records (kind)
  (seq-filter (lambda (record) (equal (plist-get record :kind) kind)) brain--journal))

(defun brain--heads-save ()
  "Write the rebuildable heads cache atomically."
  (let* ((alist nil)
         (file (brain--heads-file))
         (brain--inhibit-guards t))
    (maphash (lambda (file-id rev) (push (cons file-id (brain--rev->json rev)) alist))
             brain--heads)
    (make-directory (file-name-directory file) t)
    (let ((temp (make-temp-file (expand-file-name ".heads-" (file-name-directory file))))
          (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (write-region (brain--json-encode
                           (list (cons "version" 1)
                                 (cons "heads" (or alist :null))))
                          nil temp nil 'no-message)
            (rename-file temp file t))
        (when (file-exists-p temp) (ignore-errors (delete-file temp)))))
    (brain--fsync file)
    t))

;;; ---------------------------------------------------------------------------
;;; Objects and atomic replacement
;;; ---------------------------------------------------------------------------

(defun brain--publish-object (bytes digest &optional producer)
  "Publish BYTES as objects/PRODUCER/<DIGEST>.org without overwriting.
PRODUCER defaults to this peer's own namespace (mac)."
  (let* ((producer (or producer "mac"))
         (final (brain--object-path producer digest))
         (directory (file-name-directory final))
         (brain--inhibit-guards t)
         (coding-system-for-write 'binary))
    (make-directory directory t)
    (cond
     ((file-exists-p final)
      (if (equal (brain--sha256-file final) digest)
          t
        (signal 'brain-alternate-route (list "object_bytes_differ" final))))
     (t
      (let ((temp (make-temp-file (expand-file-name ".brain-obj-" directory))))
        (unwind-protect
            (progn
              (write-region bytes nil temp nil 'no-message)
              (rename-file temp final nil))
          (when (file-exists-p temp) (ignore-errors (delete-file temp))))
        t)))))

(defun brain--rename-file-primitive (from to &optional ok-if-exists)
  "Rename FROM to TO with the file primitive, firing no `rename-file' advice.
`brain--atomic-replace' runs inside the no-yield section, where user-facing
advice must not run: `org-roam-db-autosync-mode' advises `rename-file' with
`org-roam-db-autosync--rename-file-a', which calls `org-roam-db-update-file'
and that re-saves the buffer visiting TO.  Because brain has just replaced the
file, that nested `basic-save-buffer' sees a stale visited modtime and asks
\"<file> has changed since visited or saved.  Save anyway?\", which blocks a
daemon with no user at the keyboard forever (and \"no\" becomes `user-error',
i.e. `commit_error:user-error').  The cache that advice maintains is refreshed
by the commit itself: `brain--run-post-commit-hooks' runs `after-save-hook' for
every already visiting buffer, and a human save's own buffer gets it from
`basic-save-buffer' once the handler returns.

Every advice layer is peeled, not just one: the order of advice on
`rename-file' depends on load order.  `Emacs.org' enables
`org-roam-db-autosync-mode' before `brain-enable', so there the outermost layer
is brain's own guard and org-roam's advice sits underneath it; tests that
enable them the other way round see the opposite order.  `advice--cd*r' walks
to the primitive whatever the order and however many layers there are."
  (funcall (advice--cd*r (symbol-function #'rename-file)) from to ok-if-exists))

(defun brain--atomic-replace (path bytes)
  "Replace PATH with BYTES via a same-directory rename, preserving its mode."
  (let* ((directory (file-name-directory path))
         (mode (or (file-modes path) #o644))
         (brain--inhibit-guards t)
         (temp (make-temp-file (expand-file-name ".brain-new-" directory))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region bytes nil temp nil 'no-message))
          (set-file-modes temp mode)
          (brain--rename-file-primitive temp path t))
      (when (file-exists-p temp) (ignore-errors (delete-file temp))))
    path))

(defun brain--read-object (producer digest expected-length)
  "Return the verified bytes of PRODUCER/DIGEST.org, or a symbol reason.
The value is a unibyte string, or one of `missing', `mismatch', `oversize'."
  (let ((path (brain--object-path producer digest)))
    (cond
     ((not (file-regular-p path)) 'missing)
     ((and expected-length
           (> (file-attribute-size (file-attributes path)) expected-length))
      'mismatch)
     (t
      (let ((bytes (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally path)
                     (buffer-string))))
        (cond
         ((and expected-length (/= (length bytes) expected-length)) 'mismatch)
         ((> (length bytes) brain-object-max-bytes) 'oversize)
         ((not (equal (brain--sha256 bytes) digest)) 'mismatch)
         (t bytes)))))))

;;; ---------------------------------------------------------------------------
;;; Buffers: identity, dirty state and refresh
;;; ---------------------------------------------------------------------------

(defun brain--buffer-base (buffer)
  (with-current-buffer buffer (or (buffer-base-buffer) buffer)))

(defun brain--buffer-file-id (buffer)
  "Return the managed file_id visited by BUFFER, direct or indirect."
  (when (buffer-live-p buffer)
    (let* ((base (brain--buffer-base buffer))
           (truename (buffer-local-value 'buffer-file-truename base))
           (name (buffer-local-value 'buffer-file-name base)))
      (or (and (stringp truename) (brain--identity-for-path truename))
          (and (stringp name) (brain--identity-for-path name))))))

(defun brain--managed-buffer-p (&optional buffer)
  (and (brain--buffer-file-id (or buffer (current-buffer))) t))

(defun brain--visiting-buffers (file-id)
  "Every live buffer whose true identity is FILE-ID (base and indirect)."
  (seq-filter (lambda (buffer)
                (and (buffer-live-p buffer)
                     (equal (brain--buffer-file-id buffer) file-id)))
              (buffer-list)))

(defun brain--base-buffers (buffers)
  (delete-dups (mapcar #'brain--buffer-base buffers)))

(defun brain--human-source-base (spec)
  "Base buffer of a human save's own buffer, or nil for any other commit."
  (let ((source (and (equal (or (plist-get spec :origin) "human") "human")
                     (plist-get spec :buffer))))
    (and (bufferp source) (buffer-live-p source) (brain--buffer-base source))))

(defun brain--refreshable-buffers (spec buffers)
  "BUFFERS minus the base buffer of the human save that produced this commit.
The saving buffer already holds the exact installed bytes: erasing and
reinserting them would destroy its markers, folding and undo list, and
`basic-save-buffer' runs `after-save-hook' in it once after the handler
returns.  Only already visiting clean buffers are refreshed."
  (let ((source (brain--human-source-base spec)))
    (if source
        (seq-remove (lambda (buffer) (eq (brain--buffer-base buffer) source))
                    buffers)
      buffers)))

(defun brain--buffer-dirty-p (buffer)
  (and (buffer-live-p buffer)
       (with-current-buffer buffer (buffer-modified-p))))

(defun brain--any-buffer-dirty-p (buffers)
  (seq-find #'brain--buffer-dirty-p buffers))

(defun brain--autosave-file (file-id)
  "Return the auto-save file name Emacs would use for FILE-ID, or nil."
  (let ((path (brain--file-path file-id)))
    (when path
      (condition-case nil
          (with-temp-buffer
            (setq buffer-file-name path)
            (make-auto-save-file-name))
        (error nil)))))

(defun brain--recovery-marker (file-id)
  "Return a reason string when FILE-ID has a persistent dirty/recovery marker."
  (let* ((lease (gethash file-id brain--dirty))
         (autosave (brain--autosave-file file-id))
         (path (brain--file-path file-id)))
    (cond
     (lease "dirty_lease")
     ((and autosave
           (file-exists-p autosave)
           (or (not (file-exists-p path))
               (time-less-p (file-attribute-modification-time (file-attributes path))
                            (file-attribute-modification-time (file-attributes autosave)))))
      "autosave_marker")
     (t nil))))

(defun brain--refresh-buffer (buffer text)
  "Replace BUFFER's text with TEXT, preserving point, narrowing and windows.
Modification hooks and undo recording are inhibited; the buffer ends unmodified
and its visited modtime matches the file just installed."
  (with-current-buffer (brain--buffer-base buffer)
    (let* ((windows (get-buffer-window-list (current-buffer) nil t))
           (states (mapcar (lambda (window)
                             (list window (window-start window) (window-point window)))
                           windows))
           (narrowed (buffer-narrowed-p))
           (start (point-min))
           (end (point-max))
           (point (point))
           (inhibit-read-only t)
           (inhibit-modification-hooks t)
           (inhibit-field-text-motion t)
           (buffer-undo-list t))
      (save-restriction
        (widen)
        (erase-buffer)
        (insert text))
      (if narrowed
          (narrow-to-region (min start (point-max)) (min end (point-max)))
        (widen))
      (goto-char (min point (point-max)))
      (set-buffer-modified-p nil)
      (set-visited-file-modtime)
      ;; The cache never saw these edits: modification hooks are inhibited, so
      ;; it must be rebuilt instead of erroring on its next access (which would
      ;; pop a *Warnings* window from the daemon).  This is not a parser run.
      (when (and (derived-mode-p 'org-mode) (fboundp 'org-element-cache-reset))
        (org-element-cache-reset nil t))
      (dolist (state states)
        (let ((window (nth 0 state)))
          (when (window-live-p window)
            (set-window-start window (min (nth 1 state) (point-max)) t)
            (set-window-point window (min (nth 2 state) (point-max)))))))
    t))

(defun brain--refresh-all (buffers text)
  "Replace the shared text with TEXT, restoring each alias's own view.
Every visiting buffer keeps its point, narrowing and window state; the text is
written once through the base buffer so aliases cannot diverge."
  (let ((states (mapcar (lambda (buffer)
                          (with-current-buffer buffer
                            (list buffer (point) (point-min) (point-max)
                                  (buffer-narrowed-p))))
                        buffers))
        (bases (brain--base-buffers buffers)))
    (dolist (buffer bases)
      (brain--refresh-buffer buffer text))
    (dolist (state states)
      (let ((buffer (nth 0 state)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (unless (memq buffer bases)
              (when (nth 4 state)
                (narrow-to-region (min (nth 2 state) (point-max))
                                  (min (nth 3 state) (point-max)))))
            (goto-char (min (nth 1 state) (point-max)))
            (when (buffer-file-name) (set-visited-file-modtime)))))))
  t)

(defun brain--clamp-visiting-buffer (buffer)
  "Clamp BUFFER's point into its current text without touching the text."
  (with-current-buffer buffer
    (let ((point (point)))
      (cond
       ((> point (point-max)) (goto-char (point-max)))
       ((< point (point-min)) (goto-char (point-min)))))
    (when (buffer-file-name) (set-visited-file-modtime))
    t))

;;; ---------------------------------------------------------------------------
;;; Encoding
;;; ---------------------------------------------------------------------------

(defun brain--utf8-coding-p (coding)
  "Non-nil when CODING writes UTF-8, or is still undecided.
`undecided' means Emacs has not yet picked an encoding for this file; writing
UTF-8 is then exactly what a normal save would do, and the object stays UTF-8."
  (let ((base (and coding (coding-system-base coding))))
    (or (null base)
        (eq base 'utf-8)
        (memq base '(undecided prefer-utf-8)))))

(defun brain--encode-buffer-text (&optional buffer)
  "Encode BUFFER's exact text as a unibyte UTF-8 string.
Returns `unsupported-coding' when the buffer's coding system is a non-UTF-8
encoding and `lossy-coding' when the round trip would change the text."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((declared (or buffer-file-coding-system 'utf-8-unix))
           (coding (if (memq (coding-system-base declared) '(undecided prefer-utf-8))
                       'utf-8-unix
                     declared))
           (text (buffer-substring-no-properties (point-min) (point-max))))
      (cond
       ((not (brain--utf8-coding-p declared)) 'unsupported-coding)
       (t
        (let ((encoded (condition-case nil
                           (encode-coding-string text coding)
                         (error nil))))
          (cond
           ((null encoded) 'lossy-coding)
           ((not (string= (decode-coding-string encoded coding) text)) 'lossy-coding)
           ((> (length encoded) brain-object-max-bytes) 'too_large)
           (t encoded))))))))

;;; ---------------------------------------------------------------------------
;;; Results and attention
;;; ---------------------------------------------------------------------------

(defun brain--result (status file-id &rest fields)
  (append (list :status status :file-id file-id) fields))

(defun brain--journal-result (result)
  "Journal one durable install result so a replay can answer after restart."
  (let ((key (or (plist-get result :attempt-id) (plist-get result :operation-id))))
    (when key
      (puthash key result brain--results)
      (brain--journal-append "result" :result_key key
                             :file_id (plist-get result :file-id)
                             :status (plist-get result :status)
                             :current_revision (plist-get result :current-revision)
                             :new_revision (plist-get result :new-revision)
                             :mac_seq (plist-get result :mac-seq)
                             :reason (plist-get result :reason))))
  result)

(defun brain--attention (file-id reason &optional operation-id)
  "Record a durable attention state for FILE-ID and journal the reason."
  (puthash file-id reason brain--attention)
  (brain--journal-append "attention" :file_id file-id :reason reason
                         :operation_id operation-id)
  (brain--result "attention" file-id :reason reason
                 :current-revision (gethash file-id brain--heads)))
;;; ---------------------------------------------------------------------------
;;; Semantic projection (derived from the exact committed bytes)
;;; ---------------------------------------------------------------------------

(defun brain--projection-parse (bytes file-id revision)
  "Parse BYTES in a temporary buffer that visits no file and runs no hook."
  (with-temp-buffer
    (insert (decode-coding-string bytes 'utf-8))
    (delay-mode-hooks (org-mode))
    (org-with-wide-buffer
     (goto-char (point-min))
     (let ((headings nil) (count 0) (truncated nil) (filetags nil))
       (when (re-search-forward "^#\\+filetags:[ \t]*\\(.*\\)$" nil t)
         (setq filetags (split-string (match-string-no-properties 1) ":" t)))
       (goto-char (point-min))
       (while (and (not truncated) (re-search-forward "^\\*+ " nil t))
         (if (>= count brain-projection-max-headings)
             (setq truncated t)
           (let ((element (org-element-at-point (match-beginning 0))))
             (when (eq (org-element-type element) 'headline)
               (setq count (1+ count))
               (let* ((begin (org-element-property :begin element))
                      (heading (list (cons "level" (org-element-property :level element))
                                     (cons "title"
                                           (substring-no-properties
                                            (or (org-element-property :raw-value element)
                                                "")))))
                      (todo (org-element-property :todo-keyword element))
                      (tags (org-element-property :tags element)))
                 (when todo (push (cons "todo" todo) heading))
                 (when tags (push (cons "tags" tags) heading))
                 (dolist (property '(("ID" . "id")
                                     ("PROJECT" . "project")
                                     ("BRAIN_KIND" . "brain_kind")
                                     ("KANBAN_BOARD" . "kanban_board")
                                     ("KANBAN_TASK" . "kanban_task")
                                     ("KANBAN_ASSIGNEE" . "kanban_assignee")))
                   (let ((value (org-entry-get begin (car property))))
                     (when (and value (not (string-empty-p value)))
                       (push (cons (cdr property) value) heading))))
                 (push (nreverse heading) headings))))))
       (list (cons "file_id" file-id)
             (cons "revision" (brain--rev->json revision))
             (cons "filetags" (or (and filetags (cons :json-array filetags)) :null))
             (cons "headings" (cons :json-array (or (nreverse headings) nil)))
             (cons "truncated" (if truncated t :false)))))))

(defun brain--projection (bytes file-id revision)
  "Return a bounded semantic projection parsed from BYTES.
The Org parser runs here, before the no-yield section, in a temporary buffer
that visits no file and runs no user hook.  Nil means the projection must be
deferred with attention instead of being dropped."
  (condition-case err
      (let ((semantic (brain--projection-parse bytes file-id revision)))
        (if (and semantic
                 (<= (length (encode-coding-string (brain--json-encode semantic)
                                                   'utf-8))
                     brain-projection-max-bytes))
            semantic
          nil))
    (error
     (brain--log "projection failed for %s: %s" file-id (car err))
     nil)))

(defun brain--projection-with-status (bytes file-id revision)
  "Return (semantic . PLIST) or (deferred . REASON) for BYTES."
  (condition-case err
      (let ((semantic (brain--projection-parse bytes file-id revision)))
        (cond
         ((null semantic) (cons 'deferred "projection_empty"))
         ((> (length (encode-coding-string (brain--json-encode semantic) 'utf-8))
             brain-projection-max-bytes)
          (cons 'deferred "projection_overflow"))
         (t (cons 'semantic semantic))))
    (error (cons 'deferred (format "projection_failed:%s" (car err))))))

(defconst brain--projection-deferral-reasons '("projection_empty" "projection_overflow")
  "Attention-kind journal reasons that are deferrals, not attention rows.
`brain--defer-projection' journals under the `attention' kind because a
deferral must be durable and visible, but it is not a human decision: the
in-memory table it fills is `brain--deferred'.  A rebuild must not turn one
into an attention row, or a path whose projection merely overflowed could never
be retired as missing, and `brain-status' would report attention for a derived
manifest that is disposable by design.")

(defun brain--projection-deferral-reason-p (reason)
  "Non-nil when REASON names a deferred projection rather than an attention row."
  (and (stringp reason)
       (or (member reason brain--projection-deferral-reasons)
           (string-prefix-p "projection_failed:" reason))))

(defun brain--defer-projection (file-id reason operation-id revision)
  "Record that FILE-ID's semantic projection is deferred, visibly and durably.
The committed bytes stay committed; only the derived manifest waits, so a hot
task is never lost and never reported as a conflict."
  (puthash file-id (list :reason reason :operation-id operation-id
                         :revision revision)
           brain--deferred)
  (brain--journal-append "attention" :file_id file-id :reason reason
                         :operation_id operation-id :revision revision)
  reason)

(defun brain--projection-for (bytes file-id revision operation-id)
  "Return the bounded projection for BYTES, recording a deferral when needed."
  (let* ((probe (brain--projection-with-status bytes file-id revision))
         (semantic (and (eq (car probe) 'semantic) (cdr probe))))
    (if semantic
        (progn (remhash file-id brain--deferred) semantic)
      (brain--defer-projection file-id (cdr probe) operation-id revision)
      nil)))

;;; ---------------------------------------------------------------------------
;;; The commit primitive
;;; ---------------------------------------------------------------------------

(defun brain-commit-file (spec)
  "The one enforcement point for managed canonical writes.

SPEC is a plist:
  :file-id            managed identity (required)
  :bytes              exact UTF-8 bytes to install (required)
  :origin             \"human\" or \"librarian\"
  :expected-revision  revision the caller based its bytes on, or nil to create
  :require-expected   non-nil when EXPECTED must equal the Mac head exactly
  :object-hash        expected sha256 of BYTES (verified when given)
  :operation-id       caller operation id (allocated when absent)
  :attempt-id         remote attempt id, used for replayable results
  :mutation-id        librarian mutation id
  :buffer             originating human buffer
  :tick               `buffer-chars-modified-tick' captured before the section
  :semantic           pre-computed projection (remote path) or nil
  :ignore-marker      non-nil to ignore a dirty/recovery marker (recovery only)

Returns a result plist with :status committed, dirty, stale, waiting_bytes,
unavailable or attention, durably recorded before it is reported."
  (let* ((file-id (plist-get spec :file-id))
         (bytes (plist-get spec :bytes))
         (operation-id (or (plist-get spec :operation-id) (brain--uuid)))
         (digest (or (plist-get spec :object-hash) (and bytes (brain--sha256 bytes))))
         (spec (plist-put (plist-put spec :operation-id operation-id)
                          :object-hash digest))
         (key (or (plist-get spec :attempt-id) operation-id)))
    (cond
     ((not (and brain-id brain-writer-id))
      (brain--result "unavailable" file-id :reason "unconfigured"))
     ((not brain--recovered)
      (brain--result "unavailable" file-id :reason "not_recovered"))
     ((not (stringp bytes))
      (brain--result "attention" file-id :reason "invalid_object"))
     ((> (length bytes) brain-object-max-bytes)
      (brain--result "attention" file-id :reason "too_large"))
     ((gethash key brain--results)
      (append (gethash key brain--results) (list :duplicate t)))
     (t
      (let ((result (condition-case err
                        (brain--commit spec)
                      (brain-locked
                       (brain--result "dirty" file-id :reason "reentrant"))
                      (brain-alternate-route
                       (brain--result "attention" file-id :reason "object_conflict"))
                      (brain-journal-fault
                       ;; A durability failure is not a commit outcome: reporting
                       ;; "attention" would invent a result for a commit whose
                       ;; journal write did not land.  Propagate it so the
                       ;; dispatcher stops and the fault stays visible.
                       (signal (car err) (cdr err)))
                      (error
                       (brain--log "commit error for %s: %S" file-id err)
                       (brain--result "attention" file-id
                                      :reason (format "commit_error:%s" (car err)))))))
        ;; The result must carry its own identity so a replay after restart can
        ;; answer by attempt id instead of re-running the install.
        (setq result (plist-put result :operation-id operation-id))
        (setq result (plist-put result :attempt-id (plist-get spec :attempt-id)))
        (when (equal (plist-get result :status) "attention")
          (puthash file-id (or (plist-get result :reason) "attention") brain--attention))
        (brain--journal-result result))))))

(defun brain--commit (spec)
  "Check every participant at actual use, then install; record the result."
  (let* ((file-id (plist-get spec :file-id))
         (bytes (plist-get spec :bytes))
         (digest (plist-get spec :object-hash))
         (origin (or (plist-get spec :origin) "human"))
         (human (equal origin "human"))
         (expected (plist-get spec :expected-revision))
         (ignore-marker (plist-get spec :ignore-marker))
         (source (plist-get spec :buffer))
         (resolution (brain--resolve file-id))
         (path (plist-get resolution :path))
         (status (plist-get resolution :status))
         (head (gethash file-id brain--heads))
         (buffers (brain--visiting-buffers file-id))
         ;; A human save reconciles its own unsaved text: the editing buffer is
         ;; the authority.  Only a *different* modified buffer of the same
         ;; identity, or an unexpected disk state, can block it.
         (marker (unless human (brain--recovery-marker file-id)))
         (conflict (brain--conflicting-dirty-buffer buffers source))
         (disk (if (equal status "ok") (brain--sha256-file path) nil)))
    (cond
     ((equal status "unsafe")
      (brain--result "attention" file-id
                     :reason (or (plist-get resolution :reason) "unsafe_path")))
     ((and (not human) (brain--retired-p file-id))
      ;; §3: "Remote install checks path active/unborn-versus-retired at the Mac
      ;; final install guard; matching an old expected_revision cannot resurrect a
      ;; retired path."  Only a local human save/baseline reactivates a path; an
      ;; unborn path is still creatable by a remote install, as before.
      (brain--result "attention" file-id :current-revision head :reason "path_retired"))
     ((and human (brain--retired-p file-id))
      ;; §3: "Local human recreation reactivates through the guarded save/baseline
      ;; path".  The save allocates the next revision on the RETAINED chain, so the
      ;; path never rewinds and the reactivation is its own lifecycle fact.  It is
      ;; deliberately not the "already current" shortcut: identical bytes still
      ;; need a revision to bring a retired path back to active.
      (brain--install spec path bytes digest head buffers origin))
     ((equal disk digest)
      ;; The requested bytes are already the canonical bytes.
      (if human
          (brain--settle-already-current spec)
        (brain--result "committed" file-id :current-revision head :new-revision head
                       :reason "already_current")))
     ((and marker (not ignore-marker))
      (brain--result "dirty" file-id :current-revision head :reason marker))
     ((and conflict (not ignore-marker))
      (brain--result "dirty" file-id :current-revision head
                     :reason "other_buffer_modified"))
     ((and human (not (brain--source-disk-current-p spec path)))
      (brain--result "attention" file-id :current-revision head
                     :reason "disk_changed"))
     ((and (plist-get spec :require-expected) (null expected) head)
      ;; Null means create-only: it never overwrites an existing head.
      (brain--result "stale" file-id :current-revision head
                     :reason "expected_required"))
     ((and expected (not (brain--rev-equal expected head)))
      (brain--result "stale" file-id :current-revision head :reason "stale_base"))
     ((and head (not (equal (brain--rev-sha head) disk)))
      (brain--result "attention" file-id :current-revision head
                     :reason "disk_mismatch"))
     ((and (null head) (equal status "ok"))
      ;; An existing not-yet-enrolled file first gets its baseline; a remote
      ;; request with a null expected revision never overwrites it, while a
      ;; human save continues on top of the enrolled baseline.
      (brain--enroll-baseline file-id path disk)
      (if human
          (brain--install spec path bytes digest (gethash file-id brain--heads)
                          buffers origin)
        (brain--result "stale" file-id
                       :current-revision (gethash file-id brain--heads)
                       :reason "baseline_enrolled")))
     (t
      (brain--install spec path bytes digest head buffers origin)))))

(defun brain--settle-already-current (spec)
  "Finish a human save whose exact bytes are already the canonical bytes.
Nothing is installed and no revision is invented, but the save clears only the
dirty generation it actually saved: without that record a restart brings the
lease back and blocks the file for good."
  (let* ((file-id (plist-get spec :file-id))
         (lease (gethash file-id brain--dirty))
         (generation (plist-get lease :generation))
         (source (brain--human-source-base spec))
         (head (gethash file-id brain--heads)))
    (when source
      (with-current-buffer source
        (set-buffer-modified-p nil)
        (set-visited-file-modtime)))
    (when lease
      (brain--clear-lease file-id generation spec)
      (brain--emit-event
       "brain.file.clean"
       (list (cons "file_id" file-id)
             (cons "revision" (brain--rev->json head))
             (cons "dirty_generation" generation)
             (cons "operation_id" (plist-get spec :operation-id))
             (cons "client_epoch" (or brain--client-epoch :null)))))
    (brain--result "committed" file-id :current-revision head :new-revision head
                   :reason "already_current")))

(defun brain--conflicting-dirty-buffer (buffers source)
  "Return a modified buffer of this identity that is not SOURCE's own text.
Aliases (indirect buffers) share SOURCE's text, so they are not a conflict;
an independent second buffer visiting the same file is."
  (let ((source-base (and source (buffer-live-p source) (brain--buffer-base source))))
    (seq-find (lambda (buffer)
                (and (brain--buffer-dirty-p buffer)
                     (not (and source-base
                               (eq (brain--buffer-base buffer) source-base)))))
              buffers)))

(defun brain--source-disk-current-p (spec path)
  "Non-nil when SPEC's source buffer still visits the file now at PATH."
  (let ((buffer (plist-get spec :buffer)))
    (cond
     ((or (null buffer) (not (buffer-live-p buffer))) t)
     ((null path) t)
     (t (with-current-buffer buffer
          (and (buffer-file-name)
               (verify-visited-file-modtime buffer)))))))

(defun brain--enroll-baseline (file-id path digest)
  "Allocate a baseline revision for an existing verified file and publish it.
  The snapshot record carries its own `operation_id' so history can report the
  ORIGINAL fact identity of seq0 (§2) instead of minting a new one per request.
  A path that was retired and is recreated by a human save resumes from its
  RETAINED head (§3), so its chain is never rewound."
  (let* ((bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally path)
                  (buffer-string)))
         (choice (brain--baseline-revision file-id digest))
         (revision (car choice))
         (predecessor (cdr choice))
         (operation-id (brain--uuid)))
    (brain--publish-object bytes digest)
    (brain--journal-append "snapshot" :file_id file-id :revision revision
                           :prev_revision predecessor
                           :object_hash digest :operation_id operation-id)
    (puthash file-id revision brain--heads)
    (brain--lifecycle-reactivate-if-retired file-id revision digest predecessor)
    (brain--fsync (brain--object-path "mac" digest) path)
    (brain--heads-save)
    revision))

(defun brain--install (spec path bytes digest head buffers origin)
  "The non-yielding check-to-install section and its durable renewal."
  (let* ((file-id (plist-get spec :file-id))
         (text (decode-coding-string bytes 'utf-8))
         (lease (gethash file-id brain--dirty))
         (generation (plist-get lease :generation))
         result)
    (unless (equal (brain--sha256 bytes) digest)
      (signal 'brain-alternate-route (list "object_hash_mismatch" file-id)))
    (setq brain--in-critical t)
    (unwind-protect
        (let ((inhibit-quit t))
          (when (member file-id brain--locked)
            (signal 'brain-locked (list file-id)))
          (push file-id brain--locked)
          (unwind-protect
              (progn
                (dolist (buffer buffers) (brain--lock-buffer buffer))
                (unwind-protect
                    (setq result (brain--install-checks spec bytes text digest
                                                        head buffers origin))
                  (dolist (buffer buffers) (brain--unlock-buffer buffer))))
            (setq brain--locked (delete file-id brain--locked))))
      (setq brain--in-critical nil))
    (pcase (plist-get result :status)
      ("committed"
       (if (not (plist-get result :installed))
           result
         (setq brain--commit-count (1+ brain--commit-count))
         (let ((new (plist-get result :new-revision)))
           (brain--fsync (brain--journal-file) (brain--object-path "mac" digest)
                         path (file-name-directory path))
           (brain--heads-save)
           (if (not (brain--fsync (brain--journal-file) (brain--heads-file)))
               (progn
                 (brain--attention file-id "fsync_failed" (plist-get spec :operation-id))
                 (brain--result "attention" file-id :current-revision new
                                :reason "fsync_failed"))
             (brain--clear-lease file-id generation spec)
             (brain--emit-commit-events spec file-id head new origin generation)
             (brain--run-post-commit-hooks (brain--refreshable-buffers spec buffers))
             result))))
      (_ result))))

(defun brain--install-checks (spec bytes text digest head buffers origin)
  "Recheck every participant at actual use, then install.  No yield inside."
  (let* ((file-id (plist-get spec :file-id))
         (recheck (brain--resolve file-id))
         (recheck-path (plist-get recheck :path))
         (recheck-head (gethash file-id brain--heads))
         (recheck-disk (and (equal (plist-get recheck :status) "ok")
                            (brain--sha256-file recheck-path)))
         (recheck-dirty (brain--conflicting-dirty-buffer buffers (plist-get spec :buffer)))
         (tick-ok (or (null spec) (null (plist-get spec :tick))
                      (not (plist-get spec :buffer))
                      (equal (with-current-buffer (plist-get spec :buffer)
                               (buffer-chars-modified-tick))
                             (plist-get spec :tick)))))
    (cond
     ((and (not (equal origin "human")) (brain--retired-p file-id))
      ;; §3's final install guard: rechecked inside the no-yield section, so a
      ;; retirement that landed between the outer check and here cannot be
      ;; undone by a remote install that matched the old expected revision.
      (brain--result "attention" file-id :current-revision recheck-head
                     :reason "path_retired"))
     ((not (brain--rev-equal recheck-head head))
      (brain--result "stale" file-id :current-revision recheck-head
                     :reason "head_advanced"))
     ((and head (not (equal recheck-disk (brain--rev-sha head)))
           ;; A human save that revives a retired path is the authority for its
           ;; bytes (§3: "Local human recreation reactivates through the guarded
           ;; save/baseline path").  The retained head is its predecessor, not a
           ;; competing state, so the disk/head mismatch is the expected
           ;; difference rather than a refusal.
           (not (and (equal origin "human") (brain--retired-p file-id))))
      (brain--result "attention" file-id :current-revision head
                     :reason "disk_changed"))
     ((and (null head) recheck-disk)
      (brain--result "stale" file-id :reason "baseline_needed"))
     ((or recheck-dirty (not tick-ok))
      (brain--result "dirty" file-id :current-revision head :reason "modified"))
     (t
      (brain--install-now spec recheck-path bytes text digest head origin)))))

(defun brain--install-now (spec path bytes text digest head origin)
  "Install the exact candidate bytes and refresh only already visiting buffers."
  (let* ((file-id (plist-get spec :file-id))
         (operation-id (plist-get spec :operation-id))
         (seq (if head (1+ (brain--rev-seq head)) 0))
         (revision (brain--rev seq digest))
         (buffers (brain--visiting-buffers file-id))
         (refresh (brain--refreshable-buffers spec buffers))
         (source (brain--human-source-base spec))
         (retirement (and (equal origin "human") (gethash file-id brain--retired))))
    ;; ---- no yield from here to the refreshed buffers ----
    (brain--journal-append-nofsync
     "intent" :file_id file-id :operation_id operation-id
     :attempt_id (plist-get spec :attempt-id)
     :mutation_id (plist-get spec :mutation-id)
     :origin origin :prev_revision head :new_revision revision
     :object_hash digest :byte_length (length bytes) :phase "intent")
    (brain--publish-object bytes digest)
    (brain--atomic-replace path bytes)
    (brain--refresh-all refresh text)
    ;; The saving buffer already holds these exact bytes: it is finished, never
    ;; rewritten, so its markers, folding, narrowing and undo list survive.
    (when source
      (with-current-buffer source
        (set-buffer-modified-p nil)
        (set-visited-file-modtime)))
    (puthash file-id revision brain--heads)
    (when retirement
      ;; §3: the human save that revives a retired path records the reactivation
      ;; as its own lifecycle fact, after the committed record and before the
      ;; result is reported.
      (brain--lifecycle-reactivate-if-retired file-id revision digest head))
    (brain--result
     "committed" file-id
     :installed t
     :current-revision head
     :new-revision revision
     :object-hash digest
     :mac-seq (brain--journal-append-nofsync
               "committed" :file_id file-id :operation_id operation-id
               :attempt_id (plist-get spec :attempt-id)
               :mutation_id (plist-get spec :mutation-id)
               :origin origin :prev_revision head :new_revision revision
               :object_hash digest
               :semantic (plist-get spec :semantic)
               :phase "committed")
     :semantic (plist-get spec :semantic)
     :origin origin
     :operation-id operation-id)))

(defun brain--clear-lease (file-id generation spec)
  "Clear only the lease generation this commit actually saved.
The save event itself carries the cleared generation, so no second event is
invented; the journal record is what recovery replays."
  (let ((lease (gethash file-id brain--dirty)))
    (when (and lease
               (or (null generation)
                   (equal generation (plist-get lease :generation))))
      (remhash file-id brain--dirty)
      (brain--journal-append "clean" :file_id file-id
                             :revision (gethash file-id brain--heads)
                             :dirty_generation (plist-get lease :generation)
                             :operation_id (plist-get spec :operation-id)))))

(defun brain--run-post-commit-hooks (buffers)
  "Refresh derived indexes (org-roam) for already visiting buffers, after commit.
BUFFERS excludes a human save's own buffer (see `brain--refreshable-buffers'):
`basic-save-buffer' runs `after-save-hook' in it exactly once after the
write-contents handler returns, so the hook must not run twice."
  (dolist (buffer (brain--base-buffers buffers))
    (when (buffer-live-p buffer)
      (condition-case err
          (with-current-buffer buffer
            (run-hooks 'after-save-hook))
        (error (brain--log "after-save-hook failed: %S" err))))))

(defun brain--lock-buffer (buffer)
  (with-current-buffer buffer
    (unless (memq (current-buffer) brain--locked-buffers)
      (setq-local brain--locked-read-only buffer-read-only)
      (push (current-buffer) brain--locked-buffers)
      (setq buffer-read-only t))))

(defun brain--unlock-buffer (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (memq (current-buffer) brain--locked-buffers)
        (setq brain--locked-buffers (delq (current-buffer) brain--locked-buffers))
        (when (local-variable-p 'brain--locked-read-only)
          (setq buffer-read-only brain--locked-read-only)
          (kill-local-variable 'brain--locked-read-only))))))

;;; ---------------------------------------------------------------------------
;;; Human saves
;;; ---------------------------------------------------------------------------

(defun brain--human-save (buffer)
  "Save managed BUFFER through the commit primitive.  Errors keep the bytes."
  (with-current-buffer buffer
    (let* ((file-id (brain--buffer-file-id buffer))
           (encoded (brain--encode-buffer-text buffer)))
      (cond
       ((null file-id) nil)
       ((memq encoded '(unsupported-coding lossy-coding too_large))
        (brain--attention file-id (symbol-name encoded))
        (signal 'user-error
                (list (format "brain: refusing to save %s (%s)" file-id
                              (symbol-name encoded)))))
       (t
        (let* ((operation-id (brain--uuid))
               (head (gethash file-id brain--heads))
               (digest (brain--sha256 encoded))
               (next (if head (1+ (brain--rev-seq head)) 0))
               ;; Derived from the final encoded candidate bytes, here, before
               ;; the no-yield section: no Org parser runs inside it.
               (semantic (brain--projection-for encoded file-id
                                                (brain--rev next digest)
                                                operation-id))
               (result (brain-commit-file
                        (list :file-id file-id
                              :origin "human"
                              :bytes encoded
                              :expected-revision head
                              :operation-id operation-id
                              :buffer buffer
                              :semantic semantic
                              :tick (buffer-chars-modified-tick))))
               (status (plist-get result :status)))
          (unless (equal status "committed")
            (signal 'user-error
                    (list (format "brain: save of %s refused (%s%s)"
                                  file-id status
                                  (if (plist-get result :reason)
                                      (concat ": " (plist-get result :reason))
                                    "")))))
          ;; `basic-save-buffer' assigns `last-coding-system-used' to
          ;; `buffer-file-coding-system' after this handler returns; our bytes
          ;; are UTF-8, so report that and never `binary'.
          (setq last-coding-system-used 'utf-8-unix)
          t))))))

(defun brain-write-contents-handler ()
  "`write-contents-functions' entry for managed buffers.
A non-nil value means Emacs must not write the file itself: the primitive
already installed the exact bytes, or refused and kept the buffer modified."
  (if (not (and brain--enabled (brain--managed-buffer-p (current-buffer))))
      nil
    (brain--human-save (current-buffer))
    t))

;;; ---------------------------------------------------------------------------
;;; Dirty leases
;;; ---------------------------------------------------------------------------

(defun brain--note-first-edit ()
  "Journal a dirty lease for the current managed buffer before it changes.
Errors are swallowed: the lease is advisory scheduling state, while
`buffer-modified-p' is the enforcement checked at install time."
  (condition-case err
      (when (and brain--enabled (brain--managed-buffer-p (current-buffer)))
        (let ((file-id (brain--buffer-file-id (current-buffer))))
          (unless (gethash file-id brain--dirty)
            (let* ((base (gethash file-id brain--heads))
                   (generation (1+ (or (gethash file-id brain--generations) 0)))
                   (operation-id (brain--uuid)))
              (puthash file-id generation brain--generations)
              (puthash file-id (list :generation generation :base base
                                     :operation-id operation-id
                                     :epoch brain--client-epoch)
                       brain--dirty)
              (brain--journal-append "dirty" :file_id file-id :base_revision base
                                     :dirty_generation generation
                                     :operation_id operation-id
                                     :client_epoch brain--client-epoch)
              (brain--emit-event
               "brain.file.dirty"
               (list (cons "file_id" file-id)
                     (cons "base_revision" (brain--rev->json base))
                     (cons "dirty_generation" generation)
                     (cons "operation_id" operation-id)
                     (cons "client_epoch" (or brain--client-epoch :null))))))))
    (error (brain--log "dirty lease failed: %S" err))))

(defun brain--before-change-guard (begin end)
  "`before-change-functions' shim.  Never signals: a signalling before-change
function is set to nil by Emacs and would then no longer run at all."
  (ignore begin end)
  (condition-case nil
      (when (and brain--enabled (not brain--inhibit-guards))
        (brain--note-first-edit))
    (error nil)))

(defun brain--after-change-fallback (begin end old-length)
  "`after-change-functions' fallback detector; not an enforcement point."
  (ignore begin end old-length)
  (condition-case nil
      (when (and brain--enabled (not brain--inhibit-guards))
        (brain--note-first-edit))
    (error nil)))

;;; ---------------------------------------------------------------------------
;;; Alternate route guards
;;; ---------------------------------------------------------------------------

(defun brain--guard-active-p ()
  (and brain--enabled (not brain--inhibit-guards) (not brain--in-critical)))

(defun brain--guard-path (path operation)
  (when (and (brain--guard-active-p) (stringp path)
             (brain--identity-for-path path))
    (signal 'brain-alternate-route (list operation path))))

(defun brain--managed-directory-p (path)
  "Non-nil when PATH is a directory at or beneath a managed root (§3).
A parent-directory move is outside the single-writer assumption: renaming a
directory would relocate an unknown number of identities at once, with no
lifecycle record for any of them.  It stays refused rather than becoming a
silent bulk move."
  (and (stringp path)
       (file-directory-p path)
       (let ((absolute (file-name-as-directory (expand-file-name path))))
         (seq-find (lambda (entry)
                     (let ((root (file-name-as-directory
                                  (expand-file-name (cdr entry)))))
                       (string-prefix-p root absolute)))
                   brain-managed-roots))))

(defun brain--lifecycle-managed-rename-p (file newname)
  "Non-nil when FILE -> NEWNAME is an eligible single-file managed rename (§3).
  \"Existing managed rename-file/delete-file advice routes eligible single-file
  operations into these wrappers (including org-roam's normal rename/delete),
  while parent-directory moves and unsafe save-as remain refused.\"  The source
  and the destination must both be managed identities, the destination must be
  a file name rather than a directory, and the operation must be a rename of
  the file itself -- never a move into a directory, which would take the whole
  parent with it."
  (let ((source (and (stringp file) (brain--identity-for-path file)))
        (destination (and (stringp newname) (brain--identity-for-path newname))))
    (and source destination
         (not (equal source destination))
         ;; A directory destination is a parent move: refused, not routed.
         (not (file-directory-p newname))
         (not (directory-name-p newname)))))

(defun brain-guard-write-region (original start end filename &optional append visit lockname mustbenew)
  "Refuse a direct managed write that does not go through the primitive."
  (if (and (brain--guard-active-p) (stringp filename))
      (progn
        (brain--guard-path filename "write-region")
        (funcall original start end filename append visit lockname mustbenew))
    (funcall original start end filename append visit lockname mustbenew)))

(defun brain-guard-rename-file (original file newname &optional ok-if-already-exists)
  "Route an eligible managed single-file rename into `brain-rename-file' (§3).
  Anything else keeps the accepted refusal: a parent-directory move, a rename
  that leaves the managed namespace, and a rename while a lifecycle command is
  running. A refusal stays a refusal -- this advice never becomes a general
  filesystem permission."
  (cond
   ((not (brain--guard-active-p))
    (funcall original file newname ok-if-already-exists))
   ;; §3: "parent-directory moves ... remain refused."  A directory move is not a
   ;; single-file lifecycle: it would relocate an unknown number of identities
   ;; with no record for any of them, so it is refused outright rather than
   ;; routed or passed through.
   ((or (brain--managed-directory-p file) (brain--managed-directory-p newname))
    (signal 'brain-alternate-route (list "parent_directory_move" file)))
   ((brain--lifecycle-managed-rename-p file newname)
    (let* ((source (brain--identity-for-path file))
           (destination (brain--identity-for-path newname))
           (result (brain-rename-file source destination)))
      (if (equal (plist-get result :status) "committed")
          nil
        (signal 'brain-alternate-route
                (list (or (plist-get result :reason) "rename_refused") file)))))
   (t
    (brain--guard-path file "rename-file-source")
    (brain--guard-path newname "rename-file-destination")
    (funcall original file newname ok-if-already-exists))))

(defun brain-guard-delete-file (original file &optional trash)
  "Route an eligible managed single-file delete into `brain-delete-file' (§3).
  The managed path is retired through the durable lifecycle record instead of
  being unlinked behind Brain's back; an unmanaged file is untouched."
  (cond
   ((not (brain--guard-active-p))
    (funcall original file trash))
   ((brain--identity-for-path file)
    (let* ((file-id (brain--identity-for-path file))
           (result (brain-delete-file file-id)))
      (if (equal (plist-get result :status) "committed")
          nil
        (signal 'brain-alternate-route
                (list (or (plist-get result :reason) "delete_refused") file)))))
   (t
    (brain--guard-path file "delete-file")
    (funcall original file trash))))

(defun brain-guard-auto-revert (original &rest args)
  "Global auto-revert must not mutate a managed buffer outside Brain refresh."
  (if (and brain--enabled (brain--managed-buffer-p (current-buffer)))
      nil
    (apply original args)))

(defun brain-guard-set-visited-file-name (original filename &optional no-renaming auto-save-flag)
  "Refuse save-as into the managed namespace from another identity."
  (let ((target (and filename (brain--identity-for-path filename)))
        (current (brain--buffer-file-id (current-buffer))))
    (if (and (brain--guard-active-p) target (not (equal target current)))
        (signal 'brain-alternate-route (list "set-visited-file-name" filename))
      (funcall original filename no-renaming auto-save-flag))))

(defun brain--install-guards ()
  (advice-add 'write-region :around #'brain-guard-write-region)
  (advice-add 'rename-file :around #'brain-guard-rename-file)
  (advice-add 'delete-file :around #'brain-guard-delete-file)
  (advice-add 'set-visited-file-name :around #'brain-guard-set-visited-file-name)
  (advice-add 'auto-revert-handler :around #'brain-guard-auto-revert))

(defun brain--remove-guards ()
  (advice-remove 'write-region #'brain-guard-write-region)
  (advice-remove 'rename-file #'brain-guard-rename-file)
  (advice-remove 'delete-file #'brain-guard-delete-file)
  (advice-remove 'set-visited-file-name #'brain-guard-set-visited-file-name)
  (advice-remove 'auto-revert-handler #'brain-guard-auto-revert))

;;; ---------------------------------------------------------------------------
;;; Identity lifecycle: guarded rename/delete/reactivation (design §3)
;;; ---------------------------------------------------------------------------
;;
;; §3 gives the Mac a lifecycle that is separate from the content revision
;; sequence:
;;
;;   * a monotonic Mac journal counter (`lifecycle_generation') bound to each
;;     affected path, never reused and never derived from a revision seq;
;;   * durable records for `retire', `relocate' and `reactivate', replayable by
;;     operation id, so a crash between the intent and the atomic action is
;;     resolved from the journal instead of guessed;
;;   * retirement PRESERVES the source head, its object and its history and only
;;     marks the path inactive -- it never invents an empty Org revision;
;;   * a path that was used before resumes at `predecessor = its retained head`
;;     and `seq + 1`; only a never-used path starts at seq 0.  The writer id
;;     never changes.
;;
;; Two things this section deliberately does NOT do:
;;
;; 1. It never guesses an external move.  A path that disappeared out of
;;    protocol is retired only after TWO complete inventories at least
;;    `brain-missing-retire-interval' apart both lack it AND an explicit target
;;    recheck at the writer guard proves it missing with no buffer, lease,
;;    recovery marker, attention row or in-flight install.  A page end, a
;;    partial scan or a single absent target is never retirement evidence.
;; 2. It never retargets a dirty buffer.  A lifecycle command refuses a dirty
;;    source or destination outright, and the retarget after the atomic action
;;    only touches buffers that are still clean and still visit the old path.
;;
;; The wire side is `brain.file.lifecycle' (§3), feature-gated like every other
;; corpus kind: the node refuses an unnegotiated corpus event and never acks it,
;; so emitting one on an old peer would spend a durable seq the gateway never
;; sees and stall the event stream.  The Mac therefore emits only once it has
;; OBSERVED corpus-v1 live -- a corpus-mode snapshot request can only reach it
;; through a node and a gateway that both negotiated the feature -- and a
;; lifecycle fact journaled before that is emitted from the journal on the first
;; such request (`brain--flush-lifecycle-events').  The fact itself is never
;; lost: it is durable in the journal either way.

(defun brain--retired-p (file-id)
  "Non-nil when FILE-ID is retired (inactive) per the durable journal."
  (and file-id (gethash file-id brain--retired) t))

(defun brain--alias-available-p (file-id)
  "Non-nil when FILE-ID's alias key is free or already names FILE-ID itself
  (§3). Two spellings one case-insensitive volume collapses are an explicit
  ambiguity, never a silent pick, so a rename into such a spelling is refused
  before the atomic action instead of leaving a destination the store will
  reject."
  (let ((known (gethash (brain--alias-key file-id) brain--identities)))
    (or (null known) (equal known file-id))))

(defun brain--lifecycle-next-generation ()
  "Allocate the next monotonic lifecycle generation (§3: separate from revisions)."
  (setq brain--lifecycle-seq (1+ brain--lifecycle-seq)))

(defun brain--baseline-revision (file-id digest)
  "Return (REVISION . PREDECESSOR) for a baseline of FILE-ID at DIGEST (§3). A
  path that was never used starts at seq 0 with no predecessor.  A path that
  WAS used -- including one whose file was deleted and whose path is now
  recreated -- resumes from its retained head: `predecessor = retained head',
  `seq + 1'.  The writer id never changes, so the chain stays one writer's
  chain."
  (let ((head (gethash file-id brain--heads)))
    (if head
        (cons (brain--rev (1+ (brain--rev-seq head)) digest) head)
      (cons (brain--rev 0 digest) nil))))

(defun brain--lifecycle-reactivate-if-retired (file-id revision digest &optional predecessor)
  "Record a `reactivate' fact when a guarded save revives a retired path (§3).
  \"Local human recreation reactivates through the guarded save/baseline path,
  not a remote retry.\"  The destination is the path itself with the revision
  the save just allocated, and its PREDECESSOR is the retained head the chain
  continued from -- not the new revision, which would claim the step preceded
  itself.  The source is the retirement being revived, so the two facts read as
  one story. Nothing is emitted for a path that was never retired."
  (let ((retirement (gethash file-id brain--retired)))
    (when retirement
      (let* ((generation (brain--lifecycle-next-generation))
             (operation-id (brain--uuid))
             (payload (brain--lifecycle-payload
                       operation-id "reactivate"
                       file-id (plist-get retirement :head)
                       file-id predecessor revision digest
                       generation "recreated")))
        (brain--journal-append "lifecycle" :operation_id operation-id
                               :action "reactivate"
                               :source_file_id file-id
                               :source_revision (plist-get retirement :head)
                               :destination_file_id file-id
                               :destination_predecessor predecessor
                               :destination_revision revision
                               :destination_object_hash digest
                               :lifecycle_generation generation :reason "recreated"
                               :payload payload)
        (puthash file-id generation brain--lifecycle-generations)
        (remhash file-id brain--retired)
        (brain--lifecycle-emit payload)))))

(defun brain--lifecycle-payload (operation-id action source-id source-revision
                                             destination-id predecessor revision digest
                                             generation reason)
  "Build one `brain.file.lifecycle' payload (§3). `source' is null for a
  reactivation that revives no named source, `destination' is null for a
  retirement.  A nil revision is encoded as JSON null explicitly:
  `brain--jsonify' would otherwise write the empty alist `{}', which the
  gateway reads as an absent revision only because `check_revision' treats `{}'
  as null -- naming the absence is what keeps the two sides' spellings from
  drifting."
  (list (cons "operation_id" operation-id)
        (cons "action" action)
        (cons "source" (if source-id
                            (list (cons "file_id" source-id)
                                  (cons "last_revision"
                                        (if source-revision
                                            (brain--rev->json source-revision)
                                          :null)))
                          :null))
        (cons "destination" (if destination-id
                                 (list (cons "file_id" destination-id)
                                       (cons "predecessor"
                                             (if predecessor (brain--rev->json predecessor) :null))
                                       (cons "revision" (brain--rev->json revision))
                                       (cons "object_hash" digest))
                               :null))
        (cons "reason" reason)
        (cons "lifecycle_generation" generation)))

(defun brain--lifecycle-emit (payload)
  "Emit one lifecycle PAYLOAD when corpus-v1 is live on this session (§3/§1)."
  (when brain--corpus-observed
    (brain--emit-event "brain.file.lifecycle" payload)))

(defun brain--lifecycle-event-emitted-p (operation-id)
  "Non-nil when a `brain.file.lifecycle' event for OPERATION-ID is journaled."
  (seq-find (lambda (record)
              (and (equal (plist-get record :kind) "event")
                   (equal (plist-get record :event_kind) "brain.file.lifecycle")
                   (equal (alist-get "operation_id"
                                     (alist-get "payload" (plist-get record :payload)
                                                nil nil #'equal)
                                     nil nil #'equal)
                          operation-id)))
            brain--journal))

(defun brain--flush-lifecycle-events ()
  "Emit every journaled lifecycle fact that has not been put on the wire yet. §3
  makes the lifecycle record durable in the journal; the event is only the
  notification.  A fact recorded while corpus-v1 was off is therefore not lost
  -- it is emitted the first time this session proves the feature live."
  (when brain--corpus-observed
    (dolist (record (brain--journal-records "lifecycle"))
      (let ((operation-id (plist-get record :operation_id))
            (payload (plist-get record :payload)))
        (when (and operation-id payload
                   (not (brain--lifecycle-event-emitted-p operation-id)))
          (brain--emit-event "brain.file.lifecycle" payload))))))

(defun brain--lifecycle-outcome (operation-id)
  "Return the recorded outcome of OPERATION-ID, or nil (§3: replay by id). \"All
  duplicate operation IDs return recorded outcomes.\"  A recorded outcome is
  either the committed lifecycle fact or the recorded refusal/abort: a
  duplicate id must never perform a second action, and must never be silently
  retried as if the first attempt had not been made.  A caller that wants to
  try again after a recorded non-install uses a new operation id."
  (let ((record (car (last (seq-filter
                            (lambda (entry)
                              (and (member (plist-get entry :kind)
                                           '("lifecycle" "lifecycle_aborted"
                                             "lifecycle_attention"))
                                   (equal (plist-get entry :operation_id) operation-id)))
                            brain--journal)))))
    (when record
      (let ((kind (plist-get record :kind))
            (destination (plist-get record :destination_file_id)))
        (pcase kind
          ("lifecycle"
           (append (brain--result "committed"
                                  (or (plist-get record :source_file_id) destination)
                                  :action (plist-get record :action)
                                  :new-revision (plist-get record :destination_revision)
                                  :lifecycle-generation (plist-get record :lifecycle_generation)
                                  :reason (plist-get record :reason))
                   (list :operation-id operation-id :duplicate t)))
          ("lifecycle_aborted"
           ;; The operation provably did not install.  Nothing was applied, so the
           ;; answer is "not installed", not a success and not a new attempt.
           (append (brain--result "stale" (plist-get record :source_file_id)
                                  :action (plist-get record :action)
                                  :reason (or (plist-get record :reason) "not_installed"))
                   (list :operation-id operation-id :duplicate t)))
          (_
           (append (brain--result "attention" (plist-get record :file_id)
                                  :action (plist-get record :action)
                                  :reason (or (plist-get record :reason) "recovery_mismatch"))
                   (list :operation-id operation-id :duplicate t))))))))

(defun brain--lifecycle-refusal (source-id destination-id &optional ignore-critical)
  "Return a reason when a two-path lifecycle operation must not run (§3).
\"Commands require clean source/destination, no recovery markers, no local
install in progress and no overwrite of an existing destination.\"  Both paths
are checked: a dirty buffer on either side would be lost by the atomic action.
IGNORE-CRITICAL is bound inside the no-yield section, where the exclusion this
call would otherwise report is the one the caller already holds."
  (cond
   ((and (not ignore-critical) brain--in-critical) "install_in_progress")
   ((and (not ignore-critical)
         (or (member source-id brain--locked)
             (and destination-id (member destination-id brain--locked))))
    "install_in_progress")
   ((gethash source-id brain--dirty) "dirty_lease")
   ((and destination-id (gethash destination-id brain--dirty)) "dirty_lease")
   ((brain--any-buffer-dirty-p (brain--visiting-buffers source-id)) "modified_buffer")
   ((and destination-id
         (brain--any-buffer-dirty-p (brain--visiting-buffers destination-id)))
    "modified_buffer")
   ((brain--recovery-marker source-id) (brain--recovery-marker source-id))
   ((and destination-id (brain--recovery-marker destination-id))
    (brain--recovery-marker destination-id))
   (t nil)))

(defun brain--lifecycle-critical (file-ids body)
  "Run BODY with the writer exclusion held over FILE-IDS (§3: no yield).
Every visiting buffer of every affected path is locked read-only for the
duration, exactly like the install section, and the ids are pushed onto
`brain--locked' so a nested commit of either path is refused rather than
interleaved."
  (let ((buffers (seq-mapcat (lambda (id) (brain--visiting-buffers id)) file-ids))
        (brain--in-critical t)
        (inhibit-quit t)
        (result nil))
    (dolist (buffer buffers) (brain--lock-buffer buffer))
    (dolist (id file-ids) (push id brain--locked))
    (unwind-protect
        (setq result (funcall body))
      ;; Non-destructive release: `delete' would mutate the list in place, and a
      ;; caller holding a reference to it (a probe, a log, a test) would then see
      ;; an exclusion that was never released that way.
      (setq brain--locked (seq-remove (lambda (id) (member id file-ids)) brain--locked))
      (dolist (buffer buffers) (brain--unlock-buffer buffer)))
    result))

(defun brain--lifecycle-apply (intent)
  "Finish one lifecycle INTENT: journal the committed record and publish it.
  INTENT is the journaled intent plist.  The record is written and fsynced
  BEFORE the in-memory state moves, so a crash between the two is repaired by
  `brain--rebuild-lifecycle' and `brain--rebuild-heads' from the record itself."
  (let* ((operation-id (plist-get intent :operation_id))
         (action (plist-get intent :action))
         (source-id (plist-get intent :source_file_id))
         (source-revision (plist-get intent :source_revision))
         (destination-id (plist-get intent :destination_file_id))
         (predecessor (plist-get intent :destination_predecessor))
         (revision (plist-get intent :destination_revision))
         (digest (plist-get intent :destination_object_hash))
         (generation (plist-get intent :lifecycle_generation))
         (reason (plist-get intent :reason))
         (payload (brain--lifecycle-payload operation-id action source-id source-revision
                                            destination-id predecessor revision digest
                                            generation reason)))
    (brain--journal-append "lifecycle" :operation_id operation-id :action action
                           :source_file_id source-id :source_revision source-revision
                           :destination_file_id destination-id
                           :destination_predecessor predecessor
                           :destination_revision revision
                           :destination_object_hash digest
                           :lifecycle_generation generation :reason reason
                           :payload payload)
    (when (and destination-id revision)
      (puthash destination-id revision brain--heads))
    (when (and (equal action "relocate") destination-id source-id)
      ;; The destination is a new path identity and must be registered before any
      ;; later save can collide with it; the retired source keeps its head but
      ;; gives up its alias entry, so a human recreation of that path is not
      ;; refused as an alias of a path that no longer exists.
      (ignore-errors (brain--register-identity destination-id))
      (let ((alias (brain--alias-key source-id)))
        (when (equal (gethash alias brain--identities) source-id)
          (remhash alias brain--identities))))
    (when source-id
      (puthash source-id generation brain--lifecycle-generations)
      (when (member action '("retire" "relocate"))
        ;; §3: retire PRESERVES the head and marks the path inactive.  It never
        ;; invents an empty revision and never rewrites history.
        (puthash source-id (list :generation generation :head source-revision)
                 brain--retired)))
    (when destination-id
      (puthash destination-id generation brain--lifecycle-generations)
      (remhash destination-id brain--retired))
    (brain--heads-save)
    (brain--lifecycle-emit payload)
    (append (brain--result "committed" (or source-id destination-id)
                           :action action
                           :new-revision revision
                           :current-revision source-revision
                           :lifecycle-generation generation
                           :reason reason)
            (list :operation-id operation-id))))

(defun brain--lifecycle-attention (operation-id reason file-id)
  "Record an unrecoverable lifecycle outcome as attention, never as success."
  (puthash file-id reason brain--attention)
  (brain--journal-append "lifecycle_attention" :operation_id operation-id
                         :file_id file-id :reason reason)
  (brain--log "lifecycle %s needs attention: %s" operation-id reason)
  (brain--result "attention" file-id :reason reason :operation-id operation-id))

(defun brain--delete-file-primitive (path)
  "Delete PATH with the file primitive, firing no `delete-file' advice. The
  lifecycle command owns the durable record; the advice layers belong to the
  user-facing path and must not run inside the no-yield section."
  (funcall (advice--cd*r (symbol-function #'delete-file)) path nil))

(defun brain-rename-file (file-id new-file-id &optional operation-id)
  "Guarded managed rename of FILE-ID to NEW-FILE-ID (§3). This is a narrow
  wrapper, not a general remote tool: it renames ONE eligible managed file to
  ONE unused managed identity, publishes the source bytes as the destination's
  immutable object, journals and fsyncs the intent before the atomic rename,
  and journals the committed lifecycle record afterwards.  The destination
  takes a canonical revision from ITS OWN retained chain -- seq 0 only if the
  path was never used, otherwise `predecessor = retained head' and `seq + 1'.

  Refused, with the file untouched: an unsafe or missing source, an existing or
  unsafe destination, a retired source, a dirty source or destination, a lease,
  a recovery marker and an in-flight install."
  (let ((operation-id (or operation-id (brain--uuid))))
    (cond
     ((not (and brain-id brain-writer-id))
      (brain--result "unavailable" file-id :reason "unconfigured"))
     ((not brain--recovered)
      (brain--result "unavailable" file-id :reason "not_recovered"))
     ((brain--lifecycle-outcome operation-id))
     ((and (stringp file-id) (equal file-id new-file-id))
      (brain--result "attention" file-id :reason "same_identity"))
     (t
      (let* ((source (brain--resolve file-id))
             (destination (brain--resolve new-file-id))
             (source-path (plist-get source :path))
             (destination-path (plist-get destination :path))
             (refusal (brain--lifecycle-refusal file-id new-file-id)))
        (cond
         ((not (equal (plist-get source :status) "ok"))
          (brain--result "attention" file-id
                         :reason (or (plist-get source :reason) "source_missing")))
         ((not (equal (plist-get destination :status) "absent"))
          ;; §3: "no overwrite of an existing destination"; an unsafe destination
          ;; (symlink component, escape, bad path) is refused the same way.
          (brain--result "attention" file-id
                         :reason (if (equal (plist-get destination :status) "unsafe")
                                     (or (plist-get destination :reason) "unsafe_path")
                                   "destination_exists")))
         ((brain--retired-p file-id)
          (brain--result "attention" file-id :reason "source_retired"))
         ((not (brain--alias-available-p new-file-id))
          (brain--result "attention" file-id :reason "alias_ambiguity"))
         (refusal (brain--result "dirty" file-id :reason refusal))
         (t (brain--rename-now file-id new-file-id operation-id
                               source-path destination-path))))))))

(defun brain--rename-now (file-id new-file-id operation-id source-path destination-path)
  "Perform the guarded rename of FILE-ID to NEW-FILE-ID.  See `brain-rename-file'."
  (let* ((bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally source-path)
                  (buffer-string)))
         (digest (brain--sha256 bytes)))
    (cond
     ((> (length bytes) brain-object-max-bytes)
      (brain--result "attention" file-id :reason "too_large"))
     ((not (brain--utf8-bytes-p bytes))
      (brain--result "attention" file-id :reason "unsupported_coding"))
     (t
      (let* ((source-head (gethash file-id brain--heads))
             (destination-head (gethash new-file-id brain--heads))
             (revision (brain--rev (if destination-head
                                       (1+ (brain--rev-seq destination-head))
                                     0)
                                   digest))
             (generation (brain--lifecycle-next-generation))
             (intent (list :operation_id operation-id :action "relocate"
                           :source_file_id file-id :source_revision source-head
                           :source_hash digest
                           :destination_file_id new-file-id
                           :destination_predecessor destination-head
                           :destination_revision revision
                           :destination_object_hash digest
                           :lifecycle_generation generation
                           :from_path source-path :to_path destination-path
                           :reason "rename")))
        ;; §3: "Publish/retain source immutable bytes before action."
        (brain--publish-object bytes digest)
        (brain--fsync (brain--object-path "mac" digest))
        ;; §3: "journal/fsync intent before the atomic rename".
        (brain--journal-append "lifecycle_intent"
                               :operation_id operation-id :action "relocate"
                               :source_file_id file-id :source_revision source-head
                               :source_hash digest
                               :destination_file_id new-file-id
                               :destination_predecessor destination-head
                               :destination_revision revision
                               :destination_object_hash digest
                               :lifecycle_generation generation
                               :from_path source-path :to_path destination-path
                               :reason "rename")
        (let ((result
               (brain--lifecycle-critical (list file-id new-file-id)
                 (lambda ()
                   ;; ---- no yield from here to the committed record ----
                   (let ((late (brain--lifecycle-refusal file-id new-file-id t)))
                     (if late
                         (brain--result "dirty" file-id :reason late)
                       (progn
                         (brain--rename-file-primitive source-path destination-path nil)
                         (brain--lifecycle-apply intent))))))))
          (when (equal (plist-get result :status) "committed")
            (brain--lifecycle-retarget-buffers file-id destination-path)
            (brain--lifecycle-deferred-hooks "relocate" source-path destination-path))
          result))))))

(defun brain--lifecycle-retarget-buffers (file-id destination-path)
  "Point the clean buffers visiting FILE-ID at DESTINATION-PATH (§3).
Only a buffer that still visits the old path and is still clean is retargeted;
point, narrowing and window state are kept and nothing is displayed.  A buffer
that became dirty is left exactly where it is -- retargeting it would move the
human's unsaved text onto a path the lifecycle just retired."
  (dolist (buffer (brain--base-buffers (brain--visiting-buffers file-id)))
    (when (and (buffer-live-p buffer) (not (brain--buffer-dirty-p buffer)))
      (with-current-buffer buffer
        (let ((brain--inhibit-guards t))
          (condition-case err
              (progn
                (set-visited-file-name destination-path t)
                (set-buffer-modified-p nil)
                (set-visited-file-modtime))
            (error (brain--log "retarget of %s failed: %S" file-id err))))))))

(defun brain--advice-outermost-p (symbol function)
  "Non-nil when FUNCTION is the OUTERMOST advice on SYMBOL. The order is a
  property of load order, not of this module: `Emacs.org' enables
  `org-roam-db-autosync-mode' before Brain loads, so there brain's guard wraps
  org-roam's advice; a test that enables autosync afterwards sees the opposite
  order.  The lifecycle needs to know which of the two is true, because only
  the outermost one can stop the inner layer from running."
  (let ((entry (symbol-function symbol)))
    (and (advice--p entry) (eq (advice--car entry) function))))

(defun brain--lifecycle-deferred-hooks (action from-path to-path)
  "Run the derived-index work the lifecycle deferred until the durable commit.
  §3: \"defer org-roam indexing/hooks until durable commit\".  The atomic
  action runs with the user-facing advice peeled off, so when brain's guard is
  the outermost layer the package's own hook never fires and is invoked here,
  after the record is fsynced.  When the package's advice is outermost it
  already runs after this command returns, and running it here too would index
  the same file twice. Nothing is reimplemented: when org-roam is not loaded
  this is a no-op."
  (pcase action
    ((or "relocate" "reactivate")
     (when (and (fboundp 'org-roam-db-autosync--rename-file-a)
                (brain--advice-outermost-p 'rename-file #'brain-guard-rename-file)
                from-path to-path)
       (condition-case err
           (org-roam-db-autosync--rename-file-a from-path to-path)
         (error (brain--log "deferred org-roam rename hook failed: %S" err)))))
    ("retire"
     (when (and (fboundp 'org-roam-db-autosync--delete-file-a)
                (brain--advice-outermost-p 'delete-file #'brain-guard-delete-file)
                from-path)
       (condition-case err
           (org-roam-db-autosync--delete-file-a from-path nil)
         (error (brain--log "deferred org-roam delete hook failed: %S" err)))))
    (_ nil)))

(defun brain-delete-file (file-id &optional operation-id)
  "Guarded managed retirement of FILE-ID (§3). The immutable bytes are published
  first, the intent is fsynced, the file is unlinked, and only then is the
  retirement recorded.  The path keeps its head, its object and its history; it
  is marked inactive, so a stale remote install that still matches the old
  expected revision cannot resurrect it."
  (let ((operation-id (or operation-id (brain--uuid))))
    (cond
     ((not (and brain-id brain-writer-id))
      (brain--result "unavailable" file-id :reason "unconfigured"))
     ((not brain--recovered)
      (brain--result "unavailable" file-id :reason "not_recovered"))
     ((brain--lifecycle-outcome operation-id))
     ((brain--retired-p file-id)
      ;; Already inactive: the honest answer is that there is nothing to do.
      (brain--result "committed" file-id :reason "already_retired"
                     :current-revision (gethash file-id brain--heads)))
     (t
      (let* ((resolution (brain--resolve file-id))
             (path (plist-get resolution :path))
             (refusal (brain--lifecycle-refusal file-id nil)))
        (cond
         ((not (equal (plist-get resolution :status) "ok"))
          (brain--result "attention" file-id
                         :reason (or (plist-get resolution :reason) "source_missing")))
         (refusal (brain--result "dirty" file-id :reason refusal))
         (t (brain--delete-now file-id operation-id path))))))))

(defun brain--delete-now (file-id operation-id path)
  "Unlink PATH and record the retirement of FILE-ID.  See `brain-delete-file'."
  (let* ((bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally path)
                  (buffer-string)))
         (digest (brain--sha256 bytes))
         (head (gethash file-id brain--heads))
         (generation (brain--lifecycle-next-generation))
         (intent (list :operation_id operation-id :action "retire"
                       :source_file_id file-id :source_revision head
                       :source_hash digest
                       :destination_file_id nil :destination_predecessor nil
                       :destination_revision nil :destination_object_hash nil
                       :lifecycle_generation generation
                       :from_path path :to_path nil
                       :reason "delete")))
    (brain--publish-object bytes digest)
    (brain--fsync (brain--object-path "mac" digest))
    (brain--journal-append "lifecycle_intent"
                           :operation_id operation-id :action "retire"
                           :source_file_id file-id :source_revision head
                           :source_hash digest
                           :lifecycle_generation generation
                           :from_path path :reason "delete")
    (brain--lifecycle-critical (list file-id)
      (lambda ()
        ;; ---- no yield from here to the committed record ----
        (let ((late (brain--lifecycle-refusal file-id nil t)))
          (if late
              (brain--result "dirty" file-id :reason late)
            (let ((result (progn
                            (brain--delete-file-primitive path)
                            (brain--lifecycle-apply intent))))
              (when (equal (plist-get result :status) "committed")
                (brain--lifecycle-deferred-hooks "retire" path nil))
              result)))))))

;; --- out-of-protocol missing paths (§3: two complete inventories) -----------

(defun brain--note-inventory-membership (paths)
  "Record one COMPLETE inventory's membership for the retirement proof (§3). A
  path that reappears voids its earlier observations: it is not missing.  Only
  paths that still have a head are tracked -- there is nothing to retire for a
  path that was never enrolled."
  (let ((now (float-time))
        (present (make-hash-table :test #'equal))
        (absent nil))
    (dolist (path paths) (puthash path t present))
    (maphash (lambda (file-id _observations)
               (when (gethash file-id present)
                 (push file-id absent)))
             brain--missing-observations)
    (dolist (file-id absent) (remhash file-id brain--missing-observations))
    (maphash (lambda (file-id _head)
               (unless (or (gethash file-id present) (brain--retired-p file-id))
                 (puthash file-id
                          (cons now (seq-take (gethash file-id brain--missing-observations) 7))
                          brain--missing-observations)))
             brain--heads)))

(defun brain--missing-retire-eligible-p (file-id)
  "Non-nil when FILE-ID may be retired as a proven-missing path (§3). Every
  clause is required: a retained head to retire, two complete inventories at
  least `brain-missing-retire-interval' apart that both lacked the path, no
  retirement already, no attention row (an existing attention is never
  auto-reconciled), no lease, no recovery marker, no visiting buffer and no
  in-flight install."
  (let ((observations (gethash file-id brain--missing-observations)))
    (and (gethash file-id brain--heads)
         (not (brain--retired-p file-id))
         (null (gethash file-id brain--attention))
         (null (gethash file-id brain--dirty))
         (null (brain--visiting-buffers file-id))
         (null (brain--recovery-marker file-id))
         (not brain--in-critical)
         (not (member file-id brain--locked))
         (>= (length observations) 2)
         (>= (- (nth 0 observations) (nth 1 observations))
             brain-missing-retire-interval))))

(defun brain--lifecycle-retire-missing (file-id)
  "Retire FILE-ID as a proven-missing path (§3). Called only from the explicit
  target recheck, and only when `brain--missing-retire-eligible-p' holds.
  Nothing is read from disk: the path is already gone, and the retained head
  and object are what the retirement records."
  (let* ((head (gethash file-id brain--heads))
         (generation (brain--lifecycle-next-generation))
         (intent (list :operation_id (brain--uuid) :action "retire"
                       :source_file_id file-id :source_revision head
                       :source_hash (and head (brain--rev-sha head))
                       :destination_file_id nil :destination_predecessor nil
                       :destination_revision nil :destination_object_hash nil
                       :lifecycle_generation generation
                       :from_path nil :to_path nil
                       :reason "missing_two_scans")))
    (remhash file-id brain--missing-observations)
    (brain--lifecycle-apply intent)))

;; --- explicit clean disk reconcile (§3) -------------------------------------

(defun brain-reconcile-file (file-id expected-head expected-disk-hash)
  "Adopt a clean out-of-protocol disk change for FILE-ID, explicitly (§3). This
  is the ONLY way a disk/head mismatch becomes a canonical revision, and it
  never runs by itself: the caller must name the head it displayed and the
  exact sha256 it observed on disk, and both must still hold at the writer
  guard.  The bytes are NOT rewritten -- they are already the file -- they are
  published as the immutable object and journaled as the next revision on the
  path's own chain, so the history keeps every earlier object.

  Refused when the head or the disk hash moved, when a buffer is modified, when
  a lease or a recovery marker exists, and while an install is in flight."
  (interactive
   (let* ((file-id (or (brain--buffer-file-id (current-buffer))
                       (read-string "Managed file_id: ")))
          (head (gethash file-id brain--heads)))
     (list file-id head (read-string "Expected disk sha256: "))))
  (let ((operation-id (brain--uuid)))
    (cond
     ((not (and brain-id brain-writer-id))
      (brain--result "unavailable" file-id :reason "unconfigured"))
     ((not brain--recovered)
      (brain--result "unavailable" file-id :reason "not_recovered"))
     ((not (stringp expected-disk-hash))
      (brain--result "attention" file-id :reason "expected_hash_required"))
     ((brain--retired-p file-id)
      (brain--result "attention" file-id :reason "path_retired"))
     (t
      (let* ((resolution (brain--resolve file-id))
             (path (plist-get resolution :path))
             (head (gethash file-id brain--heads))
             (refusal (brain--lifecycle-refusal file-id nil)))
        (cond
         ((not (equal (plist-get resolution :status) "ok"))
          (brain--result "attention" file-id
                         :reason (or (plist-get resolution :reason) "source_missing")))
         ((not (brain--rev-equal expected-head head))
          ;; The displayed head moved: the operator is looking at stale state.
          (brain--result "stale" file-id :current-revision head :reason "head_moved"))
         (refusal (brain--result "dirty" file-id :reason refusal))
         (t
          (let ((disk (brain--sha256-file path)))
            (if (not (equal disk expected-disk-hash))
                (brain--result "attention" file-id :current-revision head
                               :reason "disk_changed")
              (brain--reconcile-now file-id operation-id path disk head))))))))))

(defun brain--reconcile-now (file-id operation-id path digest head)
  "Journal HEAD's successor for the bytes already at PATH.  See
  `brain-reconcile-file'."
  (let* ((bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally path)
                  (buffer-string)))
         (revision (brain--rev (if head (1+ (brain--rev-seq head)) 0) digest)))
    (cond
     ((> (length bytes) brain-object-max-bytes)
      (brain--result "attention" file-id :reason "too_large"))
     ((not (brain--utf8-bytes-p bytes))
      (brain--result "attention" file-id :reason "unsupported_coding"))
     ((not (equal (brain--sha256 bytes) digest))
      ;; The bytes changed between the hash and the open.
      (brain--result "attention" file-id :reason "disk_changed"))
     (t
      (brain--publish-object bytes digest)
      (brain--fsync (brain--object-path "mac" digest))
      (brain--lifecycle-critical (list file-id)
        (lambda ()
          ;; ---- no yield from here to the committed record ----
          (let ((late (brain--lifecycle-refusal file-id nil t)))
            (if late
                (brain--result "dirty" file-id :reason late)
              (progn
                (brain--journal-append "committed" :file_id file-id
                                       :operation_id operation-id
                                       :prev_revision head :new_revision revision
                                       :object_hash digest :origin "reconcile"
                                       :phase "committed")
                (puthash file-id revision brain--heads)
                (brain--fsync (brain--journal-file) path (file-name-directory path))
                (brain--heads-save)
                ;; The mismatch this command exists to resolve is now resolved,
                ;; by an explicit operator action -- not by a scan.  The clearing
                ;; is journaled, so it is evidence, not silence.
                (when (gethash file-id brain--attention)
                  (remhash file-id brain--attention)
                  (brain--journal-append "attention_cleared" :file_id file-id
                                         :reason "reconciled"
                                         :operation_id operation-id))
                (brain--emit-event
                 "brain.file.changed"
                 (list (cons "file_id" file-id)
                       (cons "predecessor_revision" (brain--rev->json head))
                       (cons "revision" (brain--rev->json revision))
                       (cons "object_hash" digest)
                       (cons "operation_id" operation-id)
                       (cons "client_epoch" (or brain--client-epoch :null))))
                (brain--result "committed" file-id
                               :installed nil
                               :current-revision head
                               :new-revision revision
                               :object-hash digest
                               :operation-id operation-id))))))))))

(defun brain--rebuild-lifecycle ()
  "Rebuild retired membership and lifecycle generations from the journal (§3)."
  (clrhash brain--retired)
  (clrhash brain--lifecycle-generations)
  (setq brain--lifecycle-seq 0)
  (dolist (record (brain--journal-records "lifecycle"))
    (let ((generation (or (plist-get record :lifecycle_generation) 0))
          (action (plist-get record :action))
          (source (plist-get record :source_file_id))
          (destination (plist-get record :destination_file_id)))
      (setq brain--lifecycle-seq (max brain--lifecycle-seq generation))
      (when source
        (puthash source generation brain--lifecycle-generations)
        (when (member action '("retire" "relocate"))
          (puthash source (list :generation generation
                                :head (plist-get record :source_revision))
                   brain--retired)))
      (when destination
        (puthash destination generation brain--lifecycle-generations)
        (remhash destination brain--retired))))
  brain--retired)

(defun brain--recover-lifecycle ()
  "Resolve every journaled lifecycle intent that never reached a record (§3).
  The intent names both exact paths and the intended bytes, so the outcome is
  decided from disk and the retained hash -- never guessed."
  (dolist (record (brain--journal-records "lifecycle_intent"))
    (let ((operation-id (plist-get record :operation_id)))
      (unless (or (brain--lifecycle-outcome operation-id)
                  (seq-find (lambda (other)
                              (and (equal (plist-get other :operation_id) operation-id)
                                   (member (plist-get other :kind)
                                           '("lifecycle_aborted" "lifecycle_attention"))))
                            brain--journal))
        (brain--recover-lifecycle-intent record)))))

(defun brain--recover-lifecycle-intent (record)
  "Resolve one unresolved lifecycle INTENT.  See `brain--recover-lifecycle'."
  (let* ((operation-id (plist-get record :operation_id))
         (action (plist-get record :action))
         (source-id (plist-get record :source_file_id))
         (source-path (plist-get record :from_path))
         (destination-path (plist-get record :to_path))
         (intended (plist-get record :source_hash))
         (old (and source-path (file-exists-p source-path)))
         (new (and destination-path (file-exists-p destination-path))))
    (pcase action
      ("relocate"
       (cond
        ;; Old present, new absent: the rename never happened.  Nothing is
        ;; invented; the operation is recorded as not installed.
        ((and old (not new))
         (brain--journal-append "lifecycle_aborted" :operation_id operation-id
                                :action action :reason "not_installed")
         (brain--log "lifecycle %s did not install; both paths are unchanged" operation-id))
        ;; Old absent, new carries exactly the intended bytes: finish the record.
        ((and (not old) new (equal (brain--sha256-file destination-path) intended))
         (brain--lifecycle-apply record)
         (brain--lifecycle-retarget-buffers source-id destination-path)
         (brain--lifecycle-deferred-hooks action source-path destination-path))
        (t
         ;; Both present, neither present, or unexpected bytes: no guessed
         ;; success.  A human decides.
         (brain--lifecycle-attention operation-id "recovery_mismatch" source-id))))
      ("retire"
       (cond
        ;; The unlink landed before the record: finish the retirement.
        ((not old) (brain--lifecycle-apply record))
        ;; Unchanged bytes still there: the unlink never ran, so retry it under
        ;; the same guards rather than leaving the intent dangling.
        ((and old (equal (brain--sha256-file source-path) intended))
         (let ((refusal (brain--lifecycle-refusal source-id nil)))
           (if refusal
               (brain--journal-append "lifecycle_aborted" :operation_id operation-id
                                      :action action :reason refusal)
             (progn
               (brain--delete-file-primitive source-path)
               (brain--lifecycle-apply record)))))
        (t (brain--lifecycle-attention operation-id "recovery_mismatch" source-id))))
      (_ (brain--lifecycle-attention operation-id "unknown_action" source-id)))))

;;; ---------------------------------------------------------------------------
;;; Outbound events, outbox and IPC
;;; ---------------------------------------------------------------------------

(defun brain--emit-event (kind payload &optional no-send)
  "Durably journal one Brain event before it can leave, then send it.

E9c: the wire identity is tentative until the journal append succeeded.  The
reviewed version incremented `brain--wire-seq' first, so a failed append burned
a wire sequence and produced no event in the journal, no entry in
`brain--outbox' and nothing on the wire — the peer then sees a permanent gap at
a position this writer can never replay.  Publishing after the append means a
failed emission costs nothing: the next attempt reuses the same wire sequence."
  (when (and brain-id brain-peer-id)
    (let* ((next (1+ brain--wire-seq))
           (event (list (cons "v" brain-protocol-version)
                        (cons "type" "brain.event")
                        (cons "brain_id" brain-id)
                        (cons "peer_id" brain-peer-id)
                        (cons "event_id" (brain--uuid))
                        (cons "seq" next)
                        (cons "kind" kind)
                        (cons "payload" payload))))
      ;; May signal `brain-journal-fault': the caller must not report a
      ;; delivered page, and nothing below runs, so no identity is published.
      (brain--journal-append "event" :wire_seq next :event_kind kind
                             :file_id (alist-get "file_id" payload nil nil #'equal)
                             :payload event)
      (setq brain--wire-seq next)
      (setq brain--outbox (append brain--outbox (list event)))
      (unless no-send (brain--pump-outbox))
      event)))

(defun brain--emit-commit-events (spec file-id predecessor revision origin generation)
  (let ((payload (list (cons "file_id" file-id)
                       (cons "predecessor_revision" (brain--rev->json predecessor))
                       (cons "revision" (brain--rev->json revision))
                       (cons "object_hash" (brain--rev-sha revision))
                       (cons "operation_id" (plist-get spec :operation-id))
                       (cons "client_epoch" (or brain--client-epoch :null)))))
    (when generation
      (setq payload (append payload (list (cons "dirty_generation" generation)))))
    (when (plist-get spec :semantic)
      (setq payload (append payload (list (cons "semantic" (plist-get spec :semantic))))))
    (brain--emit-event (if (equal origin "human") "brain.file.saved"
                         "brain.file.changed")
                       payload)))

(defun brain--ipc-send (object)
  "Send one typed frame to the node.  Returns non-nil when it was queued."
  (if (not (and brain--ipc (process-live-p brain--ipc)))
      nil
    (condition-case err
        (let* ((body (encode-coding-string (brain--json-encode object) 'utf-8))
               (length (length body)))
          (when (> length brain-frame-max-bytes)
            (signal 'brain-alternate-route (list "frame_too_large")))
          (process-send-string brain--ipc
                               (concat (unibyte-string (logand #xff (ash length -24))
                                                       (logand #xff (ash length -16))
                                                       (logand #xff (ash length -8))
                                                       (logand #xff length))
                                       body))
          t)
      (error (brain--log "ipc send failed: %S" err) nil))))

(defun brain--pump-outbox ()
  "Send unacknowledged events in wire order.  Stops at the first failure."
  (when (and brain--reconciled brain--ipc (process-live-p brain--ipc))
    (let ((pending (seq-filter
                    (lambda (event)
                      (> (alist-get "seq" event nil nil #'equal) brain--acked-seq))
                    brain--outbox)))
      (while (and pending (brain--ipc-send (car pending)))
        (setq pending (cdr pending))))))

(defun brain--handle-ack (frame)
  (let ((through (alist-get "through_seq" frame nil nil #'equal)))
    (when (and (integerp through) (> through brain--acked-seq))
      (setq brain--acked-seq through)
      (setq brain--outbox
            (seq-filter (lambda (event)
                          (> (alist-get "seq" event nil nil #'equal) through))
                        brain--outbox))
      (brain--journal-append "ack" :through_seq through))))

(defun brain--unibyte (string)
  (if (multibyte-string-p string) (string-to-unibyte string) string))

(defun brain--frames-take ()
  "Pop complete frames from the inbound byte buffer, returning JSON alists."
  (let ((frames nil) (done nil))
    (while (not done)
      (if (< (length brain--ipc-bytes) 4)
          (setq done t)
        (let* ((bytes brain--ipc-bytes)
               (length (logior (ash (aref bytes 0) 24) (ash (aref bytes 1) 16)
                               (ash (aref bytes 2) 8) (aref bytes 3))))
          (cond
           ((> length brain-frame-max-bytes)
            (setq brain--ipc-bytes "")
            (brain--log "oversize ipc frame dropped")
            (setq done t))
           ((< (length bytes) (+ 4 length)) (setq done t))
           (t
            (let ((body (substring bytes 4 (+ 4 length))))
              (setq brain--ipc-bytes (substring bytes (+ 4 length)))
              (let ((frame (condition-case nil
                               (brain--json-decode (decode-coding-string body 'utf-8))
                             (error nil))))
                (if frame (push frame frames)
                  (brain--log "malformed ipc frame dropped")))))))))
    (nreverse frames)))

(defun brain--ipc-filter (_process chunk)
  "Process filter: decode and ENQUEUE only.  Never commits, never yields."
  (condition-case err
      (progn
        (setq brain--ipc-bytes (concat (brain--unibyte brain--ipc-bytes)
                                       (brain--unibyte chunk)))
        (dolist (frame (brain--frames-take))
          (when (brain--admissible-frame-p frame)
            (setq brain--inbox (append brain--inbox (list frame))))))
    (error (brain--log "ipc filter error: %S" err))))

(defun brain--admissible-frame-p (frame)
  (and (listp frame)
       (equal (alist-get "v" frame nil nil #'equal) brain-protocol-version)
       (member (alist-get "type" frame nil nil #'equal)
               '("brain.install.request" "brain.snapshot.request" "brain.ack"
                 "brain.replay.request" "brain.event" "brain.install.result"))))

(defun brain--ipc-sentinel (process _event)
  (when (memq (process-status process) '(closed failed exit signal))
    (brain--log "ipc closed")
    (setq brain--ipc nil
          brain--reconciled nil
          brain--ipc-bytes "")))

(defun brain--unix-socket-p (attributes)
  "True when ATTRIBUTES describe a UNIX socket, whatever `file-attributes' reports.
`file-attributes' puts the type in its first element: `t' for a directory, a
string for a symbolic link and nil for everything else -- and on the reviewed
Mac a real 0600 node.sock is exactly that nil case, which is why the reviewed
test `(eq (car (file-attributes socket 'string)) 'socket)' could never pass.
The modes string's first character is the POSIX file type, so `s' is the honest
test."
  (let ((modes (file-attribute-modes attributes)))
    (and (stringp modes) (> (length modes) 0) (eq ?s (aref modes 0)))))

(defun brain--ipc-connect ()
  "Connect to the node endpoint after checking its type and ownership."
  (let* ((socket (brain--socket-path))
         ;; Numeric ids on purpose: with the `string' id format the owner comes back as a
         ;; name, which `user-uid' cannot be compared with (it signals wrong-type-argument).
         (attributes (file-attributes socket))
         (type (car attributes))
         (uid (and attributes (file-attribute-user-id attributes))))
    (cond
     ((null attributes) (brain--log "no node socket") nil)
     ((stringp type) (brain--log "refusing symlinked socket") nil)
     ((not (brain--unix-socket-p attributes)) (brain--log "node endpoint is not a socket") nil)
     ((and uid (/= uid (user-uid))) (brain--log "socket owned by another uid") nil)
     (t
      (condition-case err
          (setq brain--ipc (make-network-process
                            :name "brain-node" :family 'local :service socket
                            :coding 'binary :filter #'brain--ipc-filter
                            :sentinel #'brain--ipc-sentinel :noquery t))
        (error (brain--log "ipc connect failed: %S" err) nil))))))

(defconst brain--corpus-feature "corpus-v1"
  "The additive corpus feature this client advertises (design t_c52859ca v2 §1).
Pinned to the gateway's `contracts.CORPUS_FEATURE' and the node's
`BrainIPCServer.corpusFeature' by a test; the wire stays Brain v1, and the
feature is live only when all three endpoints advertise it.")

(defun brain--subscribe ()
  (when (brain--ipc-connect)
    (setq brain--epoch (1+ brain--epoch)
          brain--client-epoch (or brain--client-epoch (brain--uuid)))
    ;; The third advertisement of the three-way agreement (§1). The node relays
    ;; this list upstream on `device.heartbeat', because the gateway cannot see
    ;; `brain.subscribe' itself. An old node ignores the field; an old client
    ;; omits it, which is what keeps the extension off for a mixed pair.
    (brain--ipc-send (list (cons "v" brain-protocol-version)
                           (cons "type" "brain.subscribe")
                           (cons "client_epoch" brain--client-epoch)
                           (cons "corpus_features"
                                 (cons :json-array (list brain--corpus-feature)))))))

(defun brain--announce-ready ()
  "Report reconciliation to the node, which then allows install routing."
  (when (and brain--client-epoch
             (brain--ipc-send (list (cons "v" brain-protocol-version)
                                    (cons "type" "brain.client.ready")
                                    (cons "client_epoch" brain--client-epoch))))
    (setq brain--reconciled t)
    (brain--emit-event "emacs.online" (list (cons "epoch" (max 1 brain--epoch))))
    ;; §4: the profile is emitted "after readiness and on relevant configuration
    ;; change". Readiness is exactly here, so a reconnecting client re-publishes
    ;; its configuration instead of leaving the gateway on a stale one.
    (brain--emit-query-profile)
    (brain--pump-outbox)
    t))

;;; ---------------------------------------------------------------------------
;;; Bounded reconnect
;;; ---------------------------------------------------------------------------

(defun brain--ipc-connected-p ()
  (and brain--ipc (process-live-p brain--ipc) t))

(defun brain--reconnect ()
  "One bounded reconnect attempt after the node endpoint went away.
The design requires the client to subscribe with its epoch after recovery:
the node clears its reconciliation flag on `brain.subscribe' and routes install
requests again only once `brain.client.ready' carries that same epoch, so a
reconnect repeats both frames. The durable outbox is resent by
`brain--announce-ready', which is what makes an offline save survive a node
restart without a manual `brain-disable'/`brain-enable'."
  (when (and brain--enabled (not (brain--ipc-connected-p)))
    (condition-case err
        (progn
          (brain--subscribe)
          (when (brain--ipc-connected-p)
            (brain--announce-ready)))
      (error (brain--log "ipc reconnect failed: %S" err)))))

(defun brain--start-reconnect ()
  "Poll for a usable node endpoint while Brain is enabled (one timer, no chain)."
  (brain--stop-reconnect)
  (setq brain--reconnect-timer
        (run-with-timer brain-reconnect-interval brain-reconnect-interval
                        #'brain--reconnect)))

(defun brain--stop-reconnect ()
  (when brain--reconnect-timer
    (cancel-timer brain--reconnect-timer)
    (setq brain--reconnect-timer nil)))

;;; ---------------------------------------------------------------------------
;;; Inbound dispatcher
;;; ---------------------------------------------------------------------------

(defun brain--start-dispatch ()
  "Arm the one inbound dispatcher timer, as a REGULAR timer, not an idle one.

`brain--ipc-filter' only enqueues, so the commit path can never run inside a
process filter.  The trigger that drains the queue must not depend on Emacs
being idle, though: a repeating idle timer is re-armed with its `triggered'
flag set (`timer-event-handler' -> `timer-activate-when-idle') and only
`internal-timer-start-idle', which Emacs calls when a NEW idle period begins
after real input, clears it again.  One long idle period therefore runs it
exactly once, which is what the live pair did on 2026-10-31: 105 gateway acks
and one `brain.install.request' sat in `brain--inbox' with `brain--acked-seq'
still 0 while four idle dispatcher timers were all marked triggered, because a
daemon driven by `emacsclient' is never \"touched\".  A regular timer is
re-armed from wall-clock time, so it fires whether or not anybody is at the
keyboard."
  (brain--stop-dispatch)
  (setq brain--dispatch-timer
        (run-with-timer brain-dispatch-interval brain-dispatch-interval
                        #'brain-dispatch-once)))

(defun brain--stop-dispatch ()
  (when brain--dispatch-timer
    (cancel-timer brain--dispatch-timer)
    (setq brain--dispatch-timer nil)))

;;; ---------------------------------------------------------------------------
;;; Inbound dispatch
;;; ---------------------------------------------------------------------------

(defun brain-dispatch-once ()
  "Execute every queued inbound frame exactly once.

E9c: while the journal fault is latched no frame is dispatched.  Every handler
that matters needs a durable journal write, so draining the queue would only
produce a run of failures — and the reviewed `condition-case' around each frame
turned exactly that into a silently \"handled\" frame.  The queue is left intact
so nothing is lost, and the fault stays visible through `brain-status' until a
validated reload clears it."
  (when (and brain--recovered (not brain--dispatching) brain--inbox)
    (if brain--journal-fault
        (brain--log "dispatch refused: journal fault (%s) is latched"
                    (plist-get brain--journal-fault :reason))
      (let ((brain--dispatching t)
            (stopped nil))
        (while (and brain--inbox (not stopped))
          (let ((frame (pop brain--inbox)))
            (condition-case err
                (brain--dispatch-frame frame)
              (brain-journal-fault
               ;; A durability failure is not a per-frame accident: put the
               ;; frame back and stop the drain.  The queue survives, and the
               ;; latched fault is what `brain-status' reports.
               (push frame brain--inbox)
               (setq stopped t)
               (brain--log "dispatch stopped: %S" err))
              (error (brain--log "dispatch error: %S" err)))))))))

(defun brain--dispatch-frame (frame)
  (pcase (alist-get "type" frame nil nil #'equal)
    ("brain.install.request" (brain--handle-install-request frame))
    ("brain.snapshot.request" (brain--handle-snapshot-request frame))
    ("brain.ack" (brain--handle-ack frame))
    ("brain.replay.request" (brain--handle-replay-request frame))
    ("brain.install.result" (brain--log "install result echoed by gateway"))
    ("brain.event" (brain--log "gateway event received"))
    (_ (brain--log "ignored inbound type"))))

(defun brain--frame-brain-id-ok-p (frame)
  (equal (alist-get "brain_id" frame nil nil #'equal) brain-id))

(defun brain--handle-install-request (frame)
  (let* ((file-id (alist-get "file_id" frame nil nil #'equal))
         (attempt-id (alist-get "attempt_id" frame nil nil #'equal))
         (mutation-id (alist-get "mutation_id" frame nil nil #'equal))
         (digest (alist-get "object_hash" frame nil nil #'equal))
         (byte-length (alist-get "byte_length" frame nil nil #'equal))
         (expected (brain--rev<-json
                    (alist-get "expected_revision" frame nil nil #'equal))))
    (cond
     ((not (brain--frame-brain-id-ok-p frame))
      (brain--log "install request for a foreign brain id refused"))
     ((gethash attempt-id brain--results)
      (brain--send-result (gethash attempt-id brain--results)))
     (t
      (let* ((bytes (and (stringp digest)
                         (brain--read-object "hermes" digest byte-length)))
             (result
              (pcase bytes
                ((or 'missing 'oversize)
                 (brain--result "waiting_bytes" file-id
                                :current-revision (gethash file-id brain--heads)
                                :reason (symbol-name bytes)))
                ('mismatch
                 (brain--result "attention" file-id :reason "object_mismatch"))
                (_
                 (let ((decoded (condition-case nil
                                    (decode-coding-string bytes 'utf-8)
                                  (error nil))))
                   (if (not (stringp decoded))
                       (brain--result "attention" file-id :reason "invalid_utf8")
                     (let* ((head (gethash file-id brain--heads))
                            (next (if head (1+ (brain--rev-seq head)) 0))
                            (semantic (brain--projection-for bytes file-id
                                                             (brain--rev next digest)
                                                             attempt-id)))
                       (brain-commit-file
                        (list :file-id file-id :origin "librarian" :bytes bytes
                              :object-hash digest :expected-revision expected
                              :require-expected t :attempt-id attempt-id
                              :mutation-id mutation-id :operation-id attempt-id
                              :semantic semantic)))))))))
        (setq result (plist-put result :attempt-id attempt-id))
        (setq result (plist-put result :mutation-id mutation-id))
        (setq result (plist-put result :file-id file-id))
        (brain--journal-result result)
        (brain--send-result result))))))

(defun brain--send-result (result)
  "Send one `brain.install.result' frame with the reviewed field set."
  (brain--ipc-send
   (list (cons "v" brain-protocol-version)
         (cons "type" "brain.install.result")
         (cons "brain_id" brain-id)
         (cons "attempt_id" (or (plist-get result :attempt-id)
                                (plist-get result :operation-id)))
         (cons "mutation_id" (plist-get result :mutation-id))
         (cons "file_id" (plist-get result :file-id))
         (cons "status" (plist-get result :status))
         (cons "current_revision" (brain--rev->json (plist-get result :current-revision)))
         (cons "new_revision" (brain--rev->json (plist-get result :new-revision)))
         (cons "mac_seq" (or (plist-get result :mac-seq) :null))
         (cons "blocked_reason" (or (plist-get result :reason) :null)))))

(defun brain--replay-events (after-seq limit)
  "Return (EVENTS . STOPPED): retained events after AFTER-SEQ, ascending.

The source of truth is the JOURNAL, not the outbox: an event the gateway already
acknowledged is no longer in `brain--outbox' but is still the honest answer to a
replay request, and the outbox alone would claim it never existed.  The original
envelope is replayed byte-for-byte — same `seq', same `event_id', same payload —
because a new identity or a rebuilt revision would be a second fact, not a
replay of the first.

STOPPED is the first position that is missing from the journal, or nil when the
window is complete.  Replay never invents an event to bridge a hole: a missing
position is reported so the sender can tell a lost range from a late one."
  (let ((events nil)
        (stopped nil)
        (wanted (1+ after-seq))
        (count 0))
    (catch 'done
      (dolist (record brain--journal)
        (when (equal (plist-get record :kind) "event")
          (let ((seq (plist-get record :wire_seq)))
            (cond
             ((or (not (integerp seq)) (<= seq after-seq)))
             ((/= seq wanted)
              ;; A hole in the retained stream: report it, never skip it.
              (setq stopped wanted)
              (throw 'done nil))
             ((>= count limit)
              (throw 'done nil))
             (t
              (push (plist-get record :payload) events)
              (setq count (1+ count))
              (setq wanted (1+ seq))))))))
    (cons (nreverse events) stopped)))

(defun brain--handle-replay-request (frame)
  "Answer one `brain.replay.request': an attempt result, or a stream range.

The attempt branch is unchanged.  The stream branch is a real answer now: the
reviewed module logged \"stream replay is answered by the gateway\" and sent
nothing, so a `gap' refusal from Hermes could never be filled even when this
writer still held every event.  Only this Mac's own stream is answered, and only
from the journal it actually retained."
  (let ((attempt-id (alist-get "attempt_id" frame nil nil #'equal))
        (peer-id (alist-get "peer_id" frame nil nil #'equal))
        (after-seq (alist-get "after_seq" frame nil nil #'equal)))
    (cond
     ((and (stringp attempt-id) (gethash attempt-id brain--results))
      (brain--send-result (gethash attempt-id brain--results)))
     ((stringp attempt-id)
      ;; No durable result for this attempt: answering with an invented file
      ;; identity would violate the contract, so nothing is sent.
      (brain--log "replay request for unknown attempt refused"))
     ((not (brain--frame-brain-id-ok-p frame))
      (brain--log "stream replay request for a foreign brain id refused"))
     ((not (equal peer-id brain-peer-id))
      ;; Only the stream this Mac produces can be replayed from this journal.
      (brain--log "stream replay request for another peer refused"))
     ((not (and (integerp after-seq) (>= after-seq 0)))
      (brain--log "stream replay request with an invalid cursor refused"))
     (t
      (let* ((probe (brain--replay-events after-seq 100))
             (events (car probe))
             (stopped (cdr probe)))
        (dolist (event events) (brain--ipc-send event))
        (if stopped
            (brain--log "stream replay stopped at missing seq %S after %S"
                        stopped after-seq)
          (brain--log "stream replay answered after %S with %S events"
                      after-seq (length events))))))))

;;; ---------------------------------------------------------------------------
;;; Snapshots and inventory (design t_c52859ca v2 §2)
;;; ---------------------------------------------------------------------------
;;
;; The legacy shapes are untouched: a target request is still `{file_id}` and a
;; legacy page is still `{limit[, after_file_id]}` with limit 1..100, and
;; `brain--snapshot-page' keeps its first-next `continuation' semantics exactly.
;; §1 forbids silently changing old page interpretation, so the legacy page is
;; left byte-for-byte as it was and the new capture lives beside it.
;;
;; The corpus shapes are additive and disjoint (`mode` is a new field, so no frame
;; can be read as both):
;;
;;   inventory page  {mode:"inventory", inventory_id, after_file_id|null, limit 1..50}
;;   history page    {mode:"history", file_id, after_revision_seq:-1|seq, limit 1..50}
;;
;; The inventory is a CAPTURE, not a transaction: one `inventory_id' names one
;; immutable sorted PATH LIST (plus each path's head at capture time), and pages
;; are slices of that saved list.  It is deliberately not a frozen view of file
;; CONTENTS -- §2 says so -- so a file edited between pages still appears once and
;; its head is re-read when its target is requested.  Re-walking the disk per page
;; (what the legacy page does) cannot satisfy "stable capture amidst new files": a
;; file created between pages would shift every later slice, and a file deleted
;; between pages would silently vanish from the enumeration, which is exactly the
;; "page end is not deletion" hazard §2 forbids.

(defcustom brain-inventory-max-paths 10000
  "Maximum paths one captured inventory may hold (§2: at most 10,000)."
  :type 'integer)

(defcustom brain-inventory-max-bytes (* 8 1024 1024)
  "Maximum serialised size of one captured inventory's metadata (§2: 8 MiB)."
  :type 'integer)

(defcustom brain-inventory-ttl 86400
  "Seconds an unused capture stays valid (§2: expire after 24 hours)."
  :type 'integer)

(defcustom brain-inventory-slice-entries 50
  "Maximum entries one traversal slice may visit (§2: at most 50)."
  :type 'integer)

(defcustom brain-inventory-slice-seconds 0.02
  "Maximum seconds one traversal slice may run (§2: at most 20 ms)."
  :type 'number)

(defvar brain--inventories (make-hash-table :test #'equal)
  "inventory_id -> capture plist.  See `brain--inventory-capture'.")

(defvar brain--inventory-order nil
  "Capture ids, oldest first, so expiry can drop the least recently used.")

;; --- enumeration ------------------------------------------------------------
;;
;; The walk is resumable, because §2 bounds it to "regular timer slices (at most
;; 50 entries or 20 ms of traversal per slice)".  Its whole state is one plist, so
;; a slice can stop anywhere and the next request continues from exactly there:
;;
;;   :stack  pending directory frames, innermost first
;;   :found  relative paths of eligible regular files, reversed
;;
;; A frame is (:directory DIR :root ROOT :relative REL :read BOOL :entries NAMES).
;; `:read' is what distinguishes "this directory has not been listed yet" from
;; "this directory was listed and is empty" -- with only `:entries', an empty
;; directory is indistinguishable from an unvisited one and the walk re-reads it
;; forever.  Excluded directories are never pushed, so a `.git' tree costs one
;; `lstat', not a walk.

(defvar brain--inventory-walk nil
  "Resumable walk state: (:stack FRAMES :found PATHS) or nil.")

(defun brain--inventory-walk-start ()
  "Reset the walk to the managed roots and return its state."
  (setq brain--inventory-walk
        (list :stack (mapcar (lambda (entry)
                               (list :directory (file-name-as-directory
                                                 (expand-file-name (cdr entry)))
                                     :root (car entry) :relative "" :read nil
                                     :entries nil))
                             brain-managed-roots)
              :found nil))
  brain--inventory-walk)

(defun brain--directory-entries (directory)
  "Return (NAMES . ERROR) for DIRECTORY, without descending into it.
NAMES is every entry name except `.` and `..`, or nil when the directory cannot
be read; ERROR is a short reason string or nil.  `directory-files' signals on an
unreadable directory, and §2 requires that to be an explicit incomplete capture
rather than an empty one."
  (condition-case err
      (cons (directory-files directory nil "\\`[^.]" t) nil)
    (file-error (cons nil (format "unreadable_directory:%s" (car err))))
    (error (cons nil (format "enumeration_error:%s" (car err))))))

(defun brain--inventory-walk-step ()
  "Run one bounded traversal slice.  Returns nil when finished, else a reason.
A missing root is an explicit incomplete capture (§2: \"Missing/inaccessible
root ... are complete=false with a reason; never equivalent to empty\")."
  (let ((deadline (time-add (current-time) brain-inventory-slice-seconds))
        (budget brain-inventory-slice-entries)
        (stack (plist-get brain--inventory-walk :stack))
        (found (plist-get brain--inventory-walk :found))
        (stopped nil))
    (while (and stack (not stopped))
      (let* ((frame (car stack))
             (directory (plist-get frame :directory))
             (root (plist-get frame :root))
             (relative (plist-get frame :relative)))
        (cond
         ;; A root that is not a directory at all is a missing root, not empty.
         ((and (string-empty-p relative) (not (file-directory-p directory)))
          (setq stopped "missing_root")
          (setq stack nil))
         ;; Not listed yet: list it and remember that it was listed.
         ((not (plist-get frame :read))
          (let ((probe (brain--directory-entries directory)))
            (if (cdr probe)
                (progn (setq stopped (cdr probe)) (setq stack nil))
              (setcar stack (plist-put (plist-put frame :entries (car probe))
                                       :read t)))))
         ;; Listed and exhausted: this directory is done.
         ((null (plist-get frame :entries))
          (setq stack (cdr stack)))
         (t
          (let* ((name (car (plist-get frame :entries)))
                 (child-relative (if (string-empty-p relative)
                                     name
                                     (concat relative "/" name)))
                 (child (expand-file-name name directory)))
            (setcar stack (plist-put frame :entries (cdr (plist-get frame :entries))))
            (setq budget (1- budget))
            (cond
             ;; A symlink is never followed and never enrolled (§2/§3).
             ((file-symlink-p child) nil)
             ((file-directory-p child)
              (unless (member name brain--excluded-directories)
                (push (list :directory child :root root :relative child-relative
                            :read nil :entries nil)
                      stack)))
             ((file-regular-p child)
              (unless (brain--eligibility root child-relative)
                ;; The capture stores full identities (root/relative), not bare
                ;; relative paths: `file_id' is the path identity (§3), and every
                ;; consumer -- paging, alias keys, heads -- works on that form.
                (push (concat root "/" child-relative) found)))
             (t nil))))))
      (when (and (null stopped)
                 (or (<= budget 0) (time-less-p deadline (current-time))))
        (setq stopped "slice_budget")))
    (setq brain--inventory-walk (list :stack stack :found found))
    stopped))

;; --- capture ----------------------------------------------------------------

(defun brain--inventory-expired-p (capture)
  "Non-nil when CAPTURE has not been used for `brain-inventory-ttl' seconds.
Expiry is measured from last use, so a long walk is never expired mid-flight by
its own duration; only an abandoned capture ages out."
  (and (numberp (plist-get capture :used))
       (> (- (float-time) (plist-get capture :used)) brain-inventory-ttl)))

(defun brain--inventory-expire-others ()
  "Drop every capture that has aged out.  Bounded by the number of captures."
  (let ((keep nil))
    (dolist (id brain--inventory-order)
      (let ((capture (gethash id brain--inventories)))
        (cond
         ((null capture) nil)
         ((brain--inventory-expired-p capture) (remhash id brain--inventories))
         (t (push id keep)))))
    (setq brain--inventory-order (nreverse keep))))

(defun brain--inventory-capture (inventory-id)
  "Return the live capture for INVENTORY-ID, or nil when the Mac holds none.
The capture is created by `brain--inventory-start' on a FIRST page request (§2:
\"A captured list persists Mac-locally across page retries\").  A capture that is
still walking is resumed by the next page request rather than restarted, so a
large corpus is enumerated in bounded slices across several requests."
  (let ((capture (gethash inventory-id brain--inventories)))
    (cond
     ((and capture (brain--inventory-expired-p capture))
      (remhash inventory-id brain--inventories)
      (setq brain--inventory-order (delete inventory-id brain--inventory-order))
      (list :status "expired" :inventory-id inventory-id))
     (capture capture)
     (t nil))))

(defun brain--inventory-start (inventory-id)
  "Create and return a fresh capture for INVENTORY-ID, replacing any stale one.
Only a page request with NO cursor may start a capture (§2): a continuation is
a slice of the list the caller was already given, and a fresh list under the
same id would silently change what later pages mean."
  (remhash inventory-id brain--inventories)
  (setq brain--inventory-order (delete inventory-id brain--inventory-order))
  (let ((fresh (list :status "walking" :inventory-id inventory-id
                     :created (float-time) :used (float-time)
                     :paths nil :reason nil :bytes 0)))
    (puthash inventory-id fresh brain--inventories)
    (setq brain--inventory-order (append brain--inventory-order (list inventory-id)))
    (brain--inventory-expire-others)
    (brain--inventory-walk-start)
    fresh))

(defun brain--inventory-finish (capture)
  "Finish CAPTURE: sort, dedupe, alias-check and bound its paths. Returns the
  updated capture.  §2: \"publishes no completed list until traversal and alias
  validation finish\", so this is the only place a capture becomes `complete'.
  A capture that fails a bound or the alias check keeps its paths for diagnosis
  but reports `paths' as nil, so no page can publish a partial list that a
  consumer could read as retirement for everything it omits."
  (let* ((paths (sort (delete-dups (plist-get capture :paths)) #'string<))
         (count (length paths))
         (bytes 0)
         (alias (make-hash-table :test #'equal))
         (reason nil))
    (cond
     ((> count brain-inventory-max-paths)
      (setq reason "inventory_oversize"))
     (t
      (dolist (path paths)
        (setq bytes (+ bytes (length path)))
        (when (> bytes brain-inventory-max-bytes)
          (setq reason "inventory_oversize")))
      (unless reason
        ;; Alias validation: two spellings that one case-insensitive volume would
        ;; collapse are an explicit ambiguity, never a silent pick (§3).
        (let ((collision nil))
          (dolist (path paths)
            (unless collision
              (let ((key (brain--alias-key path))
                    (known (gethash (brain--alias-key path) alias)))
                (cond
                 ((null known) (puthash key path alias))
                 ((not (equal known path)) (setq collision (list known path)))))))
          (when collision (setq reason "alias_ambiguity"))))))
    (plist-put (plist-put (plist-put capture :paths (unless reason paths)) :bytes bytes)
               :reason reason)))

(defun brain--inventory-ready-p (capture)
  "Non-nil when CAPTURE has finished walking and its list is validated."
  (and capture (member (plist-get capture :status) '("complete" "incomplete"))))

(defun brain--inventory-advance (capture)
  "Run one traversal slice for CAPTURE and return it, possibly finished."
  (unless (brain--inventory-ready-p capture)
    (let ((stopped (brain--inventory-walk-step)))
      (cond
       ((equal stopped "slice_budget")
        ;; Still walking: the next page request resumes exactly here.
        (setq capture (plist-put capture :used (float-time))))
       (stopped
        ;; An enumeration failure is complete=false with a reason, never empty.
        (setq capture (plist-put (plist-put (plist-put capture :paths
                                                       (plist-get brain--inventory-walk :found))
                                            :status "incomplete")
                                 :reason stopped)))
       (t
        (setq capture (plist-put capture :paths
                                 (plist-get brain--inventory-walk :found)))
        (setq capture (brain--inventory-finish capture))
        (setq capture (plist-put capture :status
                                 (if (plist-get capture :reason) "incomplete"
                                   "complete"))))))
    ;; §3: only a COMPLETE inventory is membership evidence, and one capture is
    ;; one observation however many pages it is read in.  An incomplete capture
    ;; (missing root, unreadable directory, oversize, alias ambiguity) says
    ;; nothing about what is absent, so it must never count toward a retirement.
    (when (and (equal (plist-get capture :status) "complete")
               (not (plist-get capture :noted)))
      (setq capture (plist-put capture :noted t))
      (brain--note-inventory-membership (plist-get capture :paths)))
    (puthash (plist-get capture :inventory-id) capture brain--inventories))
  capture)

;; --- the legacy shapes, byte-for-byte unchanged ------------------------------
;;
;; §1: "No fix silently changes old page interpretation."  These three functions
;; are exactly the accepted bytes from the live module; the corpus capture is a
;; separate path below and never reinterprets them.

(defun brain--snapshot-event (request-id file-id result &optional extra done)
  (brain--emit-event
   "brain.file.snapshot"
   (append (list (cons "request_id" request-id)
                 (cons "file_id" file-id)
                 (cons "result" result))
           extra
           (list (cons "done" (if done t :false))))))

(defun brain--eligible-file-ids ()
  "Every regular `.org' file beneath the managed roots, lexicographically sorted."
  (let ((ids nil))
    (dolist (entry brain-managed-roots)
      (let* ((root (car entry))
             (directory (file-name-as-directory (expand-file-name (cdr entry)))))
        (when (file-directory-p directory)
          (dolist (path (directory-files-recursively directory "\\.org\\'" nil nil))
            (when (file-regular-p path)
              (let ((id (ignore-errors
                          (brain--make-file-id root (substring path (length directory))))))
                (when id (push id ids))))))))
    (sort (delete-dups ids) #'string<)))

(defun brain--snapshot-page (request-id after limit)
  "Answer one bounded inventory page.  No file bodies are read or published."
  (let* ((all (seq-filter (lambda (id) (or (null after) (string< after id)))
                          (brain--eligible-file-ids)))
         (page (seq-take all (max 1 (min 100 limit))))
         (more (seq-drop all (length page)))
         (last-id (or (car (last page)) after)))
    (dolist (file-id page)
      (let ((head (gethash file-id brain--heads)))
        (brain--snapshot-event request-id file-id (if head "present" "absent")
                               (append (when head
                                         (list (cons "revision" (brain--rev->json head))
                                               (cons "object_hash" (brain--rev-sha head))))
                                       (list (cons "continuation" (or (car more) :null))))
                               nil)))
    (brain--snapshot-event request-id last-id "absent"
                           (list (cons "continuation" (or (car more) :null))) t)))

;; --- target baseline: the actual-use guards (§2) -----------------------------
;;
;; §2: "Mac target snapshot enrollment MUST reuse the canonical writer's
;; actual-use safety guard: resolve/check all path components and opened bytes,
;; register/check aliases, check ALL modified visiting/indirect buffers, leases,
;; autosave/recovery markers, encoding and journal state; no yield between final
;; check and baseline journaling/publication.  Publish only saved exact UTF-8
;; bytes."
;;
;; The accepted live `brain--snapshot-target' checked only the lease.  The facts
;; it did NOT check are exactly the ones that make bulk enrollment unsafe:
;;
;;   * `brain--resolve' lstats every component (already used) -- kept;
;;   * a modified visiting buffer with NO lease.  A lease is journaled on the
;;     first edit, but a buffer can be modified before Brain enabled, or by a
;;     mode/hook that wrote text while `brain--inhibit-guards' was bound.  The
;;     buffer itself is the enforcement (`brain--any-buffer-dirty-p'), and it was
;;     never consulted here -- so enrollment could publish the DISK bytes while a
;;     human had unsaved text, and the next save would then report a disk/head
;;     mismatch the human never caused;
;;   * indirect buffers: `brain--visiting-buffers' already returns base and
;;     indirect buffers of one identity, so the check above covers them;
;;   * the autosave/recovery marker (`brain--recovery-marker'), which is what
;;     survives a crash with unsaved text;
;;   * alias registration of the identity being enrolled (§3: "register/check
;;     aliases"), so a capture cannot enroll two spellings one volume collapses;
;;   * the encoding of the bytes actually opened: §2 says "Publish only saved
;;     exact UTF-8 bytes", and the accepted code hashed the file without ever
;;     proving it decodes as UTF-8.  A binary or Latin-1 file would have been
;;     enrolled and then failed on the gateway.
;;
;; "No yield between final check and baseline journaling/publication" is
;; `brain--enroll-baseline-guarded' below: one `condition-case'-free body that
;; re-reads the bytes, re-hashes them, re-checks the markers and then journals.
;; Nothing in it calls a process, sleeps or accepts input.

(defun brain--snapshot-attention (request-id file-id reason &optional fields)
  "Answer one `attention' target snapshot, keeping REASON off the wire.
§1 keeps the legacy `brain.file.snapshot' shape unchanged, and the reviewed
gateway contracts admit only `request_id', `file_id' and `result' plus the
optional `revision', `object_hash', `dirty_generation', `continuation' and
`done'.  A `reason' field is refused with `payload_field', and a refused event
still spends its durable seq -- `channel.receive' journals it as a refusal -- so
the gateway would permanently lose the attention fact for that target, on the
old target request §1 says must continue unchanged.  The reason is therefore
recorded Mac-locally and the frame stays inside the reviewed shape."
  (brain--journal-append "snapshot_attention" :file_id file-id :reason reason
                         :request_id request-id)
  (brain--log "snapshot attention for %s: %s" file-id reason)
  (brain--snapshot-event request-id file-id "attention" fields t))

(defun brain--snapshot-target (request-id file-id)
  "Answer one target snapshot without opening or touching a visiting buffer.
  Every actual-use guard runs before a baseline is allocated; a refusal is an
  `attention' answer, never a silent enrollment.  The refusal reason is
  journaled locally (`brain--snapshot-attention') instead of being put on the
  frame."
  (let* ((resolution (brain--resolve file-id))
         (path (plist-get resolution :path))
         (head (gethash file-id brain--heads))
         (lease (gethash file-id brain--dirty))
         (buffers (brain--visiting-buffers file-id))
         (dirty-buffer (brain--any-buffer-dirty-p buffers)))
    (cond
     ((equal (plist-get resolution :status) "unsafe")
      (brain--snapshot-attention
       request-id file-id
       (or (plist-get resolution :reason) "unsafe_path")
       (list (cons "continuation" :null))))
     ((equal (plist-get resolution :status) "absent")
      (if lease
          (brain--snapshot-attention
           request-id file-id "dirty_lease"
           (list (cons "dirty_generation" (plist-get lease :generation))))
        ;; §3: absence is never retirement evidence by itself.  This target
        ;; recheck is the SECOND half of the proof -- the census recorded two
        ;; complete inventories at least 60 s apart that both lacked the path --
        ;; and the retirement still needs the writer guard to agree that nothing
        ;; human owns this identity.
        (when (brain--missing-retire-eligible-p file-id)
          (brain--lifecycle-retire-missing file-id))
        (brain--snapshot-event request-id file-id "absent" nil t)))
     ;; §3: a retired path is inactive.  A file that reappeared on disk is a
     ;; human recreation, and the guarded save/baseline path is what reactivates
     ;; it -- a remote snapshot request is not.  Enrolling it here would revive a
     ;; retired identity behind the gateway's back.
     ((brain--retired-p file-id)
      (brain--snapshot-attention request-id file-id "path_retired"
                                 (list (cons "continuation" :null))))
     ;; A modified buffer of this identity owns the file, whether or not a lease
     ;; was journaled.  §2 forbids publishing text the human has not saved.
     ((or dirty-buffer (and lease (null head)))
      (brain--snapshot-attention
       request-id file-id
       (if dirty-buffer "modified_buffer" "dirty_lease")
       (list (cons "dirty_generation"
                   (and lease (plist-get lease :generation))))))
     (t
      (let ((digest (brain--sha256-file path)))
        (cond
         ((and head (not (equal digest (brain--rev-sha head))))
          (brain--snapshot-attention
           request-id file-id "disk_mismatch"
           (list (cons "revision" (brain--rev->json head))
                 (cons "object_hash" (brain--rev-sha head))
                 (cons "dirty_generation"
                       (and lease (plist-get lease :generation))))))
         (t
          (let ((outcome (if head (list :status "present" :revision head)
                           (brain--enroll-baseline-guarded file-id path digest))))
            (if (equal (plist-get outcome :status) "present")
                (brain--snapshot-event
                 request-id file-id "present"
                 (list (cons "revision" (brain--rev->json (plist-get outcome :revision)))
                       (cons "object_hash" (brain--rev-sha (plist-get outcome :revision)))
                       (cons "dirty_generation" (and lease (plist-get lease :generation))))
                 t)
              (brain--snapshot-attention
               request-id file-id (plist-get outcome :reason)))))))))))

(defun brain--enroll-baseline-guarded (file-id path digest)
  "Enroll a verified baseline under the canonical writer's actual-use guards.
Returns (:status \"present\" :revision REV) or (:status \"attention\" :reason R).
The final section re-reads and re-hashes the exact opened bytes, re-checks every
marker, and only then journals and publishes -- with no yield in between, so a
save cannot land between the last check and the baseline."
  (let* ((resolution (brain--resolve file-id))
         (recheck-path (plist-get resolution :path)))
    (cond
     ((not (equal (plist-get resolution :status) "ok"))
      (list :status "attention" :reason "path_changed"))
     ((not (equal recheck-path path))
      (list :status "attention" :reason "path_changed"))
     ;; A marker that appeared since the outer check is a real refusal: an autosave
     ;; or a lease means unsaved human text exists for this path.
     ((brain--recovery-marker file-id)
      (list :status "attention" :reason (or (brain--recovery-marker file-id)
                                            "recovery_marker")))
     ((brain--any-buffer-dirty-p (brain--visiting-buffers file-id))
      (list :status "attention" :reason "modified_buffer"))
     (t
      (let* ((bytes (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally recheck-path)
                      (buffer-string)))
             (opened (brain--sha256 bytes)))
        (cond
         ((> (length bytes) brain-object-max-bytes)
          (list :status "attention" :reason "too_large"))
         ((not (equal opened digest))
          ;; The bytes changed between the hash and the open: never enroll a
          ;; baseline the caller did not ask for.
          (list :status "attention" :reason "disk_changed"))
         ;; §2: "Publish only saved exact UTF-8 bytes."  A file that does not
         ;; decode as UTF-8 is not a managed Org object, so it is refused here
         ;; rather than enrolled and rejected later by the gateway.
         ((not (brain--utf8-bytes-p bytes))
          (list :status "attention" :reason "unsupported_coding"))
         (t
          (let ((revision (brain--enroll-baseline-bytes file-id bytes opened)))
            (list :status "present" :revision revision)))))))))

(defun brain--utf8-bytes-p (bytes)
  "Non-nil when BYTES is valid UTF-8 text, with no raw-byte characters.
Emacs does not signal on invalid UTF-8: `decode-coding-string' turns each
undecodable byte into a raw-byte character (#x3FFF80..#x3FFFFF) and
`encode-coding-string' turns it back, so a round-trip test alone would accept
`#xFF' as \"UTF-8\".  §2 requires \"Publish only saved exact UTF-8 bytes\", so the
raw-byte range is refused explicitly -- that is what actually distinguishes a
UTF-8 Org file from a binary or Latin-1 one."
  (condition-case nil
      (let ((text (decode-coding-string bytes 'utf-8)))
        (and (stringp text)
             (equal (encode-coding-string text 'utf-8) bytes)
             (not (seq-find (lambda (character)
                              (and (>= character #x3FFF80) (<= character #x3FFFFF)))
                            (string-to-list text)))))
    (error nil)))

(defun brain--enroll-baseline-bytes (file-id bytes digest)
  "Allocate a baseline revision for BYTES, publish the object and journal the
  snapshot. The bytes are the exact ones the guard just verified; nothing is
  re-read here. Alias registration happens before the journal, so a colliding
  spelling refuses the enrollment instead of leaving a head for an identity the
  store will reject. The record carries its own `operation_id': §2 requires
  history to report the ORIGINAL operation id of each fact, and a seq0 fact
  whose id is minted at read time would present the same chain step under a new
  identity on every retry. A path that was retired and now exists again resumes
  from its retained head (§3), and the reactivation is journaled as its own
  lifecycle fact."
  (brain--register-identity file-id)
  (let* ((choice (brain--baseline-revision file-id digest))
         (revision (car choice))
         (predecessor (cdr choice))
         (operation-id (brain--uuid)))
    (brain--publish-object bytes digest)
    (brain--journal-append "snapshot" :file_id file-id :revision revision
                           :prev_revision predecessor
                           :object_hash digest :operation_id operation-id)
    (puthash file-id revision brain--heads)
    (brain--lifecycle-reactivate-if-retired file-id revision digest predecessor)
    (brain--fsync (brain--object-path "mac" digest)
                  (brain--file-path file-id))
    (brain--heads-save)
    revision))

(defun brain--inventory-page (request-id inventory-id after limit)
  "Answer one page of the captured list named by INVENTORY-ID.
`after' is exclusive: the first page passes nil, later pages pass the last
emitted `file_id'.  Nothing here reads or publishes a file body (§2: \"No body
publication during page enumeration\").

A continuation for an `inventory_id' the Mac does not hold -- an id from before
a restart, or one that expired -- is answered with `inventory_expired' and NO
capture is started.  §2 forbids \"continuation against a changed list\": the
caller's cursor is a position in the list it was given, so slicing a freshly
walked list from it would silently skip or repeat paths.  The coordinator
restarts with a new id, which is exactly what §2's restart rule assumes."
  (let ((capture (brain--inventory-capture inventory-id)))
    (cond
     ((equal (plist-get capture :status) "expired")
      ;; §2: an expired id requires a NEW inventory, never continuation against a
      ;; list that has changed underneath the caller.
      (brain--inventory-event request-id inventory-id nil nil t nil "inventory_expired"))
     ((null capture)
      (if after
          (brain--inventory-event request-id inventory-id nil nil t nil
                                  "inventory_expired")
        (setq capture (brain--inventory-start inventory-id))
        (brain--inventory-page-answer request-id inventory-id after limit capture)))
     (t
      (brain--inventory-page-answer request-id inventory-id after limit capture)))))

(defun brain--inventory-page-answer (request-id inventory-id after limit capture)
  "Advance CAPTURE and emit one page of it.  See `brain--inventory-page'."
  (setq capture (brain--inventory-advance capture))
  (cond
   ((not (brain--inventory-ready-p capture))
    ;; The walk is still in progress.  This is not a page and not an end: the
    ;; caller must ask again with the same cursor.  `complete=false` plus a
    ;; reason is how §2 says \"not a trustworthy enumeration yet\", and the
    ;; reviewed contracts refuse an empty page that echoes a cursor
    ;; (\"an empty page has no next_after\"), so the cursor is not repeated here.
    (brain--inventory-event request-id inventory-id nil nil nil nil
                            "inventory_walking"))
   (t
    (let* ((paths (plist-get capture :paths))
           (reason (plist-get capture :reason))
           (remaining (seq-drop-while (lambda (path)
                                        (and after (not (string< after path))))
                                      paths))
           (page (seq-take remaining (max 1 (min 50 limit))))
           (more (seq-drop remaining (length page)))
           (entries (mapcar (lambda (path)
                              (let ((head (gethash path brain--heads)))
                                (list (cons "file_id" path)
                                      (cons "head_revision"
                                            (if head (brain--rev->json head) :null)))))
                            page))
           (next (and page (car (last page))))
           ;; An incomplete capture is never \"done\": `done' means the walk of a
           ;; trustworthy list reached its end, and a refused list has no end to
           ;; reach.  Reporting done=true with complete=false would invite a
           ;; consumer to treat the (empty) page as the whole corpus.
           (done (and (null more) (null reason))))
      (brain--inventory-event request-id inventory-id entries next done
                              (null reason) reason)))))

(defun brain--inventory-event (request-id inventory-id entries next done complete reason)
  "Emit one `brain.inventory.page'.  `complete' is a boolean, `reason' text."
  (brain--emit-event
   "brain.inventory.page"
   (append (list (cons "request_id" request-id)
                 (cons "inventory_id" inventory-id)
                 (cons "entries" (cons :json-array (or entries nil)))
                 (cons "next_after" (or next :null))
                 (cons "done" (if done t :false))
                 (cons "complete" (if complete t :false)))
           (when reason (list (cons "reason" reason))))))

;; --- the history page answer ------------------------------------------------

(defun brain--history-operation-id (file-id record revision)
  "Return the ORIGINAL operation id of one chain fact.
A record that journaled its own id reports exactly that id.  A legacy record
written before the id was journaled -- including every seq0 snapshot already in
the live journal -- gets a DETERMINISTIC derivation from durable Mac state
(brain id, path identity and revision), so the same fact keeps one identity
across repeated requests, re-pages and restarts.  Minting a fresh id here would
present one chain step under a different identity on every retry and defeat the
gateway's exactly-once chain installation (§2)."
  (or (plist-get record :operation_id)
      (brain--derived-uuid
       (format "history/%s/%s/%s/%s"
               brain-id file-id (brain--rev-seq revision) (brain--rev-sha revision)))))

(defun brain--history-facts (file-id after-seq limit)
  "Return (FACTS . MORE): FILE-ID's retained chain after AFTER-SEQ. A fact is
  the ORIGINAL committed fact of one chain step: its operation id, its
  predecessor and its revision.  `after-seq' is -1 for the beginning of the
  retained chain.  Facts ascend by revision seq and never repeat one, so the
  caller can install exactly one link at a time and can never be handed a hole
  (§2: \"Hermes records each original fact and installs one chain step at a
  time; never fabricates seq0 or skips to a latest nonzero head\")."
  (let ((facts nil)
        (more nil)
        (seen (make-hash-table :test #'eql))
        (chain nil))
    ;; Ascend by seq explicitly rather than relying on journal order: one seq is
    ;; one chain step, whatever order the records were written in.
    ;;
    ;; A lifecycle record can itself be a chain step: §3 gives a relocation
    ;; destination "a canonical revision from its own retained path chain", and a
    ;; reactivation continues the chain it revives.  Those revisions are canonical
    ;; facts of the path, so history must report them -- otherwise the gateway
    ;; would see a head with a hole below it and could never install the step.
    (dolist (record (append (brain--journal-records "snapshot")
                            (brain--journal-records "committed")
                            (seq-filter (lambda (entry)
                                          (and (equal (plist-get entry :kind) "lifecycle")
                                               (plist-get entry :destination_revision)))
                                        brain--journal)))
      (let* ((record-file (or (plist-get record :file_id)
                              (plist-get record :destination_file_id)))
             (revision (or (plist-get record :revision)
                           (plist-get record :new_revision)
                           (plist-get record :destination_revision))))
        (when (and (equal record-file file-id) revision
                   (> (brain--rev-seq revision) after-seq))
          (let ((seq (brain--rev-seq revision)))
            (unless (gethash seq seen)
              (puthash seq t seen)
              (push (list seq record revision) chain))))))
    (dolist (step (sort chain (lambda (a b) (< (car a) (car b)))))
      (let ((record (nth 1 step))
            (revision (nth 2 step)))
        (cond
         ;; A fact beyond this page: the page is not the end of the chain.
         ((>= (length facts) limit)
          (setq more t))
         (t
          (push (list (cons "operation_id"
                            (brain--history-operation-id file-id record revision))
                      (cons "predecessor_revision"
                            (let ((predecessor (or (plist-get record :prev_revision)
                                                   (plist-get record :destination_predecessor))))
                              (if predecessor (brain--rev->json predecessor) :null)))
                      (cons "revision" (brain--rev->json revision))
                      (cons "object_hash" (brain--rev-sha revision)))
                facts)))))
    (cons (nreverse facts) more)))

(defun brain--history-page (request-id file-id after-seq limit)
  "Answer one bounded history page.  No new canonical commit is created."
  (let* ((probe (brain--history-facts file-id after-seq limit))
         (facts (car probe))
         (more (cdr probe))
         (next (and facts
                    (plist-get (brain--rev<-json
                                (alist-get "revision" (car (last facts)) nil nil #'equal))
                               :seq))))
    (brain--emit-event
     "brain.file.history"
     (list (cons "request_id" request-id)
           (cons "file_id" file-id)
           (cons "facts" (cons :json-array (or facts nil)))
           (cons "next_after_seq" (or next :null))
           (cons "done" (if more :false t))
           (cons "complete" t)))))

;; --- the query profile ------------------------------------------------------
;;
;; §4 exports the EFFECTIVE Org configuration, so these functions read Org's own
;; variables and ask Org itself which keywords are done states.  `brain' does not
;; `require' Org at load time -- it is loaded by the user's configuration and is
;; inert until configured, and requiring Org here would change that load order --
;; so Org is required at the point of use instead.  That is also what makes the
;; variables special: with `lexical-binding' a free `org-todo-keywords' would be a
;; lexical variable, and a caller's `let'-binding of it would silently not be seen.

(defun brain--require-org ()
  "Load Org on first use and return non-nil when its configuration is readable."
  (require 'org)
  (require 'org-agenda nil t)
  t)

(defun brain--todo-keyword (raw)
  "Return the keyword text of RAW, stripping Org's fast-key/effort/logger suffix."
  (if (and (stringp raw) (string-match "\\`\\([^(@!/]+\\)" raw))
      (match-string 1 raw)
    raw))

(defun brain--todo-sequences ()
  "Return the effective Org TODO configuration as data (§4). Each sequence is
  `{name, keywords, done}`: the ordered keyword list, and the subset Org itself
  treats as done states.  Both facts come from Org, not from a
  re-implementation: letting `org-mode' build its table from ONE sequence makes
  `org-done-keywords' Org's own answer for that sequence, which is what decides
  the `|' split, the implicit last-keyword rule and the `type' form."
  (brain--require-org)
  (let ((sequences nil) (index 0))
    (dolist (entry (or org-todo-keywords '((sequence "TODO" "DONE"))))
      (let* ((kind (car entry))
             (raw (cdr entry))
             (keywords (delq nil (mapcar (lambda (word)
                                           (unless (equal word "|")
                                             (brain--todo-keyword word)))
                                         raw)))
             ;; Org's own done set for exactly this sequence.  `org-todo-keywords'
             ;; is a special variable (see the `defvar' block), so this `let' is a
             ;; dynamic binding: `org-mode' reads it, sets `org-done-keywords' from
             ;; it, and the caller's configuration is restored on exit.
             (done (let ((org-todo-keywords (list (cons kind raw))))
                     (with-temp-buffer
                       (org-mode)
                       (mapcar #'identity (or org-done-keywords nil))))))
        (setq index (1+ index))
        (push (list (cons "name" (format "%s-%d" (or kind 'sequence) index))
                    (cons "keywords" (cons :json-array keywords))
                    (cons "done" (cons :json-array
                                       (seq-filter (lambda (word) (member word keywords))
                                                   done))))
              sequences)))
    (nreverse sequences)))

(defun brain--agenda-file-ids ()
  "Return the managed agenda files as file_ids, sorted and deduped (§4)."
  (brain--require-org)
  (let ((ids nil))
    (dolist (entry (ignore-errors (org-agenda-files t)))
      (when (and (stringp entry) (string-match-p "\\.org\\'" entry))
        (let ((id (brain--identity-for-path entry)))
          (when (and id
                     (brain--eligible-p (substring id 0 (string-search "/" id))
                                        (substring id (1+ (string-search "/" id)))))
            (push id ids)))))
    (sort (delete-dups ids) #'string<)))

(defun brain--timezone-name ()
  "Return the IANA zone name this Emacs is running in, or nil.
`current-time-zone' gives an offset and an abbreviation, not a name, so the name
is read from where the OS records it.  Nil is honest: §4 says unsupported values
are REPORTED, so a missing name becomes an `unsupported' entry, never a guessed
one."
  (let ((tz (getenv "TZ")))
    (cond
     ((and (stringp tz) (not (string-empty-p tz)))
      (if (string-prefix-p ":" tz) (substring tz 1) tz))
     ((file-symlink-p "/etc/localtime")
      (let ((target (file-truename "/etc/localtime")))
        (when (string-match "/zoneinfo/\\(.+\\)\\'" target)
          (match-string 1 target))))
     (t nil))))

(defun brain--query-profile ()
  "Return the bounded query profile payload (§4): data, never Lisp. Fields:
  version, profile_hash, todo_sequences, agenda_file_ids, timezone, week_start,
  deadline_warning_days[, unsupported].  `profile_hash' is the sha256 of the
  canonical JSON of everything else, computed over the WIRE form of the same
  facts -- the gateway receives that form and must be able to re-derive the
  hash from what it holds, so hashing the pre-encoding Lisp (with its
  `:json-array' markers) would make the value unverifiable on the other side."
  (brain--require-org)
  (let* ((timezone (brain--timezone-name))
         (unsupported (unless timezone (list "timezone")))
         (body (list (cons "version" 1)
                     (cons "todo_sequences" (cons :json-array (brain--todo-sequences)))
                     (cons "agenda_file_ids" (cons :json-array (brain--agenda-file-ids)))
                     (cons "timezone" (or timezone :null))
                     (cons "week_start" (if (integerp org-agenda-start-on-weekday)
                                            org-agenda-start-on-weekday
                                          (if (integerp calendar-week-start-day)
                                              calendar-week-start-day 1)))
                     (cons "deadline_warning_days"
                           (if (integerp org-deadline-warning-days)
                               org-deadline-warning-days 14))))
         ;; The wire form, which is what the gateway stores and re-hashes.
         (wire (brain--json-decode (brain--json-encode body))))
    (append body
            (list (cons "profile_hash" (brain--sha256 (brain--json-encode wire))))
            (when unsupported
              (list (cons "unsupported" (cons :json-array unsupported)))))))

(defun brain--emit-query-profile ()
  "Emit one `brain.query.profile' after readiness (§4)."
  (brain--emit-event "brain.query.profile" (brain--query-profile)))

;; --- request dispatch -------------------------------------------------------

(defun brain--handle-snapshot-request (frame)
  "Dispatch one `brain.snapshot.request'. The legacy shapes are tried first and
  unchanged; `mode' selects the corpus shapes.  An unknown mode is refused
  rather than reinterpreted, and the node refuses a corpus mode on an
  unnegotiated session before it ever gets here.

  A corpus-mode request is also the Mac's PROOF that corpus-v1 is live end to
  end: the node refuses such a request downstream unless the node and the
  gateway both advertised the feature, so receiving one means all three
  endpoints agreed.  That is what licenses lifecycle events (§3) and flushes
  any fact journaled while the feature was off."
  (let ((request-id (alist-get "request_id" frame nil nil #'equal))
        (file-id (alist-get "file_id" frame nil nil #'equal))
        (limit (alist-get "limit" frame nil nil #'equal))
        (after (alist-get "after_file_id" frame nil nil #'equal))
        (mode (alist-get "mode" frame nil nil #'equal))
        (inventory-id (alist-get "inventory_id" frame nil nil #'equal))
        (after-seq (alist-get "after_revision_seq" frame nil nil #'equal)))
    (when (and (member mode '("inventory" "history"))
               (brain--frame-brain-id-ok-p frame))
      (setq brain--corpus-observed t)
      (brain--flush-lifecycle-events))
    (cond
     ((not (brain--frame-brain-id-ok-p frame))
      (brain--log "snapshot request for a foreign brain id refused"))
     ((equal mode "inventory")
      (if (not (and (stringp inventory-id) (integerp limit)))
          (brain--log "inventory request without inventory_id or limit refused")
        (brain--inventory-page request-id inventory-id after limit)))
     ((equal mode "history")
      (if (not (and (stringp file-id) (integerp limit)))
          (brain--log "history request without file_id or limit refused")
        (brain--history-page request-id file-id
                             (if (integerp after-seq) after-seq -1) limit)))
     ((and mode (not (member mode '("inventory" "history"))))
      (brain--log "snapshot request with unknown mode refused"))
     (file-id (brain--snapshot-target request-id file-id))
     (limit (brain--snapshot-page request-id after limit))
     (t (brain--log "snapshot request without target or page")))))

;;; ---------------------------------------------------------------------------
;;; Recovery
;;; ---------------------------------------------------------------------------

(defun brain--rebuild-heads ()
  "Rebuild `brain--heads' from the committed journal chain. A path may carry
  MORE THAN ONE snapshot record: a retired path that a human recreated resumes
  from its retained head (§3), so its baseline is a later seq, not a second seq
  0.  The head is therefore the highest seq, exactly as for committed records
  -- taking the first record would rewind a reactivated chain."
  (clrhash brain--heads)
  (dolist (record (brain--journal-records "snapshot"))
    (let ((file-id (plist-get record :file_id))
          (revision (plist-get record :revision)))
      (when (and file-id revision)
        (let ((known (gethash file-id brain--heads)))
          (when (or (null known)
                    (> (brain--rev-seq revision) (brain--rev-seq known)))
            (puthash file-id revision brain--heads))))))
  (dolist (record (brain--journal-records "committed"))
    (let ((file-id (plist-get record :file_id))
          (revision (plist-get record :new_revision)))
      (when (and file-id revision)
        (let ((known (gethash file-id brain--heads)))
          (when (or (null known)
                    (> (brain--rev-seq revision) (brain--rev-seq known)))
            (puthash file-id revision brain--heads))))))
  ;; §3: a relocation destination and a reactivation carry a canonical revision
  ;; of their own path's chain, so they are head facts exactly like a commit.
  (dolist (record (brain--journal-records "lifecycle"))
    (let ((file-id (plist-get record :destination_file_id))
          (revision (plist-get record :destination_revision)))
      (when (and file-id revision)
        (let ((known (gethash file-id brain--heads)))
          (when (or (null known)
                    (> (brain--rev-seq revision) (brain--rev-seq known)))
            (puthash file-id revision brain--heads))))))
  brain--heads)

(defun brain--rebuild-dirty ()
  "Rebuild dirty leases: a dirty generation is cleared only by its own save."
  (clrhash brain--dirty)
  (clrhash brain--generations)
  (dolist (record brain--journal)
    (let ((file-id (plist-get record :file_id)))
      (pcase (plist-get record :kind)
        ("dirty"
         (puthash file-id
                  (list :generation (plist-get record :dirty_generation)
                        :base (plist-get record :base_revision)
                        :operation-id (plist-get record :operation_id)
                        :epoch (plist-get record :client_epoch))
                  brain--dirty)
         (puthash file-id (max (or (gethash file-id brain--generations) 0)
                               (or (plist-get record :dirty_generation) 0))
                  brain--generations))
        ("clean"
         (let ((lease (gethash file-id brain--dirty)))
           (when (and lease
                      (= (or (plist-get lease :generation) 0)
                         (or (plist-get record :dirty_generation) 0)))
             (remhash file-id brain--dirty))))
        (_ nil))))
  brain--dirty)

(defun brain--rebuild-results ()
  (clrhash brain--results)
  (dolist (record (brain--journal-records "result"))
    (let ((key (plist-get record :result_key)))
      (when key
        (puthash key
                 (list :status (plist-get record :status)
                       :file-id (plist-get record :file_id)
                       :current-revision (plist-get record :current_revision)
                       :new-revision (plist-get record :new_revision)
                       :mac-seq (plist-get record :mac_seq)
                       :reason (plist-get record :reason))
                 brain--results))))
  brain--results)

(defun brain--rebuild-attention ()
  "Rebuild `brain--attention' from the journal's durable attention rows (§3).
The missing-path retirement guard reads this table, and the two inventories
that prove a path missing always happen AFTER the most recent restart -- so a
table that only ever held this session's rows is blind exactly when the guard
acts.  A durable attention row is a human decision, so it survives recovery
until an explicit `attention_cleared' record (written by
`brain-reconcile-file') says otherwise: recovery never auto-reconciles one.

The three ways this module puts a row in the table are all replayed, so the
rebuilt table is the one the writer would have had without the restart:
`brain--attention' and `brain--recover-intents' journal an `attention' record,
`brain--lifecycle-attention' journals `lifecycle_attention', and an install
whose result is `attention' journals a `result' record that `brain-commit-file'
mirrors into the table.

Projection deferrals are journaled under the `attention' kind so they are
durable, but they belong to `brain--deferred' and are not attention rows; a
derived manifest that overflowed must not block a retirement or report
attention."
  (clrhash brain--attention)
  (dolist (record brain--journal)
    (let ((file-id (plist-get record :file_id))
          (reason (plist-get record :reason)))
      (when file-id
        (pcase (plist-get record :kind)
          ((or "attention" "lifecycle_attention")
           (unless (brain--projection-deferral-reason-p reason)
             (puthash file-id (or reason "attention") brain--attention)))
          ("result"
           (when (equal (plist-get record :status) "attention")
             (puthash file-id (or reason "attention") brain--attention)))
          ("attention_cleared" (remhash file-id brain--attention))
          (_ nil)))))
  brain--attention)

(defun brain--recover-intents ()
  "Finish, keep pending or escalate every journaled intent.
Intent + disk = new hash finishes the commit; intent + disk = predecessor keeps
the exact attempt pending; neither hash becomes attention.  No buffer is
reverted and no seq is guessed."
  (dolist (record (brain--journal-records "intent"))
    (let* ((file-id (plist-get record :file_id))
           (operation-id (plist-get record :operation_id))
           (revision (plist-get record :new_revision))
           (previous (plist-get record :prev_revision)))
      (unless (cl-find-if (lambda (other)
                            (and (equal (plist-get other :file_id) file-id)
                                 (equal (plist-get other :operation_id) operation-id)
                                 (member (plist-get other :kind)
                                         '("committed" "attention"))))
                          brain--journal)
        (let* ((resolution (brain--resolve file-id))
               (disk (when (equal (plist-get resolution :status) "ok")
                       (brain--sha256-file (plist-get resolution :path)))))
          (cond
           ((and disk (equal disk (brain--rev-sha revision)))
            (puthash file-id revision brain--heads)
            (brain--journal-append "committed" :file_id file-id
                                   :operation_id operation-id
                                   :new_revision revision :prev_revision previous
                                   :object_hash (brain--rev-sha revision)
                                   :phase "recovered")
            (brain--log "recovered finished commit for %s" file-id))
           ((or (and disk previous (equal disk (brain--rev-sha previous)))
                (and (null disk) (null previous)))
            (brain--log "intent did not install for %s; attempt kept pending" file-id))
           (t
            (puthash file-id "recovery_mismatch" brain--attention)
            (brain--journal-append "attention" :file_id file-id
                                   :operation_id operation-id
                                   :reason "recovery_mismatch"))))))))

(defun brain--release-stale-leases ()
  "Release journal-replayed leases whose buffer is no longer unsaved.
A dirty lease means \"the human has unsaved text\"; once every visiting buffer
of the file is clean (its save was committed, or the daemon simply restarted
with nothing modified), the lease is stale: keeping it would block every
install on the file forever.  A genuinely unsaved buffer keeps its lease, and
the buffer itself is the enforcement at install time, so releasing here can
never install over unsaved text."
  (maphash (lambda (file-id lease)
             (unless (brain--any-buffer-dirty-p (brain--visiting-buffers file-id))
               (remhash file-id brain--dirty)
               (brain--journal-append "clean" :file_id file-id
                                      :revision (gethash file-id brain--heads)
                                      :dirty_generation (plist-get lease :generation)
                                      :operation_id (plist-get lease :operation-id))
               (brain--emit-event
                "brain.file.clean"
                (list (cons "file_id" file-id)
                      (cons "revision" (brain--rev->json (gethash file-id brain--heads)))
                      (cons "dirty_generation" (plist-get lease :generation))
                      (cons "operation_id" (plist-get lease :operation-id))
                      (cons "client_epoch" (or brain--client-epoch :null))))))
           brain--dirty))

(defun brain--mark-live-dirty-buffers ()
  "Mark every already visiting managed buffer with unsaved text as dirty."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer (buffer-modified-p))
               (brain--buffer-file-id buffer))
      (with-current-buffer buffer
        (brain--note-first-edit)))))

(defun brain-recover ()
  "Reconcile journal, heads cache and dirty markers before installs are allowed."
  (setq brain--recovered nil)
  (condition-case err
      (brain--journal-load)
    (brain-journal-fault
     ;; A damaged journal is not repaired and not truncated: the fault is
     ;; latched so no further record is written over it, and recovery stops
     ;; before any table is rebuilt from a file it cannot trust.
     (brain--journal-latch-fault "corrupt" err (plist-get brain--journal-fault :local-seq))
     (signal (car err) (cdr err))))
  (brain--rebuild-heads)
  (brain--rebuild-dirty)
  (brain--rebuild-results)
  ;; §3: a durable attention row must be visible to the writer guard before any
  ;; lifecycle or census action can consult it.  The missing-path proof is two
  ;; inventories that always happen after the most recent restart, so a table
  ;; holding only this session's rows would let a path the recovery deliberately
  ;; left for a human be retired automatically.  Rebuilt here, before
  ;; `brain--recover-intents' and `brain--recover-lifecycle' can add rows of
  ;; their own.
  (brain--rebuild-attention)
  (setq brain--wire-seq
        (or (cl-loop for record in brain--journal
                     maximize (or (and (equal (plist-get record :kind) "event")
                                       (plist-get record :wire_seq))
                                  0))
            0))
  (setq brain--acked-seq
        (or (cl-loop for record in brain--journal
                     maximize (or (and (equal (plist-get record :kind) "ack")
                                       (plist-get record :through_seq))
                                  0))
            0))
  (setq brain--outbox
        (delq nil
              (mapcar (lambda (record)
                        (when (and (equal (plist-get record :kind) "event")
                                   (> (or (plist-get record :wire_seq) 0)
                                      brain--acked-seq))
                          (plist-get record :payload)))
                      brain--journal)))
  (brain--recover-intents)
  ;; §3: rebuild lifecycle membership from the journal BEFORE any install is
  ;; allowed, then resolve lifecycle intents that never reached a record.  A
  ;; replayed retirement must not clobber a newer reactivation, so the rebuild
  ;; runs first and the intent resolution reads the state it produced.
  (brain--rebuild-lifecycle)
  (brain--recover-lifecycle)
  (setq brain--corpus-observed nil)
  (setq brain--recovered t)
  brain--recovered)

;;; ---------------------------------------------------------------------------
;;; Status
;;; ---------------------------------------------------------------------------

(defun brain-status (&optional file-id)
  "Return structured Brain state.  Never messages, never opens a buffer."
  (list :enabled brain--enabled
        :recovered brain--recovered
        :configured (and brain-id brain-writer-id t)
        :connected (and brain--ipc (process-live-p brain--ipc) t)
        :reconciled brain--reconciled
        :epoch brain--epoch
        :files (hash-table-count brain--heads)
        :dirty (hash-table-count brain--dirty)
        :attention (hash-table-count brain--attention)
        :deferred (hash-table-count brain--deferred)
        :unacked (- brain--wire-seq brain--acked-seq)
        ;; E9c: a latched journal fault is a first-class state, not a log line.
        ;; It outranks every other state because nothing durable can move while
        ;; it is set.
        :journal-fault brain--journal-fault
        :state (cond
                (brain--journal-fault 'journal-fault)
                ((and file-id (gethash file-id brain--attention)) 'attention)
                ((> (hash-table-count brain--attention) 0) 'attention)
                ((and file-id (gethash file-id brain--dirty)) 'waiting-dirty)
                ((> (hash-table-count brain--dirty) 0) 'waiting-dirty)
                ((not (and brain--ipc (process-live-p brain--ipc))) 'offline)
                ((> (- brain--wire-seq brain--acked-seq) 0) 'lag)
                (t 'synchronized))
        :attention-files (let (files)
                           (maphash (lambda (key _value) (push key files))
                                    brain--attention)
                           files)
        :file file-id
        :file-revision (and file-id (gethash file-id brain--heads))
        :file-dirty (and file-id (gethash file-id brain--dirty))
        :deferred-files (let (files)
                          (maphash (lambda (key _value) (push key files))
                                   brain--deferred)
                          files)
        :file-deferred (and file-id (gethash file-id brain--deferred))))

(defun brain-mode-line-string ()
  "Quiet mode-line indicator.  Empty unless something needs attention."
  (pcase (plist-get (brain-status) :state)
    ('journal-fault " Brain:fault")
    ('attention " Brain:attn")
    ('waiting-dirty " Brain:dirty")
    ('lag " Brain:lag")
    ('offline " Brain:off")
    (_ "")))

;;; ---------------------------------------------------------------------------
;;; Buffer setup, enable and disable
;;; ---------------------------------------------------------------------------

(defun brain--setup-buffer ()
  "Install the managed buffer's save path and dirty instrumentation.
Runs from `find-file-hook' and again from `after-change-major-mode-hook': a
mode restart (`org-mode-restart', `M-x org-mode', `normal-mode' on revert)
kills the buffer-local hooks, and losing them would refuse the user's next
save and stop leasing the edit."
  (when (and brain--enabled (brain--managed-buffer-p (current-buffer)))
    (let ((file-id (brain--buffer-file-id (current-buffer))))
      (ignore-errors (brain--register-identity file-id))
      (add-hook 'write-contents-functions #'brain-write-contents-handler nil t)
      (add-hook 'before-change-functions #'brain--before-change-guard nil t)
      (add-hook 'after-change-functions #'brain--after-change-fallback nil t)
      ;; Global auto-revert must not mutate a managed buffer outside Brain refresh.
      (when (bound-and-true-p auto-revert-mode)
        (auto-revert-mode -1))
      (when (and (buffer-modified-p) (not (gethash file-id brain--dirty)))
        (brain--note-first-edit))
      t)))

(defun brain--disable-buffer-hooks (buffer)
  (with-current-buffer buffer
    (remove-hook 'write-contents-functions #'brain-write-contents-handler t)
    (remove-hook 'before-change-functions #'brain--before-change-guard t)
    (remove-hook 'after-change-functions #'brain--after-change-fallback t)))

(defun brain-configurable-p ()
  (and (stringp brain-id) (stringp brain-writer-id)
       (not (string-empty-p brain-id))
       (not (string-empty-p brain-writer-id))))

(defun brain-enable ()
  "Recover, install guards and connect.  Idempotent; refuses without identity."
  (interactive)
  (cond
   (brain--enabled t)
   ((not (brain-configurable-p))
    (brain--log "brain-enable ignored: brain-id/brain-writer-id unset")
    nil)
   (t
    (let ((directory (brain--state-dir)))
      (make-directory directory t)
      (make-directory (brain--journal-dir) t)
      (make-directory (brain--ipc-dir) t)
      ;; `make-directory' leaves the process umask (0755 here) on every directory it creates,
      ;; and the reviewed `BrainIPC.prepareEndpoint' refuses an endpoint directory whose mode
      ;; grants any group/other bit (`mode & 0o077'). Brain's own state is private, so it is
      ;; created private: a 0755 ipc/ made every install fail closed until it was chmod'd by
      ;; hand.
      (dolist (created (list directory (brain--journal-dir) (brain--ipc-dir)))
        (set-file-modes (directory-file-name created) #o700)))
    (setq brain--enabled t)
    (brain--install-guards)
    (add-hook 'find-file-hook #'brain--setup-buffer t)
    (add-hook 'after-change-major-mode-hook #'brain--setup-buffer)
    ;; E9c: recovery comes BEFORE any buffer is set up.  `brain--setup-buffer'
    ;; journals a dirty lease for an already-modified managed buffer, and with
    ;; the reviewed order the journal had not been loaded yet — so a cold start
    ;; with unsaved text wrote a `dirty' record at local-seq 1 with a null base,
    ;; duplicating an identity the file already owned.  The old writer accepted
    ;; that silently; a strict reload refuses it, which is how the ordering bug
    ;; surfaced.  Loading first also means an already-restored lease is not
    ;; re-journaled, because `brain--setup-buffer' skips a file that has one.
    (brain-recover)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer (brain--setup-buffer)))
    (brain--release-stale-leases)
    (brain--mark-live-dirty-buffers)
    (brain--subscribe)
    (brain--announce-ready)
    (brain--start-reconnect)
    (brain--start-dispatch)
    t)))

(defun brain-disable ()
  "Stop guarding and connecting.  Journal and pending state are preserved."
  (interactive)
  (setq brain--enabled nil)
  (brain--stop-reconnect)
  (brain--stop-dispatch)
  (brain--remove-guards)
  (remove-hook 'find-file-hook #'brain--setup-buffer)
  (remove-hook 'after-change-major-mode-hook #'brain--setup-buffer)
  (dolist (buffer (buffer-list)) (brain--disable-buffer-hooks buffer))
  (when (and brain--ipc (process-live-p brain--ipc))
    (ignore-errors (delete-process brain--ipc)))
  (setq brain--ipc nil
        brain--reconciled nil)
  t)

(defun brain--maybe-enable ()
  "Enable when the reviewed cutover has configured this Mac's identity."
  (when (and (brain-configurable-p) (not brain--enabled))
    (condition-case err
        (brain-enable)
      (error (brain--log "brain-enable failed: %S" err)))))

(add-hook 'after-init-hook #'brain--maybe-enable)
(add-hook 'emacs-startup-hook #'brain--maybe-enable)
(when (brain-configurable-p) (brain--maybe-enable))

(provide 'brain)
;;; brain.el ends here

;;; ---------------------------------------------------------------------------
;;; E9c C2: the stream evidence exporter
;;; ---------------------------------------------------------------------------
;;
;; Design t_c4596fd0, "Evidence and local administrative recovery": a fixed
;; background-administration exporter, not a remote protocol.  It reads the
;; journal LITERALLY, compares the parsed event identities and order with the
;; in-memory journal and the outbox, and writes the raw bytes plus a closed JSON
;; manifest into a caller-selected administrative directory.
;;
;; It never appends to the canonical journal, never changes a counter and never
;; repairs anything: an export that cannot prove its own consistency produces no
;; certificate, because a half-truth is worse than no evidence.

(defconst brain-evidence-format 1
  "The manifest format this exporter writes.  A verifier refuses any other.")

(defun brain--export-write-atomically (path text)
  "Write TEXT to PATH through a temporary file and a rename."
  (let* ((directory (file-name-directory path))
         (brain--inhibit-guards t)
         (temp (make-temp-file (expand-file-name ".evidence-" directory))))
    (unwind-protect
        (progn
          (with-temp-file temp
            (setq coding-system-for-write 'utf-8-unix)
            (insert text))
          (rename-file temp path t))
      (when (file-exists-p temp) (ignore-errors (delete-file temp))))
    path))

(defun brain--true-directory (path)
  "The real name of PATH as a directory, resolving the deepest existing ancestor.

`file-truename' answers for a path that does not exist yet by resolving what it
can, which is exactly what a destination check needs: the directory is created
by the export, so it cannot be required to exist before the check."
  (file-name-as-directory (file-truename (file-name-as-directory (expand-file-name path)))))

(defun brain--path-under-p (path root)
  "Non-nil when real PATH is ROOT or lies beneath it."
  (let ((prefix (brain--true-directory root)))
    (string-prefix-p prefix (brain--true-directory path))))

(defun brain--export-destination-refusal (destination)
  "Why DESTINATION may not receive the private journal, or nil when it may.

The raw journal is private: it carries every managed path, every revision hash and
every operation id this Mac has ever written.  The design puts it in an
administrative directory outside the canonical Org roots and outside the transport
share, so a sync can never carry it.  A docstring saying so is not enforcement, so
the boundary is checked here, on real names, before anything is written:

* every configured managed root (the canonical Org trees);
* the transport share (immutable objects, synced);
* the Brain state directory itself, whose journal is the thing being captured.

`file-truename' is what makes this a boundary rather than a string test: a
destination reached through a symlink is refused too, because the sync does not
care how the path was spelled."
  (let ((roots (append (mapcar (lambda (cell) (cdr cell)) brain-managed-roots)
                       (list (brain--transport-dir) (brain--state-dir)))))
    (seq-find (lambda (root)
                (and (stringp root) (not (string-empty-p root))
                     (brain--path-under-p destination root)))
              roots)))

(defun brain--export-event-identities (records)
  "Return the (seq . event_id) list of the event RECORDS, in order."
  (let (out)
    (dolist (record records)
      (when (equal (plist-get record :kind) "event")
        (push (cons (plist-get record :wire_seq)
                    (alist-get "event_id" (plist-get record :payload) nil nil #'equal))
              out)))
    (nreverse out)))

(defun brain--module-source-file ()
  "The SOURCE file this module was loaded from, or nil.

`locate-library' answers with the file Emacs actually loads, which is `brain.elc' when a compiled
copy sits beside the source.  The reviewed set names `.el' source bytes, so a manifest hashing the
compiled artifact would claim a module identity nobody reviewed — and the recovery verifier would
refuse the very capture this exporter just wrote.  The source is therefore resolved explicitly:
the loaded file's `.elc' suffix is stripped when a readable `.el' exists beside it."
  (let* ((loaded (or (and (fboundp 'brain-export-stream-evidence)
                          (symbol-file 'brain-export-stream-evidence 'defun))
                     (locate-library "brain")
                     load-file-name
                     (expand-file-name "brain.el")))
         (source (if (string-suffix-p ".elc" loaded)
                     (concat (string-remove-suffix "c" loaded))
                   loaded)))
    (if (file-regular-p source) source (and (file-regular-p loaded) loaded))))

(defun brain-export-stream-evidence (destination)
  "Export this Mac's stream evidence into DESTINATION and return the manifest.

DESTINATION must be an administrative directory outside the canonical Org roots
and outside the transport share: the raw journal is private and is never written
where a sync would carry it.  That is enforced, not merely documented — a
destination inside a managed root, the transport share or the Brain state
directory signals `brain-invalid-path' before any file or directory is created.
The export is one non-yielding evaluation, so the file, the memory journal and
the outbox describe the same instant.

The manifest is closed: it names the exact bytes it describes, so a verifier can
re-hash them instead of trusting a claim.  When the three views disagree the
export FAILS and writes no manifest — an inconsistent capture is not evidence of
anything."
  (let* ((destination (file-name-as-directory (expand-file-name destination)))
         (file (brain--journal-file))
         (journal-path (expand-file-name "journal.jsonl" destination))
         (manifest-path (expand-file-name "manifest.json" destination))
         (refusal (brain--export-destination-refusal destination))
         (bytes (when (file-regular-p file)
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string))))
         ;; The SAME reader the writer's reload uses: evidence that accepted a
         ;; file the writer refuses would prove nothing.
         (journal (brain--journal-parse bytes))
         (memory (brain--export-event-identities brain--journal))
         (file-events (brain--export-event-identities journal))
         (outbox (mapcar (lambda (event)
                           (cons (alist-get "seq" event nil nil #'equal)
                                 (alist-get "event_id" event nil nil #'equal)))
                         brain--outbox))
         (local-max (or (cl-loop for record in journal
                                 maximize (or (plist-get record :local-seq) 0))
                        0))
         (wire-max (or (cl-loop for pair in file-events maximize (car pair)) 0))
         (ack-max (or (cl-loop for record in journal
                               when (equal (plist-get record :kind) "ack")
                               maximize (or (plist-get record :through_seq) 0))
                      0)))
    ;; The boundary is checked BEFORE anything is written: a refusal must not
    ;; leave a half-capture behind, and must not create the directory it refused.
    (when refusal
      (signal 'brain-invalid-path
              (list (format "evidence destination is inside %s" refusal))))
    ;; The three views must describe one stream.  A disagreement means the
    ;; in-memory state is not the file's state, and no certificate may claim it is.
    (unless (equal memory file-events)
      (signal 'brain-journal-corrupt
              (list "the in-memory journal does not match the file's events")))
    (unless (equal outbox
                   (seq-filter (lambda (pair) (> (car pair) ack-max)) file-events))
      (signal 'brain-journal-corrupt
              (list "the outbox is not the retained unacked event set")))
    (make-directory destination t)
    (when bytes
      (brain--export-write-atomically journal-path bytes))
    (let ((manifest
           (list (cons "format" brain-evidence-format)
                 (cons "brain_id" (or brain-id :null))
                 (cons "writer_id" (or brain-writer-id :null))
                 (cons "peer_id" (or brain-peer-id :null))
                 (cons "captured_at" (round (float-time)))
                 (cons "source_module_sha256"
                       (or (brain--sha256-file (brain--module-source-file)) :null))
                 (cons "journal_sha256" (or (and bytes (brain--sha256 bytes)) :null))
                 (cons "journal_bytes" (or (and bytes (length bytes)) 0))
                 (cons "journal_records" (length journal))
                 (cons "local_seq_max" local-max)
                 (cons "wire_seq_max" wire-max)
                 (cons "ack_watermark" ack-max)
                 (cons "events" (cons :json-array
                                      (mapcar (lambda (pair)
                                                (list (cons "seq" (car pair))
                                                      (cons "event_id" (cdr pair))))
                                              file-events)))
                 (cons "outbox" (cons :json-array
                                      (mapcar (lambda (pair)
                                                (list (cons "seq" (car pair))
                                                      (cons "event_id" (cdr pair))))
                                              outbox)))
                 (cons "journal_file" "journal.jsonl"))))
      (brain--export-write-atomically manifest-path
                                      (brain--json-encode manifest))
      manifest)))
