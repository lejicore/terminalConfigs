;;; brain-test.el --- ERT tests for the Mac Brain commit client -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for brain.el (design t_0511a7c7, chunk B3).  Everything below drives
;; REAL temporary files and REAL buffers: the commit primitive is not stubbed,
;; `buffer-modified-p' is not mocked, and the IPC path goes through the real
;; process filter with real length-prefixed frames.
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

(defmacro brain-test--with-environment (&rest body)
  "Run BODY with real temporary managed roots, state dir and a live module."
  (declare (indent 0) (debug t))
  `(let* ((brain-test--root (make-temp-file "brain-test-" t))
          (brain-test--state (expand-file-name "state/" brain-test--root))
          (org-files (expand-file-name "org-files/" brain-test--root))
          (org-roam (expand-file-name "org-roam/" brain-test--root))
          (brain-id "11111111-1111-4111-8111-111111111111")
          (brain-writer-id "22222222-2222-4222-8222-222222222222")
          (brain-managed-roots (list (cons "org-files" org-files)
                                     (cons "org-roam" org-roam)))
          (brain-state-directory brain-test--state)
          (brain-transport-directory nil)
          (brain-node-socket (expand-file-name "ipc/test.sock" brain-test--state))
          (brain-fsync-enabled nil))
     (brain-test--reset-state)
     (make-directory org-files t)
     (make-directory org-roam t)
     (unwind-protect
         (progn
           (brain-enable)
           ,@body)
       (brain-disable)
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

(defun brain-test--bytes (text)
  (encode-coding-string text 'utf-8))

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
