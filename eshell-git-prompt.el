;;; eshell-git-prompt.el --- An informative and fancy Eshell prompt for Git users  -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Chunyang Xu

;; Author: Chunyang Xu <xuchunyang56@gmail.com>
;; URL: https://github.com/xuchunyang/eshell-git-prompt
;; Package-Requires: ((emacs "24.1") (dash "2.11.0"))
;; Keywords: eshell git
;; Version: 0.1
;; Created: 09/11/2015

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Usage:
;; You can call `eshell-git-prompt-use-theme' to pick up a theme then launch
;; Eshell.
;;
;; Add the following to your initialization file to let Eshell to use it every
;; time:
;;   (eshell-git-prompt-use-theme 'robbyrussell)
;;
;; TODO
;; - [ ] Test with Emacs 24.5 and in text-base Emacs
;;
;; Note
;; 1 You must kill all Eshell buffers and re-enter Eshell to make your new
;;   prompt take effect.
;; 2 You must set `eshell-prompt-regexp' to FULLY match your Eshell prompt,
;;   sometimes it is impossible, especially when you don't want use any special
;;   characters (e.g., '$') to state the end of your Eshell prompt
;; 3 If you set `eshell-prompt-function' or `eshell-prompt-regexp' incorrectly,
;;   Eshell may crashes, if it happens, you can M-x `eshell-git-prompt-use-theme'
;;   to revert to the default Eshell prompt, then read Note #1.

;;; Code:

(require 'cl-lib)
(require 'dash)

(declare-function eshell/pwd "em-dirs")

(eval-when-compile
  (defvar eshell-last-command-status)
  (defvar eshell-prompt-function)
  (defvar eshell-prompt-regexp))


;;; * Customization
(defcustom eshell-git-prompt-themes
  '((robbyrussell
     eshell-git-prompt-robbyrussell
     eshell-git-prompt-robbyrussell-regexp)
    (git-radar
     eshell-git-prompt-git-radar
     eshell-git-prompt-git-radar-regexp)
    (default
      eshell-git-prompt-default-func
      eshell-git-prompt-default-regexp))
  "A list of all available themes.
You can add your own theme to this list, then run
`eshell-git-prompt-use-theme' to use it."
  :group 'eshell-prompt
  :type '(repeat (list symbol symbol symbol)))


;;; * Internal

(defmacro with-face (str &rest properties)
  (declare (indent 1))
  `(propertize ,str 'face (list ,@properties)))

(cl-defun eshell-git-prompt--git-root-dir
    (&optional (directory default-directory))
  "Return Git root directory name if exist, otherwise, return nil."
  (let ((root (locate-dominating-file directory ".git")))
    (and root (file-name-as-directory root))))

(cl-defun eshell-git-prompt--shorten-directory-name
    (&optional (directory default-directory))
  "Return only current directory name (without ending slash).
DIRECTORY must end with slash.

For example:

  \"~/foo/bar\" => \"bar\"
  \"~\" => \"~\"
  \"/\" => \"/\""
  (let ((dir (abbreviate-file-name directory)))
    (if (> (length dir) 1)
        (file-name-nondirectory (substring dir 0 -1))
      dir)))

(defun eshell-git-prompt--slash-str (str)
  "Make sure STR is ended with one slash, return it."
  (if (string-suffix-p "/" str)
      str
    (concat str "/")))

(defun eshell-git-prompt-last-command-status ()
  "Return Eshell last command execution status.
When Eshell just launches, `eshell-last-command-status' is not defined yet,
return 0 (i.e., success)."
  (if (not (boundp 'eshell-last-command-status))
      0
    eshell-last-command-status))

(defconst eshell-git-prompt---git-global-arguments
  '("--no-pager" "--literal-pathspecs" "-c" "core.preloadindex=true")
  "Global git arguments.")

(defun eshell-git-prompt--process-git-arguments (args)
  "Prepare ARGS for a function that invokes Git."
  (setq args (-flatten args))
  (append eshell-git-prompt---git-global-arguments args))

(defun eshell-git-prompt--git-insert (&rest args)
  "Execute Git with ARGS, inserting its output at point."
  (setq args (eshell-git-prompt--process-git-arguments args))
  (apply #'process-file "git" nil (list t nil) nil args))

(defun eshell-git-prompt--git-string (&rest args)
  "Execute Git with ARGS, returning the first line of its output.
If there is no output return nil.  If the output begins with a
newline return an empty string."
  (with-temp-buffer
    (apply #'eshell-git-prompt--git-insert args)
    (unless (bobp)
      (goto-char (point-min))
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun eshell-git-prompt--git-lines (&rest args)
  "Execute Git with ARGS, returning its output as a list of lines.
Empty lines anywhere in the output are omitted."
  (with-temp-buffer
    (apply #'eshell-git-prompt--git-insert args)
    (split-string (buffer-string) "\n" t)))

(defun eshell-git-prompt--collect-status ()
  "Return working directory status as a plist.
If working directory is clean, return nil."
  (let ((untracked 0)                   ; next git-add, then git-commit
        (modified 0)                    ; next git-commit
        (modified-updated 0)            ; next git-commit
        (new-added 0)                   ; next git-commit
        (deleted 0)                     ; next git-rm, then git-commit
        (deleted-updated 0)             ; next git-commit
        (renamed-updated 0)             ; next git-commit
        )
    (-when-let (status-items (eshell-git-prompt--git-lines "status" "--porcelain"))
      (--each status-items
        (pcase (substring it 0 2)
          ("??" (cl-incf untracked))
          ("MM" (progn (cl-incf modified)
                       (cl-incf modified-updated)))
          (" M" (cl-incf modified))
          ("A " (cl-incf new-added))
          (" D" (cl-incf deleted))
          ("D " (cl-incf deleted-updated))
          ("R " (cl-incf renamed-updated))))
      (list :untracked untracked
            :modified modified
            :modified-updated  modified-updated
            :new-added new-added
            :deleted deleted
            :deleted-updated deleted-updated
            :renamed-updated renamed-updated))))

(defun eshell-git-prompt--branch-name ()
  "Return current branch name."
  (eshell-git-prompt--git-string "symbolic-ref" "HEAD" "--short"))

(defvar eshell-git-prompt-branch-name nil)

(defun eshell-git-prompt--commit-short-sha ()
  (eshell-git-prompt--git-string "rev-parse" "--short" "HEAD"))

(defun  eshell-git-prompt--readable-branch-name ()
  (-if-let (branch-name eshell-git-prompt-branch-name)
      branch-name
    (concat "detached@" (eshell-git-prompt--commit-short-sha))))

(defun eshell-git-prompt--remote-branch-name ()
  (eshell-git-prompt--git-string "for-each-ref" "--format=%(upstream:short)"
                                 (format "refs/heads/%s"
                                         eshell-git-prompt-branch-name)))

(defvar eshell-git-prompt-remote-branch-name nil)

(defun eshell-git-prompt--commits-ahead-of-remote ()
  (-if-let (remote-branch-name eshell-git-prompt-remote-branch-name)
      (string-to-number
       (eshell-git-prompt--git-string "rev-list" "--right-only" "--count"
                                      (format "%s...HEAD" remote-branch-name)))
    0))

(defun eshell-git-prompt--commits-behind-of-remote ()
  (-if-let (remote-branch-name eshell-git-prompt-remote-branch-name)
      (string-to-number
       (eshell-git-prompt--git-string "rev-list" "--left-only" "--count"
                                      (format "%s...HEAD" remote-branch-name)))
    0))


;;; * Themes

;; the Eshell default prompt
(defun eshell-git-prompt-default-func ()
  (concat (abbreviate-file-name (eshell/pwd))
          (if (= (user-uid) 0) " # " " $ ")))

(defconst eshell-git-prompt-default-regexp "^[^#$\n]* [#$] ")

;; oh-my-zsh's robbyrussell theme
;; see https://github.com/robbyrussell/oh-my-zsh/wiki/Themes#robbyrussell
(defun eshell-git-prompt-robbyrussell ()
  "Eshell Git prompt with oh-my-zsh's robbyrussell theme.

It looks like:

➜ eshell-git-prompt git:(master) ✗ git status "
  (concat
   (with-face "➜"
     :foreground (if (zerop (eshell-git-prompt-last-command-status))
                     "green" "red"))
   " "
   (with-face (eshell-git-prompt--shorten-directory-name)
     :foreground "cyan")
   ;; When in Git repo
   (when (eshell-git-prompt--git-root-dir)
     (setq eshell-git-prompt-branch-name (eshell-git-prompt--branch-name))
     (concat
      " "
      (with-face "git:(" :foreground "blue")
      (with-face (eshell-git-prompt--readable-branch-name) :foreground "red")
      (with-face ")" :foreground "blue")
      ;; when the working directory is not clean
      (when (eshell-git-prompt--collect-status)
        (concat " " (with-face "✗" :foreground "yellow")))))
   ;; To make it possible to let `eshell-prompt-regexp' to match the full prompt
   (propertize "$" 'invisible t) " "))

(defconst eshell-git-prompt-robbyrussell-regexp "^[^$\n]*\\\$ ")

;; git-radar
;; see https://github.com/michaeldfallen/git-radar

(defun eshell-git-prompt-git-radar ()
  "Eshell Git prompt inspired by git-radar."
  (concat
   (with-face "➜"
     :foreground (if (zerop (eshell-git-prompt-last-command-status))
                     "green" "red"))
   " "
   (with-face (eshell-git-prompt--shorten-directory-name)
     :foreground "cyan")
   ;; Yo, we are in a Git repo, display some information about it
   (when (eshell-git-prompt--git-root-dir)
     (setq eshell-git-prompt-branch-name
           (eshell-git-prompt--branch-name)
           eshell-git-prompt-remote-branch-name
           (eshell-git-prompt--remote-branch-name))
     (concat
      " "
      (with-face "git:(" :foreground "dark gray")

      ;; Branch name
      (with-face (eshell-git-prompt--readable-branch-name)
        :foreground "gray")

      ;; Local commits
      (when eshell-git-prompt-remote-branch-name
        (let ((local-behind (eshell-git-prompt--commits-behind-of-remote))
              (local-ahead (eshell-git-prompt--commits-ahead-of-remote)))
          (cond ((and (> local-ahead 0) (> local-behind 0))
                 (concat " "
                         (with-face (number-to-string local-behind)
                           :foreground "white")
                         (with-face "⇵" :foreground "yellow")
                         (number-to-string local-ahead)))
                ((> local-behind 0)
                 (concat " "
                         (with-face (number-to-string local-behind)
                           :foreground "white")
                         (with-face "↓" :foreground "red")))
                ((> local-ahead 0)
                 (concat " "
                         (with-face (number-to-string local-ahead)
                           :foreground "white")
                         (with-face "↑" :foreground "LimeGreen"))))))

      (with-face ")" :foreground "dark gray")

      ;; File status
      (-when-let (git-status (eshell-git-prompt--collect-status))
        (-let [(&plist :untracked untracked
                       :new-added new-added
                       :modified-updated modified-updated
                       :modified modified)
               git-status]
          (concat
           ;; Updated to index changes
           (let (group1)
             (setq group1
                   (concat
                    (when (> new-added 0)
                      (concat
                       (with-face (number-to-string new-added)
                         :foreground "white")
                       (with-face "A" :foreground "green")))
                    (when (> modified-updated 0)
                      (concat
                       (with-face (number-to-string modified-updated)
                         :foreground "white")
                       (with-face "M" :foreground "green")))))
             (when (> (length group1) 0)
               (concat " " group1)))
           ;; Modified but not updated
           (when (> modified 0)
             (concat " " (with-face (number-to-string modified)
                           :foreground "white")
                     (with-face "M" :foreground "red")))
           ;; Untracked file
           (when (> untracked 0)
             (with-face (format " %dA" untracked)
               :foreground "white")))))))
   ;; To make it possible to let `eshell-prompt-regexp' to match the full prompt
   (propertize "$" 'invisible t) " "))

(defconst eshell-git-prompt-git-radar-regexp "^[^$\n]*\\\$ ")

(defvar eshell-git-prompt-current-theme nil)

;;;###autoload
(defun eshell-git-prompt-use-theme (theme)
  "Pick up a Eshell prompt theme from `eshell-git-prompt-themes' to use."
  (interactive
   (let ((theme
          (completing-read "Use theme:"
                           (--map (symbol-name (car it))
                                  eshell-git-prompt-themes)
                           nil t)))
     (list (intern theme))))
  (when (stringp theme)
    (setq theme (intern theme)))
  (-if-let (func-regexp (assoc-default theme eshell-git-prompt-themes))
      (progn
        (setq eshell-prompt-function (symbol-function (car func-regexp))
              eshell-prompt-regexp (symbol-value (cadr func-regexp)))
        (setq eshell-git-prompt-current-theme theme)
        (when (called-interactively-p 'interactive)
          (message
           "Now kill all Eshell buffers and re-enter Eshell to use %s theme"
           (symbol-name theme))))
    (user-error "Theme \"%s\" is not available" theme)))

(provide 'eshell-git-prompt)

;; Local Variables:
;; eval: (when (require 'rainbow-mode nil t) (rainbow-mode 1))
;; End:
;;; eshell-git-prompt.el ends here
