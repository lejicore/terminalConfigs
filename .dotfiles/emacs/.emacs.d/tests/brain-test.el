;;; brain-test.el --- ERT tests for the Mac Brain commit client -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for brain.el (design t_0511a7c7, chunk B3).  Everything below drives
;; REAL temporary files and REAL buffers: the commit primitive is not stubbed,
;; `buffer-modified-p' is not mocked, and the IPC path goes through the real
;; process filter with real length-prefixed frames.
;;
;; The managed-save tests also drive the real `org-roam-db-autosync-mode'
;; advice on `rename-file' (loaded from the user's straight build tree); they
;; skip only when org-roam is not installed at all.
;;
;; Run: emacs -Q --batch -L <module dir> -l ert -l tests/brain-test.el \
;;        -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

(let* ((source (file-name-directory
                (directory-file-name
                 (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path source))

(require 'brain)

;; Loaded lazily by `brain-test--load-org-roam'; declared here so the bindings
;; below are dynamic bindings of the real variables, not new lexical ones.
(defvar org-roam-directory)
(defvar org-roam-db-location)

;;; ---------------------------------------------------------------------------
;;; Harness
;;; ---------------------------------------------------------------------------

(defvar brain-test--root nil)
(defvar brain-test--state nil)

(defun brain-test--reset-state ()
  (setq brain--journal nil
        brain--journal-seq 0
        brain--heads (make-hash-table :test #'equal)
        brain--dirty (make-hash-table :test #'equal)
        brain--generations (make-hash-table :test #'equal)
        brain--attention (make-hash-table :test #'equal)
        brain--deferred (make-hash-table :test #'equal)
        brain--identities (make-hash-table :test #'equal)
        brain--results (make-hash-table :test #'equal)
        brain--outbox nil
        brain--inbox nil
        brain--ipc-bytes ""
        brain--wire-seq 0
        brain--acked-seq 0
        brain--epoch 0
        brain--client-epoch nil
        brain--recovered nil
        brain--enabled nil
        brain--locked nil
        brain--locked-buffers nil
        brain--dispatching nil
        brain--in-critical nil
        brain--inhibit-guards nil
        brain--ipc nil
        brain--commit-count 0))

(defvar brain-test--org-roam-first nil
  "Non-nil when the environment must enable autosync before `brain-enable'.
That is the order the live daemon has: `Emacs.org' turns on
`org-roam-db-autosync-mode' before the Brain module is loaded, so org-roam's
`rename-file' advice is installed first and brain's guard wraps around it.
Only `brain-test--with-live-advice-order' binds this.")

(defmacro brain-test--with-environment (&rest body)
  "Run BODY with real temporary managed roots, state dir and a live module.
See `brain-test--with-live-advice-order' for the live advice order."
  (declare (indent 0) (debug t))
  `(let* ((brain-test--root (make-temp-file "brain-test-" t))
          (brain-test--state (expand-file-name "state/" brain-test--root))
          (org-files (expand-file-name "org-files/" brain-test--root))
          (org-roam (expand-file-name "org-roam/" brain-test--root))
          ;; Only the org-roam tests look at these, but they must be bound for
          ;; the whole environment: the live order enables autosync before
          ;; `brain-enable', and the mode's hooks read them later, at save time.
          (org-roam-directory (file-name-as-directory org-roam))
          (org-roam-db-location (expand-file-name "roam.db" brain-test--root))
          (brain-id "11111111-1111-4111-8111-111111111111")
          (brain-writer-id "22222222-2222-4222-8222-222222222222")
          (brain-managed-roots (list (cons "org-files" org-files)
                                     (cons "org-roam" org-roam)))
          (brain-state-directory brain-test--state)
          (brain-transport-directory nil)
          (brain-node-socket (expand-file-name "ipc/test.sock" brain-test--state))
          (brain-inventory-slice-entries 50)
          (brain-inventory-slice-seconds 0.02)
          (brain-inventory-max-paths 10000)
          (brain-fsync-enabled nil))
     (brain-test--reset-state)
     (make-directory org-files t)
     (make-directory org-roam t)
     (unwind-protect
         (progn
           (when brain-test--org-roam-first (brain-test--org-roam-enable))
           (brain-enable)
           ,@body)
       (brain-disable)
       (when brain-test--org-roam-first (brain-test--org-roam-disable))
       (dolist (buffer (buffer-list))
         (let ((name (buffer-file-name buffer)))
           (when (or (string-prefix-p "brain-test" (buffer-name buffer))
                     (and name (string-prefix-p brain-test--root (expand-file-name name)))
                     (string-prefix-p "*Capture" (buffer-name buffer)))
             (ignore-errors (kill-buffer buffer)))))
       (delete-directory brain-test--root t))))

(defun brain-test--read-bytes (path)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun brain-test--write (path text)
  "Write TEXT to PATH without going through the Brain primitive."
  (let ((brain--inhibit-guards t))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil path nil 'no-message)))
  path)

(defun brain-test--write-bytes (path bytes)
  "Write raw BYTES to PATH without going through the Brain primitive.
Used where the point of the test is bytes that are not valid UTF-8."
  (let ((brain--inhibit-guards t))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'binary))
      (write-region bytes nil path nil 'no-message)))
  path)

(defun brain-test--delete (path)
  "Delete PATH without going through the Brain guard."
  (let ((brain--inhibit-guards t))
    (when (file-exists-p path) (delete-file path))))

(defun brain-test--bytes (text)
  (encode-coding-string text 'utf-8))

(defun brain-test--frame (object)
  "The exact node IPC framing of OBJECT: 4-byte big-endian length, then the body."
  (let* ((body (encode-coding-string (brain--json-encode object) 'utf-8))
         (length (length body)))
    (concat (unibyte-string (logand #xff (ash length -24))
                            (logand #xff (ash length -16))
                            (logand #xff (ash length -8))
                            (logand #xff length))
            body)))

(defun brain-test--install-spec (file-id expected text &rest extra)
  (append (list :file-id file-id
                :origin "librarian"
                :bytes (brain-test--bytes text)
                :expected-revision expected
                :require-expected t
                :attempt-id (or (plist-get extra :attempt-id) (brain--uuid)))
          extra))

(defun brain-test--visit (file-id)
  "Visit FILE-ID in a real buffer and return it."
  (let ((buffer (find-file-noselect (brain--file-path file-id))))
    (with-current-buffer buffer
      (setq buffer-file-coding-system 'utf-8-unix))
    buffer))

(defun brain-test--enroll (file-id text)
  "Write TEXT and enroll it as revision 0 through the primitive."
  (let ((path (brain--file-path file-id)))
    (brain-test--write path text)
    (brain--enroll-baseline file-id path (brain--sha256-file path))
    (gethash file-id brain--heads)))

(defun brain-test--restart ()
  "Simulate a cold Emacs start: drop runtime state and recover from the journal."
  (brain-test--reset-state)
  (brain-enable))

(defun brain-test--journal-kinds ()
  (mapcar (lambda (record) (plist-get record :kind)) brain--journal))

(defun brain-test--last-event ()
  "Return the last journaled Brain event envelope."
  (car (last (brain--journal-records "event"))))

(defun brain-test--last-event-payload ()
  "Return the payload of the last journaled Brain event envelope."
  (alist-get "payload" (plist-get (brain-test--last-event) :payload) nil nil #'equal))

;;; ---------------------------------------------------------------------------
;;; The real org-roam autosync hook
;;; ---------------------------------------------------------------------------

(defvar brain-test--org-roam-loaded nil
  "Non-nil once the real org-roam is on the load path and required.")

(defun brain-test--load-org-roam ()
  "Load the real org-roam, so its advice on `rename-file' is the live one.
The suite runs under `emacs -Q --batch', where the user's package directory is
not on `load-path'; the straight build tree is added when it exists.  A stub is
never substituted: the defect being covered only exists with the real advice.
The tree's own Org build is deliberately left out: it was compiled against a
different Org release than the built-in one, so adding it makes Org emit its
mixed-version warning into `*Warnings*' and swaps the Org the rest of this suite
runs with.  org-roam itself, and the advice under test, are the user's real
bytes."
  (unless brain-test--org-roam-loaded
    (unless (require 'org-roam-db nil t)
      (dolist (dir (ignore-errors
                     (directory-files (expand-file-name "~/.cache/emacs/straight/build")
                                      t "^[^.]")))
        (when (and (file-directory-p dir)
                   (not (equal (file-name-nondirectory (directory-file-name dir)) "org")))
          (add-to-list 'load-path dir)))
      (require 'org-roam-db nil t))
    (setq brain-test--org-roam-loaded (and (featurep 'org-roam-db) t)))
  brain-test--org-roam-loaded)

(defun brain-test--org-roam-enable ()
  "Enable the real `org-roam-db-autosync-mode' over the environment's roam root.
`org-roam-directory' and `org-roam-db-location' are bound by
`brain-test--with-environment'; the mode reads them at enable time and its
hooks read them again at save time.  Skipped only when org-roam is genuinely
absent from this Emacs."
  (unless (brain-test--load-org-roam)
    (ert-skip "org-roam is not installed in this Emacs"))
  (org-roam-db-autosync-mode 1))

(defun brain-test--org-roam-disable ()
  (when brain-test--org-roam-loaded
    (org-roam-db-autosync-mode -1)))

(defun brain-test--rename-advice-layers ()
  "Return the advice layers on `rename-file', outermost first.
The order is a property of load order, not of this suite: it is what decides
whether peeling a single layer of advice is enough."
  (let ((function (symbol-function 'rename-file))
        (layers nil))
    (while (advice--p function)
      (push (advice--car function) layers)
      (setq function (advice--cdr function)))
    (nreverse layers)))

(defmacro brain-test--with-org-roam-autosync (&rest body)
  "Run BODY with `org-roam-db-autosync-mode' live over the managed roam root.
This enables autosync *after* `brain-enable', so org-roam's `rename-file'
advice ends up outermost.  `brain-test--with-live-advice-order' is the order
the live daemon has; both must be covered."
  (declare (indent 0) (debug t))
  `(progn
     (brain-test--org-roam-enable)
     (unwind-protect
         (progn ,@body)
       (brain-test--org-roam-disable))))

(defmacro brain-test--with-live-advice-order (&rest body)
  "Run BODY in the environment and advice order the live daemon has.
`Emacs.org' enables `org-roam-db-autosync-mode' before the Brain module is
loaded, so org-roam's `rename-file' advice is added first and brain's own guard
wraps around it.  A replace that only peels one layer passes the opposite order
and still fires org-roam's advice here."
  (declare (indent 0) (debug t))
  `(let ((brain-test--org-roam-first t))
     (brain-test--with-environment ,@body)))

(defun brain-test--call-without-questions (function)
  "Call FUNCTION with every question answered \"no\", returning the questions.
A save that reaches a prompt in a daemon blocks forever; answering \"no\" turns
that into an error, so a test can never hang on it."
  (let ((asked nil))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (&rest args) (push (apply #'format args) asked) nil))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest args) (push (apply #'format args) asked) nil)))
      (funcall function))
    (nreverse asked)))

(defun brain-test--roam-db-hash (path)
  "Return the org-roam cache hash recorded for PATH, or nil."
  (caar (org-roam-db-query [:select hash :from files :where (= file $s1)] path)))

(defun brain-test--roam-file-title (path)
  "Return the org-roam cache file title recorded for PATH, or nil."
  (caar (org-roam-db-query [:select [title] :from files :where (= file $s1)] path)))

;;; ---------------------------------------------------------------------------
;;; Identity and path safety
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-identity-rejects-unsafe-paths ()
  (brain-test--with-environment
    (should-error (brain--make-file-id "org-files" "../escape.org")
                  :type 'brain-invalid-path)
    (should-error (brain--make-file-id "org-files" "/etc/passwd.org")
                  :type 'brain-invalid-path)
    (should-error (brain--make-file-id "org-files" "notes.txt")
                  :type 'brain-invalid-path)
    (should-error (brain--make-file-id "org-files" "a.sync-conflict-2026.org")
                  :type 'brain-invalid-path)
    (should-error (brain--make-file-id "elsewhere" "note.org")
                  :type 'brain-invalid-path)
    (should-error (brain--make-file-id "org-files" "a\\b.org")
                  :type 'brain-invalid-path)
    (should (equal (brain--make-file-id "org-files" "sub/Note.org")
                   "org-files/sub/Note.org"))))

(ert-deftest brain-test-resolve-refuses-symlink-components ()
  (brain-test--with-environment
    (let* ((outside (expand-file-name "outside.org" brain-test--root))
           (link (expand-file-name "org-files/Link.org" brain-test--root))
           (directory-link (expand-file-name "org-files/sub" brain-test--root)))
      (brain-test--write outside "* outside\n")
      (make-symbolic-link outside link)
      (should (equal (plist-get (brain--resolve "org-files/Link.org") :status)
                     "unsafe"))
      (should (equal (plist-get (brain--resolve "org-files/Link.org") :reason)
                     "symlink_component"))
      (make-symbolic-link (file-name-directory outside) directory-link)
      (should (equal (plist-get (brain--resolve "org-files/sub/Note.org") :status)
                     "unsafe")))))

(ert-deftest brain-test-case-fold-alias-refused ()
  (brain-test--with-environment
    (brain--register-identity "org-files/Note.org")
    (should-error (brain--register-identity "org-files/note.org")
                  :type 'brain-alternate-route)
    (should (equal (brain--register-identity "org-files/Note.org")
                   "org-files/Note.org"))))

(ert-deftest brain-test-nfc-relative-path-required ()
  (brain-test--with-environment
    (let ((decomposed (concat "org-files/e" (string #x0301) ".org")))
      (should-error (brain--make-file-id "org-files" (substring decomposed 10))
                    :type 'brain-invalid-path))))

;;; ---------------------------------------------------------------------------
;;; Human save through the primitive
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-human-save-installs-and-enrols ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Note.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* Original\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* Added by human\n")
          (should (buffer-modified-p))
          (save-buffer)
          (should-not (buffer-modified-p)))
        ;; The canonical bytes are exactly the buffer text, UTF-8, no rewrite.
        (should (equal (brain-test--read-bytes path)
                       (brain-test--bytes "* Original\n* Added by human\n")))
        (should (equal (with-current-buffer buffer
                         (buffer-substring-no-properties (point-min) (point-max)))
                       "* Original\n* Added by human\n")))
      ;; An existing file gets its baseline (seq 0) and then the saved revision
      ;; (seq 1): the predecessor chain is complete.
      (let ((revision (gethash file-id brain--heads)))
        (should (= (plist-get revision :seq) 1))
        (should (equal (plist-get revision :sha256)
                       (brain--sha256-file path))))
      (should (member "intent" (brain-test--journal-kinds)))
      (should (member "committed" (brain-test--journal-kinds)))
      ;; The immutable object was published under the Mac producer namespace.
      (should (file-exists-p (brain--object-path "mac" (brain--sha256-file path)))))))

(ert-deftest brain-test-human-save-journals-its-clean-generation ()
  (brain-test--with-environment
    (let* ((file-id "org-files/CleanSave.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* A\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* edited\n")
          (save-buffer)
          (should-not (buffer-modified-p))
          ;; The next save must not prompt "file changed on disk".
          (should (verify-visited-file-modtime buffer))))
      ;; The save journals the exact generation and revision it cleared.
      (should-not (gethash file-id brain--dirty))
      (let ((clean (car (brain--journal-records "clean"))))
        (should clean)
        (should (equal (plist-get clean :revision) (gethash file-id brain--heads)))
        (should (= (plist-get clean :dirty_generation) 1)))
      ;; A restart replays that clean record, so the generation that was
      ;; already saved never blocks a later remote install.
      (brain-test--restart)
      (should-not (gethash file-id brain--dirty))
      (should (equal (plist-get (brain-commit-file
                                 (brain-test--install-spec
                                  file-id (gethash file-id brain--heads)
                                  "* A\n* edited\n* remote\n"))
                                :status)
                     "committed"))
      (should (equal (brain-test--read-bytes path)
                     (brain-test--bytes "* A\n* edited\n* remote\n"))))))

(ert-deftest brain-test-save-of-identical-bytes-clears-its-lease ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Same.org")
           (path (brain--file-path file-id))
           (text "* A\n"))
      (brain-test--enroll file-id text)
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "x")
          (delete-char -1)
          (should (buffer-modified-p))
          (should (gethash file-id brain--dirty))
          ;; The buffer text again equals the disk bytes: nothing new is
          ;; installed, but the save still clears the generation it saved.
          (save-buffer)
          (should-not (buffer-modified-p))))
      (should-not (gethash file-id brain--dirty))
      (should (member "clean" (brain-test--journal-kinds)))
      (should (equal (alist-get "kind" (plist-get (brain-test--last-event) :payload)
                                nil nil #'equal)
                     "brain.file.clean"))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes text))))))

(ert-deftest brain-test-restart-releases-a-lease-left-on-a-clean-buffer ()
  "A journal-replayed lease whose buffer is clean again is released at enable:
the clean save of that generation may have been journaled by a previous
process, and keeping the lease would block every install on the file forever.
The pending remote attempt is then delivered under its journaled id."
  (brain-test--with-environment
    (let* ((file-id "org-files/StaleLease.org")
           (path (brain--file-path file-id))
           (original "* Base\n")
           (base (brain-test--enroll file-id original))
           (buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* Unsaved\n"))
      (should (gethash file-id brain--dirty))
      ;; The human saves, but the process "crashes" before the clean event can
      ;; matter: simulate by committing the save and then restarting with the
      ;; buffer clean on disk (the daemon restart visits the saved file).
      (with-current-buffer buffer
        (save-buffer)
        (should-not (buffer-modified-p)))
      (should-not (gethash file-id brain--dirty))
      ;; Now simulate the live defect shape: a dirty lease journaled by a
      ;; previous run, with the buffer already clean after a restart.  Journal
      ;; the dirty record itself, so the restart replays it exactly like the
      ;; live daemon's journal.
      (brain--journal-append "dirty" :file_id file-id :base_revision base
                             :dirty_generation 2
                             :operation_id (brain--uuid)
                             :client_epoch "old-epoch")
      (puthash file-id (list :generation 2 :base base
                             :operation-id (plist-get (car (last brain--journal))
                                                       :operation_id)
                             :epoch "old-epoch")
               brain--dirty)
      (brain-test--restart)
      ;; The stale lease is gone and a clean record + brain.file.clean event
      ;; were journaled for the gateway's files.human_lease_json.
      (should-not (gethash file-id brain--dirty))
      (let ((clean (cl-find-if (lambda (record)
                                 (and (equal (plist-get record :kind) "clean")
                                      (= (or (plist-get record :dirty_generation) 0) 2)))
                               brain--journal)))
        (should clean))
      (should (equal (alist-get "kind" (plist-get (brain-test--last-event) :payload)
                                nil nil #'equal)
                     "brain.file.clean"))
      ;; The pending remote install is no longer blocked by the stale lease.
      (let ((result (brain-commit-file
                     (brain-test--install-spec
                      file-id (gethash file-id brain--heads)
                      "* Base\n* Unsaved\n* Remote\n" :attempt-id "11111111-2222-4333-8444-555555555555"))))
        (should (equal (plist-get result :status) "committed"))
        (should (equal (brain-test--read-bytes path)
                       (brain-test--bytes "* Base\n* Unsaved\n* Remote\n")))))))

(ert-deftest brain-test-restart-keeps-a-lease-on-a-genuinely-dirty-buffer ()
  "An unsaved buffer still owns its lease across a restart: the lease and the
buffer together are what block installs byte-for-byte (criterion 3)."
  (brain-test--with-environment
    (let* ((file-id "org-files/LiveDirty.org")
           (path (brain--file-path file-id))
           (original "* Base\n")
           (base (brain-test--enroll file-id original))
           (buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* Unsaved\n"))
      (should (gethash file-id brain--dirty))
      ;; A restart (brain-disable + brain-enable) keeps the lease because the
      ;; buffer is still modified.
      (brain-test--restart)
      (should (gethash file-id brain--dirty))
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id base "* Base\n* Remote\n"))))
        (should (equal (plist-get result :status) "dirty"))
        (should (equal (plist-get result :reason) "dirty_lease")))
      ;; Bytes unchanged on disk and in the buffer.
      (should (equal (brain-test--read-bytes path) (brain-test--bytes original)))
      (should (equal (with-current-buffer buffer
                       (buffer-substring-no-properties (point-min) (point-max)))
                     (concat original "* Unsaved\n"))))))

(ert-deftest brain-test-human-save-keeps-markers-folding-and-tick ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Marks.org")
           (path (brain--file-path file-id))
           (text "* One\nbody one\n* Two\nbody two\n* Three\nbody three\n"))
      (brain-test--write path text)
      (let ((buffer (brain-test--visit file-id)) marker position folded tick)
        (with-current-buffer buffer
          (org-mode)
          ;; A mode change must not lose the save path (see the restart test).
          (should (memq #'brain-write-contents-handler write-contents-functions))
          (goto-char (point-min))
          (search-forward "* Three")
          (setq position (line-beginning-position))
          (setq marker (copy-marker position))
          (goto-char (point-min))
          (org-fold-hide-subtree)
          (setq folded (org-fold-folded-p (save-excursion (forward-line 1) (point))))
          (goto-char (point-max))
          (insert "* Four\n")
          (setq tick (buffer-chars-modified-tick))
          (save-buffer)
          ;; An ordinary save never erases and reinserts the saving buffer.
          (should (= (buffer-chars-modified-tick) tick))
          (should (equal (marker-position marker) position))
          (should (eq (org-fold-folded-p (save-excursion (goto-char (point-min))
                                                         (forward-line 1)
                                                         (point)))
                      folded))
          (should-not (buffer-modified-p)))
        (should (equal (brain-test--read-bytes path)
                       (brain-test--bytes (concat text "* Four\n"))))))))

(ert-deftest brain-test-human-save-carries-a-bounded-projection ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Todo.org")
           (path (brain--file-path file-id))
           (text (concat "* TODO task :kanban:ready:\n:PROPERTIES:\n"
                         ":ID: x-1\n:PROJECT: p\n:END:\n")))
      (brain-test--write path text)
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "body\n")
          (save-buffer)))
      (let* ((event (plist-get (brain-test--last-event) :payload))
             (payload (alist-get "payload" event nil nil #'equal))
             (semantic (alist-get "semantic" payload nil nil #'equal))
             (headings (cdr (alist-get "headings" semantic nil nil #'equal))))
        (should (equal (alist-get "kind" event nil nil #'equal) "brain.file.saved"))
        (should semantic)
        (should (= (length headings) 1))
        (should (equal (alist-get "todo" (nth 0 headings) nil nil #'equal) "TODO"))
        (should (equal (alist-get "id" (nth 0 headings) nil nil #'equal) "x-1"))
        (should (equal (alist-get "project" (nth 0 headings) nil nil #'equal) "p"))
        (should (<= (length (encode-coding-string (brain--json-encode semantic)
                                                  'utf-8))
                    brain-projection-max-bytes))))))

(ert-deftest brain-test-text-is-not-rewritten-by-guards ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Plain.org")
           (path (brain--file-path file-id))
           (text "* one\n* two\n"))
      (brain-test--write path text)
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (should-not (buffer-modified-p))
          (set-buffer-modified-p t)
          (save-buffer)))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes text))))))

(ert-deftest brain-test-unsupported-coding-refused-with-bytes-intact ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Coding.org")
           (path (brain--file-path file-id))
           (text "* Keep me\n* and me\n"))
      (brain-test--write path text)
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* human edit\n")
          (setq buffer-file-coding-system 'iso-latin-1)
          (should-error (save-buffer) :type 'user-error)
          ;; The buffer keeps the user's bytes and the file is untouched.
          (should (buffer-modified-p))
          (should (string-match-p "human edit"
                                  (buffer-substring-no-properties (point-min) (point-max))))))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes text)))
      (should (gethash file-id brain--attention)))))

;;; ---------------------------------------------------------------------------
;;; Remote install: dirty, clean, aliases, point/narrowing
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-dirty-buffer-blocks-install-byte-for-byte ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Dirty.org")
           (path (brain--file-path file-id))
           (original "* Base\n")
           (base (brain-test--enroll file-id original))
           (buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* Unsaved human line\n"))
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id base "* Base\n* Library line\n"))))
        (should (equal (plist-get result :status) "dirty"))
        (should (equal (plist-get result :reason) "dirty_lease")))
      ;; Nothing on disk and nothing in the buffer changed, byte for byte.
      (should (equal (brain-test--read-bytes path) (brain-test--bytes original)))
      (should (equal (with-current-buffer buffer
                       (buffer-substring-no-properties (point-min) (point-max)))
                     (concat original "* Unsaved human line\n")))
      (should (equal (gethash file-id brain--heads) base))
      (should (gethash file-id brain--dirty)))))

(defun brain-test--expect (result status)
  "Assert RESULT is STATUS, showing the whole result when it is not."
  (unless (equal (plist-get result :status) status)
    (ert-fail (format "expected %s, got %S" status result)))
  result)

(ert-deftest brain-test-clean-install-preserves-point-narrowing-and-windows ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Clean.org")
           (unvisited "org-files/Unvisited.org")
           (path (brain--file-path file-id))
           (text "* One\nbody one\n* Two\nbody two\n* Three\nbody three\n")
           (base (brain-test--enroll file-id text))
           (buffer (brain-test--visit file-id)))
      (brain-test--write (brain--file-path unvisited) "* untouched\n")
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "* Two")
        (narrow-to-region (line-beginning-position) (point-max))
        (goto-char (point-min))
        (forward-char 3))
      (let ((window (selected-window))
            (expected-point nil))
        (with-current-buffer buffer (setq expected-point (point)))
        (set-window-buffer window buffer)
        (set-window-start window 1)
        (set-window-point window expected-point)
        (let ((result (brain-commit-file
                       (brain-test--install-spec file-id base
                                                 "* One\nbody one\n* Two\ninstalled two\n* Three\nbody three\n"))))
          (brain-test--expect result "committed")
          (should (equal (plist-get result :origin) "librarian"))
          (with-current-buffer buffer
            (should (equal (save-restriction
                             (widen)
                             (buffer-substring-no-properties (point-min) (point-max)))
                           "* One\nbody one\n* Two\ninstalled two\n* Three\nbody three\n"))
            (should (buffer-narrowed-p))
            (should (= (point-min) (save-excursion
                                     (save-restriction
                                       (widen)
                                       (goto-char (point-min))
                                       (search-forward "* Two")
                                       (line-beginning-position)))))
            (should (= (point) (+ (point-min) 3)))
            (should-not (buffer-modified-p)))
          (should (= (window-point window) expected-point))))
      ;; No buffer was created for the unvisited target.
      (should-not (get-file-buffer (brain--file-path unvisited))))))

(ert-deftest brain-test-indirect-and-base-buffers-are-one-identity ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Alias.org")
           (text "* A\n* B\n")
           (base-revision (brain-test--enroll file-id text))
           (buffer (brain-test--visit file-id))
           (indirect nil))
      (with-current-buffer buffer
        (goto-char (point-min))
        (setq indirect (clone-indirect-buffer "brain-test-indirect" nil t))
        (narrow-to-region (point-min) (line-end-position))
        (goto-char (point-max)))
      ;; A modification made through the indirect buffer blocks a remote install.
      (with-current-buffer indirect
        (goto-char (point-max))
        (insert "edited"))
      (should (equal (plist-get (brain-commit-file
                                 (brain-test--install-spec file-id base-revision
                                                           "* A\n* remote\n* B\n"))
                                :status)
                     "dirty"))
      ;; Both aliases are the same identity and both see the same text.
      (let ((visiting (brain--visiting-buffers file-id)))
        (should (= (length visiting) 2))
        (should (memq buffer visiting))
        (should (memq indirect visiting))))))

(ert-deftest brain-test-alias-and-base-refresh-together ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Twin.org")
           (text "* One\n* Two\n")
           (base (brain-test--enroll file-id text))
           (buffer (brain-test--visit file-id))
           (indirect nil)
           new-text)
      (setq new-text "* One\n* Two updated\n")
      ;; Both aliases keep a real (non-trivial) narrowing: the base sees the
      ;; second headline only, the indirect buffer a sub-range of it.
      (with-current-buffer buffer
        (setq indirect (clone-indirect-buffer "brain-test-twin" nil t))
        (narrow-to-region 7 (point-max))
        (goto-char 8))
      (with-current-buffer indirect
        (narrow-to-region 3 (point-max))
        (goto-char (point-max)))
      (brain-test--expect
       (brain-commit-file (brain-test--install-spec file-id base new-text))
       "committed")
      (dolist (candidate (list buffer indirect))
        (with-current-buffer candidate
          (should (equal (save-restriction
                           (widen)
                           (buffer-substring-no-properties (point-min) (point-max)))
                         new-text))
          (should-not (buffer-modified-p))
          (should (buffer-narrowed-p))))
      (with-current-buffer buffer
        (should (= (point-min) 7))
        (should (= (point) 8)))
      (with-current-buffer indirect
        (should (= (point-min) 3))
        (should (= (point) (point-max)))))))

;;; ---------------------------------------------------------------------------
;;; Scheduling: human-first, install-first, filter reentrancy
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-process-filter-only-enqueues ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Filter.org")
           (text "* A\n")
           (base (brain-test--enroll file-id text))
           (attempt (brain--uuid))
           (payload (list (cons "v" 1)
                          (cons "type" "brain.install.request")
                          (cons "brain_id" brain-id)
                          (cons "attempt_id" attempt)
                          (cons "mutation_id" (brain--uuid))
                          (cons "file_id" file-id)
                          (cons "expected_revision" (brain--rev->json base))
                          (cons "object_hash" (brain--sha256 (brain-test--bytes "* A\n* B\n")))
                          (cons "byte_length" (length (brain-test--bytes "* A\n* B\n")))))
           (body (encode-coding-string (brain--json-encode payload) 'utf-8))
           (frame (concat (unibyte-string 0 0 (/ (length body) 256) (% (length body) 256))
                          body)))
      ;; The object must exist in the producer namespace the node reads.
      (brain--publish-object (brain-test--bytes "* A\n* B\n")
                             (alist-get "object_hash" payload nil nil #'equal)
                             "hermes")
      (brain--ipc-filter nil frame)
      ;; The filter enqueued, and nothing was installed.
      (should (= (length brain--inbox) 1))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes text)))
      (should (equal (gethash file-id brain--heads) base))
      ;; A second dispatch attempt while one is running is a no-op.
      (let ((brain--dispatching t))
        (brain-dispatch-once)
        (should (= (length brain--inbox) 1)))
      (brain-dispatch-once)
      (should (null brain--inbox))
      (should (= (plist-get (gethash file-id brain--heads) :seq) 1))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes "* A\n* B\n"))))))

(ert-deftest brain-test-human-first-then-queued-install-is-dirty ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Race.org")
           (text "* A\n")
           (base (brain-test--enroll file-id text))
           (attempt (brain--uuid))
           (bytes (brain-test--bytes "* A\n* library\n"))
           (payload (list (cons "v" 1)
                          (cons "type" "brain.install.request")
                          (cons "brain_id" brain-id)
                          (cons "attempt_id" attempt)
                          (cons "mutation_id" (brain--uuid))
                          (cons "file_id" file-id)
                          (cons "expected_revision" (brain--rev->json base))
                          (cons "object_hash" (brain--sha256 bytes))
                          (cons "byte_length" (length bytes))))
           (body (encode-coding-string (brain--json-encode payload) 'utf-8))
           (buffer (brain-test--visit file-id)))
      (brain--publish-object bytes (alist-get "object_hash" payload nil nil #'equal) "hermes")
      (brain--ipc-filter nil (concat (unibyte-string 0 0 (/ (length body) 256)
                                                     (% (length body) 256))
                                     body))
      ;; Human edit first.
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* human\n"))
      (brain-dispatch-once)
      (should (equal (plist-get (gethash attempt brain--results) :status) "dirty"))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes text)))
      (should (equal (gethash file-id brain--heads) base)))))

(ert-deftest brain-test-install-first-then-edit-starts-from-new-revision ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Order.org")
           (base (brain-test--enroll file-id "* A\n"))
           (buffer (brain-test--visit file-id))
           (installed "* A\n* remote\n"))
      (should (equal (plist-get (brain-commit-file
                                 (brain-test--install-spec file-id base installed))
                                :status)
                     "committed"))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* human\n")
        (save-buffer))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes (concat installed "* human\n"))))
      (should (= (plist-get (gethash file-id brain--heads) :seq) 2)))))

;;; ---------------------------------------------------------------------------
;;; Stale disk, stale base, duplicate attempts, reentrancy
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-external-disk-change-is-attention-never-overwrite ()
  (brain-test--with-environment
    (let* ((file-id "org-files/External.org")
           (path (brain--file-path file-id))
           (base (brain-test--enroll file-id "* A\n"))
           (buffer (brain-test--visit file-id))
           (outside "* written by someone else\n"))
      (brain-test--write path outside)
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id base "* A\n* library\n"))))
        (should (equal (plist-get result :status) "attention"))
        (should (equal (plist-get result :reason) "disk_mismatch")))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes outside)))
      (with-current-buffer buffer
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) "* A\n")))
      (should (gethash file-id brain--attention)))))

(ert-deftest brain-test-stale-expected-revision-rejected ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Stale.org")
           (base (brain-test--enroll file-id "* A\n")))
      (should (equal (plist-get (brain-commit-file
                                 (brain-test--install-spec file-id base "* A\n* two\n"))
                                :status)
                     "committed"))
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id base "* A\n* three\n"))))
        (should (equal (plist-get result :status) "stale"))
        (should (equal (plist-get result :reason) "stale_base")))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes "* A\n* two\n"))))))

(ert-deftest brain-test-null-expected-does-not-overwrite-an-enrolled-file ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Null.org")
           (path (brain--file-path file-id)))
      (brain-test--enroll file-id "* human content\n")
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id nil
                                               "* remote replaced everything\n"))))
        (should (equal (plist-get result :status) "stale"))
        (should (equal (plist-get result :reason) "expected_required")))
      ;; No overwrite, no new revision.
      (should (equal (brain-test--read-bytes path)
                     (brain-test--bytes "* human content\n")))
      (should (= (plist-get (gethash file-id brain--heads) :seq) 0))
      ;; Null expected still creates a genuinely absent file.
      (let ((created (brain-commit-file
                      (brain-test--install-spec "org-files/Fresh.org" nil
                                                "* created\n"))))
        (should (equal (plist-get created :status) "committed"))
        (should (equal (brain-test--read-bytes (brain--file-path "org-files/Fresh.org"))
                       (brain-test--bytes "* created\n")))))))

(ert-deftest brain-test-refresh-invalidates-the-org-element-cache ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Elements.org")
           (text "* One\nbody\n* Two\nbody two\n")
           (base (brain-test--enroll file-id text))
           (buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        (org-mode)
        (goto-char (point-max))
        (org-element-at-point))
      (should (equal (plist-get (brain-commit-file
                                 (brain-test--install-spec
                                  file-id base
                                  "* Zero\nnew\n* One\nbody\n* Two\nbody two\n"))
                                :status)
                     "committed"))
      ;; The parser is asked about the refreshed text, not the old one, and the
      ;; mismatch must not surface as a *Warnings* buffer in the daemon.
      (with-current-buffer buffer
        (goto-char (point-max))
        (forward-line -1)
        (let ((element (org-element-at-point)))
          (should (eq (org-element-type element) 'paragraph))
          (should (= (org-element-property :begin element) (line-beginning-position)))))
      (should-not (get-buffer "*Warnings*")))))

(ert-deftest brain-test-projection-overflow-is-deferred-and-visible ()
  (brain-test--with-environment
    (let* ((brain-projection-max-bytes 200)
           (file-id "org-files/Big.org")
           (text (mapconcat (lambda (index)
                              (format "* Heading %d with a long title %s\n:PROPERTIES:\n:ID: id-%d\n:END:\n"
                                      index (make-string 40 ?x) index))
                            (number-sequence 1 20) "\n"))
           (bytes (brain-test--bytes text))
           (base (brain-test--enroll file-id "* small\n"))
           (attempt (brain--uuid))
           (payload (list (cons "v" 1)
                          (cons "type" "brain.install.request")
                          (cons "brain_id" brain-id)
                          (cons "attempt_id" attempt)
                          (cons "mutation_id" (brain--uuid))
                          (cons "file_id" file-id)
                          (cons "expected_revision" (brain--rev->json base))
                          (cons "object_hash" (brain--sha256 bytes))
                          (cons "byte_length" (length bytes)))))
      (brain--publish-object bytes (alist-get "object_hash" payload nil nil #'equal)
                             "hermes")
      (brain--handle-install-request payload)
      (let ((result (gethash attempt brain--results)))
        ;; The bytes are committed; only the derived manifest is deferred.
        (should (equal (plist-get result :status) "committed"))
        (should-not (plist-get result :semantic)))
      (should (gethash file-id brain--deferred))
      (should (equal (plist-get (gethash file-id brain--deferred) :reason)
                     "projection_overflow"))
      (should (= (plist-get (brain-status) :deferred) 1))
      (should (equal (plist-get (brain-status file-id) :file-deferred)
                     (gethash file-id brain--deferred)))
      (should (member "attention" (brain-test--journal-kinds)))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     bytes)))))

(ert-deftest brain-test-duplicate-attempt-returns-same-result ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Dupe.org")
           (base (brain-test--enroll file-id "* A\n"))
           (attempt (brain--uuid))
           (first (brain-commit-file
                   (brain-test--install-spec file-id base "* A\n* one\n"
                                             :attempt-id attempt)))
           (second (brain-commit-file
                    (brain-test--install-spec file-id base "* A\n* different\n"
                                              :attempt-id attempt))))
      (should (equal (plist-get first :status) "committed"))
      (should (equal (plist-get second :status) "committed"))
      (should (plist-get second :duplicate))
      (should (equal (plist-get second :new-revision) (plist-get first :new-revision)))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes "* A\n* one\n")))
      (should (= (plist-get (gethash file-id brain--heads) :seq) 1)))))

(ert-deftest brain-test-reentrant-commit-is-dirty ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Reenter.org")
           (base (brain-test--enroll file-id "* A\n"))
           (inner nil)
           (original (symbol-function 'brain--install-checks)))
      (unwind-protect
          (progn
            (fset 'brain--install-checks
                  (lambda (&rest _args)
                    (setq inner (brain-commit-file
                                 (brain-test--install-spec file-id base "* A\n* inner\n")))
                    (brain--result "attention" file-id :reason "stub")))
            (let ((outer (brain-commit-file
                          (brain-test--install-spec file-id base "* A\n* outer\n"))))
              (should (equal (plist-get outer :status) "attention"))
              (should (equal (plist-get inner :status) "dirty"))
              (should (equal (plist-get inner :reason) "reentrant"))))
        (fset 'brain--install-checks original))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes "* A\n"))))))

;;; ---------------------------------------------------------------------------
;;; The inbound dispatcher, and the wire spelling of an absent value
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-dispatcher-is-a-regular-timer-not-an-idle-one ()
  "The dispatcher must not be an idle timer.

A repeating idle timer runs at most once per idle period: Emacs re-arms it with
its `triggered' flag set, and only a NEW idle period (which needs real input)
clears that flag.  Live on 2026-10-31 the daemon had four such timers, all
marked triggered, with 105 gateway acks plus one install request still queued
and `brain--acked-seq' at 0 -- `emacsclient' is not input."
  (brain-test--with-environment
    (let ((regular (seq-filter (lambda (timer) (eq (timer--function timer)
                                                   #'brain-dispatch-once))
                               timer-list))
          (idle (seq-filter (lambda (timer) (eq (timer--function timer)
                                                #'brain-dispatch-once))
                            timer-idle-list)))
      (should (= (length regular) 1))
      (should-not idle)
      (should (timerp brain--dispatch-timer))
      (should (eq (timer--function brain--dispatch-timer) #'brain-dispatch-once)))
    (brain-disable)
    (should-not brain--dispatch-timer)
    (should-not (seq-filter (lambda (timer) (eq (timer--function timer)
                                                #'brain-dispatch-once))
                            timer-list))))

(ert-deftest brain-test-dispatcher-runs-without-user-input ()
  "A queued ack is consumed by the timer alone, with nobody at the keyboard.

This is the live defect read back as a test: the filter enqueues, and the timer
must drain the queue while Emacs sits idle.  Batch `sleep-for' runs regular
timers and never runs idle ones, which is exactly the unattended daemon."
  (brain-test--with-environment
    (brain--emit-event "emacs.online" (list (cons "epoch" 1)))
    (brain--emit-event "emacs.online" (list (cons "epoch" 2)))
    (should (= brain--wire-seq 2))
    (should (= (length brain--outbox) 2))
    (should (= brain--acked-seq 0))
    (brain--ipc-filter nil (brain-test--frame
                            (list (cons "v" brain-protocol-version)
                                  (cons "type" "brain.ack")
                                  (cons "brain_id" brain-id)
                                  (cons "peer_id" "hermes")
                                  (cons "through_seq" 2))))
    (should (= (length brain--inbox) 1))
    ;; No user input: only elapsed time.
    (sleep-for 0.6)
    (should (null brain--inbox))
    (should (= brain--acked-seq 2))
    (should-not brain--outbox)
    (let ((records (brain--journal-records "ack")))
      (should (= (length records) 1))
      (should (= (plist-get (car records) :through_seq) 2)))))

(ert-deftest brain-test-json-encodes-an-absent-value-as-null ()
  "An absent value is `null', never `{}'.

`json-serialize' reads a Lisp nil as the empty alist, so a nil value used to be
written `{}'.  The gateway refused exactly that for `client_epoch'
(`invalid_field: client_epoch must be a UUID string', live 2026-10-31), while a
JSON null is admissible for every nullable field."
  (should (equal (brain--json-encode nil) "null"))
  (should (equal (brain--json-encode (list (cons "client_epoch" nil)))
                 "{\"client_epoch\":null}"))
  ;; A JSON array (the `:json-array' marker) keeps its brackets, and a nil element inside it
  ;; is null too -- `brain--jsonify' recurses through the marker, so vectors never arrive raw.
  (should (equal (brain--json-encode (list (cons "a" (cons :json-array (list nil)))))
                 "{\"a\":[null]}"))
  (should-not (string-match-p "{}" (brain--json-encode
                                    (list (cons "base_revision" nil)
                                          (cons "client_epoch" nil)))))
  ;; `false' and the JSON array marker keep their own spellings.
  (should (equal (brain--json-encode (list (cons "a" :false))) "{\"a\":false}"))
  (should (equal (brain--json-encode (list (cons "a" (cons :json-array nil)))) "{\"a\":[]}")))

(ert-deftest brain-test-recovered-event-frame-keeps-the-null-spelling ()
  "A frame reloaded from the journal goes back on the wire as `null', not `{}'.

The live pre-epoch `brain.file.dirty' frame was journaled with a JSON null
`client_epoch', reloaded by `brain-recover' with a plain nil, and re-emitted as
`{}' -- the one frame of fifteen the deployed contract refused.  Reloading must
not change what the frame says."
  (brain-test--with-environment
    (let* ((payload (list (cons "v" brain-protocol-version)
                          (cons "type" "brain.event")
                          (cons "brain_id" brain-id)
                          (cons "peer_id" "mac")
                          (cons "event_id" "f1a2699f-0b75-441c-9ead-74f25b26f782")
                          (cons "seq" 1)
                          (cons "kind" "brain.file.dirty")
                          (cons "payload"
                                (list (cons "file_id"
                                            "org-roam/brain-acceptance-fixture.org")
                                      (cons "base_revision" :null)
                                      (cons "dirty_generation" 1)
                                      (cons "operation_id"
                                            "b240620c-c281-417d-80af-408e33d2e3c1")
                                      (cons "client_epoch" :null)))))
           ;; Exactly the line `brain--journal-write' writes for that event.
           (line (brain--json-encode
                  (brain--record->json
                   (list :local-seq 2 :kind "event" :at 1793417489 :wire_seq 1
                         :event_kind "brain.file.dirty"
                         :file_id "org-roam/brain-acceptance-fixture.org"
                         :payload payload)))))
      (should (string-match-p "\"client_epoch\":null" line))
      (should-not (string-match-p "{}" line))
      (brain-test--write (brain--journal-file) (concat line "\n"))
      (brain-recover)
      (should (= brain--wire-seq 1))
      (should (= (length brain--outbox) 1))
      (let* ((frame (car brain--outbox))
             (encoded (brain--json-encode frame))
             (body (alist-get "payload" frame nil nil #'equal)))
        (should (equal (alist-get "seq" frame nil nil #'equal) 1))
        (should-not (alist-get "client_epoch" body nil nil #'equal))
        (should-not (alist-get "base_revision" body nil nil #'equal))
        (should (string-match-p "\"client_epoch\":null" encoded))
        (should (string-match-p "\"base_revision\":null" encoded))
        (should-not (string-match-p "{}" encoded))))))

;;; ---------------------------------------------------------------------------
;;; Recovery: intent phases, autosave markers, restart
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-recovery-finishes-installed-intent ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Recover.org")
           (path (brain--file-path file-id))
           (text "* installed bytes\n")
           (revision (brain--rev 1 (brain--sha256 (brain-test--bytes text)))))
      (brain-test--write path text)
      (brain--journal-append "intent" :file_id file-id :operation_id (brain--uuid)
                             :prev_revision nil :new_revision revision
                             :object_hash (plist-get revision :sha256)
                             :origin "librarian" :phase "intent")
      ;; Simulate a cold start: everything in memory is gone.
      (brain-test--reset-state)
      (brain-recover)
      (should (equal (gethash file-id brain--heads) revision))
      (should (member "committed" (brain-test--journal-kinds)))
      (should-not (gethash file-id brain--attention)))))

(ert-deftest brain-test-recovery-keeps-uninstalled-intent-pending ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Pending.org")
           (path (brain--file-path file-id))
           (predecessor-text "* predecessor\n")
           (predecessor (brain--rev 1 (brain--sha256 (brain-test--bytes predecessor-text))))
           (revision (brain--rev 2 (brain--sha256 (brain-test--bytes "* new\n")))))
      (brain-test--write path predecessor-text)
      (brain--journal-append "intent" :file_id file-id :operation_id (brain--uuid)
                             :prev_revision predecessor :new_revision revision
                             :object_hash (plist-get revision :sha256)
                             :origin "librarian" :phase "intent")
      (brain-test--reset-state)
      (brain-recover)
      (should (null (gethash file-id brain--heads)))
      (should-not (gethash file-id brain--attention))
      (should-not (member "committed"
                          (mapcar (lambda (r) (plist-get r :kind))
                                  (brain--journal-records "committed"))))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes predecessor-text))))))

(ert-deftest brain-test-recovery-escalates-unknown-disk-state ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Unknown.org")
           (path (brain--file-path file-id))
           (revision (brain--rev 1 (brain--sha256 (brain-test--bytes "* intended\n")))))
      (brain-test--write path "* something else entirely\n")
      (brain--journal-append "intent" :file_id file-id :operation_id (brain--uuid)
                             :prev_revision nil :new_revision revision
                             :object_hash (plist-get revision :sha256)
                             :origin "librarian" :phase "intent")
      (brain-test--reset-state)
      (brain-recover)
      (should (equal (gethash file-id brain--attention) "recovery_mismatch"))
      (should (equal (brain-test--read-bytes path)
                     (brain-test--bytes "* something else entirely\n"))))))

(ert-deftest brain-test-autosave-marker-blocks-install ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Autosave.org")
           (path (brain--file-path file-id))
           (base (brain-test--enroll file-id "* A\n"))
           (autosave (brain--autosave-file file-id)))
      (brain-test--write autosave "* unsaved recovery text\n")
      (should (file-exists-p autosave))
      (let ((result (brain-commit-file
                     (brain-test--install-spec file-id base "* A\n* library\n"))))
        (should (equal (plist-get result :status) "dirty"))
        (should (equal (plist-get result :reason) "autosave_marker")))
      (should (equal (brain-test--read-bytes path) (brain-test--bytes "* A\n"))))))

(ert-deftest brain-test-revision-seq-survives-restart ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Restart.org")
           (buffer (progn (brain-test--write (brain--file-path file-id) "* A\n")
                          (brain-test--visit file-id))))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* first\n")
        (save-buffer))
      (let ((first (plist-get (gethash file-id brain--heads) :seq)))
        ;; Cold start: journal reloaded, seq never reset.
        (brain-test--restart)
        (should (= (plist-get (gethash file-id brain--heads) :seq) first))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* second\n")
          (save-buffer))
        (should (= (plist-get (gethash file-id brain--heads) :seq) (1+ first)))))))

(ert-deftest brain-test-heads-cache-rebuilt-from-journal ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Cache.org")
           (base (brain-test--enroll file-id "* A\n")))
      (brain-commit-file (brain-test--install-spec file-id base "* A\n* two\n"))
      (let ((heads (gethash file-id brain--heads)))
        ;; Corrupt the cache on disk; recovery must rebuild from the journal.
        (brain-test--write (brain--heads-file) "{\"version\":1,\"heads\":{\"bogus\":1}}")
        (brain-test--reset-state)
        (brain-recover)
        (should (equal (gethash file-id brain--heads) heads))))))

;;; ---------------------------------------------------------------------------
;;; Alternate routes
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-org-capture-into-managed-file-uses-the-primitive ()
  (brain-test--with-environment
    (require 'org-capture)
    (let* ((file-id "org-files/Capture.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* Inbox\n")
      (brain--enroll-baseline file-id path (brain--sha256-file path))
      (let ((before (plist-get (gethash file-id brain--heads) :seq))
            (org-capture-templates
             (list (list "t" "Task" 'entry (list 'file path)
                         "* TODO captured\n" :immediate-finish t))))
        (org-capture nil "t")
        ;; org-capture finalizes with `save-buffer', so the write must have gone
        ;; through the commit primitive rather than around it.
        (should (> (plist-get (gethash file-id brain--heads) :seq) before))
        (should (string-match-p "captured" (brain-test--read-bytes path)))
        (should (file-exists-p (brain--object-path
                                "mac" (plist-get (gethash file-id brain--heads) :sha256))))))))

(ert-deftest brain-test-org-save-all-org-buffers-uses-the-primitive ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Refile.org")
           (path (brain--file-path file-id))
           (buffer (progn (brain-test--write path "* One\n")
                          (brain-test--visit file-id))))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* refiled\n"))
      ;; The configured refile advice saves every Org buffer; that path must be
      ;; the primitive too.
      (org-save-all-org-buffers)
      (should (equal (brain-test--read-bytes path) (brain-test--bytes "* One\n* refiled\n")))
      (should (= (plist-get (gethash file-id brain--heads) :seq) 1)))))

(ert-deftest brain-test-write-region-to-managed-path-refused ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Guard.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* A\n")
      (should-error (write-region "* bypass\n" nil path)
                    :type 'brain-alternate-route)
      (should (equal (brain-test--read-bytes path) (brain-test--bytes "* A\n"))))))

(ert-deftest brain-test-rename-and-delete-refused ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Guarded.org")
           (path (brain--file-path file-id))
           (target (expand-file-name "org-files/Other.org" brain-test--root)))
      (brain-test--write path "* A\n")
      (should-error (rename-file path target) :type 'brain-alternate-route)
      (should-error (delete-file path) :type 'brain-alternate-route)
      (should (file-exists-p path)))))

(ert-deftest brain-test-save-as-into-managed-root-refused ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Edit.org")
           (path (brain--file-path file-id))
           (buffer nil))
      (brain-test--write path "* A\n")
      (setq buffer (brain-test--visit file-id))
      (with-current-buffer buffer
        (should-error (set-visited-file-name
                       (expand-file-name "org-files/Copied.org" brain-test--root))
                      :type 'brain-alternate-route))
      (should-not (file-exists-p (expand-file-name "org-files/Copied.org"
                                                   brain-test--root))))))

(ert-deftest brain-test-babel-tangle-into-managed-root-refused ()
  (brain-test--with-environment
    (let* ((target (expand-file-name "org-files/Tangled.org" brain-test--root))
           (source (expand-file-name "tangle-source.org" brain-test--root)))
      (brain-test--write source
                         (format "#+begin_src emacs-lisp :tangle %s\n(message \"x\")\n#+end_src\n"
                                 target))
      (let ((result (condition-case err
                        (progn (org-babel-tangle-file source) 'tangled)
                      (error (car err)))))
        (should (eq result 'brain-alternate-route)))
      (should-not (file-exists-p target)))))

(ert-deftest brain-test-auto-revert-cannot-mutate-managed-buffer ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Revert.org")
           (path (brain--file-path file-id))
           (outside (expand-file-name "outside.org" brain-test--root))
           (managed nil))
      (brain-test--write path "* original\n")
      (brain-test--write outside "* outside\n")
      (setq managed (brain-test--visit file-id))
      (let ((unmanaged (find-file-noselect outside)))
        (with-current-buffer unmanaged (auto-revert-mode 1))
        (with-current-buffer managed (auto-revert-mode 1))
        (brain-test--write path "* changed on disk\n")
        (brain-test--write outside "* changed outside\n")
        ;; Global auto-revert reverts the unmanaged buffer, never the managed one.
        (with-current-buffer unmanaged (auto-revert-handler))
        (with-current-buffer managed (auto-revert-handler))
        (with-current-buffer unmanaged
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "* changed outside\n")))
        (with-current-buffer managed
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "* original\n")))
        (kill-buffer unmanaged)))))

(ert-deftest brain-test-setup-disables-auto-revert-in-managed-buffer ()
  (brain-test--with-environment
    (let* ((file-id "org-files/NoRevert.org")
           (path (brain--file-path file-id))
           (buffer nil))
      (brain-test--write path "* original\n")
      (setq buffer (brain-test--visit file-id))
      (with-current-buffer buffer
        (auto-revert-mode 1)
        (should (bound-and-true-p auto-revert-mode)))
      ;; Re-running the managed-buffer setup turns it back off.
      (with-current-buffer buffer
        (brain--setup-buffer)
        (should-not (bound-and-true-p auto-revert-mode))))))

;;; ---------------------------------------------------------------------------
;;; Offline saves, outbox and durable replay
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-offline-save-journals-outbox-until-ack ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Offline.org")
           (path (brain--file-path file-id))
           (buffer nil))
      (brain-test--write path "* A\n")
      (setq buffer (brain-test--visit file-id))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* offline\n")
        (save-buffer))
      ;; No node connection: the save still committed and the events are durable.
      (should (equal (brain-test--read-bytes path) (brain-test--bytes "* A\n* offline\n")))
      (should (= brain--wire-seq 2))                 ; dirty + saved
      (should (= (length brain--outbox) 2))
      ;; Ack through seq 1 only: the second event stays pending.
      (brain--handle-ack (list (cons "through_seq" 1)))
      (should (= brain--acked-seq 1))
      (should (= (length brain--outbox) 1))
      ;; Cold start replays the unacknowledged event with its original seq.
      (let ((pending-seq (alist-get "seq" (car brain--outbox) nil nil #'equal)))
        (brain-test--restart)
        (should (= (length brain--outbox) 1))
        (should (= (alist-get "seq" (car brain--outbox) nil nil #'equal) pending-seq))
        (should (equal (alist-get "kind" (car brain--outbox) nil nil #'equal)
                       "brain.file.saved")))
      (should (= brain--wire-seq 2)))))

(ert-deftest brain-test-outbox-seq-is-contiguous-and-distinct ()
  (brain-test--with-environment
    (let ((first-file "org-files/SeqA.org")
          (second-file "org-files/SeqB.org"))
      (let ((revision (brain-test--enroll first-file "* A\n")))
        (brain-commit-file (brain-test--install-spec first-file revision "* A\n* two\n")))
      (let ((revision (brain-test--enroll second-file "* B\n")))
        (brain-commit-file (brain-test--install-spec second-file revision "* B\n* two\n")))
      ;; Two files each reach revision seq 1, while the wire seq stays one
      ;; contiguous stream.
      (should (= (plist-get (gethash first-file brain--heads) :seq) 1))
      (should (= (plist-get (gethash second-file brain--heads) :seq) 1))
      (let ((events (seq-filter (lambda (record) (equal (plist-get record :kind) "event"))
                                brain--journal))
            (seqs nil))
        (dolist (event events)
          (push (plist-get event :wire_seq) seqs))
        (setq seqs (nreverse seqs))
        (should (= (length seqs) 2))
        (should (equal seqs (number-sequence 1 (length seqs))))))))

;;; ---------------------------------------------------------------------------
;;; The shared object namespace
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-object-path-matches-the-gateway-object-store-layout ()
  "The Mac and the gateway must name one file for one digest.
The reviewed gateway store publishes and reads
`<state_root>/transport/objects/<producer>/<sha256>.org' (`store.py',
`ObjectStore'), and the reviewed deployment declares the same producer
namespaces.  The transport directory is the synced root, so the Mac half has to
write `objects/<producer>/<sha>.org' inside it: with a different namespace
Syncthing delivers bytes the store can never see (`objects.exists' false,
`confirm_commit_bytes' never satisfiable)."
  (brain-test--with-environment
    (let* ((text "* object\n")
           (bytes (brain-test--bytes text))
           (digest (brain--sha256 bytes))
           (transport (brain--transport-dir))
           (mac-path (brain--object-path "mac" digest))
           (hermes-path (brain--object-path "hermes" digest)))
      ;; The exact relative path the Python ObjectStore builds.
      (should (equal (file-relative-name mac-path transport)
                     (concat "objects/mac/" digest ".org")))
      (should (equal (file-relative-name hermes-path transport)
                     (concat "objects/hermes/" digest ".org")))
      ;; The transport directory is `transport/' beneath the private state dir.
      (should (equal transport (expand-file-name "transport/" brain-test--state)))
      ;; Publishing writes exactly there, and the same namespace reads it back.
      (brain--publish-object bytes digest)
      (should (file-regular-p mac-path))
      (should (equal (brain-test--read-bytes mac-path) bytes))
      (should (equal (brain--read-object "mac" digest (length bytes)) bytes))
      ;; A digest that was never published is not found anywhere else either.
      (should-not (file-exists-p (expand-file-name (concat "mac/" digest ".org")
                                                   transport))))))

;;; ---------------------------------------------------------------------------
;;; Snapshots, inventory and projection
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-snapshot-enrols-target-without-opening-a-buffer ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Snap.org")
           (path (brain--file-path file-id))
           (text "* snapshot me\n"))
      (brain-test--write path text)
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let ((revision (gethash file-id brain--heads)))
        (should (= (plist-get revision :seq) 0))
        (should (equal (plist-get revision :sha256) (brain--sha256-file path))))
      (should-not (get-file-buffer path))
      (should (file-exists-p (brain--object-path "mac" (brain--sha256-file path))))
      (let ((payload (brain-test--last-event-payload)))
        (should (equal (alist-get "result" payload nil nil #'equal) "present"))))))

(ert-deftest brain-test-snapshot-of-dirty-target-reports-lease ()
  (brain-test--with-environment
    (let* ((file-id "org-files/SnapDirty.org")
           (path (brain--file-path file-id))
           (buffer nil))
      (brain-test--write path "* disk\n")
      (setq buffer (brain-test--visit file-id))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* unsaved\n"))
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let* ((payload (brain-test--last-event-payload)))
        (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
        (should (alist-get "dirty_generation" payload nil nil #'equal)))
      ;; The unsaved text was never published.
      (should-not (file-directory-p (file-name-directory
                                     (brain--object-path "mac" "x")))))))

(ert-deftest brain-test-inventory-page-is-bounded-and-bodyless ()
  (brain-test--with-environment
    (dolist (name '("A.org" "B.org" "C.org"))
      (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                         (concat "* " name "\n")))
    (brain--handle-snapshot-request
     (list (cons "v" 1) (cons "type" "brain.snapshot.request")
           (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
           (cons "limit" 2)))
    (let* ((events (seq-filter (lambda (record)
                                 (and (equal (plist-get record :kind) "event")
                                      (equal (plist-get record :event_kind)
                                             "brain.file.snapshot")))
                               brain--journal))
           (final (alist-get "payload"
                             (plist-get (car (last events)) :payload) nil nil #'equal)))
      (should (= (length events) 3))        ; two targets + page end
      (should (equal (alist-get "file_id" final nil nil #'equal) "org-files/B.org"))
      (should (eq (alist-get "done" final nil nil #'equal) t))
      (should (equal (alist-get "continuation" final nil nil #'equal)
                     "org-files/C.org"))
      ;; No object was published by the inventory page itself.
      (should-not (file-exists-p (brain--object-path "mac"
                                                     (brain--sha256-file
                                                      (expand-file-name "org-files/A.org"
                                                                        brain-test--root))))))))

(ert-deftest brain-test-projection-is-bounded-and-derived-from-bytes ()
  (brain-test--with-environment
    (let* ((text (concat "* TODO Task\n:PROPERTIES:\n:ID: abc-123\n:PROJECT: companion-link\n:KANBAN_BOARD: companion\n:KANBAN_ASSIGNEE: coder\n:END:\nbody\n"
                         "* Project\n:PROPERTIES:\n:ID: p-1\n:BRAIN_KIND: project\n:END:\n"))
           (semantic (brain--projection (brain-test--bytes text)
                                        "org-files/Proj.org" (brain--rev 0 "a")))
           (headings (cdr (alist-get "headings" semantic nil nil #'equal))))
      (should semantic)
      (should (= (length headings) 2))
      (should (equal (alist-get "todo" (nth 0 headings) nil nil #'equal) "TODO"))
      (should (equal (alist-get "id" (nth 0 headings) nil nil #'equal) "abc-123"))
      (should (equal (alist-get "kanban_assignee" (nth 0 headings) nil nil #'equal)
                     "coder"))
      (should (equal (alist-get "brain_kind" (nth 1 headings) nil nil #'equal)
                     "project"))
      (should (<= (length (encode-coding-string (brain--json-encode semantic) 'utf-8))
                  brain-projection-max-bytes)))))

(ert-deftest brain-test-projection-overflow-is-dropped-not-truncated ()
  (brain-test--with-environment
    (let* ((brain-projection-max-bytes 200)
           (text (mapconcat (lambda (index)
                              (format "* Heading %d with a long title %s\n:PROPERTIES:\n:ID: id-%d\n:END:\n"
                                      index (make-string 40 ?x) index))
                            (number-sequence 1 20) "\n"))
           (semantic (brain--projection (brain-test--bytes text)
                                        "org-files/Big.org" (brain--rev 0 "a"))))
      (should (null semantic)))))

;;; ---------------------------------------------------------------------------
;;; Quiet behaviour, hooks and status
;;; ---------------------------------------------------------------------------

(ert-deftest brain-test-no-messages-no-buffer-creation ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Quiet.org")
           (base (brain-test--enroll file-id "* A\n"))
           (messages nil)
           (frames nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args)
                   (push (apply #'format args) messages)
                   nil))
                ((symbol-function 'x-create-frame)
                 (lambda (&rest args) (push args frames) nil)))
        (should (equal (plist-get (brain-commit-file
                                   (brain-test--install-spec file-id base "* A\n* quiet\n"))
                                  :status)
                       "committed")))
      (should (null messages))
      (should (null frames)))))

(ert-deftest brain-test-mode-line-is-quiet-when-synchronized ()
  (brain-test--with-environment
    (let ((process (start-process "brain-test-live" nil "sleep" "5")))
      (unwind-protect
          (progn
            (setq brain--ipc process)
            (should (eq (plist-get (brain-status) :state) 'synchronized))
            (should (equal (brain-mode-line-string) "")))
        (delete-process process)
        (setq brain--ipc nil)))
    (should (eq (plist-get (brain-status) :state) 'offline))))

(ert-deftest brain-test-status-reports-attention-and-dirty ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Status.org")
           (base (brain-test--enroll file-id "* A\n")))
      (brain-commit-file (brain-test--install-spec file-id base "* A\n* ok\n"))
      (should (eq (plist-get (brain-status) :state) 'offline))
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* pending\n"))
        (should (eq (plist-get (brain-status) :state) 'waiting-dirty))
        (should (equal (brain-mode-line-string) " Brain:dirty")))
      (puthash "org-files/Status.org" "disk_mismatch" brain--attention)
      (should (eq (plist-get (brain-status) :state) 'attention))
      (should (equal (brain-mode-line-string) " Brain:attn")))))

(ert-deftest brain-test-major-mode-restart-keeps-save-path-and-lease ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Restart.org")
           (path (brain--file-path file-id))
           (text "#+TODO: TODO DONE\n* A\n"))
      (brain-test--write path text)
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (org-mode)
          ;; C-c C-c on a #+ line restarts the major mode, which kills the
          ;; buffer-local hooks; the save path and the lease must survive it.
          (org-mode-restart)
          (should (memq #'brain-write-contents-handler write-contents-functions))
          (should (memq #'brain--before-change-guard before-change-functions))
          (goto-char (point-max))
          (insert "* B\n")
          (should (gethash file-id brain--dirty))
          (save-buffer)
          (should-not (buffer-modified-p)))
        (should (equal (brain-test--read-bytes path)
                       (brain-test--bytes "#+TODO: TODO DONE\n* A\n* B\n")))))))

(ert-deftest brain-test-human-save-runs-after-save-hook-once ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Once.org")
           (path (brain--file-path file-id))
           (count 0))
      (brain-test--write path "* A\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (add-hook 'after-save-hook (lambda () (setq count (1+ count))) nil t)
          (goto-char (point-max))
          (insert "* B\n")
          (save-buffer)))
      ;; The handler commits; `basic-save-buffer' runs `after-save-hook' once.
      (should (= count 1))
      (should (equal (brain-test--read-bytes path)
                     (brain-test--bytes "* A\n* B\n"))))))

(ert-deftest brain-test-after-save-hook-runs-once-and-not-inside-the-section ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Hooks.org")
           (base (brain-test--enroll file-id "* A\n"))
           (buffer (brain-test--visit file-id))
           (save-count 0)
           (change-count 0))
      (with-current-buffer buffer
        (add-hook 'after-save-hook (lambda () (setq save-count (1+ save-count))) nil t)
        (add-hook 'after-change-functions
                  (lambda (&rest _) (setq change-count (1+ change-count))) nil t))
      (brain-commit-file (brain-test--install-spec file-id base "* A\n* refreshed\n"))
      ;; The derived-index hook ran once, after the commit; no modification hook
      ;; fired while the text was being replaced.
      (should (= save-count 1))
      (should (= change-count 0)))))

;;; ---------------------------------------------------------------------------
;;; Managed saves under the live org-roam configuration
;;; ---------------------------------------------------------------------------
;;
;; `Emacs.org' enables `org-roam-db-autosync-mode' before the Brain module is
;; loaded, so `rename-file' carries org-roam's advice first and brain's own
;; guard wraps around it.  Both orders are exercised below: a replace that
;; peels only one advice layer passes the opposite order (autosync enabled
;; after `brain-enable') and still fires org-roam's advice in the live one.

(defun brain-test--assert-managed-human-save-never-asks ()
  "Save an existing and a brand-new managed roam file, asserting silence.
Each save must install exactly the reviewed bytes, leave the buffer clean and
its visited-file state consistent, and leave the derived index on the bytes
that are on disk.  Any question reaching `yes-or-no-p' is a failure: in a
daemon with no user at the keyboard it blocks forever, and answering no becomes
`attention: commit_error:user-error'.  Runs inside
`brain-test--with-environment' with `org-roam-db-autosync-mode' live."
  ;; 1. A file that already exists on disk.
  (let* ((file-id "org-roam/Existing.org")
         (path (brain--file-path file-id))
         (text "* Existing\n")
         (asked nil))
    (brain-test--write path text)
    (let ((buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        ;; The live hook, not a stand-in, must be the one installed.
        (should (memq #'org-roam-db-autosync--try-update-on-save-h after-save-hook))
        (goto-char (point-max))
        (insert "* edited\n")
        (setq asked (brain-test--call-without-questions #'save-buffer))
        (should-not asked)
        (should-not (buffer-modified-p))
        (should (verify-visited-file-modtime buffer))))
    (should (equal (brain-test--read-bytes path)
                   (brain-test--bytes (concat text "* edited\n"))))
    (should (equal (plist-get (gethash file-id brain--heads) :sha256)
                   (brain--sha256-file path)))
    ;; The derived index was refreshed from the installed bytes.
    (should (equal (brain-test--roam-db-hash path) (org-roam-db--file-hash path))))
  ;; 2. A brand-new file: the buffer visits a path that does not exist yet.
  (let* ((file-id "org-roam/Brand.org")
         (path (brain--file-path file-id))
         (asked nil))
    (should-not (file-exists-p path))
    (let ((buffer (brain-test--visit file-id)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "* Brand new\n")
        (setq asked (brain-test--call-without-questions #'save-buffer))
        (should-not asked)
        (should-not (buffer-modified-p))
        (should (verify-visited-file-modtime buffer))))
    (should (equal (brain-test--read-bytes path) (brain-test--bytes "* Brand new\n")))
    (should (file-exists-p (brain--object-path "mac" (brain--sha256-file path))))
    (should (equal (brain-test--roam-db-hash path) (org-roam-db--file-hash path)))))

(defun brain-test--assert-remote-install-refreshes-index ()
  "Install a remote commit into a visited roam file and check the index.
The `rename-file' advice that used to run inside the replace indexed the
visiting buffer's *pre-install* text (and recorded the new file's hash, so the
cache looked current while it was stale).  The commit must refresh the index
itself, from the bytes it installed, and ask no question.  Runs inside
`brain-test--with-environment' with `org-roam-db-autosync-mode' live."
  (let* ((file-id "org-roam/Remote.org")
         (path (brain--file-path file-id))
         (base nil)
         (buffer nil)
         (result nil)
         (asked nil)
         (installed "#+title: installed\n* from gateway\n"))
    (brain-test--write path "#+title: base\n* base\n")
    (setq base (brain--enroll-baseline file-id path (brain--sha256-file path)))
    (setq buffer (brain-test--visit file-id))
    (with-current-buffer buffer
      (should (memq #'org-roam-db-autosync--try-update-on-save-h after-save-hook))
      ;; The live daemon already has these bytes indexed.
      (org-roam-db-update-file path))
    (should (equal (brain-test--roam-file-title path) "base"))
    (setq asked
          (brain-test--call-without-questions
           (lambda ()
             (setq result (brain-commit-file
                           (brain-test--install-spec file-id base installed))))))
    (should-not asked)
    (should (equal (plist-get result :status) "committed"))
    (should (equal (brain-test--read-bytes path) (brain-test--bytes installed)))
    (with-current-buffer buffer
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     installed))
      (should-not (buffer-modified-p))
      (should (verify-visited-file-modtime buffer)))
    ;; The index follows the installed bytes, not the replaced ones.
    (should (equal (brain-test--roam-file-title path) "installed"))
    (should (equal (brain-test--roam-db-hash path) (org-roam-db--file-hash path)))))

(ert-deftest brain-test-human-save-under-org-roam-autosync-never-asks ()
  "A managed save must never reach the prompt `basic-save-buffer' asks.
`org-roam-db-autosync-mode' advises `rename-file'; the advice re-saves the
buffer visiting the replaced path, and while brain is replacing the file that
nested save used to ask whether to save a file that changed since it was
visited -- which blocks a daemon with no user at the keyboard, and answering
no turned every save into `attention: commit_error:user-error' (observed live
on the Mac, 2026-10-31).  A new file and an existing file must both save
through `brain-write-contents-handler' with no question at all.

This is the order a test gets by enabling autosync after `brain-enable':
org-roam's advice is outermost.  The live order is covered by
`brain-test-human-save-under-live-advice-order-never-asks'."
  (brain-test--with-environment
    (brain-test--with-org-roam-autosync
      (let ((layers (brain-test--rename-advice-layers)))
        (should (memq 'org-roam-db-autosync--rename-file-a layers))
        (should (memq 'brain-guard-rename-file layers))
        (should (eq (car layers) 'org-roam-db-autosync--rename-file-a)))
      (brain-test--assert-managed-human-save-never-asks))))

(ert-deftest brain-test-human-save-under-live-advice-order-never-asks ()
  "The live load order: autosync enabled before `brain-enable'.
That puts brain's own guard outermost and org-roam's advice underneath it, so
a replace that peels a single advice layer removes the guard and leaves
org-roam's advice running inside the no-yield section -- which is exactly the
live defect.  Both an existing and a brand-new file must save without a
question."
  (brain-test--with-live-advice-order
    (let ((layers (brain-test--rename-advice-layers)))
      (should (eq (car layers) 'brain-guard-rename-file))
      (should (memq 'org-roam-db-autosync--rename-file-a layers)))
    (brain-test--assert-managed-human-save-never-asks)))

(ert-deftest brain-test-remote-install-refreshes-the-derived-index ()
  "A remote install must leave the org-roam cache on the installed bytes.
Covers the order where autosync is enabled after `brain-enable'; the live order
is covered by
`brain-test-remote-install-under-live-advice-order-refreshes-the-index'."
  (brain-test--with-environment
    (brain-test--with-org-roam-autosync
      (should (memq 'org-roam-db-autosync--rename-file-a
                    (brain-test--rename-advice-layers)))
      (brain-test--assert-remote-install-refreshes-index))))

(ert-deftest brain-test-remote-install-under-live-advice-order-refreshes-the-index ()
  "The same install under the live advice order: brain's guard outermost."
  (brain-test--with-live-advice-order
    (should (eq (car (brain-test--rename-advice-layers)) 'brain-guard-rename-file))
    (brain-test--assert-remote-install-refreshes-index)))

(ert-deftest brain-test-hook-error-does-not-lose-instrumentation ()
  (brain-test--with-environment
    (let* ((file-id "org-files/HookErr.org")
           (buffer nil))
      (brain-test--write (brain--file-path file-id) "* A\n")
      (setq buffer (brain-test--visit file-id))
      (with-current-buffer buffer
        (should (memq #'brain--before-change-guard before-change-functions))
        (cl-letf (((symbol-function 'brain--note-first-edit)
                   (lambda () (error "instrumentation failure"))))
          (goto-char (point-max))
          (insert "* edit\n")
          (should (buffer-modified-p)))
        ;; The shim swallowed the error, so Emacs never removed it.
        (should (memq #'brain--before-change-guard before-change-functions))))))

(ert-deftest brain-test-hooks-removed-when-disabled ()
  (brain-test--with-environment
    (let* ((file-id "org-files/Disabled.org"))
      (brain-test--write (brain--file-path file-id) "* A\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (should (memq #'brain-write-contents-handler write-contents-functions))))
      (brain-disable)
      (let ((buffer (get-file-buffer (brain--file-path file-id))))
        (with-current-buffer buffer
          (should-not (memq #'brain-write-contents-handler write-contents-functions))))
      ;; Guards are inert while disabled: the file can be written directly.
      (write-region "* direct\n" nil (brain--file-path file-id))
      (should (equal (brain-test--read-bytes (brain--file-path file-id))
                     (brain-test--bytes "* direct\n"))))))

;;; ---------------------------------------------------------------------------
;;; Node IPC endpoint, private directories and reconnection (B7 §13.3)
;;; ---------------------------------------------------------------------------

(defvar brain-test--node nil
  "The scripted node listener of the current test.")

(defun brain-test--frames-decode (bytes)
  "Split BYTES into complete frames; return (FRAMES . LEFTOVER-BYTES)."
  (let ((frames nil) (offset 0) (done nil))
    (while (not done)
      (if (< (- (length bytes) offset) 4)
          (setq done t)
        (let ((length (logior (ash (aref bytes offset) 24)
                              (ash (aref bytes (+ offset 1)) 16)
                              (ash (aref bytes (+ offset 2)) 8)
                              (aref bytes (+ offset 3)))))
          (if (< (- (length bytes) offset) (+ 4 length))
              (setq done t)
            (let ((body (substring bytes (+ offset 4) (+ offset 4 length))))
              (push (brain--json-decode (decode-coding-string body 'utf-8)) frames)
              (setq offset (+ offset 4 length)))))))
    (cons (nreverse frames) (substring bytes offset))))

(defun brain-test--node-receive (chunk)
  "Record the frames CHUNK carries: the real client framing, decoded."
  (setq brain-test--node
        (plist-put brain-test--node :bytes
                   (concat (plist-get brain-test--node :bytes) (brain--unibyte chunk))))
  (let ((decoded (brain-test--frames-decode (plist-get brain-test--node :bytes))))
    (setq brain-test--node (plist-put brain-test--node :bytes (cdr decoded)))
    (when (car decoded)
      (setq brain-test--node
            (plist-put brain-test--node :frames
                       (append (plist-get brain-test--node :frames) (car decoded)))))))

(defun brain-test--node-start (path)
  "A real local listener standing in for the node on PATH."
  (setq brain-test--node (list :path path :bytes "" :frames nil :process nil))
  (setq brain-test--node
        (plist-put brain-test--node :process
                   (make-network-process
                    :name "brain-test-node" :server t :family 'local :service path
                    :coding 'binary :noquery t
                    :filter (lambda (_process chunk) (brain-test--node-receive chunk)))))
  (plist-get brain-test--node :process))

(defun brain-test--node-stop ()
  "Kill the scripted node; its socket file is left behind, like a crashed node."
  (let ((process (plist-get brain-test--node :process)))
    (when (processp process)
      (ignore-errors (delete-process process))))
  (setq brain-test--node (plist-put brain-test--node :process nil)))

(defun brain-test--node-drop-connection ()
  "Close the accepted connection, which is what a node restart does to the client's IPC.
A local server in Emacs keeps each accepted connection as its own process (`NAME <N>')."
  (dolist (process (process-list))
    (when (and (process-live-p process)
               (string-prefix-p "brain-test-node <" (process-name process)))
      (delete-process process))))

(defun brain-test--node-frames (&optional type)
  (let ((frames (plist-get brain-test--node :frames)))
    (if type
        (seq-filter (lambda (frame)
                      (equal (alist-get "type" frame nil nil #'equal) type))
                    frames)
      frames)))

(defun brain-test--node-forget ()
  "Drop the frames recorded so far: what the *new* node process received is the subject."
  (setq brain-test--node (plist-put brain-test--node :frames nil)))

(defun brain-test--wait-for (predicate &optional timeout)
  "Wait up to TIMEOUT for PREDICATE, pumping process output (batch has no event loop)."
  (let ((deadline (+ (float-time) (or timeout 2.0))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(ert-deftest brain-test-ipc-connect-accepts-a-real-node-socket ()
  "The node endpoint is a socket even though `file-attributes' says its type is nil.
The reviewed test required `(eq (car (file-attributes SOCKET 'string)) 'socket)',
which is nil for a real 0600 socket on this Emacs/OS, so the client logged
`node endpoint is not a socket' and stayed offline forever."
  (let* ((root (make-temp-file "brain-ipc-" t))
         (socket (expand-file-name "ipc/node.sock" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory socket) t)
          (brain-test--node-start socket)
          (let ((attributes (file-attributes socket)))
            ;; The premise of the defect, asserted on the real socket this OS creates.
            (should (null (car attributes)))
            (should-not (eq (car attributes) 'socket)))
          (let ((brain-node-socket socket)
                (brain--ipc nil)
                (brain--reconnect-timer nil))
            (unwind-protect
                (progn
                  (should (brain--ipc-connect))
                  (should (process-live-p brain--ipc))
                  (should (plist-get (brain-status) :connected))
                  (should (brain--unix-socket-p (file-attributes socket))))
              (when (process-live-p brain--ipc) (delete-process brain--ipc))
              (setq brain--ipc nil)))
          ;; Both refusals survive: a symlink and a plain file are never endpoints.
          (let ((link (expand-file-name "ipc/link.sock" root))
                (plain (expand-file-name "ipc/plain.sock" root)))
            (make-symbolic-link socket link)
            (write-region "not a socket" nil plain nil 'no-message)
            (dolist (candidate (list link plain))
              (let ((brain-node-socket candidate)
                    (brain--ipc nil))
                (should-not (brain--ipc-connect))
                (should-not brain--ipc)))))
      (brain-test--node-stop)
      (delete-directory root t))))

(ert-deftest brain-test-enable-creates-private-brain-directories ()
  "`brain-enable' creates state/journal/ipc 0700, which the node requires.
`BrainIPC.prepareEndpoint' refuses an endpoint directory with any group/other
bit; `make-directory' alone left them 0755 (the process umask)."
  (brain-test--with-environment
    (dolist (directory (list (brain--state-dir) (brain--journal-dir) (brain--ipc-dir)))
      (should (file-directory-p directory))
      (should (equal (logand (file-modes directory) #o077) 0)))))

(ert-deftest brain-test-ipc-reconnects-and-resubscribes-after-the-node-restarts ()
  "A node restart reconnects and resubscribes with the same client epoch.
Without the bounded reconnect the client stayed `:connected nil :state offline'
until a manual `brain-disable'/`brain-enable'."
  (let* ((root (make-temp-file "brain-ipc-reconnect-" t))
         (state (expand-file-name "state/" root))
         (org-files (expand-file-name "org-files/" root))
         (org-roam (expand-file-name "org-roam/" root))
         (socket (expand-file-name "ipc/node.sock" state)))
    (unwind-protect
        (progn
          (make-directory org-files t)
          (make-directory org-roam t)
          (make-directory (file-name-directory socket) t)
          (let ((brain-id "11111111-1111-4111-8111-111111111111")
                (brain-writer-id "22222222-2222-4222-8222-222222222222")
                (brain-managed-roots (list (cons "org-files" org-files)
                                           (cons "org-roam" org-roam)))
                (brain-state-directory state)
                (brain-transport-directory nil)
                (brain-node-socket socket)
                (brain-fsync-enabled nil)
                (brain-reconnect-interval 0.05))
            (brain-test--reset-state)
            (brain-test--node-start socket)
            (unwind-protect
                (progn
                  (brain-enable)
                  (should (brain-test--wait-for
                           (lambda () (brain-test--node-frames "brain.client.ready"))))
                  (let ((epoch brain--client-epoch))
                    (should epoch)
                    (should (equal (alist-get "client_epoch"
                                              (car (brain-test--node-frames "brain.subscribe"))
                                              nil nil #'equal)
                                   epoch))
                    ;; The node restarts: the connection goes away, the endpoint goes away, the
                    ;; endpoint comes back. No manual `brain-disable'/`brain-enable' anywhere.
                    (brain-test--node-drop-connection)
                    (brain-test--node-stop)
                    (delete-file socket)
                    (should (brain-test--wait-for
                             (lambda () (not (plist-get (brain-status) :connected)))))
                    (brain-test--node-forget)
                    (brain-test--node-start socket)
                    (should (brain-test--wait-for
                             (lambda () (brain-test--node-frames "brain.client.ready"))))
                    (let ((subscribe (car (brain-test--node-frames "brain.subscribe")))
                          (ready (car (brain-test--node-frames "brain.client.ready"))))
                      (should subscribe)
                      (should ready)
                      ;; The node clears its reconciliation flag on subscribe and only routes
                      ;; installs again for a ready carrying that same epoch.
                      (should (equal (alist-get "client_epoch" subscribe nil nil #'equal) epoch))
                      (should (equal (alist-get "client_epoch" ready nil nil #'equal) epoch)))
                    (should (plist-get (brain-status) :connected))
                    (should brain--reconciled)))
                (brain-disable))
            )
            )
      (brain-test--node-stop)
      (delete-directory root t))))

(provide 'brain-test)
;;; brain-test.el ends here
;;; ---------------------------------------------------------------------------
;;; E2: corpus census, snapshots, history and the query profile
;;; (design t_c52859ca v2 §2/§3/§4)
;;; ---------------------------------------------------------------------------
;;
;; Everything below drives REAL temporary roots and REAL buffers.  Nothing is
;; stubbed: the census walks a real directory tree, the guards read real files and
;; real modified buffers, the history is read from the real journal, and the
;; profile is built from real Org configuration.  The shared fixture
;; `tests/fixtures/eligibility.json' is the same file the Python side reads, so a
;; divergence between the two implementations fails here rather than in
;; production.

(defvar brain-test--directory
  (file-name-directory (or load-file-name buffer-file-name
                           (expand-file-name "brain-test.el")))
  "Directory this suite was loaded from, captured at load time.
`load-file-name' is nil while ERT runs the tests, so the fixture path cannot be
computed lazily.")

(defun brain-test--fixture-path ()
  "Return the shared fixture's path, wherever this suite was installed.
The suite is loaded from two layouts: a flat directory during development
(`<dir>/brain-test.el' with `<dir>/tests/fixtures/') and the installed layout
(`.emacs.d/tests/brain-test.el' with `.emacs.d/tests/fixtures/').  Both are tried
rather than assumed, so a moved file cannot silently skip the cross-language
check."
  (let ((candidates (list (expand-file-name "tests/fixtures/eligibility.json"
                                            brain-test--directory)
                          (expand-file-name "fixtures/eligibility.json"
                                            brain-test--directory))))
    (seq-find #'file-exists-p candidates)))

(defvar brain-test--fixture-cache nil
  "Parsed `eligibility.json', loaded once per suite.")

(defun brain-test--fixture ()
  "Return the shared eligibility fixture as a Lisp alist tree."
  (unless brain-test--fixture-cache
    (let ((path (brain-test--fixture-path)))
      (unless path
        (ert-skip (format "shared fixture is not installed beside %s"
                          brain-test--directory)))
      (with-temp-buffer
        (set-buffer-multibyte t)
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents path))
        (setq brain-test--fixture-cache
              (brain--json-decode (buffer-substring-no-properties
                                   (point-min) (point-max)))))))
  brain-test--fixture-cache)

(defun brain-test--fixture-list (key)
  "Return KEY's value from the fixture as a list of alists."
  (alist-get key (brain-test--fixture) nil nil #'equal))

(defun brain-test--write-tree (spec)
  "Create SPEC, an alist of relative path -> text, beneath `brain-test--root'.
A nil value creates a directory.  Paths are relative to the environment root, so
\"org-files/a.org\" lands inside the managed root."
  (dolist (cell spec)
    (let ((path (expand-file-name (car cell) brain-test--root)))
      (if (null (cdr cell))
          (make-directory path t)
        (brain-test--write path (cdr cell))))))

(defun brain-test--inventory-request (inventory-id &optional after limit)
  "Drive one real corpus inventory page request through the dispatcher."
  (brain--handle-snapshot-request
   (append (list (cons "v" 1) (cons "type" "brain.snapshot.request")
                 (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
                 (cons "mode" "inventory") (cons "inventory_id" inventory-id)
                 (cons "limit" (or limit 50)))
           (when after (list (cons "after_file_id" after))))))

(defun brain-test--history-request (file-id after-seq &optional limit)
  "Drive one real corpus history page request through the dispatcher."
  (brain--handle-snapshot-request
   (list (cons "v" 1) (cons "type" "brain.snapshot.request")
         (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
         (cons "mode" "history") (cons "file_id" file-id)
         (cons "after_revision_seq" after-seq) (cons "limit" (or limit 50)))))

(defun brain-test--events-of-kind (kind)
  "Every journaled event payload of KIND, in emission order, wire-decoded.
The payload is round-tripped through the real encoder and decoder, so a test sees
exactly what the node receives: `:json-array' is an encoder directive, not data,
and it must not leak into an assertion."
  (let ((out nil))
    (dolist (record brain--journal)
      (when (and (equal (plist-get record :kind) "event")
                 (equal (plist-get record :event_kind) kind))
        (push (brain--json-decode
               (brain--json-encode
                (alist-get "payload" (plist-get record :payload) nil nil #'equal)))
              out)))
    (nreverse out)))

(defun brain-test--last-payload-of-kind (kind)
  (car (last (brain-test--events-of-kind kind))))

(defun brain-test--flag (payload name)
  "Return PAYLOAD's NAME as a Lisp boolean.
The wire spells JSON `true'/`false'; `brain--json-decode' reads them back as `t'
and `:false' (its `:false-object'), so an assertion must not compare against
`nil' and expect a JSON false to satisfy it."
  (eq (alist-get name payload nil nil #'equal) t))

(defun brain-test--value (payload name)
  "Return PAYLOAD's NAME, with a JSON false normalised to nil."
  (let ((value (alist-get name payload nil nil #'equal)))
    (if (eq value :false) nil value)))

(defun brain-test--inventory-entries (payload)
  "The `entries' of one inventory page payload as a list of (FILE-ID . HEAD)."
  (mapcar (lambda (entry)
            (cons (alist-get "file_id" entry nil nil #'equal)
                  (alist-get "head_revision" entry nil nil #'equal)))
          (alist-get "entries" payload nil nil #'equal)))

(defun brain-test--drain-inventory (inventory-id limit)
  "Walk every page of INVENTORY-ID and return (ENTRIES . FINAL-PAGE).
Pages are requested with the cursor each one names, until a page reports `done'.
The guard is a safety net, not the loop condition: a capture that never finishes
would otherwise hang the suite instead of failing it."
  (let ((after nil) (entries nil) (page nil) (guard 0) (done nil))
    (while (and (< guard 400) (not done))
      (brain-test--inventory-request inventory-id after limit)
      (setq page (brain-test--last-payload-of-kind "brain.inventory.page"))
      (setq entries (append entries (brain-test--inventory-entries page)))
      (setq after (alist-get "next_after" page nil nil #'equal))
      (setq done (brain-test--flag page "done"))
      (setq guard (1+ guard)))
    (cons entries page)))

;;; --- the shared eligibility predicate and the alias key ---------------------

(ert-deftest brain-test-eligibility-fixture-alias-keys ()
  "Every pinned alias key is reproduced by the Mac's casefold implementation.
This is the cross-language half of §3: the fixture's `key' values were computed
by Python's `str.casefold()' over NFC, and the Mac must produce the same string
for the same input.  A `downcase'-only implementation fails on `Straße.org',
`ΣΟΦΟΣ.org', `ﬁle.org', `µm.org' and the Cherokee block.

The key is computed from the identity text directly, not through
`brain--alias-key', because some pinned inputs are deliberately non-NFC: §3 makes
NFC a precondition of the identity, and the alias key normalises anyway."
  (brain-test--with-environment
    (dolist (case (brain-test--fixture-list "alias"))
      (let* ((input (alist-get "input" case nil nil #'equal))
             (key (alist-get "key" case nil nil #'equal))
             (slash (string-search "/" input))
             (root (substring input 0 slash))
             (relative (substring input (1+ slash))))
        (should (equal (concat root "/" (brain--casefold (brain--nfc relative)))
                       key))))))

(ert-deftest brain-test-eligibility-fixture-collisions ()
  "Every pinned collision group collapses to ONE alias key.
§3: \"reject conflicting spellings, never pick one\".  Registering the first and
then the second must signal, and the same key must be produced by all members."
  (brain-test--with-environment
    (dolist (group (brain-test--fixture-list "alias_collisions"))
      (let ((keys (mapcar #'brain--alias-key group)))
        (should (= (length (delete-dups (copy-sequence keys))) 1))
        (dolist (member group)
          (if (equal member (car group))
              (should (equal (brain--register-identity member) member))
            (should-error (brain--register-identity member)
                          :type 'brain-alternate-route)))))))

(ert-deftest brain-test-eligibility-fixture-distinct-identities ()
  "Every pinned distinct pair keeps two different alias keys.
This is the other half of the collision rule: an over-eager fold that collapsed
`Straße.org' with `Strasse.org' (one `s', not two) would silently merge two real
notes."
  (brain-test--with-environment
    (dolist (pair (brain-test--fixture-list "alias_distinct"))
      (let ((left (nth 0 pair)) (right (nth 1 pair)))
        (should-not (equal (brain--alias-key left) (brain--alias-key right)))
        (should (equal (brain--register-identity left) left))
        (should (equal (brain--register-identity right) right))))))

(ert-deftest brain-test-eligibility-fixture-eligible ()
  "Every pinned eligible path is accepted, including the heuristic traps.
§3 forbids excluding names merely because they contain \"test\", \"temp\" or
\"latex\": `test-notes.org', `temp-idea.org', `latex-export-notes.org',
`build-log.org' and `tmp-notes.org' are real knowledge and must stay eligible."
  (brain-test--with-environment
    (dolist (file-id (brain-test--fixture-list "eligible"))
      (let* ((split (cons (substring file-id 0 (string-search "/" file-id))
                          (substring file-id (1+ (string-search "/" file-id))))))
        (should-not (brain--eligibility (car split) (cdr split)))
        (should (brain--eligible-p (car split) (cdr split)))
        ;; And the identity guard agrees with the predicate.
        (should (equal (brain--make-file-id (car split) (cdr split)) file-id))))))

(ert-deftest brain-test-eligibility-fixture-ineligible ()
  "Every pinned ineligible path is refused with its pinned category.
The category vocabulary, not an exception type, is the cross-language contract."
  (brain-test--with-environment
    (dolist (case (brain-test--fixture-list "ineligible"))
      (let* ((file-id (alist-get "file_id" case nil nil #'equal))
             (expected (alist-get "category" case nil nil #'equal))
             (slash (string-search "/" file-id))
             (root (if slash (substring file-id 0 slash) file-id))
             (relative (if slash (substring file-id (1+ slash)) "")))
        (should (equal (brain--eligibility root relative) expected))))))

(ert-deftest brain-test-eligibility-excludes-directories-not-filenames ()
  "An excluded DIRECTORY name is refused; a FILE with that name is not.
`org-files/build/out.org' is in an excluded directory; `org-files/build.org' is a
note whose name merely starts with the same word.  Distinguishing them is what
keeps §3's \"do NOT exclude arbitrary filenames\" honest."
  (brain-test--with-environment
    (should (equal (brain--eligibility "org-files" "build/out.org") "excluded_directory"))
    (should (equal (brain--eligibility "org-files" "tmp/generated.org")
                   "excluded_directory"))
    (should-not (brain--eligibility "org-files" "build.org"))
    (should-not (brain--eligibility "org-files" "tmp.org"))
    (should-not (brain--eligibility "org-files" "generated.org"))
    (should-not (brain--eligibility "org-files" "exports.org"))
    ;; A nested directory that is NOT excluded stays eligible.
    (should-not (brain--eligibility "org-files" "projects/companion/Note.org"))))

(ert-deftest brain-test-eligibility-precedence-is-documented ()
  "The refusal category is the FIRST matching class, not an arbitrary one.
`org-files/.git/x.org~' is both an excluded directory and a backup file; the
documented order decides, and the fixture pins the answer so E4 can reproduce it."
  (brain-test--with-environment
    (should (equal (brain--eligibility "org-files" ".git/x.org~") "backup_tilde"))
    (should (equal (brain--eligibility "org-files" ".git/x.org") "excluded_directory"))
    (should (equal (brain--eligibility "org-files" ".git/x.txt") "not_org"))
    (should (equal (brain--eligibility "elsewhere" "/etc/x.org") "unknown_root"))))

;;; --- the captured inventory -------------------------------------------------

(ert-deftest brain-test-inventory-empty-root-is-complete-and-empty ()
  "An empty complete root is entries=[], done=true, next_after=null (§2).
It is NOT an error, and it carries no dummy `file_id' -- the accepted legacy page
emitted a terminal event naming nil, which the gateway's validator refuses."
  (brain-test--with-environment
    (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
           (page (cdr result)))
      (should (null (car result)))
      (should (brain-test--flag page "done"))
      (should (brain-test--flag page "complete"))
      (should (null (alist-get "next_after" page nil nil #'equal)))
      (should (null (alist-get "reason" page nil nil #'equal))))))

(ert-deftest brain-test-inventory-page-sizes-0-1-50-51-101 ()
  "The capture pages correctly at the boundaries §2 names: 0, 1, 50, 51 and 101.
Each page is bounded by `limit', `next_after' is the last emitted id, `done' is
true only on the final page, and the concatenation is exactly the captured list."
  (brain-test--with-environment
    (dolist (count '(0 1 50 51 101))
      (let ((ids nil))
        ;; A fresh root for each size, so the capture cannot see the previous one.
        (dolist (path (directory-files (expand-file-name "org-files/" brain-test--root)
                                       nil "\\`[^.]" t))
          (brain-test--delete (expand-file-name path (expand-file-name "org-files/"
                                                                      brain-test--root))))
        (dotimes (index count)
          (let ((name (format "note-%03d.org" index)))
            (brain-test--write (expand-file-name (concat "org-files/" name)
                                                 brain-test--root)
                               (format "* %s\n" name))
            (push (concat "org-files/" name) ids)))
        (setq ids (sort ids #'string<))
        (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
               (entries (car result))
               (page (cdr result))
               (emitted (mapcar #'car entries)))
          (should (equal emitted ids))
          (should (brain-test--flag page "done"))
          (should (brain-test--flag page "complete"))
          ;; Every page was bounded, and every page named its own last id.
          (dolist (payload (brain-test--events-of-kind "brain.inventory.page"))
            (should (<= (length (brain-test--inventory-entries payload)) 50))
            (let ((page-entries (brain-test--inventory-entries payload))
                  (next (alist-get "next_after" payload nil nil #'equal)))
              (cond
               ((null page-entries) (should (null next)))
               (t (should (equal next (car (last (mapcar #'car page-entries))))))))))))))

(ert-deftest brain-test-inventory-capture-is-stable-amidst-new-files ()
  "A capture is an immutable PATH LIST: files created between pages do not appear.
§2 says the capture identifies \"an immutable captured sorted PATH LIST, not frozen
file contents\".  Re-walking per page would shift every later slice when a file is
created, which is exactly the instability the capture exists to prevent."
  (brain-test--with-environment
    (dolist (name '("a.org" "b.org" "c.org" "d.org"))
      (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                         (concat "* " name "\n")))
    (let* ((inventory-id (brain--uuid))
           (first (progn (brain-test--inventory-request inventory-id nil 2)
                         (brain-test--last-payload-of-kind "brain.inventory.page")))
           (first-entries (brain-test--inventory-entries first)))
      (should (= (length first-entries) 2))
      ;; A new file appears on disk between pages.
      (brain-test--write (expand-file-name "org-files/aa-new.org" brain-test--root)
                         "* new\n")
      (let* ((second (progn (brain-test--inventory-request
                             inventory-id (alist-get "next_after" first nil nil #'equal) 2)
                            (brain-test--last-payload-of-kind "brain.inventory.page")))
             (second-entries (brain-test--inventory-entries second)))
        ;; The capture's own list is unchanged: no `aa-new.org', and the slice
        ;; continues exactly after the first page's cursor.
        (should-not (member "org-files/aa-new.org" (mapcar #'car second-entries)))
        (should (equal (mapcar #'car second-entries) '("org-files/c.org" "org-files/d.org")))
        (should (brain-test--flag second "done")))
      ;; A NEW inventory sees the new file: the capture is per-id, not global.
      (let* ((fresh (brain-test--drain-inventory (brain--uuid) 50))
             (emitted (mapcar #'car (car fresh))))
        (should (member "org-files/aa-new.org" emitted))
        (should (= (length emitted) 5))))))

(ert-deftest brain-test-inventory-expiry-requires-a-new-capture ()
  "An expired inventory_id returns `inventory_expired', never a continuation.
§2: \"Expired id returns inventory_expired, requiring a new inventory, not
continuation against a changed list.\""
  (brain-test--with-environment
    (brain-test--write (expand-file-name "org-files/a.org" brain-test--root) "* a\n")
    (let ((inventory-id (brain--uuid)))
      (brain-test--inventory-request inventory-id nil 50)
      (should (brain-test--flag (brain-test--last-payload-of-kind "brain.inventory.page") "complete"))
      ;; Age the capture past its TTL, exactly as an abandoned capture would age.
      (let ((capture (gethash inventory-id brain--inventories)))
        (puthash inventory-id (plist-put capture :used (- (float-time)
                                                          (1+ brain-inventory-ttl)))
                 brain--inventories))
      (brain-test--inventory-request inventory-id nil 50)
      (let ((payload (brain-test--last-payload-of-kind "brain.inventory.page")))
        (should (equal (alist-get "reason" payload nil nil #'equal) "inventory_expired"))
        (should (not (brain-test--flag payload "complete")))
        (should (null (brain-test--inventory-entries payload)))
        ;; And the aged capture is gone from the table, not merely refused.
        (should-not (gethash inventory-id brain--inventories))))))

(ert-deftest brain-test-inventory-inaccessible-root-is-incomplete-not-empty ()
  "A missing or unreadable root is complete=false with a reason (§2).
It must never be reported as `entries=[], done=true', which a caller would read as
\"this root is empty\" and could then treat as a retirement signal."
  (brain-test--with-environment
    (let ((saved brain-managed-roots))
      (unwind-protect
          (progn
            ;; A configured root that does not exist at all.
            (setq brain-managed-roots
                  (list (cons "org-files" (expand-file-name "missing-root/"
                                                            brain-test--root))
                        (cons "org-roam" (expand-file-name "org-roam/" brain-test--root))))
            (let ((result (brain-test--drain-inventory (brain--uuid) 50))
                  (page nil))
              (setq page (cdr result))
              (should (not (brain-test--flag page "complete")))
              (should (equal (alist-get "reason" page nil nil #'equal) "missing_root"))
              (should (null (car result)))))
        (setq brain-managed-roots saved)))))

(ert-deftest brain-test-inventory-unreadable-directory-is-incomplete ()
  "A directory that exists but cannot be read is complete=false, not empty.
`directory-files' signals on it; the capture must turn that into an explicit
reason rather than silently enumerating nothing."
  (brain-test--with-environment
    (let* ((locked (expand-file-name "org-files/locked/" brain-test--root)))
      (make-directory locked t)
      (brain-test--write (expand-file-name "org-files/visible.org" brain-test--root)
                         "* visible\n")
      (unwind-protect
          (progn
            (set-file-modes locked #o000)
            (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
                   (page (cdr result)))
              ;; Root can be read but the child cannot: still incomplete.
              (should (not (brain-test--flag page "complete")))
              (should (stringp (alist-get "reason" page nil nil #'equal)))
              ;; And the failure is never dressed up as an empty complete list.
              (should-not (and (brain-test--flag page "complete")
                               (null (car result))))))
        (set-file-modes locked #o755)))))

(ert-deftest brain-test-inventory-oversize-is-explicit-attention ()
  "A capture over the path bound is complete=false with `inventory_oversize'.
§2: \"Oversize corpus is explicit attention with no retirement inference.\"  The
bound is lowered here so the test does not need 10,000 real files."
  (brain-test--with-environment
    (let ((brain-inventory-max-paths 3))
      (dotimes (index 5)
        (let ((name (format "n-%d.org" index)))
          (brain-test--write (expand-file-name (concat "org-files/" name)
                                               brain-test--root)
                             (concat "* " name "\n"))))
      (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
             (page (cdr result)))
        (should (not (brain-test--flag page "complete")))
        (should (equal (alist-get "reason" page nil nil #'equal) "inventory_oversize"))
        ;; No entries are published from an oversize capture: a partial list would
        ;; be a retirement signal for everything it omits.
        (should (null (car result)))))))

(ert-deftest brain-test-inventory-excludes-non-eligible-files ()
  "The census reports only eligible paths, and never enters excluded directories.
Real files of every excluded class are created on disk; the capture must contain
exactly the eligible ones."
  (brain-test--with-environment
    (let ((eligible '("keep.org" "sub/keep-two.org" "Straße.org" "test-notes.org"
                      "build.org")))
      (dolist (name eligible)
        (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                           (concat "* " name "\n")))
      ;; Every refused class, as real files.
      (dolist (name '("a.sync-conflict-20260101-000000-AAAAAAA.org" ".#Locked.org"
                      "#AutoSave.org#" "Note.org~" "Note.org.swp" "Note.txt"))
        (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                           "x\n"))
      ;; A whole excluded directory with a real .org inside it.
      (make-directory (expand-file-name "org-files/.git/" brain-test--root) t)
      (brain-test--write (expand-file-name "org-files/.git/generated.org"
                                           brain-test--root)
                         "* generated\n")
      ;; A symlink to an eligible-looking target: never followed, never enrolled.
      (let ((target (expand-file-name "org-files/keep.org" brain-test--root)))
        (make-symbolic-link target (expand-file-name "org-files/Link.org"
                                                     brain-test--root)))
      (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
             (emitted (mapcar #'car (car result))))
        (should (equal emitted (sort (mapcar (lambda (name) (concat "org-files/" name))
                                             eligible)
                                     #'string<)))
        (should-not (member "org-files/Link.org" emitted))
        (should-not (member "org-files/.git/generated.org" emitted))
        (should (eq (alist-get "complete" (cdr result) nil nil #'equal) t))))))

(ert-deftest brain-test-inventory-alias-ambiguity-is-incomplete ()
  "Two spellings one volume collapses make the capture incomplete (§3).
\"reject conflicting spellings, never pick one\": the capture must not silently
emit both and let the gateway collapse them.

The two spellings are injected through the capture's own path list rather than
created on disk, because the Mac's default volume is case-INSENSITIVE: writing
`Straße.org' and `STRASSE.org' would produce one file, and the test would pass for
the wrong reason.  The alias predicate is what decides here, and it is the same
predicate the walk calls per entry."
  (brain-test--with-environment
    (let ((inventory-id (brain--uuid)))
      ;; Start the capture, then hand it the two colliding identities as if the
      ;; walk had found them on a case-sensitive volume.
      (let ((capture (brain--inventory-capture inventory-id)))
        (setq capture (plist-put capture :paths
                                 '("org-files/STRASSE.org" "org-files/Straße.org")))
        (setq capture (brain--inventory-finish capture))
        (setq capture (plist-put capture :status
                                 (if (plist-get capture :reason) "incomplete" "complete")))
        (puthash inventory-id capture brain--inventories))
      (brain-test--inventory-request inventory-id nil 50)
      (let ((page (brain-test--last-payload-of-kind "brain.inventory.page")))
        (should (not (brain-test--flag page "complete")))
        (should (equal (alist-get "reason" page nil nil #'equal) "alias_ambiguity"))
        ;; No entries are published from a refused list.
        (should (null (brain-test--inventory-entries page)))))))

(ert-deftest brain-test-inventory-entries-carry-heads-not-bodies ()
  "An entry carries `file_id' and the Mac's current `head_revision', nothing else.
§2: \"Entries indicate disk membership, not enrollment success\", and \"No body
publication during page enumeration\".  An unenrolled path has a null head and no
object is published for it."
  (brain-test--with-environment
    (let* ((enrolled "org-files/Enrolled.org")
           (unenrolled "org-files/Unenrolled.org"))
      (brain-test--write (brain--file-path enrolled) "* enrolled\n")
      (brain--enroll-baseline enrolled (brain--file-path enrolled)
                              (brain--sha256-file (brain--file-path enrolled)))
      (brain-test--write (brain--file-path unenrolled) "* unenrolled\n")
      (let* ((result (brain-test--drain-inventory (brain--uuid) 50))
             (entries (car result))
             (by-id (lambda (id) (cdr (assoc id entries)))))
        (should (equal (funcall by-id enrolled)
                       (brain--rev->json (gethash enrolled brain--heads))))
        (should (null (funcall by-id unenrolled)))
        ;; No object was published for the unenrolled path by the census.
        (should-not (file-exists-p
                     (brain--object-path "mac"
                                         (brain--sha256-file (brain--file-path unenrolled)))))
        ;; And the payload carries exactly the two documented entry fields.
        (let ((entry (car (alist-get "entries"
                                     (brain-test--last-payload-of-kind
                                      "brain.inventory.page")
                                     nil nil #'equal))))
          (should (equal (sort (mapcar #'car entry) #'string<)
                         '("file_id" "head_revision"))))))))

(ert-deftest brain-test-inventory-slices-are-bounded ()
  "One traversal slice visits at most `brain-inventory-slice-entries' entries.
§2: \"regular timer slices (at most 50 entries or 20 ms of traversal per slice)\".
The bound is lowered so the test can observe the slice boundary without a large
corpus; a slice that stopped early must not publish a partial list."
  (brain-test--with-environment
    (let ((brain-inventory-slice-entries 2))
      (dotimes (index 6)
        (let ((name (format "s-%d.org" index)))
          (brain-test--write (expand-file-name (concat "org-files/" name)
                                               brain-test--root)
                             (concat "* " name "\n"))))
      (let* ((inventory-id (brain--uuid))
             (first (progn (brain-test--inventory-request inventory-id nil 50)
                           (brain-test--last-payload-of-kind "brain.inventory.page"))))
        ;; The first slice did not finish the walk: no entries and not complete.
        (should (not (brain-test--flag first "complete")))
        (should (equal (alist-get "reason" first nil nil #'equal) "inventory_walking"))
        (should (null (brain-test--inventory-entries first)))
        ;; Asking again resumes and eventually completes with every path.
        (let* ((result (brain-test--drain-inventory inventory-id 50))
               (emitted (mapcar #'car (car result))))
          (should (= (length emitted) 6))
          (should (eq (alist-get "complete" (cdr result) nil nil #'equal) t)))))))

(ert-deftest brain-test-inventory-page-retry-is-the-same-response ()
  "Retrying the same page of the same capture returns the same entries.
§2: \"Same page retry has the same saved response, although current target content
can advance separately.\"  The capture is a saved list, so this holds by
construction -- and a file edited between the two requests proves the head in the
answer is the capture's, not a fresh walk's."
  (brain-test--with-environment
    (dolist (name '("a.org" "b.org" "c.org"))
      (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                         (concat "* " name "\n")))
    (let* ((inventory-id (brain--uuid))
           (first (progn (brain-test--inventory-request inventory-id nil 2)
                         (brain-test--last-payload-of-kind "brain.inventory.page")))
           (again (progn (brain-test--inventory-request inventory-id nil 2)
                         (brain-test--last-payload-of-kind "brain.inventory.page"))))
      (should (equal (brain-test--inventory-entries first)
                     (brain-test--inventory-entries again)))
      (should (equal (alist-get "next_after" first nil nil #'equal)
                     (alist-get "next_after" again nil nil #'equal))))))

;;; --- target baseline actual-use guards --------------------------------------

(ert-deftest brain-test-snapshot-refuses-a-modified-buffer-without-a-lease ()
  "A modified visiting buffer blocks enrollment even with no journaled lease.
§2 requires checking \"ALL modified visiting/indirect buffers\"; the accepted code
checked only the lease, so a buffer modified before Brain enabled could have its
disk bytes enrolled while the human held unsaved text."
  (brain-test--with-environment
    (let* ((file-id "org-files/Unleased.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* disk\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* unsaved\n"))
        ;; The guards are inhibited, so no lease was journaled by the edit itself.
        (remhash file-id brain--dirty)
        (should (buffer-modified-p buffer))
        (should-not (gethash file-id brain--dirty))
        (brain--handle-snapshot-request
         (list (cons "v" 1) (cons "type" "brain.snapshot.request")
               (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
               (cons "file_id" file-id)))
        (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
          (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
          (should (equal (alist-get "reason" payload nil nil #'equal) "modified_buffer")))
        ;; Nothing was enrolled and no object was published.
        (should-not (gethash file-id brain--heads))
        (should-not (file-exists-p (brain--object-path "mac" (brain--sha256-file path))))
        ;; The unsaved text is untouched.
        (with-current-buffer buffer
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "* disk\n* unsaved\n")))))))

(ert-deftest brain-test-snapshot-refuses-an-indirect-buffer-alias-that-is-dirty ()
  "An indirect buffer (an alias) that is modified also blocks enrollment.
`brain--visiting-buffers' returns base and indirect buffers of one identity, so the
guard sees the alias too -- which is the point of checking buffers rather than
leases."
  (brain-test--with-environment
    (let* ((file-id "org-files/Alias.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* disk\n")
      (let* ((base (brain-test--visit file-id))
             (alias (make-indirect-buffer base "alias-of-Alias" t)))
        (unwind-protect
            (progn
              (with-current-buffer alias
                (goto-char (point-max))
                (insert "* from alias\n"))
              (remhash file-id brain--dirty)
              (should (buffer-modified-p alias))
              (brain--handle-snapshot-request
               (list (cons "v" 1) (cons "type" "brain.snapshot.request")
                     (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
                     (cons "file_id" file-id)))
              (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
                (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
                (should (equal (alist-get "reason" payload nil nil #'equal)
                               "modified_buffer")))
              (should-not (gethash file-id brain--heads)))
          (when (buffer-live-p alias) (kill-buffer alias)))))))

(ert-deftest brain-test-snapshot-refuses-an-autosave-marker ()
  "An autosave/recovery marker blocks enrollment (§2).
The marker is what survives a crash with unsaved text, so enrolling the disk bytes
would silently discard the newer autosave."
  (brain-test--with-environment
    (let* ((file-id "org-files/Autosaved.org")
           (path (brain--file-path file-id))
           (autosave (brain--autosave-file file-id)))
      (brain-test--write path "* disk\n")
      (should (stringp autosave))
      (brain-test--write autosave "* newer unsaved\n")
      ;; Make the autosave strictly newer than the file, as a real crash would.
      (set-file-times autosave (time-add (current-time) 60))
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
        (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
        (should (equal (alist-get "reason" payload nil nil #'equal) "autosave_marker")))
      (should-not (gethash file-id brain--heads)))))

(ert-deftest brain-test-snapshot-refuses-non-utf8-bytes ()
  "A file that is not valid UTF-8 is not enrolled (§2: \"Publish only saved exact
UTF-8 bytes\").  The accepted code hashed the file without ever proving it decoded,
so a binary or Latin-1 file would have been enrolled and then failed at the
gateway."
  (brain-test--with-environment
    (let* ((file-id "org-files/Binary.org")
           (path (brain--file-path file-id))
           (raw (unibyte-string ?* ?\s #xff #xfe ?\n)))
      ;; 0xFF is never valid UTF-8.
      (brain-test--write-bytes path raw)
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
        (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
        (should (equal (alist-get "reason" payload nil nil #'equal) "unsupported_coding")))
      (should-not (gethash file-id brain--heads))
      ;; The file itself was not modified.
      (should (equal (brain-test--read-bytes path) raw)))))

(ert-deftest brain-test-snapshot-refuses-a-symlinked-target ()
  "A symlinked target is refused as an unsafe path, never enrolled (§3).
\"No traversal, controls, backslashes, absolute or symlink paths.\""
  (brain-test--with-environment
    (let* ((outside (expand-file-name "outside.org" brain-test--root))
           (link (expand-file-name "org-files/Linked.org" brain-test--root)))
      (brain-test--write outside "* outside\n")
      (make-symbolic-link outside link)
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" "org-files/Linked.org")))
      (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
        (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
        (should (equal (alist-get "reason" payload nil nil #'equal) "symlink_component")))
      (should-not (gethash "org-files/Linked.org" brain--heads)))))

(ert-deftest brain-test-snapshot-enrols-a-clean-unheaded-file ()
  "The ordinary case still works: a clean unheaded file gets seq0 and its object.
This is the historical enrollment seam §2 keeps; the guards above must not have
broken it."
  (brain-test--with-environment
    (let* ((file-id "org-files/Clean.org")
           (path (brain--file-path file-id))
           (text "* clean\n"))
      (brain-test--write path text)
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let* ((payload (brain-test--last-payload-of-kind "brain.file.snapshot"))
             (revision (gethash file-id brain--heads)))
        (should (equal (alist-get "result" payload nil nil #'equal) "present"))
        (should (= (plist-get revision :seq) 0))
        (should (equal (plist-get revision :sha256) (brain--sha256-file path)))
        ;; The exact bytes were published, and no buffer was opened.
        (should (equal (brain-test--read-bytes (brain--object-path "mac"
                                                                   (brain--sha256-file path)))
                       (brain-test--bytes text)))
        (should-not (get-file-buffer path))
        ;; And the enrollment is journaled as a snapshot, not a commit.
        (should (cl-find-if (lambda (record)
                              (and (equal (plist-get record :kind) "snapshot")
                                   (equal (plist-get record :file_id) file-id)))
                            brain--journal))))))

(ert-deftest brain-test-snapshot-enrols-a-non-ascii-name ()
  "A non-ASCII eligible name enrolls under its exact NFC identity.
§3: the identity is the path, and the alias key is NFC plus casefold; neither may
mangle the stored `file_id'."
  (brain-test--with-environment
    (let* ((file-id "org-files/Straße.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* umlaut\n")
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (should (gethash file-id brain--heads))
      (should (equal (brain--alias-key file-id) "org-files/strasse.org")))))

(ert-deftest brain-test-snapshot-of-a-head-mismatch-is-attention ()
  "A known head that differs from disk is attention, never a silent re-baseline.
§2: \"Head/disk mismatch remains attention; do not silently adopt it.\""
  (brain-test--with-environment
    (let* ((file-id "org-files/Mismatch.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* base\n")
      (brain--enroll-baseline file-id path (brain--sha256-file path))
      (brain-test--write path "* changed outside\n")
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (let ((payload (brain-test--last-payload-of-kind "brain.file.snapshot")))
        (should (equal (alist-get "result" payload nil nil #'equal) "attention"))
        (should (equal (alist-get "reason" payload nil nil #'equal) "disk_mismatch"))
        ;; The old head is reported and kept; no new revision was allocated.
        (should (= (plist-get (gethash file-id brain--heads) :seq) 0))
        (should (equal (plist-get (gethash file-id brain--heads) :sha256)
                       (brain--sha256 (brain-test--bytes "* base\n"))))))))

;;; --- history ----------------------------------------------------------------

(ert-deftest brain-test-history-emits-the-retained-chain-in-order ()
  "History returns the original committed facts, ascending, with predecessors.
§2: \"`brain.file.history` emits bounded committed facts with original
operation_id, predecessor, revision and object_hash\".  Each fact is the chain
step, so a consumer can install exactly one link at a time."
  (brain-test--with-environment
    (let* ((file-id "org-files/Chain.org")
           (path (brain--file-path file-id))
           (base (progn (brain-test--write path "* one\n")
                        (brain--enroll-baseline file-id path
                                                (brain--sha256-file path))))
           (second (brain-commit-file
                    (brain-test--install-spec file-id base "* one\n* two\n"
                                              :attempt-id (brain--uuid))))
           (_third (brain-commit-file
                    (brain-test--install-spec file-id (plist-get second :new-revision)
                                              "* one\n* two\n* three\n"
                                              :attempt-id (brain--uuid)))))
      (should (equal (plist-get second :status) "committed"))
      (brain-test--history-request file-id -1 50)
      (let* ((payload (brain-test--last-payload-of-kind "brain.file.history"))
             (facts (alist-get "facts" payload nil nil #'equal))
             (seqs (mapcar (lambda (fact)
                             (plist-get (brain--rev<-json
                                         (alist-get "revision" fact nil nil #'equal))
                                        :seq))
                           facts)))
        (should (equal seqs '(0 1 2)))
        (should (brain-test--flag payload "done"))
        (should (brain-test--flag payload "complete"))
        ;; The predecessor of each later fact is the previous revision.
        (let ((second-fact (nth 1 facts)))
          (should (equal (alist-get "predecessor_revision" second-fact nil nil #'equal)
                         (brain--rev->json base))))
        ;; Every fact names its original operation id and object hash.
        (dolist (fact facts)
          (should (stringp (alist-get "operation_id" fact nil nil #'equal)))
          (should (equal (length (alist-get "object_hash" fact nil nil #'equal)) 64)))))))

(ert-deftest brain-test-history-pages-are-contiguous-and-bounded ()
  "History pages ascend without gaps or repeats, and the cursor is a seq.
§2: the cursor is `next_after_seq', not `next_after'; a page that skipped a seq
would be refused by the gateway's validator."
  (brain-test--with-environment
    (let* ((file-id "org-files/Paged.org")
           (path (brain--file-path file-id))
           (head (progn (brain-test--write path "* v0\n")
                        (brain--enroll-baseline file-id path
                                                (brain--sha256-file path)))))
      (dotimes (index 4)
        (let ((result (brain-commit-file
                       (brain-test--install-spec
                        file-id head (format "* v%d\n" (1+ index))
                        :attempt-id (brain--uuid)))))
          (setq head (plist-get result :new-revision))))
      ;; Walk the chain two facts at a time.
      (let ((after -1) (seqs nil) (guard 0) (done nil))
        (while (and (< guard 20) (not done))
          (brain-test--history-request file-id after 2)
          (let* ((payload (brain-test--last-payload-of-kind "brain.file.history"))
                 (facts (alist-get "facts" payload nil nil #'equal)))
            (dolist (fact facts)
              (push (plist-get (brain--rev<-json (alist-get "revision" fact nil nil #'equal))
                               :seq)
                    seqs))
            (setq after (alist-get "next_after_seq" payload nil nil #'equal))
            (setq done (brain-test--flag payload "done")))
          (setq guard (1+ guard)))
        (should (equal (nreverse seqs) '(0 1 2 3 4)))
        (should done)))))

(ert-deftest brain-test-history-of-an-unenrolled-file-is-empty-not-a-gap ()
  "History of a path with no retained chain is an empty complete page.
It allocates nothing and invents no seq0 -- the caller sees \"no history\", which
is different from a failed read."
  (brain-test--with-environment
    (let ((file-id "org-files/Never.org"))
      (brain-test--write (brain--file-path file-id) "* never enrolled\n")
      (brain-test--history-request file-id -1 50)
      (let ((payload (brain-test--last-payload-of-kind "brain.file.history")))
        (should (null (alist-get "facts" payload nil nil #'equal)))
        (should (null (alist-get "next_after_seq" payload nil nil #'equal)))
        (should (brain-test--flag payload "done"))
        (should (brain-test--flag payload "complete")))
      (should-not (gethash file-id brain--heads)))))

(ert-deftest brain-test-history-never-rewinds-or-skips-after-a-nonzero-head ()
  "A file whose head is a nonzero seq reports the whole chain from -1.
§2: \"never fabricates seq0 or skips to a latest nonzero head\".  A Hermes side with
no baseline asks from -1 and must receive seq 0 first."
  (brain-test--with-environment
    (let* ((file-id "org-files/NonZero.org")
           (path (brain--file-path file-id))
           (base (progn (brain-test--write path "* a\n")
                        (brain--enroll-baseline file-id path
                                                (brain--sha256-file path))))
           (head base))
      (dotimes (index 3)
        (setq head (plist-get (brain-commit-file
                               (brain-test--install-spec file-id head
                                                         (format "* a%d\n" index)
                                                         :attempt-id (brain--uuid)))
                              :new-revision)))
      (should (= (plist-get head :seq) 3))
      (brain-test--history-request file-id -1 50)
      (let* ((payload (brain-test--last-payload-of-kind "brain.file.history"))
             (facts (alist-get "facts" payload nil nil #'equal)))
        (should (equal (mapcar (lambda (fact)
                                 (plist-get (brain--rev<-json
                                             (alist-get "revision" fact nil nil #'equal))
                                            :seq))
                               facts)
                       '(0 1 2 3)))
        ;; The first fact has no predecessor: it is the real seq0, not a guess.
        (should (null (alist-get "predecessor_revision" (car facts) nil nil #'equal)))))))

;;; --- the query profile ------------------------------------------------------

(ert-deftest brain-test-query-profile-matches-the-observed-configuration ()
  "The profile reports the real TODO sequences, done markers and agenda files.
The configuration below is the live Mac's (measured read-only from the running
daemon); §4 requires the effective Org configuration as DATA, with the done
markers explicit rather than positional."
  (brain-test--with-environment
    (require 'org)
    (require 'org-agenda)
    (let ((org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d!)")
                               (sequence "HABIT(h)" "DONE")
                               (sequence "BUYING(b1)" "|" "bought(B!)")
                               (sequence "BACKLOG(b)" "PLAN(p)" "READY(r)" "ACTIVE(a)"
                                         "REVIEW(v)" "WAIT(w@/!)" "HOLD(h)" "|"
                                         "COMPLETED(c)" "CANC(k@)")))
          (org-agenda-files (list (expand-file-name "org-files/Tasks.org"
                                                    brain-test--root)
                                  (expand-file-name "org-files/todo.org"
                                                    brain-test--root)
                                  ;; A file outside the managed roots is not an
                                  ;; agenda file_id and must not be invented into one.
                                  "/etc/hosts"))
          (org-agenda-start-on-weekday 1)
          (org-deadline-warning-days 14))
      (brain--emit-query-profile)
      (let* ((payload (brain-test--last-payload-of-kind "brain.query.profile"))
             (sequences (alist-get "todo_sequences" payload nil nil #'equal)))
        (should (= (alist-get "version" payload nil nil #'equal) 1))
        (should (equal (length (alist-get "profile_hash" payload nil nil #'equal)) 64))
        (should (= (length sequences) 4))
        ;; Sequence 1: the `|' split, with fast-key and logger suffixes stripped.
        (should (equal (alist-get "keywords" (nth 0 sequences) nil nil #'equal)
                       '("TODO" "NEXT" "DONE")))
        (should (equal (alist-get "done" (nth 0 sequences) nil nil #'equal)
                       '("DONE")))
        ;; Sequence 2: NO `|', so Org's implicit rule makes the last keyword done.
        (should (equal (alist-get "keywords" (nth 1 sequences) nil nil #'equal)
                       '("HABIT" "DONE")))
        (should (equal (alist-get "done" (nth 1 sequences) nil nil #'equal)
                       '("DONE")))
        ;; Sequence 3: a lowercase done keyword.
        (should (equal (alist-get "done" (nth 2 sequences) nil nil #'equal)
                       '("bought")))
        ;; Sequence 4: two done keywords, and the ordered keyword list is preserved.
        (should (equal (alist-get "done" (nth 3 sequences) nil nil #'equal)
                       '("COMPLETED" "CANC")))
        (should (equal (alist-get "keywords" (nth 3 sequences) nil nil #'equal)
                       '("BACKLOG" "PLAN" "READY" "ACTIVE" "REVIEW" "WAIT" "HOLD"
                         "COMPLETED" "CANC")))
        ;; Agenda files: only the two managed ones, sorted.
        (should (equal (alist-get "agenda_file_ids" payload nil nil #'equal)
                       '("org-files/Tasks.org" "org-files/todo.org")))
        (should (= (alist-get "week_start" payload nil nil #'equal) 1))
        (should (= (alist-get "deadline_warning_days" payload nil nil #'equal) 14))))))

(ert-deftest brain-test-query-profile-is-data-only-and-hash-stable ()
  "The profile carries no Lisp, and its hash covers exactly its own facts.
§4: \"No serialized Lisp/custom command bodies\", and the gateway caches the
profile by hash, so the same configuration must hash the same and a changed one
must not."
  (brain-test--with-environment
    (require 'org)
    (require 'org-agenda)
    (let* ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
           (org-agenda-files nil)
           (org-agenda-start-on-weekday 1)
           (org-deadline-warning-days 7))
      (brain--emit-query-profile)
      (let* ((first (brain-test--last-payload-of-kind "brain.query.profile"))
             (hash (alist-get "profile_hash" first nil nil #'equal)))
        ;; Every key is one of the documented data fields.
        (should (equal (sort (mapcar #'car first) #'string<)
                       '("agenda_file_ids" "deadline_warning_days" "profile_hash"
                         "timezone" "todo_sequences" "version" "week_start")))
        ;; The hash is the sha256 of the canonical JSON of everything else.  It is
        ;; checked against the *wire* form of the same payload, because that is what
        ;; the gateway receives and re-hashes: the decoded alist is what it holds.
        (let ((body (seq-remove (lambda (cell) (equal (car cell) "profile_hash")) first)))
          (should (equal hash (brain--sha256 (brain--json-encode body)))))
        ;; Re-emitting the same configuration gives the same hash.
        (brain--emit-query-profile)
        (should (equal (alist-get "profile_hash"
                                  (brain-test--last-payload-of-kind "brain.query.profile")
                                  nil nil #'equal)
                       hash))
        ;; A changed configuration changes it.
        (let ((org-deadline-warning-days 3))
          (brain--emit-query-profile)
          (should-not (equal (alist-get "profile_hash"
                                        (brain-test--last-payload-of-kind
                                         "brain.query.profile")
                                        nil nil #'equal)
                             hash)))))))

(ert-deftest brain-test-query-profile-reports-an-unsupported-timezone ()
  "A timezone the Mac cannot name is REPORTED as unsupported, never guessed.
§4: \"Export only safe finite primitives; unsupported values are reported.\""
  (brain-test--with-environment
    (require 'org)
    (require 'org-agenda)
    (let ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
          (org-agenda-files nil))
      (cl-letf (((symbol-function 'brain--timezone-name) (lambda () nil)))
        (brain--emit-query-profile)
        (let ((payload (brain-test--last-payload-of-kind "brain.query.profile")))
          (should (null (alist-get "timezone" payload nil nil #'equal)))
          (should (equal (alist-get "unsupported" payload nil nil #'equal)
                         '("timezone"))))))))

(ert-deftest brain-test-query-profile-is-emitted-after-readiness ()
  "The profile is emitted after readiness (§4), on every (re)connect.
The gateway durably caches the last profile, so a client that never publishes one
leaves semantic task/agenda operations at `profile_unavailable'."
  (brain-test--with-environment
    (require 'org)
    (require 'org-agenda)
    (let ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
          (org-agenda-files nil)
          (brain--client-epoch (brain--uuid))
          (sent nil))
      (cl-letf (((symbol-function 'brain--ipc-send)
                 (lambda (object) (push object sent) t))
                ((symbol-function 'brain--pump-outbox) (lambda () nil)))
        (brain--announce-ready)
        (should brain--reconciled)
        ;; emacs.online then the profile, in that order.
        (should (equal (mapcar (lambda (record) (plist-get record :event_kind))
                               (seq-filter (lambda (record)
                                             (equal (plist-get record :kind) "event"))
                                           (last brain--journal 3)))
                       '("emacs.online" "brain.query.profile")))))))

(ert-deftest brain-test-subscribe-advertises-corpus-v1 ()
  "`brain.subscribe' advertises corpus-v1 (§1, the client's half).
The node relays this list upstream on `device.heartbeat'; an old client omits the
field, which is what keeps the extension off for a mixed pair.  The frame is
round-tripped through the real encoder, so the assertion sees the wire form."
  (brain-test--with-environment
    (let ((sent nil))
      (cl-letf (((symbol-function 'brain--ipc-connect) (lambda () t))
                ((symbol-function 'brain--ipc-send)
                 (lambda (object) (push object sent) t)))
        (brain--subscribe)
        (let* ((frame (car sent))
               (wire (brain--json-decode (brain--json-encode frame))))
          (should (equal (alist-get "type" wire nil nil #'equal) "brain.subscribe"))
          (should (equal (alist-get "corpus_features" wire nil nil #'equal)
                         (list "corpus-v1")))
          ;; The feature name is pinned to the gateway's vocabulary.
          (should (equal brain--corpus-feature "corpus-v1")))))))

;;; --- the legacy shapes are unchanged ---------------------------------------

(ert-deftest brain-test-legacy-page-keeps-first-next-continuation ()
  "The legacy page still reports the FIRST item of the next page as `continuation'.
§1: \"No fix silently changes old page interpretation.\"  The accepted page
semantics are exclusive-after requests with a first-next continuation, and the
terminal event repeats the last emitted id -- not the new capture's `next_after'.
With three files and limit 2 the first page is A,B, so its continuation is C."
  (brain-test--with-environment
    (dolist (name '("A.org" "B.org" "C.org"))
      (brain-test--write (expand-file-name (concat "org-files/" name) brain-test--root)
                         (concat "* " name "\n")))
    (brain--handle-snapshot-request
     (list (cons "v" 1) (cons "type" "brain.snapshot.request")
           (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
           (cons "limit" 2)))
    (let ((payloads (brain-test--events-of-kind "brain.file.snapshot")))
      (should (= (length payloads) 3))
      ;; Two targets, each naming C.org as the next page's first item.
      (should (equal (alist-get "continuation" (nth 0 payloads) nil nil #'equal)
                     "org-files/C.org"))
      (should (equal (alist-get "continuation" (nth 1 payloads) nil nil #'equal)
                     "org-files/C.org"))
      ;; Terminal: repeats the last emitted id, done=true, same continuation.
      (should (equal (alist-get "file_id" (nth 2 payloads) nil nil #'equal)
                     "org-files/B.org"))
      (should (brain-test--flag (nth 2 payloads) "done")))))

(ert-deftest brain-test-legacy-target-request-is-unchanged ()
  "A legacy `{file_id}` request still answers `brain.file.snapshot', not a corpus event.
The two shapes are disjoint because `mode' is a new field."
  (brain-test--with-environment
    (let ((file-id "org-files/Legacy.org"))
      (brain-test--write (brain--file-path file-id) "* legacy\n")
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "file_id" file-id)))
      (should (brain-test--last-payload-of-kind "brain.file.snapshot"))
      (should (null (brain-test--events-of-kind "brain.inventory.page")))
      (should (null (brain-test--events-of-kind "brain.file.history"))))))

(ert-deftest brain-test-unknown-mode-is-refused-not-reinterpreted ()
  "A `mode' this client does not implement is refused, never read as a legacy shape.
§1 forbids silent reinterpretation in both directions."
  (brain-test--with-environment
    (let ((file-id "org-files/Mode.org"))
      (brain-test--write (brain--file-path file-id) "* mode\n")
      (brain--handle-snapshot-request
       (list (cons "v" 1) (cons "type" "brain.snapshot.request")
             (cons "brain_id" brain-id) (cons "request_id" (brain--uuid))
             (cons "mode" "teleport") (cons "file_id" file-id)
             (cons "limit" 10)))
      (should-not (gethash file-id brain--heads))
      (should (null (brain-test--events-of-kind "brain.file.snapshot")))
      (should (null (brain-test--events-of-kind "brain.inventory.page"))))))

;;; --- the frames the gateway must accept -------------------------------------

(ert-deftest brain-test-e2-emits-the-corpus-frames-the-gateway-validates ()
  "Emit every corpus frame the Mac can produce and dump it for cross-validation.
The Mac's own suite cannot prove that the gateway's reviewed validators accept
these payloads -- only the gateway's `contracts' can.  This test therefore writes
each real payload, exactly as the Mac journals it, to the file named by
`BRAIN_E2_FRAME_DUMP'; `tools/validate_mac_frames.py' then validates that file
with the real E1 contracts.  Without the variable the test only asserts the shapes
locally, so a plain ERT run stays self-contained."
  (brain-test--with-environment
    (require 'org)
    (require 'org-agenda)
    (let* ((dump (getenv "BRAIN_E2_FRAME_DUMP"))
           (file-id "org-files/Frames.org")
           (path (brain--file-path file-id))
           (head nil)
           (records nil))
      (brain-test--write path "* one\n")
      (setq head (brain--enroll-baseline file-id path (brain--sha256-file path)))
      (dotimes (index 2)
        (setq head (plist-get (brain-commit-file
                               (brain-test--install-spec file-id head
                                                         (format "* one\n* v%d\n" index)
                                                         :attempt-id (brain--uuid)))
                              :new-revision)))
      ;; A second file so the inventory has more than one entry.
      (brain-test--write (expand-file-name "org-files/Other.org" brain-test--root)
                         "* other\n")
      ;; 1. An inventory page with entries.
      (brain-test--inventory-request (brain--uuid) nil 50)
      ;; 2. An empty complete inventory (a fresh capture over an empty root).
      (let ((saved brain-managed-roots))
        (unwind-protect
            (progn
              (setq brain-managed-roots
                    (list (cons "org-files" (expand-file-name "empty-root/"
                                                              brain-test--root))
                          (cons "org-roam" (expand-file-name "org-roam/"
                                                             brain-test--root))))
              (make-directory (expand-file-name "empty-root/" brain-test--root) t)
              (brain-test--inventory-request (brain--uuid) nil 50))
          (setq brain-managed-roots saved)))
      ;; 3. A history page.
      (brain-test--history-request file-id -1 50)
      ;; 4. The query profile.
      (let ((org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d!)")
                                 (sequence "BUYING(b1)" "|" "bought(B!)")))
            (org-agenda-files nil))
        (brain--emit-query-profile))
      (setq records
            (seq-filter (lambda (record)
                          (and (equal (plist-get record :kind) "event")
                               (member (plist-get record :event_kind)
                                       '("brain.inventory.page" "brain.file.history"
                                         "brain.query.profile"))))
                        brain--journal))
      ;; Every kind was produced at least once.
      (dolist (kind '("brain.inventory.page" "brain.file.history" "brain.query.profile"))
        (should (seq-find (lambda (record) (equal (plist-get record :event_kind) kind))
                          records)))
      ;; The empty inventory really is entries=[], done=true, next_after=null.
      (let* ((pages (brain-test--events-of-kind "brain.inventory.page"))
             (empty (seq-find (lambda (payload)
                                (and (null (brain-test--inventory-entries payload))
                                     (brain-test--flag payload "complete")))
                              pages)))
        (should empty)
        (should (null (alist-get "next_after" empty nil nil #'equal)))
        (should (brain-test--flag empty "done")))
      (when dump
        (with-temp-file dump
          (setq coding-system-for-write 'utf-8-unix)
          (dolist (record records)
            (insert (brain--json-encode
                     (list (cons "kind" (plist-get record :event_kind))
                           (cons "payload"
                                 (alist-get "payload" (plist-get record :payload)
                                            nil nil #'equal))))
                    "\n")))
        (should (file-exists-p dump))))))

(ert-deftest brain-test-corpus-capture-does-not-release-a-lease ()
  "The census never touches leases, attention or heads (§2/§3).
A capture is a read-only enumeration: it must not release a human lease, clear an
attention row, or allocate a revision.  This is the accepted stale-clean-lease
carry's boundary -- only `brain--release-stale-leases' releases, and only at
enable, for a buffer that is genuinely clean."
  (brain-test--with-environment
    (let* ((file-id "org-files/Leased.org")
           (path (brain--file-path file-id)))
      (brain-test--write path "* disk\n")
      (let ((buffer (brain-test--visit file-id)))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "* unsaved\n")))
      (should (gethash file-id brain--dirty))
      (puthash file-id "existing_attention" brain--attention)
      (let ((before-heads (hash-table-count brain--heads)))
        (brain-test--drain-inventory (brain--uuid) 50)
        (should (gethash file-id brain--dirty))
        (should (equal (gethash file-id brain--attention) "existing_attention"))
        (should (= (hash-table-count brain--heads) before-heads))))))
