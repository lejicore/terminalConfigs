;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!


;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
(setq user-full-name "John Doe"
    user-mail-address "john@doe.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;; - `doom-unicode-font' -- for unicode glyphs
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;

;;(setq doom-font (font-spec :size 14.0))
;;(setq doom-unicode-font (font-spec :family "Symbola" :size 12.0)
(setq doom-font (font-spec :family "Fira Code Nerd Font" :size 12.0 :weight 'regular))
;; (plist-put! +ligatures-extra-symbols
;;             :true          "𝕋"
;;             :false         "𝔽"
;;             )
;;      doom-variable-pitch-font (font-spec :family "Fira Sans" :size 13))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
;;(setq doom-theme 'doom-challenger-deep)
(setq doom-theme 'doom-moonlight)

;; To have transparent frames
;;(setq my/opacity 90)
(set-frame-parameter nil 'alpha-background 90) ; For current frame
(add-to-list 'default-frame-alist '(alpha-background . 90)) ; For all new frames henceforth


;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type 'relative)

;; Disable auto pairs if it feels annoying
;;(remove-hook 'doom-first-buffer-hook #'smartparens-global-mode)

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/org/")
(setq org-log-done 'time)


;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `after!' block, otherwise Doom's defaults may override your settings. E.g.
;;
;;   (after! PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look up their documentation).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.

(setq lsp-clients-angular-language-server-command
    '("node"
         "~/.nodenv/versions/16.10.0/lib/node_modules/@angular/language-server"
         "--ngProbeLocations"
         "~/.nodenv/versions/16.10.0/lib/node_modules"
         "--tsProbeLocations"
         "~/.nodenv/versions/16.10.0/lib/node_modules"
         "--stdio"))

(advice-add 'json-parse-buffer :around
    (lambda (orig &rest rest)
        (while (re-search-forward "\\u0000" nil t)
            (replace-match ""))
        (apply orig rest)))

(setq which-key-idle-delay 1)
;; quick shortcut to change fast between php mode and web-mode
(defun toggle-php-flavor-mode ()
    "Toggle mode between PHP & Web-Mode Helper modes"
    (interactive)
    (cond ((string= mode-name "PHP\\\\l")
              (web-mode))
        ((string= mode-name "PHP")
            (web-mode))
        ((string= mode-name "Web")
            (php-mode))))

;;(global-set-key [f5] 'toggle-php-flavor-mode)
;;(setq display-line-numbers 'relative)
;;(require 'back-button)
;;(back-button-mode 1)
;;press the plus sign in the toolbar to create a mark
;;press the arrows in the toolbar to navigate marks
;;or use C-x C-Space as usual
;;(use-package frog-jump-buffer :ensure t)
(use-package frog-jump-buffer)

(defvar my-keys-minor-mode-map
    (let ((map (make-sparse-keymap)))
        (define-key map (kbd "C-|") 'frog-jump-buffer)
        map)
    "my-keys-minor-mode keymap.")

(define-minor-mode my-keys-minor-mode
    "A minor mode so that my key settings override annoying major modes."
    :init-value t
    :lighter " my-keys")
(my-keys-minor-mode 1)

(defun my-minibuffer-setup-hook ()
    (my-keys-minor-mode 0))
(add-hook 'minibuffer-setup-hook 'my-minibuffer-setup-hook)
;; (require 'bind-key)
;; (bind-key* "C-|" 'frog-jump-buffer)

;; On doom emacs

;; You can use this hydra menu that have all the commands
(map! :n "C-SPC" 'harpoon-quick-menu-hydra)
(map! :n "C-s" 'harpoon-add-file)

;; And the vanilla commands
(map! :leader "j c" 'harpoon-clear)
(map! :leader "j f" 'harpoon-toggle-file)
(map! :leader "1" 'harpoon-go-to-1)
(map! :leader "2" 'harpoon-go-to-2)
(map! :leader "3" 'harpoon-go-to-3)
(map! :leader "4" 'harpoon-go-to-4)
(map! :leader "5" 'harpoon-go-to-5)
(map! :leader "6" 'harpoon-go-to-6)
(map! :leader "7" 'harpoon-go-to-7)
(map! :leader "8" 'harpoon-go-to-8)
(map! :leader "9" 'harpoon-go-to-9)


;; dired configs

;;(setq dired-kill-when-opening-new-dired-buffer t)

(map! :leader
    (:prefix ("d" . "dired")
        :desc "Open dired" "d" #'dired
        :desc "Dired jump to current" "j" #'dired-jump)
    (:after dired
        (:map dired-mode-map
            :desc "Peep-dired image previews" "d p" #'peep-dired
            :desc "Dired view file" "d v" #'dired-view-file)
        ))

(evil-define-key 'normal dired-mode-map
    (kbd "h") 'dired-up-directory
    (kbd "l") 'dired-find-file
    )

(add-hook 'dired-mode-hook 'all-the-icons-dired-mode)

;;(setq peep-dired-cleanup-eagerly t)
                                        ; will disable at closing dired
;;(setq peep-dired-cleanup-on-disable t)
(setq peep-dired-cleanup-on-disable t)
;;(setq peep-dired-enable-on-multiple-windows nil)
;;(setq peep-dired-enable-on-directories t)

(evil-define-key 'normal peep-dired-mode-map (kbd "<SPC>") 'peep-dired-scroll-page-down
    (kbd "C-<SPC>") 'peep-dired-scroll-page-up
    (kbd "<backspace>") 'peep-dired-scroll-page-up
    (kbd "j") 'peep-dired-next-file
    (kbd "k") 'peep-dired-prev-file)
(add-hook 'peep-dired-hook 'evil-normalize-keymaps)


;;settings for multi vterm

(use-package multi-vterm
    :config
    (add-hook 'vterm-mode-hook
        (lambda ()
            (setq-local evil-insert-state-cursor 'box)
            (evil-insert-state)))
    (define-key vterm-mode-map [return]                      #'vterm-send-return)

    (setq vterm-keymap-exceptions nil)
    (evil-define-key 'insert vterm-mode-map (kbd "C-e")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-f")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-a")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-v")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-b")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-w")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-u")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-d")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-n")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-m")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-p")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-j")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-k")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-r")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-t")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-g")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-c")      #'vterm--self-insert)
    (evil-define-key 'insert vterm-mode-map (kbd "C-SPC")    #'vterm--self-insert)
    (evil-define-key 'normal vterm-mode-map (kbd "C-d")      #'vterm--self-insert)
    (evil-define-key 'normal vterm-mode-map (kbd ",c")       #'multi-vterm)
    ;;(evil-define-key 'normal vterm-mode-map (kbd "M-n")       #'+vterm/toggle)
    ;;(evil-define-key 'insert vterm-mode-map (kbd "M-n")       #'+vterm/toggle)
    ;;(unbind-key "ESC" 'vterm-mode-map)
    (evil-define-key 'insert vterm-mode-map (kbd "C-m")       #'vterm-send-escape)
    ;;(evil-define-key 'insert vterm-mode-map (kbd "C-z")       #'vterm-send-C-z)
    ;;(evil-define-key 'insert vterm-mode-map (kbd "C-m")       #'evil-escape)
    (map! :n "C-<escape>" #'+vterm/toggle)
    (map! :i "C-<escape>" #'+vterm/toggle)
    (evil-define-key 'normal vterm-mode-map (kbd ",n")       #'multi-vterm-next)
    (evil-define-key 'normal vterm-mode-map (kbd ",p")       #'multi-vterm-prev)
    (evil-define-key 'normal vterm-mode-map (kbd "i")        #'evil-insert-resume)
    (evil-define-key 'normal vterm-mode-map (kbd "o")        #'evil-insert-resume)
    (evil-define-key 'normal vterm-mode-map (kbd "<return>") #'evil-insert-resume))

;;org-alert
(use-package! org-alert
    :custom (alert-default-style 'libnotify)
    :config (setq org-alert-interval 300
                org-alert-notify-cutoff 10
                org-alert-notify-after-event-cutoff 10
                alert-libnotify-additional-args '("--hint=string:desktop-entry:emacs")
                org-alert-notification-title "Org Notifications")
    ( org-alert-enable))
;;
;;the function below will open a temporary buffer to show the content of the corresponding to the pattern i am searching in the project

;; (add-hook '+vertico/search-project-hook #'(lambda ()
;;                                             (text-mode)))

(defun my/ivy-format-function-search (cands)
    (ivy--format-function-default (mapcar (lambda (cand)
                                              (let ((file (car cand))
                                                       (line (cadr cand)))
                                                  (with-temp-buffer
                                                      (insert-file-contents file)
                                                      (concat
                                                          (propertize file 'face 'ivy-grep-info)
                                                          ":"
                                                          (propertize (number-to-string line) 'face 'font-lock-constant-face)
                                                          ": "
                                                          (buffer-substring (line-beginning-position) (line-end-position))))))
                                      cands)))


(setq ivy-format-function 'my/ivy-format-function-search)

(map! :leader
    "/" #'+vertico/project-search)

(setq-default left-fringe-width nil)
(setq-default right-fringe-width 0)
(set-fringe-mode '(0 . 0))


;;TailwindCSS
(use-package! lsp-tailwindcss)
