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
;;     `ipc/node.sock'), a durable outbox and the idle dispatcher;
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

(defcustom brain-dispatch-idle 0.25
  "Idle delay before queued install requests are executed."
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

(defvar brain--inbox nil
  "Validated inbound frames waiting for the idle dispatcher.")

(defvar brain--outbox nil
  "Durable events not yet acknowledged by the gateway, in wire order.")

(defvar brain--wire-seq 0
  "Last allocated outbound event sequence number (distinct from revision seq).")

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

;;; ---------------------------------------------------------------------------
;;; Small utilities
;;; ---------------------------------------------------------------------------

(defun brain--nfc (string)
  "Return STRING normalised to NFC (identity for ASCII paths)."
  (if (fboundp 'ucs-normalize-NFC-string)
      (ucs-normalize-NFC-string string)
    string))

(defun brain--uuid ()
  "Return a fresh UUID string (version 4 shaped)."
  (let ((hex (secure-hash 'sha256 (format "%s/%s/%s/%s" (float-time) (emacs-pid)
                                          (random most-positive-fixnum) (gensym)))))
    (format "%s-%s-4%s-%s%s-%s"
            (substring hex 0 8) (substring hex 8 12) (substring hex 13 16)
            (nth (random 4) '("8" "9" "a" "b")) (substring hex 17 20)
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

(defun brain--check-relative-path (relative)
  "Signal `brain-invalid-path' unless RELATIVE is an admissible relative path."
  (when (or (not (stringp relative))
            (string-empty-p relative)
            (> (length relative) 1024)
            (string-prefix-p "/" relative)
            (string-search "\\" relative)
            (string-search ".sync-conflict-" relative)
            (not (string-suffix-p ".org" relative))
            (not (string= (brain--nfc relative) relative)))
    (signal 'brain-invalid-path (list relative)))
  (dolist (segment (split-string relative "/"))
    (when (or (string-empty-p segment)
              (member segment '("." ".."))
              (> (length segment) 255)
              (seq-find (lambda (character) (or (< character 32) (= character 127)))
                        segment))
      (signal 'brain-invalid-path (list relative))))
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
  "Case-folded alias key of FILE-ID, used to refuse collapsing identities."
  (let* ((split (brain--split-file-id file-id)))
    (concat (car split) "/" (downcase (brain--nfc (cdr split))))))

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
  '("prev_revision" "new_revision" "base_revision" "revision" "current_revision"))

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

(defun brain--journal-write (no-fsync kind fields)
  (setq brain--journal-seq (1+ brain--journal-seq))
  (let* ((at (round (float-time)))
         (record (append (list :local-seq brain--journal-seq :kind kind :at at) fields))
         (line (concat (brain--json-encode (brain--record->json record)) "\n"))
         (file (brain--journal-file))
         (brain--inhibit-guards t)
         (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (write-region line nil file 'append 'no-message)
    (setq brain--journal (append brain--journal (list record)))
    (unless no-fsync (brain--fsync file))
    brain--journal-seq))

(defun brain--journal-load ()
  "Load the durable journal into `brain--journal'."
  (setq brain--journal nil
        brain--journal-seq 0)
  (let ((file (brain--journal-file)))
    (when (file-regular-p file)
      (with-temp-buffer
        (set-buffer-multibyte t)
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents file))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                       (line-end-position))))
            (unless (string-empty-p (string-trim line))
              (let ((record (brain--json->record (brain--json-decode line))))
                (setq brain--journal (append brain--journal (list record)))
                (setq brain--journal-seq
                      (max brain--journal-seq (or (plist-get record :local-seq) 0))))))
          (forward-line 1)))))
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
`basic-save-buffer' once the handler returns."
  (let ((function (symbol-function #'rename-file)))
    (if (advice--p function)
        (funcall (advice--cdr function) from to ok-if-exists)
      (rename-file from to ok-if-exists))))

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
  "Allocate revision 0 for an existing verified baseline and publish its object."
  (let* ((revision (brain--rev 0 digest))
         (bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally path)
                  (buffer-string))))
    (brain--publish-object bytes digest)
    (brain--journal-append "snapshot" :file_id file-id :revision revision
                           :object_hash digest)
    (puthash file-id revision brain--heads)
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
     ((not (brain--rev-equal recheck-head head))
      (brain--result "stale" file-id :current-revision recheck-head
                     :reason "head_advanced"))
     ((and head (not (equal recheck-disk (brain--rev-sha head))))
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
         (source (brain--human-source-base spec)))
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

(defun brain-guard-write-region (original start end filename &optional append visit lockname mustbenew)
  "Refuse a direct managed write that does not go through the primitive."
  (if (and (brain--guard-active-p) (stringp filename))
      (progn
        (brain--guard-path filename "write-region")
        (funcall original start end filename append visit lockname mustbenew))
    (funcall original start end filename append visit lockname mustbenew)))

(defun brain-guard-rename-file (original file newname &optional ok-if-already-exists)
  (if (brain--guard-active-p)
      (progn
        (brain--guard-path file "rename-file-source")
        (brain--guard-path newname "rename-file-destination")
        (funcall original file newname ok-if-already-exists))
    (funcall original file newname ok-if-already-exists)))

(defun brain-guard-delete-file (original file &optional trash)
  (if (brain--guard-active-p)
      (progn
        (brain--guard-path file "delete-file")
        (funcall original file trash))
    (funcall original file trash)))

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
;;; Outbound events, outbox and IPC
;;; ---------------------------------------------------------------------------

(defun brain--emit-event (kind payload &optional no-send)
  "Durably journal one Brain event before it can leave, then send it."
  (when (and brain-id brain-peer-id)
    (setq brain--wire-seq (1+ brain--wire-seq))
    (let ((event (list (cons "v" brain-protocol-version)
                       (cons "type" "brain.event")
                       (cons "brain_id" brain-id)
                       (cons "peer_id" brain-peer-id)
                       (cons "event_id" (brain--uuid))
                       (cons "seq" brain--wire-seq)
                       (cons "kind" kind)
                       (cons "payload" payload))))
      (brain--journal-append "event" :wire_seq brain--wire-seq :event_kind kind
                             :file_id (alist-get "file_id" payload nil nil #'equal)
                             :payload event)
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

(defun brain--subscribe ()
  (when (brain--ipc-connect)
    (setq brain--epoch (1+ brain--epoch)
          brain--client-epoch (or brain--client-epoch (brain--uuid)))
    (brain--ipc-send (list (cons "v" brain-protocol-version)
                           (cons "type" "brain.subscribe")
                           (cons "client_epoch" brain--client-epoch)))))

(defun brain--announce-ready ()
  "Report reconciliation to the node, which then allows install routing."
  (when (and brain--client-epoch
             (brain--ipc-send (list (cons "v" brain-protocol-version)
                                    (cons "type" "brain.client.ready")
                                    (cons "client_epoch" brain--client-epoch))))
    (setq brain--reconciled t)
    (brain--emit-event "emacs.online" (list (cons "epoch" (max 1 brain--epoch))))
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
;;; Inbound dispatch
;;; ---------------------------------------------------------------------------

(defun brain-dispatch-once ()
  "Execute every queued inbound frame exactly once."
  (when (and brain--recovered (not brain--dispatching) brain--inbox)
    (let ((brain--dispatching t))
      (while brain--inbox
        (let ((frame (pop brain--inbox)))
          (condition-case err
              (brain--dispatch-frame frame)
            (error (brain--log "dispatch error: %S" err))))))))

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

(defun brain--handle-replay-request (frame)
  (let ((attempt-id (alist-get "attempt_id" frame nil nil #'equal)))
    (cond
     ((and (stringp attempt-id) (gethash attempt-id brain--results))
      (brain--send-result (gethash attempt-id brain--results)))
     ((stringp attempt-id)
      ;; No durable result for this attempt: answering with an invented file
      ;; identity would violate the contract, so nothing is sent.
      (brain--log "replay request for unknown attempt refused"))
     (t
      ;; Stream replay is answered by the gateway.
      (brain--log "stream replay request received")))))

;;; ---------------------------------------------------------------------------
;;; Snapshots and inventory
;;; ---------------------------------------------------------------------------

(defun brain--handle-snapshot-request (frame)
  (let ((request-id (alist-get "request_id" frame nil nil #'equal))
        (file-id (alist-get "file_id" frame nil nil #'equal))
        (limit (alist-get "limit" frame nil nil #'equal))
        (after (alist-get "after_file_id" frame nil nil #'equal)))
    (cond
     ((not (brain--frame-brain-id-ok-p frame))
      (brain--log "snapshot request for a foreign brain id refused"))
     (file-id (brain--snapshot-target request-id file-id))
     (limit (brain--snapshot-page request-id after limit))
     (t (brain--log "snapshot request without target or page")))))

(defun brain--snapshot-event (request-id file-id result &optional extra done)
  (brain--emit-event
   "brain.file.snapshot"
   (append (list (cons "request_id" request-id)
                 (cons "file_id" file-id)
                 (cons "result" result))
           extra
           (list (cons "done" (if done t :false))))))

(defun brain--snapshot-target (request-id file-id)
  "Answer one target snapshot without opening or touching a visiting buffer."
  (let* ((resolution (brain--resolve file-id))
         (path (plist-get resolution :path))
         (head (gethash file-id brain--heads))
         (lease (gethash file-id brain--dirty)))
    (cond
     ((equal (plist-get resolution :status) "unsafe")
      (brain--snapshot-event request-id file-id "attention"
                             (list (cons "continuation" :null)) t))
     ((equal (plist-get resolution :status) "absent")
      (if lease
          (brain--snapshot-event request-id file-id "attention"
                                 (list (cons "dirty_generation"
                                             (plist-get lease :generation)))
                                 t)
        (brain--snapshot-event request-id file-id "absent" nil t)))
     ((and lease (null head))
      (brain--snapshot-event request-id file-id "attention"
                             (list (cons "dirty_generation" (plist-get lease :generation)))
                             t))
     (t
      (let ((digest (brain--sha256-file path)))
        (cond
         ((and head (not (equal digest (brain--rev-sha head))))
          (brain--snapshot-event request-id file-id "attention"
                                 (list (cons "revision" (brain--rev->json head))
                                       (cons "object_hash" (brain--rev-sha head))
                                       (cons "dirty_generation"
                                             (and lease (plist-get lease :generation))))
                                 t))
         (t
          (let ((revision (if head head (brain--enroll-baseline file-id path digest))))
            (brain--snapshot-event
             request-id file-id "present"
             (list (cons "revision" (brain--rev->json revision))
                   (cons "object_hash" (brain--rev-sha revision))
                   (cons "dirty_generation" (and lease (plist-get lease :generation))))
             t)))))))))

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

;;; ---------------------------------------------------------------------------
;;; Recovery
;;; ---------------------------------------------------------------------------

(defun brain--rebuild-heads ()
  "Rebuild `brain--heads' from the committed journal chain."
  (clrhash brain--heads)
  (dolist (record (brain--journal-records "snapshot"))
    (let ((file-id (plist-get record :file_id))
          (revision (plist-get record :revision)))
      (when (and file-id revision (null (gethash file-id brain--heads)))
        (puthash file-id revision brain--heads))))
  (dolist (record (brain--journal-records "committed"))
    (let ((file-id (plist-get record :file_id))
          (revision (plist-get record :new_revision)))
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
  (brain--journal-load)
  (brain--rebuild-heads)
  (brain--rebuild-dirty)
  (brain--rebuild-results)
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
        :state (cond
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
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer (brain--setup-buffer)))
    (brain-recover)
    (brain--mark-live-dirty-buffers)
    (brain--subscribe)
    (brain--announce-ready)
    (brain--start-reconnect)
    (run-with-idle-timer brain-dispatch-idle t #'brain-dispatch-once)
    t)))

(defun brain-disable ()
  "Stop guarding and connecting.  Journal and pending state are preserved."
  (interactive)
  (setq brain--enabled nil)
  (brain--stop-reconnect)
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
