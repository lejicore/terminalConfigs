;;; ox-window-zoom-test.el --- Tests for perspective-local window zoom -*- lexical-binding: t; -*-

(require 'ert)
(require 'persp-mode)

(let ((source-directory
       (file-name-directory (directory-file-name
                             (file-name-directory (or load-file-name
                                                      buffer-file-name)))))
      (persp-directory
       (expand-file-name "~/.cache/emacs/straight/repos/persp-mode.el/")))
  (add-to-list 'load-path source-directory)
  (when (file-directory-p persp-directory)
    (add-to-list 'load-path persp-directory)))

(require 'ox-window-zoom)

(defmacro ox-window-zoom-test--with-persp-mode (&rest body)
  "Run BODY with a fresh, non-persisting persp-mode instance."
  (declare (indent 0) (debug t))
  `(let ((persp-auto-save-opt 0)
         (persp-autokill-buffer-on-remove nil)
         (persp-autokill-persp-when-removed-last-buffer nil)
         (ox-window-zoom--states (make-hash-table :test #'eq)))
     (when (bound-and-true-p persp-mode)
       (persp-mode -1))
     (persp-mode 1)
     (unwind-protect
         (progn ,@body)
       (clrhash ox-window-zoom--states)
       (when (bound-and-true-p persp-mode)
         (persp-mode -1)))))

(defun ox-window-zoom-test--make-buffer (name)
  "Make a distinguishable test buffer named NAME."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (insert "first line\nsecond line\nthird line\n"))
    buffer))

(defun ox-window-zoom-test--make-layout (name first second)
  "Create a two-window layout for NAME displaying FIRST and SECOND."
  (persp-switch name)
  (persp-add-buffer (list first second) (get-current-persp) nil nil)
  (switch-to-buffer first)
  (delete-other-windows)
  (let ((other (split-window-right)))
    (set-window-buffer other second)
    (set-window-point (selected-window) 3)
    (set-window-point other 7)
    (select-window other)))

(defun ox-window-zoom-test--make-three-window-layout (name first second third)
  "Create a three-window layout for NAME displaying FIRST, SECOND, THIRD."
  (persp-switch name)
  (persp-add-buffer (list first second third) (get-current-persp) nil nil)
  (switch-to-buffer first)
  (delete-other-windows)
  (let ((second-window (split-window-right)))
    (set-window-buffer second-window second)
    (let ((third-window (split-window-below)))
      (set-window-buffer third-window third))
    (select-window second-window)))

(defun ox-window-zoom-test--state ()
  "Return the complete current frame window state."
  (window-state-get (frame-root-window) t))

(defun ox-window-zoom-test--visible-state ()
  "Return the user-visible state of every current frame window."
  (mapcar (lambda (window)
            (list (buffer-name (window-buffer window))
                  (window-point window)
                  (window-start window)
                  (window-edges window)
                  (window-hscroll window)
                  (window-vscroll window)
                  (eq window (selected-window))))
          (window-list)))

(defun ox-window-zoom-test--kill-buffers (buffers)
  "Kill live BUFFERS without persp-mode's foreign-buffer prompt."
  (dolist (buffer buffers)
    (when (buffer-live-p buffer)
      (let ((persp-mode nil))
        (kill-buffer buffer)))))

(ert-deftest ox-window-zoom-restores-the-exact-layout-and-selection ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "zoom" first second)
            (let ((expected (ox-window-zoom-test--state))
                  (perspective (get-current-persp)))
              (ox-window-zoom-toggle)
              (should (= 1 (length (window-list))))
              (should (eq (window-buffer (selected-window)) second))
              (should (gethash perspective ox-window-zoom--states))
              (should (equal expected (safe-persp-window-conf perspective)))
              (ox-window-zoom-toggle)
              (should (equal expected (ox-window-zoom-test--state)))
              (should (eq (selected-window)
                          (cl-find-if
                           (lambda (window)
                             (eq (window-buffer window) second))
                           (window-list))))
              (should-not (gethash perspective ox-window-zoom--states))))
        (ox-window-zoom-test--kill-buffers (list first second))))))

(ert-deftest ox-window-zoom-is-benign-with-one-window ()
  (ox-window-zoom-test--with-persp-mode
    (let ((buffer (ox-window-zoom-test--make-buffer "*zoom-single*")))
      (unwind-protect
          (progn
            (persp-switch "single")
            (persp-add-buffer buffer (get-current-persp) nil nil)
            (switch-to-buffer buffer)
            (delete-other-windows)
            (ox-window-zoom-toggle)
            (should (= 1 (length (window-list))))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states)))
        (when (buffer-live-p buffer)
          (let ((persp-mode nil))
            (kill-buffer buffer)))))))

(ert-deftest ox-window-zoom-keeps-state-for-buffer-switching ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-switch-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-switch-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "switch" first second)
            (let ((perspective (get-current-persp)))
              (ox-window-zoom-toggle)
              (switch-to-buffer first)
              (should (= 1 (length (window-list))))
              (should (eq (window-buffer (selected-window)) first))
              (should (gethash perspective ox-window-zoom--states)))
            (switch-to-buffer second)
            (should (= 1 (length (window-list)))))
        (ox-window-zoom-test--kill-buffers (list first second))))))

(ert-deftest ox-window-zoom-restores-the-live-pane-after-display-and-quit ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-live-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-live-second*"))
          (displayed (ox-window-zoom-test--make-buffer "*zoom-live-displayed*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "live-pane" first second)
            (ox-window-zoom-toggle)
            ;; This reproduces a package opening a pane-local buffer without
            ;; treating its display machinery as a layout mutation.
            (display-buffer displayed '((display-buffer-same-window)))
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) displayed))
            (should (gethash (get-current-persp) ox-window-zoom--states))
            (quit-window nil (selected-window))
            (should (= 1 (length (window-list))))
            (should-not (eq (window-buffer (selected-window)) displayed))
            (should (gethash (get-current-persp) ox-window-zoom--states))
            (ox-window-zoom-toggle)
            (should (= 2 (length (window-list))))
            (should-not (eq (window-buffer (selected-window)) displayed))
            (should-not (gethash (get-current-persp) ox-window-zoom--states)))
        (ox-window-zoom-test--kill-buffers
         (list first second displayed))))))

(ert-deftest ox-window-zoom-restores-current-buffer-and-point ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-current-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-current-second*"))
          (current (ox-window-zoom-test--make-buffer "*zoom-current-buffer*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "current-pane" first second)
            (ox-window-zoom-toggle)
            (switch-to-buffer current)
            (goto-char 12)
            (set-window-start (selected-window) 7 t)
            (ox-window-zoom-toggle)
            (let ((window (cl-find-if
                           (lambda (candidate)
                             (eq (window-buffer candidate) current))
                           (window-list))))
              (should window)
              (should (= 12 (window-point window)))
              (should (= 7 (window-start window)))))
        (ox-window-zoom-test--kill-buffers
         (list first second current))))))

(ert-deftest ox-window-zoom-keeps-live-pane-across-perspective-switch ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-switch-live-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-switch-live-second*"))
          (current (ox-window-zoom-test--make-buffer "*zoom-switch-live-current*"))
          (other (ox-window-zoom-test--make-buffer "*zoom-switch-live-other*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout
             "switch-live" first second)
            (ox-window-zoom-toggle)
            (switch-to-buffer current)
            (persp-switch "switch-live-other")
            (persp-add-buffer other (get-current-persp) nil nil)
            (switch-to-buffer other)
            (delete-other-windows)
            (persp-switch "switch-live")
            (should (= 1 (length (window-list))))
            (should (gethash (get-current-persp) ox-window-zoom--states))
            (should (eq (window-buffer (selected-window)) current))
            (ox-window-zoom-toggle)
            (should (= 2 (length (window-list))))
            (should (eq (window-buffer (selected-window)) current)))
        (ox-window-zoom-test--kill-buffers
         (list first second current other))))))

(ert-deftest ox-window-zoom-keeps-state-during-minibuffer-window-resize ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-minibuffer-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-minibuffer-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "minibuffer" first second)
            (let ((expected (ox-window-zoom-test--state))
                  (perspective (get-current-persp)))
              (ox-window-zoom-toggle)
              ;; This is the internal resize issued for the active
              ;; minibuffer window during minibuffer setup.  Keep it at zero
              ;; so the batch test does not need an interactive input stream.
              (window-resize (minibuffer-window) 0)
              (should (= 1 (length (window-list))))
              (should (gethash perspective ox-window-zoom--states))
              (ox-window-zoom-toggle)
              (should (equal expected (ox-window-zoom-test--state)))))
        (ox-window-zoom-test--kill-buffers (list first second))))))

(ert-deftest ox-window-zoom-keeps-independent-state-across-perspectives ()
  (ox-window-zoom-test--with-persp-mode
    (let ((a-first (ox-window-zoom-test--make-buffer "*zoom-a-first*"))
          (a-second (ox-window-zoom-test--make-buffer "*zoom-a-second*"))
          (b-first (ox-window-zoom-test--make-buffer "*zoom-b-first*"))
          (b-second (ox-window-zoom-test--make-buffer "*zoom-b-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "A" a-first a-second)
            (let ((a-state (ox-window-zoom-test--state))
                  (a-perspective (get-current-persp)))
              (ox-window-zoom-test--make-layout "B" b-first b-second)
              (let ((b-state (ox-window-zoom-test--state))
                    (b-perspective (get-current-persp)))
                (persp-switch "A")
                (ox-window-zoom-toggle)
                (should (= 1 (length (window-list))))
                (persp-switch "B")
                (ox-window-zoom-toggle)
                (should (= 1 (length (window-list))))
                (should (gethash a-perspective ox-window-zoom--states))
                (should (gethash b-perspective ox-window-zoom--states))

                ;; Switching back and forth while both are zoomed must not
                ;; replace either perspective's selected buffer.
                (persp-switch "A")
                (should (= 1 (length (window-list))))
                (should (eq (window-buffer (selected-window)) a-second))
                (persp-switch "B")
                (should (= 1 (length (window-list))))
                (should (eq (window-buffer (selected-window)) b-second))

                ;; Unzoom B, then A, following the user-visible sequence.
                (ox-window-zoom-toggle)
                (should (equal b-state (ox-window-zoom-test--state)))
                (should-not (gethash b-perspective ox-window-zoom--states))
                (persp-switch "A")
                (should (= 1 (length (window-list))))
                (ox-window-zoom-toggle)
                (should (equal a-state (ox-window-zoom-test--state)))
                (should-not (gethash a-perspective ox-window-zoom--states))))
        (ox-window-zoom-test--kill-buffers
         (list a-first a-second b-first b-second)))))))

(ert-deftest ox-window-zoom-unzooms-before-split-window-below ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-split-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-split-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "split-below" first second)
            (ox-window-zoom-toggle)
            (should (= 1 (length (window-list))))
            (let ((this-command 'split-window-below))
              (split-window-below))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states))
            (should (= 3 (length (window-list))))
            (let ((expected (ox-window-zoom-test--visible-state)))
              (ox-window-zoom-toggle)
              (should (= 1 (length (window-list))))
              (ox-window-zoom-toggle)
              (should (= 3 (length (window-list))))
              (should (equal expected
                             (ox-window-zoom-test--visible-state)))))
        (ox-window-zoom-test--kill-buffers (list first second))))))

(ert-deftest ox-window-zoom-does-not-unzoom-for-programmatic-window-calls ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-programmatic-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-programmatic-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout "programmatic" first second)
            (ox-window-zoom-toggle)
            ;; A package may reach the same primitive while displaying a
            ;; buffer.  It is not user layout intent merely because the
            ;; primitive is also reachable from a command.
            (let ((this-command 'display-buffer))
              (split-window-below))
            (should (= 2 (length (window-list))))
            (should (gethash (get-current-persp) ox-window-zoom--states))
            (ox-window-zoom-toggle)
            (should (= 2 (length (window-list))))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states)))
        (ox-window-zoom-test--kill-buffers (list first second))))))

(ert-deftest ox-window-zoom-unzooms-before-split-window-right-and-restores-three-window-layout ()
  (ox-window-zoom-test--with-persp-mode
    (let ((first (ox-window-zoom-test--make-buffer "*zoom-three-first*"))
          (second (ox-window-zoom-test--make-buffer "*zoom-three-second*"))
          (third (ox-window-zoom-test--make-buffer "*zoom-three-third*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-three-window-layout
             "split-right-three" first second third)
            (should (= 3 (length (window-list))))
            (ox-window-zoom-toggle)
            (should (= 1 (length (window-list))))
            (let ((this-command 'split-window-right))
              (split-window-right))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states))
            (should (= 4 (length (window-list))))
            (let ((expected (ox-window-zoom-test--state)))
              (ox-window-zoom-toggle)
              (should (= 1 (length (window-list))))
              (ox-window-zoom-toggle)
              (should (= 4 (length (window-list))))
              (should (equal expected (ox-window-zoom-test--state)))))
        (ox-window-zoom-test--kill-buffers
         (list first second third))))))

(ert-deftest ox-window-zoom-unzooms-before-delete-and-resize-mutations ()
  (ox-window-zoom-test--with-persp-mode
    (let ((delete-first (ox-window-zoom-test--make-buffer "*zoom-delete-first*"))
          (delete-second (ox-window-zoom-test--make-buffer "*zoom-delete-second*"))
          (delete-other-first
           (ox-window-zoom-test--make-buffer "*zoom-delete-other-first*"))
          (delete-other-second
           (ox-window-zoom-test--make-buffer "*zoom-delete-other-second*"))
          (resize-first (ox-window-zoom-test--make-buffer "*zoom-resize-first*"))
          (resize-second (ox-window-zoom-test--make-buffer "*zoom-resize-second*")))
      (unwind-protect
          (progn
            (ox-window-zoom-test--make-layout
             "delete" delete-first delete-second)
            (ox-window-zoom-toggle)
            (let ((this-command 'delete-window))
              (delete-window))
            (should (= 1 (length (window-list))))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states))

            (ox-window-zoom-test--make-layout
             "delete-other" delete-other-first delete-other-second)
            (ox-window-zoom-toggle)
            (let ((this-command 'delete-other-windows))
              (delete-other-windows))
            (should (= 1 (length (window-list))))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states))

            (ox-window-zoom-test--make-layout
             "resize" resize-first resize-second)
            (ox-window-zoom-toggle)
            (let ((this-command 'enlarge-window))
              (enlarge-window 1 t))
            (should (= 2 (length (window-list))))
            (should-not (gethash (get-current-persp)
                                 ox-window-zoom--states)))
        (ox-window-zoom-test--kill-buffers
         (list delete-first delete-second
               delete-other-first delete-other-second
               resize-first resize-second))))))

(provide 'ox-window-zoom-test)
;;; ox-window-zoom-test.el ends here
