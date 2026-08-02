;;; ox-terminal.el --- Perspective-local terminal manager -*- lexical-binding: t; -*-

;;; Commentary:
;; One canonical, creation-ordered terminal list spans all registered backends.
;; Dense slots are derived display ordinals; stable IDs and ownership never
;; depend on buffer names.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ox-workspace)

(defvar ghostel-buffer-name)
(defvar ghostel-buffer-name-function)
(defvar ghostel-exit-functions)
(defvar ghostel--managed-buffer-name)
(defvar ghostel--process)
(defvar vterm-exit-functions)
(declare-function ghostel "ghostel" (&optional arg))
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function multi-vterm "multi-vterm" ())
(declare-function delete-persp-parameter "persp-mode" (param-name &optional persp))
(declare-function ox-buffer-navigation-switch-to-editing-buffer "ox-buffer-navigation" ())
(declare-function ox-buffer-navigation-forget-owner "ox-buffer-navigation" (owner-id))
(declare-function set-persp-parameter "persp-mode" (param-name &optional value persp))
(declare-function vterm-send-return "vterm" ())
(declare-function vterm-send-string "vterm" (string &optional paste-p))

(defgroup ox-terminal nil
  "Backend-neutral perspective terminals."
  :group 'ox-workspace)

(defcustom ox-terminal-default-backend 'ghostel
  "Default backend used for newly created managed terminals."
  :type '(choice
          (const :tag "Ghostel" ghostel)
          (const :tag "VTerm" vterm))
  :group 'ox-terminal)

(defconst ox-terminal-backend-parameter 'ox-terminal-backend)

(defvar-local ox-terminal-managed-p nil)
(defvar-local ox-terminal-backend nil)
(defvar-local ox-terminal-owner-id nil)
(defvar-local ox-terminal-owner-name nil)
(defvar-local ox-terminal-id nil)
(defvar-local ox-terminal-created-sequence nil)
(defvar-local ox-terminal--lifecycle-cleaned-p nil)

(defvar ox-terminal--creation-sequence 0)
(defvar ox-terminal--backends nil)
(defvar ox-terminal--registry (make-hash-table :test #'equal))
(defvar ox-terminal--rename-timers (make-hash-table :test #'equal))
(defvar ox-terminal--last-used (make-hash-table :test #'equal))

(defun ox-terminal-register-backend (backend &rest operations)
  "Register BACKEND with plist OPERATIONS."
  (setq ox-terminal--backends (assq-delete-all backend ox-terminal--backends))
  (push (cons backend operations) ox-terminal--backends)
  backend)

(defun ox-terminal--backend-operation (backend operation)
  "Return BACKEND's function for OPERATION or signal a user error."
  (let ((function (plist-get (cdr (assq backend ox-terminal--backends)) operation)))
    (unless function
      (user-error "Terminal backend %S does not implement %S" backend operation))
    function))

(defun ox-terminal--call (backend operation &rest arguments)
  "Call BACKEND OPERATION with ARGUMENTS."
  (apply (ox-terminal--backend-operation backend operation) arguments))

(defun ox-terminal-managed-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is a live manager-owned terminal."
  (let ((buffer (or (and (stringp buffer) (get-buffer buffer))
                    buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'ox-terminal-managed-p buffer))))

(defun ox-terminal-live-p (&optional buffer)
  "Return non-nil when managed terminal BUFFER's recorded backend is live."
  (let ((buffer (or (and (stringp buffer) (get-buffer buffer))
                    buffer (current-buffer))))
    (and (ox-terminal-managed-buffer-p buffer)
         (condition-case nil
             (ox-terminal--call
              (buffer-local-value 'ox-terminal-backend buffer) :live-p buffer)
           (error nil)))))

(defun ox-terminal-buffer-p (&optional buffer)
  "Return non-nil when BUFFER belongs to any registered terminal backend.
This classification includes unmanaged backend buffers but excludes Eshell."
  (let ((buffer (or (and (stringp buffer) (get-buffer buffer))
                    buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (or (ox-terminal-managed-buffer-p buffer)
             (cl-some (lambda (entry)
                        (let ((predicate (plist-get (cdr entry) :buffer-p)))
                          (and predicate (funcall predicate buffer))))
                      ox-terminal--backends)))))

(cl-defun ox-terminal--owner-id
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return PERSPECTIVE's owner identity, creating it when necessary."
  (ox-workspace-id perspective))

(cl-defun ox-terminal-buffers
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return live managed terminals owned by PERSPECTIVE in creation order.
When PERSPECTIVE is omitted use the current perspective.  This is the only
authoritative terminal collection and ordering function."
  (when-let* ((owner-id (ox-workspace-id perspective t)))
    (ox-terminal--buffers-for-owner owner-id)))

(defun ox-terminal--register-buffer (buffer)
  "Register managed terminal BUFFER under its recorded owner."
  (when (ox-terminal-managed-buffer-p buffer)
    (let* ((owner-id (buffer-local-value 'ox-terminal-owner-id buffer))
           (buffers (gethash owner-id ox-terminal--registry)))
      (puthash owner-id (cons buffer (delq buffer buffers))
               ox-terminal--registry)))
  buffer)

(defun ox-terminal--unregister-buffer (buffer owner-id)
  "Remove BUFFER from OWNER-ID's managed terminal registry."
  (let ((buffers (delq buffer (gethash owner-id ox-terminal--registry))))
    (if buffers
        (puthash owner-id buffers ox-terminal--registry)
      (remhash owner-id ox-terminal--registry))))

(defun ox-terminal--rebuild-registry ()
  "Rebuild managed terminal registry once after loading this module.
This preserves live managed terminals when the implementation is reloaded;
normal collection never scans the global buffer list."
  (clrhash ox-terminal--registry)
  (dolist (buffer (buffer-list))
    (when (ox-terminal-managed-buffer-p buffer)
      (ox-terminal--register-buffer buffer))))

(defun ox-terminal--buffers-for-owner (owner-id)
  "Return canonical terminal list for OWNER-ID without current-perspective use."
  (let ((buffers
         (sort
          (cl-remove-if-not
           (lambda (buffer)
             (and (ox-terminal-live-p buffer)
                  (equal owner-id
                         (buffer-local-value 'ox-terminal-owner-id buffer))))
           (copy-sequence (gethash owner-id ox-terminal--registry)))
          (lambda (left right)
            (< (buffer-local-value 'ox-terminal-created-sequence left)
               (buffer-local-value 'ox-terminal-created-sequence right))))))
    (if buffers
        (puthash owner-id buffers ox-terminal--registry)
      (remhash owner-id ox-terminal--registry))
    buffers))

(cl-defun ox-terminal-count
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return the managed terminal count for PERSPECTIVE."
  (length (ox-terminal-buffers perspective)))

(cl-defun ox-terminal-perspective-backend
    (&optional (perspective (ox-workspace-current-perspective)))
  "Return PERSPECTIVE's backend override, or nil."
  (when (fboundp 'persp-parameter)
    (persp-parameter ox-terminal-backend-parameter perspective)))

(cl-defun ox-terminal-resolved-backend
    (&optional (perspective (ox-workspace-current-perspective)))
  "Resolve the backend for a new terminal in PERSPECTIVE."
  (let ((backend (or (ox-terminal-perspective-backend perspective)
                     ox-terminal-default-backend)))
    (unless (memq backend '(ghostel vterm))
      (user-error "Unsupported terminal backend: %S" backend))
    backend))

(defun ox-terminal-set-perspective-backend (backend)
  "Use BACKEND for future terminals in the current perspective."
  (interactive
   (list (intern (completing-read "Perspective terminal backend: "
                                  '("ghostel" "vterm") nil t))))
  (unless (memq backend '(ghostel vterm))
    (user-error "Unsupported terminal backend: %S" backend))
  (set-persp-parameter ox-terminal-backend-parameter backend
                       (ox-workspace-current-perspective))
  (force-mode-line-update t)
  (message "Perspective %s will create new %s terminals"
           (ox-workspace-perspective-name) backend))

(defun ox-terminal-clear-perspective-backend ()
  "Clear the current perspective's terminal backend override."
  (interactive)
  (delete-persp-parameter ox-terminal-backend-parameter
                          (ox-workspace-current-perspective))
  (force-mode-line-update t)
  (message "Perspective %s will use global terminal backend %s"
           (ox-workspace-perspective-name) ox-terminal-default-backend))

(defun ox-terminal-toggle-default-backend ()
  "Toggle the global default backend for future terminals."
  (interactive)
  (setq ox-terminal-default-backend
        (if (eq ox-terminal-default-backend 'ghostel) 'vterm 'ghostel))
  (force-mode-line-update t)
  (message "New terminals without an override will use %s"
           ox-terminal-default-backend))

(defun ox-terminal-creation-directory (&optional perspective buffer)
  "Return the creation directory for PERSPECTIVE and BUFFER.
Prefer attached project metadata, then BUFFER's absolute `default-directory',
then the user's home.  No project discovery or remote traversal is performed."
  (or (ox-workspace-project-root perspective)
      (let ((directory (buffer-local-value
                        'default-directory (or buffer (current-buffer)))))
        (and (stringp directory)
             (file-name-absolute-p directory)
             directory))
      (expand-file-name "~/")))

(defun ox-terminal--vterm-create (directory)
  "Create a fresh multi-vterm terminal in DIRECTORY."
  (require 'multi-vterm)
  (let ((default-directory directory))
    (multi-vterm)
    (current-buffer)))

(defun ox-terminal--vterm-buffer-p (buffer)
  "Return non-nil when BUFFER is a vterm buffer."
  (with-current-buffer buffer (derived-mode-p 'vterm-mode)))

(defun ox-terminal--vterm-live-p (buffer)
  "Return non-nil when BUFFER's vterm process is live."
  (let ((process (get-buffer-process buffer)))
    (and process (process-live-p process))))

(defun ox-terminal--vterm-send-string (buffer string)
  "Send STRING to vterm BUFFER."
  (with-current-buffer buffer (vterm-send-string string)))

(defun ox-terminal--vterm-send-return (buffer)
  "Send return to vterm BUFFER."
  (with-current-buffer buffer (vterm-send-return)))

(defun ox-terminal--ghostel-create (directory)
  "Create a fresh Ghostel terminal in DIRECTORY using its public command."
  (require 'ghostel)
  (let ((default-directory directory)
        (ghostel-buffer-name
         (format "*ox-ghostel-bootstrap-%d*" (1+ ox-terminal--creation-sequence)))
        (ghostel-buffer-name-function nil))
    (ghostel '(4))))

(defun ox-terminal--ghostel-buffer-p (buffer)
  "Return non-nil when BUFFER is a Ghostel buffer."
  (with-current-buffer buffer (derived-mode-p 'ghostel-mode)))

(defun ox-terminal--ghostel-live-p (buffer)
  "Return non-nil when BUFFER's Ghostel lifecycle process is live.
`ghostel--process' is private; this single adapter boundary is necessary
because native-PTY Ghostel buffers do not expose a portable public process
accessor."
  (with-current-buffer buffer
    (and (boundp 'ghostel--process)
         ghostel--process
         (process-live-p ghostel--process))))

(defun ox-terminal--ghostel-send-string (buffer string)
  "Send STRING to Ghostel BUFFER."
  (with-current-buffer buffer (ghostel-send-string string)))

(defun ox-terminal--ghostel-send-return (buffer)
  "Send return to Ghostel BUFFER."
  (with-current-buffer buffer (ghostel-send-key "return")))

(defun ox-terminal--kill-buffer (buffer)
  "Kill terminal BUFFER through normal Emacs safeguards."
  (kill-buffer buffer))

(ox-terminal-register-backend
 'vterm
 :create #'ox-terminal--vterm-create
 :buffer-p #'ox-terminal--vterm-buffer-p
 :live-p #'ox-terminal--vterm-live-p
 :send-string #'ox-terminal--vterm-send-string
 :send-return #'ox-terminal--vterm-send-return
 :kill #'ox-terminal--kill-buffer)

(ox-terminal-register-backend
 'ghostel
 :create #'ox-terminal--ghostel-create
 :buffer-p #'ox-terminal--ghostel-buffer-p
 :live-p #'ox-terminal--ghostel-live-p
 :send-string #'ox-terminal--ghostel-send-string
 :send-return #'ox-terminal--ghostel-send-return
 :kill #'ox-terminal--kill-buffer)

(defun ox-terminal--new-id (sequence)
  "Return a stable terminal ID incorporating SEQUENCE."
  (format "terminal-%d-%s" sequence
          (substring (md5 (format "%s:%s:%s" sequence (float-time) (random)))
                     0 8)))

(defun ox-terminal--sanitize-name (name)
  "Sanitize perspective NAME for a descriptive buffer name."
  (let ((name (replace-regexp-in-string "[^[:alnum:]_.@+-]" "_" name)))
    (if (string-empty-p name) "workspace" name)))

(defun ox-terminal--owner-display-name (owner-id buffers)
  "Return the display name for OWNER-ID, falling back to BUFFERS metadata."
  (let ((perspective (ox-workspace-perspective-by-id owner-id)))
    (or (and perspective (ox-workspace-perspective-name perspective))
        (and buffers
             (buffer-local-value 'ox-terminal-owner-name (car buffers)))
        "workspace")))

(defun ox-terminal--owner-name-token (owner-id)
  "Return a short stable display token derived from OWNER-ID."
  (substring (md5 owner-id) 0 6))

(defun ox-terminal--final-name (owner-name owner-id slot)
  "Return neutral dense terminal name for OWNER-NAME, OWNER-ID and SLOT.
The owner token prevents distinct perspective names that sanitize identically
from colliding while human-readable workspace names remain visible."
  (format "*%s-%s-terminal*<%d>"
          (ox-terminal--sanitize-name owner-name)
          (ox-terminal--owner-name-token owner-id)
          slot))

(defun ox-terminal-renumber-owner (owner-id)
  "Densely rename terminals owned by OWNER-ID using a collision-safe pass."
  (let* ((buffers (ox-terminal--buffers-for-owner owner-id))
         (owner-name (ox-terminal--owner-display-name owner-id buffers))
         (final-names (cl-loop for slot from 1 to (length buffers)
                               collect (ox-terminal--final-name
                                        owner-name owner-id slot))))
    (cl-loop for name in final-names
             for occupant = (get-buffer name)
             when (and occupant (not (memq occupant buffers)))
             do (user-error "Cannot renumber terminals: buffer %s already exists" name))
    (cl-loop for buffer in buffers
             for slot from 1
             do (with-current-buffer buffer
                  (rename-buffer
                   (format " *ox-terminal-renaming-%s-%d*" ox-terminal-id slot))))
    (cl-mapc (lambda (buffer name)
               (with-current-buffer buffer (rename-buffer name)))
             buffers final-names)
    (force-mode-line-update t)
    buffers))

(defun ox-terminal--run-scheduled-renumber (owner-id)
  "Run and forget OWNER-ID's deferred renumber operation."
  (remhash owner-id ox-terminal--rename-timers)
  (ox-terminal-renumber-owner owner-id))

(defun ox-terminal-schedule-renumber (owner-id &optional delay)
  "Schedule dense renumbering for OWNER-ID after DELAY."
  (when-let* ((old (gethash owner-id ox-terminal--rename-timers)))
    (when (timerp old) (cancel-timer old)))
  (puthash owner-id
           (run-at-time (or delay 0) nil
                        #'ox-terminal--run-scheduled-renumber owner-id)
           ox-terminal--rename-timers))

(defun ox-terminal--nearest-survivor (buffers sequence)
  "Return the terminal in BUFFERS nearest to dying terminal SEQUENCE."
  (or (cl-find-if
       (lambda (buffer)
         (> (buffer-local-value 'ox-terminal-created-sequence buffer) sequence))
       buffers)
      (car (last buffers))))

(defun ox-terminal--cleanup-buffer (buffer)
  "Run owner-specific lifecycle cleanup for managed terminal BUFFER once."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'ox-terminal-managed-p buffer)
             (not (buffer-local-value
                   'ox-terminal--lifecycle-cleaned-p buffer)))
    (with-current-buffer buffer
      (setq ox-terminal--lifecycle-cleaned-p t)
      (let ((owner-id ox-terminal-owner-id)
            (sequence ox-terminal-created-sequence)
            (window (get-buffer-window buffer t)))
        (ox-terminal--unregister-buffer buffer owner-id)
        (when (eq (gethash owner-id ox-terminal--last-used) buffer)
          (if-let* ((replacement
                     (ox-terminal--nearest-survivor
                      (ox-terminal--buffers-for-owner owner-id) sequence)))
              (puthash owner-id replacement ox-terminal--last-used)
            (remhash owner-id ox-terminal--last-used)))
        (ox-terminal-schedule-renumber owner-id 0)
        (when (fboundp 'ox-buffer-navigation-after-terminal-kill)
          (ox-buffer-navigation-after-terminal-kill owner-id window sequence))))))

(defun ox-terminal--cleanup-current-buffer ()
  "Run lifecycle cleanup for the dying current managed terminal."
  (ox-terminal--cleanup-buffer (current-buffer)))

(defun ox-terminal--backend-exited (buffer _event)
  "Clean up managed terminal BUFFER after a backend process exit EVENT."
  (when (and buffer
             (buffer-live-p buffer)
             (ox-terminal-managed-buffer-p buffer))
    (ox-terminal--cleanup-buffer buffer)))

(defun ox-terminal-create (&optional backend directory)
  "Create and register a managed terminal using BACKEND in DIRECTORY.
When BACKEND is nil, resolve the perspective override then the global default.
When DIRECTORY is nil, use `ox-terminal-creation-directory'.  The explicit
directory argument is for host-specific convenience commands."
  (interactive)
  (let* ((perspective (ox-workspace-current-perspective))
         (owner-id (ox-terminal--owner-id perspective))
         (owner-name (ox-workspace-perspective-name perspective))
         (backend (or backend (ox-terminal-resolved-backend perspective)))
         (directory (or directory
                        (ox-terminal-creation-directory perspective
                                                        (current-buffer))))
         (editing-buffer (current-buffer))
         buffer)
    (unless (assq backend ox-terminal--backends)
      (user-error "Unregistered terminal backend: %S" backend))
    (when (fboundp 'ox-buffer-navigation-record-buffer)
      (ox-buffer-navigation-record-buffer editing-buffer perspective))
    (setq buffer (ox-terminal--call backend :create directory))
    (unless (buffer-live-p buffer)
      (error "Backend %S did not return a live terminal buffer" backend))
    (setq ox-terminal--creation-sequence (1+ ox-terminal--creation-sequence))
    (with-current-buffer buffer
      (setq-local ox-terminal-managed-p t)
      (setq-local ox-terminal-backend backend)
      (setq-local ox-terminal-owner-id owner-id)
      (setq-local ox-terminal-owner-name owner-name)
      (setq-local ox-terminal-created-sequence ox-terminal--creation-sequence)
      (setq-local ox-terminal-id
                  (ox-terminal--new-id ox-terminal-created-sequence))
      (setq-local ox-terminal--lifecycle-cleaned-p nil)
      ;; A managed Ghostel name is workspace state, not terminal-title state.
      (when (eq backend 'ghostel)
        (setq-local ghostel-buffer-name-function nil))
      (add-hook 'kill-buffer-hook #'ox-terminal--cleanup-current-buffer nil t))
    (ox-terminal--register-buffer buffer)
    (when (and perspective (fboundp 'persp-add-buffer))
      (persp-add-buffer buffer perspective nil nil))
    (puthash owner-id buffer ox-terminal--last-used)
    (ox-terminal-renumber-owner owner-id)
    (switch-to-buffer buffer)
    buffer))

(defun ox-terminal-switch-to-buffer (buffer)
  "Switch to managed terminal BUFFER and remember it as last used."
  (unless (ox-terminal-managed-buffer-p buffer)
    (user-error "Not a managed terminal: %S" buffer))
  (when (and (fboundp 'ox-buffer-navigation-record-buffer)
             (not (ox-terminal-buffer-p (current-buffer))))
    (ox-buffer-navigation-record-buffer (current-buffer)))
  (puthash (buffer-local-value 'ox-terminal-owner-id buffer)
           buffer ox-terminal--last-used)
  (switch-to-buffer buffer)
  buffer)

(defun ox-terminal-switch-to-slot (slot)
  "Switch to dense SLOT, creating it only when it is the next slot."
  (interactive "nTerminal slot: ")
  (let* ((buffers (ox-terminal-buffers))
         (count (length buffers)))
    (cond
     ((and (> slot 0) (<= slot count))
      (ox-terminal-switch-to-buffer (nth (1- slot) buffers)))
     ((= slot (1+ count)) (ox-terminal-create))
     ((<= slot 0) (user-error "Terminal slots start at 1"))
     (t (user-error "Cannot create slot %d; next available slot is %d"
                    slot (1+ count))))))

(defun ox-terminal-select ()
  "Select a current-perspective managed terminal through completion."
  (interactive)
  (let ((buffers (ox-terminal-buffers)))
    (unless buffers (user-error "No managed terminals in this perspective"))
    (let* ((choices
            (cl-loop for buffer in buffers for slot from 1
                     collect
                     (cons (format "%d  %-7s %s" slot
                                   (buffer-local-value 'ox-terminal-backend buffer)
                                   (buffer-name buffer))
                           buffer)))
           (choice (completing-read "Terminal: " choices nil t)))
      (ox-terminal-switch-to-buffer (cdr (assoc choice choices))))))

(defun ox-terminal-switch-to-last ()
  "Switch to the last-used managed terminal in the current perspective."
  (interactive)
  (let* ((owner-id (ox-workspace-id (ox-workspace-current-perspective) t))
         (buffers (ox-terminal-buffers))
         (last (and owner-id (gethash owner-id ox-terminal--last-used)))
         (target (if (memq last buffers) last (car buffers))))
    (when target (ox-terminal-switch-to-buffer target))))

(defun ox-terminal-cycle (&optional offset)
  "Cycle through canonical terminals by OFFSET, defaulting to one."
  (interactive "p")
  (let* ((buffers (ox-terminal-buffers))
         (count (length buffers)))
    (unless (> count 0) (user-error "No managed terminals in this perspective"))
    (let* ((owner-id (ox-workspace-id (ox-workspace-current-perspective) t))
           (last (gethash owner-id ox-terminal--last-used))
           (offset (or offset 1))
           (start (or (cl-position (current-buffer) buffers)
                      (cl-position last buffers)))
           (target (if start
                       (nth (mod (+ start offset) count) buffers)
                     (if (< offset 0) (car (last buffers)) (car buffers)))))
      (ox-terminal-switch-to-buffer target))))

(defun ox-terminal-cycle-previous (&optional offset)
  "Cycle backward through terminals by OFFSET."
  (interactive "p")
  (ox-terminal-cycle (- (or offset 1))))

(defun ox-terminal-send-string (string &optional buffer)
  "Send STRING through managed terminal BUFFER's recorded backend."
  (let ((buffer (or buffer (current-buffer))))
    (unless (ox-terminal-managed-buffer-p buffer)
      (user-error "Not a managed terminal"))
    (ox-terminal--call (buffer-local-value 'ox-terminal-backend buffer)
                       :send-string buffer string)))

(defun ox-terminal-send-return (&optional buffer)
  "Send return through managed terminal BUFFER's recorded backend."
  (let ((buffer (or buffer (current-buffer))))
    (unless (ox-terminal-managed-buffer-p buffer)
      (user-error "Not a managed terminal"))
    (ox-terminal--call (buffer-local-value 'ox-terminal-backend buffer)
                       :send-return buffer)))

(defun ox-terminal-kill (&optional buffer)
  "Kill managed terminal BUFFER through its recorded backend."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (unless (ox-terminal-managed-buffer-p buffer)
      (user-error "Not a managed terminal"))
    (ox-terminal--call (buffer-local-value 'ox-terminal-backend buffer)
                       :kill buffer)))

(defvar ox-terminal-count-modeline-format
  '(:eval (let ((count (and (bound-and-true-p persp-mode)
                            (ox-terminal-count))))
            (when (and count (> count 0))
              (format "%s%d" (string #x1F5A5 #xFE0F) count))))
  "Mode-line format showing managed terminals in the current perspective.")

(defun ox-terminal--count-modeline-entry-p (entry)
  "Return non-nil when ENTRY is an old or current terminal count segment."
  (let ((parts (flatten-tree entry)))
    (or (memq 'ox-terminal-count parts)
        (memq 'my/persp-vterm-buffer-count parts)
        (and (boundp 'my/vterm-count-modeline-format)
             (equal entry my/vterm-count-modeline-format)))))

(defun ox-terminal-install-modeline ()
  "Install exactly one managed-terminal count entry.
Remove both current duplicates and the former vterm-only entry so manually
re-evaluating old and new configuration blocks cannot accumulate icons."
  (setq mode-line-misc-info
        (cl-remove-if #'ox-terminal--count-modeline-entry-p
                      mode-line-misc-info))
  (add-to-list 'mode-line-misc-info ox-terminal-count-modeline-format t))

(defun ox-terminal--perspective-changed (&rest _)
  "Refresh terminal modeline state after a perspective change."
  (force-mode-line-update t))

(defun ox-terminal--de-adopt-buffer (buffer)
  "Remove manager ownership from BUFFER without killing it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local ox-terminal-managed-p nil)
      (remove-hook 'kill-buffer-hook
                   #'ox-terminal--cleanup-current-buffer t)
      ;; Managed Ghostel buffers disable title-driven naming.  Restore the
      ;; inherited Ghostel behavior when the buffer survives its perspective.
      (when (eq ox-terminal-backend 'ghostel)
        (kill-local-variable 'ghostel-buffer-name-function)
        ;; The manager manually renamed this buffer.  Ghostel otherwise treats
        ;; that as a user rename and refuses subsequent title-based renaming.
        ;; Clearing its remembered managed name lets the next OSC title or
        ;; directory update claim the buffer name again.
        (kill-local-variable 'ghostel--managed-buffer-name)))))

(defun ox-terminal--perspective-killing (perspective)
  "Discard managed terminal state for PERSPECTIVE before it is killed."
  (when-let* ((owner-id (ox-workspace-id perspective t)))
    (when-let* ((timer (gethash owner-id ox-terminal--rename-timers)))
      (when (timerp timer) (cancel-timer timer)))
    ;; `persp-kill-without-buffers' removes buffers from the perspective but
    ;; deliberately leaves them alive.  De-adopt them so they cannot remain
    ;; orphaned manager-owned terminals after their workspace disappears.
    (dolist (buffer (copy-sequence
                     (gethash owner-id ox-terminal--registry)))
      (ox-terminal--de-adopt-buffer buffer))
    (remhash owner-id ox-terminal--rename-timers)
    (remhash owner-id ox-terminal--last-used)
    (remhash owner-id ox-terminal--registry)
    (when (fboundp 'ox-buffer-navigation-forget-owner)
      (ox-buffer-navigation-forget-owner owner-id))))

(defun ox-terminal--perspective-renamed (perspective _old-name new-name)
  "Refresh terminal display names after PERSPECTIVE becomes NEW-NAME."
  (when-let* ((owner-id (ox-workspace-id perspective t)))
    (dolist (buffer (ox-terminal--buffers-for-owner owner-id))
      (with-current-buffer buffer (setq ox-terminal-owner-name new-name)))
    (ox-terminal-renumber-owner owner-id)))

(defvar ox-terminal-prefix-map (make-sparse-keymap)
  "Prefix map for backend-neutral terminal commands.")

(defun ox-terminal--build-prefix-map ()
  "Build the reload-safe terminal prefix map."
  (setcdr ox-terminal-prefix-map nil)
  (dotimes (index 9)
    (let ((slot (1+ index)))
      (define-key ox-terminal-prefix-map (number-to-string slot)
                  (lambda ()
                    (interactive)
                    (ox-terminal-switch-to-slot slot)))))
  (define-key ox-terminal-prefix-map "0" #'ox-terminal-select)
  (define-key ox-terminal-prefix-map "l"
              #'ox-buffer-navigation-switch-to-editing-buffer))

(defun ox-terminal--install-global-keybindings ()
  "Install global terminal prefix and input-method bindings."
  (global-unset-key (kbd "C-\\"))
  (define-key global-map (kbd "C-|") #'toggle-input-method)
  (define-key global-map (kbd "C-\\") ox-terminal-prefix-map)
  ox-terminal-prefix-map)

(defun ox-terminal--install-terminal-keybindings ()
  "Install bindings in terminal and Evil terminal maps that are loaded."
  (dolist (map-symbol '(vterm-mode-map ghostel-mode-map evil-ghostel-mode-map
                       ghostel-semi-char-mode-map ghostel-char-mode-map
                       ghostel-readonly-mode-map ghostel-line-mode-map))
    (when (boundp map-symbol)
      (define-key (symbol-value map-symbol) (kbd "C-\\") ox-terminal-prefix-map)))
  (when (fboundp 'evil-define-key)
    (dolist (map-symbol '(vterm-mode-map evil-ghostel-mode-map))
      (when (boundp map-symbol)
        (evil-define-key '(normal visual insert) (symbol-value map-symbol)
          (kbd "C-\\") ox-terminal-prefix-map
          (kbd "C-6") #'ox-buffer-navigation-switch-to-editing-buffer)))))

(defun ox-terminal-install-keybindings ()
  "Install reload-safe global and terminal-local bindings."
  (ox-terminal--build-prefix-map)
  (ox-terminal--install-global-keybindings)
  (ox-terminal--install-terminal-keybindings))

(defun ox-terminal--setup-perspective-hooks ()
  "Install named persp-mode lifecycle hooks without duplication."
  (add-hook 'persp-activated-functions #'ox-terminal--perspective-changed)
  (add-hook 'persp-before-kill-functions #'ox-terminal--perspective-killing)
  (add-hook 'persp-renamed-functions #'ox-terminal--perspective-renamed))

(defun ox-terminal--setup-vterm ()
  "Install vterm lifecycle and keymap integration."
  (add-hook 'vterm-exit-functions #'ox-terminal--backend-exited)
  (ox-terminal--install-terminal-keybindings))

(defun ox-terminal--setup-ghostel ()
  "Install Ghostel lifecycle and keymap integration."
  (add-hook 'ghostel-exit-functions #'ox-terminal--backend-exited)
  (ox-terminal--install-terminal-keybindings))

(defun ox-terminal--setup-evil-keybindings ()
  "Install Evil bindings after Evil or its Ghostel integration loads."
  (ox-terminal--install-terminal-keybindings))

(ox-terminal-install-modeline)
(ox-terminal-install-keybindings)
(remove-hook 'after-load-functions 'ox-terminal--after-load-setup)
(ox-terminal--rebuild-registry)
(with-eval-after-load 'persp-mode (ox-terminal--setup-perspective-hooks))
(with-eval-after-load 'vterm (ox-terminal--setup-vterm))
(with-eval-after-load 'ghostel (ox-terminal--setup-ghostel))
(with-eval-after-load 'evil (ox-terminal--setup-evil-keybindings))
(with-eval-after-load 'evil-ghostel (ox-terminal--setup-evil-keybindings))

;; Compatibility entry points.  Their implementations use only managed state.
(defalias 'my/vterm-buffer-p #'ox-terminal-buffer-p)
(defalias 'my/persp-vterm-buffer-count #'ox-terminal-count)
(defalias 'switch-to-last-persp-vterm #'ox-terminal-switch-to-last)
(defalias 'switch-to-next-persp-vterm-from-last #'ox-terminal-cycle)
(defalias 'switch-to-prev-persp-vterm-from-last #'ox-terminal-cycle-previous)
(defalias 'my-switch-to-persp-vterm-by-number #'ox-terminal-switch-to-slot)
(defalias 'my/rename-persp-vterm-buffers
  (lambda () (interactive) (ox-terminal-renumber-owner (ox-terminal--owner-id))))

(provide 'ox-terminal)
;;; ox-terminal.el ends here
