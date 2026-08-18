;;; ox-ghostel-ssh.el --- Transparent SSH terminfo for Ghostel -*- lexical-binding: t; -*-

;;; Commentary:
;; Ghostel shells receive the private smart SSH shim path through an
;; environment variable.  Interactive shell configuration dispatches `ssh' to
;; the shim without shadowing the real executable in PATH for child programs.
;; The shim keeps OpenSSH authoritative while negotiating xterm-kitty terminfo.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar ghostel-pre-spawn-hook)

(defgroup ox-ghostel-ssh nil
  "Transparent SSH terminal compatibility for Ghostel."
  :group 'terminals)

(defcustom ox-ghostel-ssh-enable t
  "Whether Ghostel shells transparently use the smart SSH shim."
  :type 'boolean
  :group 'ox-ghostel-ssh)

(defcustom ox-ghostel-ssh-native-term "xterm-kitty"
  "Preferred terminal type for local and remote Ghostel sessions."
  :type 'string
  :group 'ox-ghostel-ssh)

(defcustom ox-ghostel-ssh-fallback-terms '("xterm-256color" "xterm" "dumb")
  "Terminal types tried when the native entry cannot be installed remotely."
  :type '(repeat string)
  :group 'ox-ghostel-ssh)

(defcustom ox-ghostel-ssh-cache-ttl (* 7 24 60 60)
  "Seconds before a cached remote capability decision is revalidated."
  :type 'integer
  :group 'ox-ghostel-ssh)

(defcustom ox-ghostel-ssh-debug nil
  "Whether the smart SSH shim emits sanitized negotiation diagnostics."
  :type 'boolean
  :group 'ox-ghostel-ssh)

(defcustom ox-ghostel-ssh-runtime-directory
  (expand-file-name "ox-ghostel-ssh/" user-emacs-directory)
  "Directory holding the generated shim, terminfo artifacts, and cache."
  :type 'directory
  :group 'ox-ghostel-ssh)

(defconst ox-ghostel-ssh--source-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the smart SSH implementation source.")

(defvar ox-ghostel-ssh--real-ssh nil)
(defvar ox-ghostel-ssh--warned-no-terminfo nil)

(defun ox-ghostel-ssh--bin-directory ()
  "Return the private wrapper bin directory."
  (expand-file-name "bin/" ox-ghostel-ssh-runtime-directory))

(defun ox-ghostel-ssh--wrapper-source ()
  "Return the committed shim source path."
  (expand-file-name "libexec/ox-ghostel-ssh"
                    ox-ghostel-ssh--source-directory))

(defun ox-ghostel-ssh--wrapper-path ()
  "Return the generated executable path named ssh."
  (expand-file-name "ssh" (ox-ghostel-ssh--bin-directory)))

(defun ox-ghostel-ssh--path-directories ()
  "Return current PATH entries excluding the private wrapper directory."
  (let ((wrapper-dir (file-name-as-directory
                      (expand-file-name (ox-ghostel-ssh--bin-directory)))))
    (cl-remove-if
     (lambda (directory)
       (equal wrapper-dir
              (file-name-as-directory (expand-file-name directory))))
     (parse-colon-path (or (getenv "PATH") "")))))

(defun ox-ghostel-ssh-resolve-real-executable ()
  "Resolve the real ssh before inserting the Ghostel-only wrapper directory."
  (let* ((directories (ox-ghostel-ssh--path-directories))
         (exec-path directories)
         (process-environment (copy-sequence process-environment)))
    (setenv "PATH" (mapconcat #'identity directories path-separator))
    (when-let* ((ssh (executable-find "ssh")))
      (expand-file-name ssh))))

(defun ox-ghostel-ssh--same-file-contents-p (left right)
  "Return non-nil when readable files LEFT and RIGHT have equal contents."
  (and (file-readable-p left)
       (file-readable-p right)
       (= (file-attribute-size (file-attributes left))
          (file-attribute-size (file-attributes right)))
       (with-temp-buffer
         (insert-file-contents-literally left)
         (let ((left-content (buffer-string)))
           (erase-buffer)
           (insert-file-contents-literally right)
           (equal left-content (buffer-string))))))

(defun ox-ghostel-ssh--install-wrapper ()
  "Install the committed shim as ssh in the private runtime bin directory."
  (let ((source (ox-ghostel-ssh--wrapper-source))
        (target (ox-ghostel-ssh--wrapper-path)))
    (unless (file-readable-p source)
      (error "Smart SSH shim is missing: %s" source))
    (make-directory (file-name-directory target) t)
    (unless (ox-ghostel-ssh--same-file-contents-p source target)
      (copy-file source target t))
    (set-file-modes target #o700)
    target))

(defun ox-ghostel-ssh--terminfo-directory ()
  "Return the generated local terminfo directory."
  (expand-file-name "terminfo/" ox-ghostel-ssh-runtime-directory))

(defun ox-ghostel-ssh--terminfo-source-path ()
  "Return the generated terminfo source path."
  (expand-file-name (format "%s.terminfo" ox-ghostel-ssh-native-term)
                    (ox-ghostel-ssh--terminfo-directory)))

(defun ox-ghostel-ssh--compiled-paths (&optional root)
  "Return character and hexadecimal compiled entry paths below ROOT."
  (let ((root (or root (ox-ghostel-ssh--terminfo-directory))))
    (list (expand-file-name
           (format "%c/%s" (aref ox-ghostel-ssh-native-term 0)
                   ox-ghostel-ssh-native-term)
           root)
          (expand-file-name
           (format "%x/%s" (aref ox-ghostel-ssh-native-term 0)
                   ox-ghostel-ssh-native-term)
           root))))

(defun ox-ghostel-ssh--call-to-file (program output-file &rest arguments)
  "Run PROGRAM with ARGUMENTS, writing stdout to OUTPUT-FILE.
Return non-nil only for a successful invocation."
  (when-let* ((program (executable-find program)))
    (with-temp-buffer
      (let ((status (apply #'call-process program nil t nil arguments)))
        (when (and (integerp status) (zerop status))
          (make-directory (file-name-directory output-file) t)
          (write-region (point-min) (point-max) output-file nil 'silent)
          t)))))

(defun ox-ghostel-ssh--terminfo-search-directories ()
  "Return candidate local terminfo database directories."
  (delete-dups
   (delq nil
         (append
          (and-let* ((value (getenv "TERMINFO"))) (list value))
          (and-let* ((value (getenv "TERMINFO_DIRS")))
            (split-string value path-separator t))
          (when (executable-find "infocmp")
            (condition-case nil
                (process-lines "infocmp" "-D")
              (error nil)))
          (list (expand-file-name "~/.terminfo")
                "/etc/terminfo" "/lib/terminfo" "/usr/lib/terminfo"
                "/usr/share/terminfo" "/usr/share/lib/terminfo"
                "/opt/homebrew/share/terminfo"
                "/run/current-system/sw/share/terminfo")))))

(defun ox-ghostel-ssh--find-compiled-entry ()
  "Find a readable compiled native terminfo entry on the local machine."
  (cl-loop for directory in (ox-ghostel-ssh--terminfo-search-directories)
           thereis (cl-find-if #'file-readable-p
                               (ox-ghostel-ssh--compiled-paths directory))))

(defun ox-ghostel-ssh--prepare-terminfo ()
  "Generate native terminfo source and a compiled no-tic payload.
Return a plist containing any successfully prepared paths."
  (let* ((directory (ox-ghostel-ssh--terminfo-directory))
         (source (ox-ghostel-ssh--terminfo-source-path))
         (compiled-paths (ox-ghostel-ssh--compiled-paths directory)))
    (make-directory directory t)
    (unless (file-readable-p source)
      (ox-ghostel-ssh--call-to-file
       "infocmp" source "-x" ox-ghostel-ssh-native-term))
    (unless (cl-some #'file-readable-p compiled-paths)
      (when (and (file-readable-p source) (executable-find "tic"))
        (call-process (executable-find "tic") nil nil nil
                      "-x" "-o" directory source)))
    (unless (cl-some #'file-readable-p compiled-paths)
      (when-let* ((installed (ox-ghostel-ssh--find-compiled-entry))
                  (target (car compiled-paths)))
        (make-directory (file-name-directory target) t)
        (copy-file installed target t)))
    (list :source (and (file-readable-p source) source)
          :compiled (cl-find-if #'file-readable-p compiled-paths))))

(defun ox-ghostel-ssh--safe-term-p (term)
  "Return non-nil when TERM is safe to embed in a fixed remote probe."
  (and (stringp term)
       (string-match-p "\\`[[:alnum:]_.+-]+\\'" term)))

(defun ox-ghostel-ssh--validate-configuration ()
  "Signal an error when terminal configuration is unsafe or unusable."
  (unless (ox-ghostel-ssh--safe-term-p ox-ghostel-ssh-native-term)
    (error "Unsafe native TERM: %S" ox-ghostel-ssh-native-term))
  (unless (and ox-ghostel-ssh-fallback-terms
               (cl-every #'ox-ghostel-ssh--safe-term-p
                         ox-ghostel-ssh-fallback-terms))
    (error "Fallback TERM list is empty or unsafe")))

(defun ox-ghostel-ssh--prepare ()
  "Prepare runtime files and return the terminfo artifact plist."
  (ox-ghostel-ssh--validate-configuration)
  (setq ox-ghostel-ssh--real-ssh
        (or ox-ghostel-ssh--real-ssh
            (ox-ghostel-ssh-resolve-real-executable)))
  (unless (and ox-ghostel-ssh--real-ssh
               (file-executable-p ox-ghostel-ssh--real-ssh))
    (error "Could not resolve a real ssh executable"))
  (ox-ghostel-ssh--install-wrapper)
  (let ((artifacts (ox-ghostel-ssh--prepare-terminfo)))
    (unless (or (plist-get artifacts :source)
                (plist-get artifacts :compiled)
                ox-ghostel-ssh--warned-no-terminfo)
      (setq ox-ghostel-ssh--warned-no-terminfo t)
      (display-warning
       'ox-ghostel-ssh
       (format "Local %s terminfo unavailable; remote bootstrap will fall back"
               ox-ghostel-ssh-native-term)
       :warning))
    artifacts))

(defun ox-ghostel-ssh--setenv (name value)
  "Set environment variable NAME to VALUE, or unset it when VALUE is nil."
  (setenv name (and value (format "%s" value))))

(defun ox-ghostel-ssh-inject-environment ()
  "Inject the smart SSH environment into the about-to-spawn Ghostel shell.
This function is intended only for `ghostel-pre-spawn-hook', whose dynamic
`process-environment' binding confines all changes to that Ghostel child."
  (when ox-ghostel-ssh-enable
    ;; Ghostel builds its dynamic environment with `append' and leaves the
    ;; final global list as a shared tail.  Detach it before setting the
    ;; Ghostel-only variables so `setenv' cannot mutate the global list.
    (setq process-environment (copy-sequence process-environment))
    (let ((artifacts (ox-ghostel-ssh--prepare)))
      ;; Do not prepend the wrapper to PATH.  PATH is inherited by every child
      ;; of the Ghostel shell, which would make unrelated programs such as Nix
      ;; and darwin-rebuild resolve this wrapper instead of the real ssh.
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_WRAPPER"
                              (ox-ghostel-ssh--wrapper-path))
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_REAL" ox-ghostel-ssh--real-ssh)
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_NATIVE_TERM"
                              ox-ghostel-ssh-native-term)
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_FALLBACK_TERMS"
                              (string-join ox-ghostel-ssh-fallback-terms ":"))
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_CACHE_TTL"
                              ox-ghostel-ssh-cache-ttl)
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_CACHE_DIR"
                              (expand-file-name "cache/"
                                                ox-ghostel-ssh-runtime-directory))
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_TERMINFO_SOURCE"
                              (plist-get artifacts :source))
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_TERMINFO_COMPILED"
                              (plist-get artifacts :compiled))
      (ox-ghostel-ssh--setenv "OX_GHOSTEL_SSH_DEBUG"
                              (if ox-ghostel-ssh-debug "1" "0")))))

(defun ox-ghostel-ssh-install ()
  "Enable Ghostel-only smart SSH environment injection."
  (interactive)
  (add-hook 'ghostel-pre-spawn-hook #'ox-ghostel-ssh-inject-environment))

(defun ox-ghostel-ssh-uninstall ()
  "Disable Ghostel-only smart SSH environment injection."
  (interactive)
  (remove-hook 'ghostel-pre-spawn-hook #'ox-ghostel-ssh-inject-environment))

(ox-ghostel-ssh-install)

(provide 'ox-ghostel-ssh)
;;; ox-ghostel-ssh.el ends here
