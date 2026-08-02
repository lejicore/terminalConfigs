;;; ox-workspace.el --- Perspective workspace metadata -*- lexical-binding: t; -*-

;;; Commentary:
;; Perspectives are workspaces.  Projects and terminal backends are optional
;; metadata; neither is inferred from a perspective's display name.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)

(declare-function delete-persp-parameter "persp-mode" (param-name &optional persp))
(declare-function persp-switch "persp-mode" (name &optional frame window called-interactively-p))
(declare-function set-persp-parameter "persp-mode" (param-name &optional value persp))
(declare-function tramp-file-name-host "tramp" (vec))

(defgroup ox-workspace nil
  "Perspective-backed workspaces."
  :group 'convenience)

(defconst ox-workspace-project-parameter 'ox-project-root)
(defconst ox-workspace-id-parameter 'ox-workspace-id)

(defvar ox-workspace--id-sequence 0)

(defun ox-workspace-current-perspective ()
  "Return the current perspective, including nil perspective support."
  (cond
   ((fboundp 'get-current-persp) (get-current-persp))
   ((fboundp 'get-frame-persp) (get-frame-persp))
   (t nil)))

(cl-defun ox-workspace-perspective-name
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return the display name of PERSPECTIVE or the current perspective."
  (cond
   ((and perspective (fboundp 'safe-persp-name))
    (safe-persp-name perspective))
   ((and (null perspective) (boundp 'persp-nil-name)) persp-nil-name)
   ((null perspective) "none")
   (t (format "%s" perspective))))

(defun ox-workspace-perspectives ()
  "Return all known perspectives in persp-mode's public ordering."
  (if (and (fboundp 'persp-names) (fboundp 'persp-get-by-name))
      (mapcar #'persp-get-by-name (persp-names))
    (list (ox-workspace-current-perspective))))

(defun ox-workspace--new-id ()
  "Return a process-local unique workspace identity."
  (setq ox-workspace--id-sequence (1+ ox-workspace--id-sequence))
  (format "workspace-%d-%s"
          ox-workspace--id-sequence
          (substring (md5 (format "%s:%s:%s"
                                  (float-time) (random) (emacs-pid)))
                     0 10)))

(cl-defun ox-workspace-id
    (&optional (perspective (ox-workspace-current-perspective)) no-create)
  "Return PERSPECTIVE's stable identity.
Use the current perspective when PERSPECTIVE is omitted.  Unless NO-CREATE is
non-nil, create and store an identity when one is absent."
  (let* ((id (and (fboundp 'persp-parameter)
                  (persp-parameter ox-workspace-id-parameter perspective))))
    (cond
     (id id)
     (no-create nil)
     ((fboundp 'set-persp-parameter)
      (setq id (ox-workspace--new-id))
      (set-persp-parameter ox-workspace-id-parameter id perspective)
      id)
     (t "workspace-global"))))

(defun ox-workspace-perspective-by-id (id)
  "Return the perspective carrying workspace identity ID."
  (cl-find-if (lambda (perspective)
                (equal id (ox-workspace-id perspective t)))
              (ox-workspace-perspectives)))

(defun ox-workspace-normalize-root (root)
  "Normalize ROOT without resolving symlinks or traversing TRAMP.
The result is absolute and has exactly one trailing directory separator."
  (when (and (stringp root) (not (string-empty-p root)))
    (file-name-as-directory
     (directory-file-name (expand-file-name root)))))

(cl-defun ox-workspace-project-root
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return PERSPECTIVE's normalized primary project root, or nil."
  (when (fboundp 'persp-parameter)
    (persp-parameter ox-workspace-project-parameter perspective)))

(cl-defun ox-workspace-set-project-root
    (root &optional (perspective (ox-workspace-current-perspective)))
  "Attach normalized ROOT to PERSPECTIVE and return it."
  (let ((root (ox-workspace-normalize-root root)))
    (unless root (user-error "Project root must be a non-empty directory name"))
    (set-persp-parameter ox-workspace-project-parameter root perspective)
    (ox-workspace-id perspective)
    root))

(defun ox-workspace-attach-project (root)
  "Attach ROOT as the current perspective's primary project."
  (interactive (list (read-directory-name "Attach project root: " nil nil t)))
  (let ((root (ox-workspace-set-project-root root)))
    (message "Perspective %s attached to %s"
             (ox-workspace-perspective-name) root)))

(defun ox-workspace-detach-project ()
  "Remove the current perspective's primary project association."
  (interactive)
  (delete-persp-parameter ox-workspace-project-parameter
                          (ox-workspace-current-perspective))
  (message "Perspective %s is now projectless"
           (ox-workspace-perspective-name)))

(defun ox-workspace-perspectives-for-project (root)
  "Return perspectives whose exact stored project root equals ROOT."
  (let ((root (ox-workspace-normalize-root root)))
    (cl-remove-if-not
     (lambda (perspective)
       (equal root (ox-workspace-project-root perspective)))
     (ox-workspace-perspectives))))

(defun ox-workspace--remote-host (root)
  "Return ROOT's TRAMP host without opening a connection."
  (when (and (file-remote-p root) (fboundp 'tramp-dissect-file-name))
    (require 'tramp)
    (tramp-file-name-host (tramp-dissect-file-name root))))

(defun ox-workspace-unique-project-name (root)
  "Return a deterministic unused perspective name for ROOT.
Use the project basename, then BASE@HOST for a remote collision, and finally
BASE<N> with the first available integer N starting at 2."
  (let* ((root (ox-workspace-normalize-root root))
         (base (file-name-nondirectory (directory-file-name root)))
         (base (if (string-empty-p base) "project" base))
         (names (and (fboundp 'persp-names) (persp-names)))
         (host (ox-workspace--remote-host root))
         (remote-name (and host (format "%s@%s" base host))))
    (cond
     ((not (member base names)) base)
     ((and remote-name (not (member remote-name names))) remote-name)
     (t
      (let ((index 2)
            candidate)
        (while (progn
                 (setq candidate (format "%s<%d>" base index))
                 (setq index (1+ index))
                 (member candidate names)))
        candidate)))))

(defun ox-workspace-switch-to-project (root)
  "Switch to the workspace attached to ROOT, creating one when needed.
Project identity is the exact normalized root, never its basename."
  (interactive (list (read-directory-name "Project root: " nil nil t)))
  (let* ((root (ox-workspace-normalize-root root))
         (matches (ox-workspace-perspectives-for-project root))
         (existing (car matches))
         (name (if matches
                   (ox-workspace-perspective-name existing)
                 (ox-workspace-unique-project-name root))))
    (persp-switch name)
    (unless matches
      (ox-workspace-set-project-root root (ox-workspace-current-perspective)))
    (project-switch-project root)
    name))

(provide 'ox-workspace)
;;; ox-workspace.el ends here
