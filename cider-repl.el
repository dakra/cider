;;; cider-repl.el --- CIDER REPL mode interactions -*- lexical-binding: t -*-

;; Copyright © 2012-2025 Tim King, Phil Hagelberg, Bozhidar Batsov
;; Copyright © 2013-2025 Bozhidar Batsov, Artur Malabarba and CIDER contributors
;;
;; Author: Tim King <kingtim@gmail.com>
;;         Phil Hagelberg <technomancy@gmail.com>
;;         Bozhidar Batsov <bozhidar@batsov.dev>
;;         Artur Malabarba <bruce.connor.am@gmail.com>
;;         Hugo Duncan <hugo@hugoduncan.org>
;;         Steve Purcell <steve@sanityinc.com>
;;         Reid McKenzie <me@arrdem.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This functionality concerns `cider-repl-mode' and REPL interaction.  For
;; REPL/connection life-cycle management see cider-connection.el.

;;; Code:

(require 'cl-lib)
(require 'easymenu)
(require 'image)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'clojure-mode)
(require 'sesman)

(require 'cider-client)
(require 'cider-doc)
(require 'cider-test)
(require 'cider-eldoc) ; for cider-eldoc-setup
(require 'cider-common)
(require 'cider-util)
(require 'cider-resolve)

(declare-function cider-inspect "cider-inspector")


(defgroup cider-repl nil
  "Interaction with the REPL."
  :prefix "cider-repl-"
  :group 'cider)

(defface cider-repl-prompt-face
  '((t (:inherit font-lock-keyword-face)))
  "Face for the prompt in the REPL buffer.")

(defface cider-repl-stdout-face
  '((t (:inherit font-lock-string-face)))
  "Face for STDOUT output in the REPL buffer.")

(defface cider-repl-stderr-face
  '((t (:inherit font-lock-warning-face)))
  "Face for STDERR output in the REPL buffer."
  :package-version '(cider . "0.6.0"))

(defface cider-repl-input-face
  '((t (:bold t)))
  "Face for previous input in the REPL buffer.")

(defface cider-repl-result-face
  '((t ()))
  "Face for the result of an evaluation in the REPL buffer.")

(defcustom cider-repl-pop-to-buffer-on-connect t
  "Controls whether to pop to the REPL buffer on connect.

When set to nil the buffer will only be created, and not displayed.  When
set to `display-only' the buffer will be displayed, but it will not become
focused.  Otherwise the buffer is displayed and focused."
  :type '(choice (const :tag "Create the buffer, but don't display it" nil)
                 (const :tag "Create and display the buffer, but don't focus it"
                        display-only)
                 (const :tag "Create, display, and focus the buffer" t)))

(defcustom cider-repl-display-in-current-window nil
  "Controls whether the REPL buffer is displayed in the current window."
  :type 'boolean)

(defcustom cider-repl-use-pretty-printing t
  "Control whether results in the REPL are pretty-printed or not.
The REPL will use the printer specified in `cider-print-fn'.
The `cider-toggle-pretty-printing' command can be used to interactively
change the setting's value."
  :type 'boolean)

(defcustom cider-repl-use-content-types nil
  "Control whether REPL results are presented using content-type information.
The `cider-repl-toggle-content-types' command can be used to interactively
change the setting's value."
  :type 'boolean
  :package-version '(cider . "0.17.0"))

(defcustom cider-repl-auto-detect-type t
  "Control whether to auto-detect the REPL type using track-state information.
If you disable this you'll have to manually change the REPL type between
Clojure and ClojureScript when invoking REPL type changing forms.
Use `cider-set-repl-type' to manually change the REPL type."
  :type 'boolean
  :safe #'booleanp
  :package-version '(cider . "0.18.0"))

(defcustom cider-repl-use-clojure-font-lock t
  "Non-nil means to use Clojure mode font-locking for input and result.
Nil means that `cider-repl-input-face' and `cider-repl-result-face'
will be used."
  :type 'boolean
  :package-version '(cider . "0.10.0"))

(defcustom cider-repl-require-ns-on-set nil
  "Controls whether to require the ns before setting it in the REPL."
  :type 'boolean
  :package-version '(cider . "0.22.0"))

(defcustom cider-repl-result-prefix ""
  "The prefix displayed in the REPL before a result value.
By default there's no prefix, but you can specify something
like \"=>\" if want results to stand out more."
  :type 'string
  :group 'cider
  :package-version '(cider . "0.5.0"))

(defcustom cider-repl-tab-command 'cider-repl-indent-and-complete-symbol
  "Select the command to be invoked by the TAB key.
The default option is `cider-repl-indent-and-complete-symbol'.  If
you'd like to use the default Emacs behavior use
`indent-for-tab-command'."
  :type 'symbol)

(defvar cider-repl-require-repl-utils-code
  '((clj . "(when-let [requires (resolve 'clojure.main/repl-requires)]
  (clojure.core/apply clojure.core/require @requires))")
    (cljs . "(require '[cljs.repl :refer [apropos dir doc find-doc print-doc pst source]])")))

(defcustom cider-repl-init-code (list (cdr (assoc 'clj cider-repl-require-repl-utils-code)))
  "Clojure code to evaluate when starting a REPL.
Will be evaluated with bindings for set!-able vars in place.

See also `cider-repl-eval-init-code'."
  :type '(list string)
  :package-version '(cider . "0.21.0"))

(defcustom cider-repl-display-help-banner t
  "When non-nil a bit of help text will be displayed on REPL start."
  :type 'boolean
  :package-version '(cider . "0.11.0"))

;; See https://github.com/clojure-emacs/cider/issues/3219 for more details
(defcustom cider-repl-display-output-before-window-boundaries nil
  "Controls whether to display output emitted before the REPL window boundaries.

If the prompt is on the first line of the window, then scroll the window
down by a single line to make the emitted output visible.

That behavior is desirable, but rarely needed and it slows down printing
output a lot (e.g. 10x) that's why it's disable by default starting with
CIDER 1.7."
  :type 'boolean
  :package-version '(cider . "1.7.0"))


;;;; REPL buffer local variables
(defvar-local cider-repl-input-start-mark nil)

(defvar-local cider-repl-prompt-start-mark nil)

(defvar-local cider-repl-old-input-counter 0
  "Counter used to generate unique `cider-old-input' properties.
This property value must be unique to avoid having adjacent inputs be
joined together.")

(defvar-local cider-repl-output-start nil
  "Marker for the start of output.
Currently its only purpose is to facilitate `cider-repl-clear-buffer'.")

(defvar-local cider-repl-output-end nil
  "Marker for the end of output.
Currently its only purpose is to facilitate `cider-repl-clear-buffer'.")

(defun cider-repl-tab ()
  "Invoked on TAB keystrokes in `cider-repl-mode' buffers."
  (interactive)
  (funcall cider-repl-tab-command))

(defun cider-repl-reset-markers ()
  "Reset all REPL markers."
  (dolist (markname '(cider-repl-output-start
                      cider-repl-output-end
                      cider-repl-prompt-start-mark
                      cider-repl-input-start-mark))
    (set markname (make-marker))
    (set-marker (symbol-value markname) (point))))


;;; REPL init

(defvar-local cider-repl-ns-cache nil
  "A dict holding information about all currently loaded namespaces.
This cache is stored in the connection buffer.")

(defvar cider-mode)
(declare-function cider-refresh-dynamic-font-lock "cider-mode")

(defun cider-repl--state-handler (response)
  "Handle server state contained in RESPONSE."
  (with-demoted-errors "Error in `cider-repl--state-handler': %s"
    (when (member "state" (nrepl-dict-get response "status"))
      (nrepl-dbind-response response (repl-type changed-namespaces session)
        (when (and repl-type
                   cider-repl-auto-detect-type
                   ;; tooling sessions always run on the JVM so they are not a valid criterion:
                   (not (equal session nrepl-tooling-session)))
          (cider-set-repl-type repl-type))
        (when (eq (cider-maybe-intern repl-type) 'cljs)
          (setq cider-repl-cljs-upgrade-pending nil))
        (unless (nrepl-dict-empty-p changed-namespaces)
          (setq cider-repl-ns-cache (nrepl-dict-merge cider-repl-ns-cache changed-namespaces))
          (let ((this-repl (current-buffer)))
            (dolist (b (buffer-list))
              (with-current-buffer b
                (when (or cider-mode (derived-mode-p 'cider-repl-mode))
                  ;; We only cider-refresh-dynamic-font-lock (and set `cider-eldoc-last-symbol')
                  ;; for Clojure buffers directly related to this repl
                  ;; (specifically, we omit 'friendly' sessions because a given buffer may be friendly to multiple repls,
                  ;;  so we don't want a buffer to mix up font locking rules from different repls).
                  ;; Note that `sesman--linked-sessions' only queries for the directly linked sessions.
                  ;; That has the additional advantage of running very/predictably fast, since it won't run our
                  ;; `cider--sesman-friendly-session-p' logic, which can be slow for its non-cached path.
                  (when (member this-repl (car (sesman--linked-sessions 'CIDER)))
                    ;; Metadata changed, so signatures may have changed too.
                    (setq cider-eldoc-last-symbol nil)
                    (when-let* ((ns-dict (or (nrepl-dict-get changed-namespaces (cider-current-ns))
                                             (let ((ns-dict (cider-resolve--get-in (cider-current-ns))))
                                               (when (seq-find (lambda (ns) (nrepl-dict-get changed-namespaces ns))
                                                               (nrepl-dict-get ns-dict "aliases"))
                                                 ns-dict)))))
                      (cider-refresh-dynamic-font-lock ns-dict))))))))))))

(defun cider-repl-require-repl-utils ()
  "Require standard REPL util functions into the current REPL."
  (interactive)
  (let* ((current-repl (cider-current-repl 'infer 'ensure))
         (require-code (cdr (assoc (cider-repl-type current-repl) cider-repl-require-repl-utils-code))))
    (nrepl-send-sync-request
     (cider-plist-put
      (nrepl--eval-request require-code (cider-current-ns))
      "inhibit-cider-middleware" "true")
     current-repl)))

(defun cider-repl-init-eval-handler (&optional callback)
  "Make an nREPL evaluation handler for use during REPL init.
Run CALLBACK once the evaluation is complete."
  (nrepl-make-response-handler (current-buffer)
                               (lambda (_buffer _value))
                               (lambda (buffer out)
                                 (cider-repl-emit-stdout buffer out))
                               (lambda (buffer err)
                                 (cider-repl-emit-stderr buffer err))
                               (lambda (buffer)
                                 (cider-repl-emit-prompt buffer)
                                 (when callback
                                   (funcall callback)))))

(defun cider-repl-eval-init-code (&optional callback)
  "Evaluate `cider-repl-init-code' in the current REPL.
Run CALLBACK once the evaluation is complete."
  (interactive)
  (let* ((request `(,@(cider--repl-request-plist)
                    "inhibit-cider-middleware" "true")))
    (cider-nrepl-request:eval
     ;; Ensure we evaluate _something_ so the initial namespace is correctly set
     (thread-first (or cider-repl-init-code '("nil"))
                   (string-join "\n"))
     (cider-repl-init-eval-handler callback)
     nil
     (line-number-at-pos (point))
     (cider-column-number-at-pos (point))
     request)))

(defun cider-repl-init (buffer &optional callback)
  "Initialize the REPL in BUFFER.
BUFFER must be a REPL buffer with `cider-repl-mode' and a running
client process connection.  CALLBACK will be run once the REPL is
fully initialized."
  (when cider-repl-display-in-current-window
    (add-to-list 'same-window-buffer-names (buffer-name buffer)))
  (pcase cider-repl-pop-to-buffer-on-connect
    (`display-only
     (let ((orig-buffer (current-buffer)))
       (display-buffer buffer)
       ;; User popup-rules (specifically `:select nil') can cause the call to
       ;; `display-buffer' to reset the current Emacs buffer to the clj/cljs
       ;; buffer that the user ran `jack-in' from - we need the current-buffer
       ;; to be the repl to initialize, so reset it back here to be resilient
       ;; against user config
       (set-buffer orig-buffer)))
    ((pred identity) (pop-to-buffer buffer)))
  (with-current-buffer buffer
    (cider-repl--insert-banner)
    (cider-repl--insert-startup-commands)
    (when-let* ((window (get-buffer-window buffer t)))
      (with-selected-window window
        (recenter (- -1 scroll-margin))))
    (cider-repl-eval-init-code callback))
  buffer)

(defun cider-repl--insert-banner ()
  "Insert the banner in the current REPL buffer."
  (insert-before-markers
   (propertize (cider-repl--banner) 'font-lock-face 'font-lock-comment-face))
  (when cider-repl-display-help-banner
    (insert-before-markers
     (propertize (cider-repl--help-banner) 'font-lock-face 'font-lock-comment-face))))

(defun cider-repl--insert-startup-commands ()
  "Insert the values from params specified in PARAM-TUPLES.
PARAM-TUPLES are tuples of (param-key description) or (param-key
description transform) where transform is called with the param-value if
present."
  (cl-labels
      ((emit-comment
        (contents)
        (insert-before-markers
         (propertize
          (if (string-blank-p contents) ";;\n" (concat ";; " contents "\n"))
          'font-lock-face 'font-lock-comment-face))))
    (let ((jack-in-command (plist-get cider-launch-params :jack-in-cmd))
          (cljs-repl-type (plist-get cider-launch-params :cljs-repl-type))
          (cljs-init-form (plist-get cider-launch-params :repl-init-form)))
      (when jack-in-command
        ;; spaces to align with the banner
        (emit-comment (concat " Startup: " jack-in-command)))
      (when (or cljs-repl-type cljs-init-form)
        (emit-comment "")
        (when cljs-repl-type
          (emit-comment (concat "ClojureScript REPL type: " (symbol-name cljs-repl-type))))
        (when cljs-init-form
          (emit-comment (concat "ClojureScript REPL init form: " cljs-init-form)))
        (emit-comment "")))))

(defun cider-repl--banner ()
  "Generate the welcome REPL buffer banner."
  (cond
   ((cider--clojure-version) (cider-repl--clojure-banner))
   ((cider--babashka-version) (cider-repl--babashka-banner))
   (t (cider-repl--basic-banner))))

(defun cider-repl--clojure-banner ()
  "Generate the welcome REPL buffer banner for Clojure(Script)."
  (format ";; Connected to nREPL server - nrepl://%s:%s
;; CIDER %s, nREPL %s
;; Clojure %s, Java %s
;;     Docs: (doc function-name)
;;           (find-doc part-of-name)
;;   Source: (source function-name)
;;  Javadoc: (javadoc java-object-or-class)
;;     Exit: <C-c C-q>
;;  Results: Stored in vars *1, *2, *3, an exception in *e;
"
          (plist-get nrepl-endpoint :host)
          (plist-get nrepl-endpoint :port)
          (cider--version)
          (cider--nrepl-version)
          (cider--clojure-version)
          (cider--java-version)))

(defun cider-repl--babashka-banner ()
  "Generate the welcome REPL buffer banner for Babashka."
  (format ";; Connected to nREPL server - nrepl://%s:%s
;; CIDER %s, babashka.nrepl %s
;; Babashka %s
;;     Docs: (doc function-name)
;;           (find-doc part-of-name)
;;   Source: (source function-name)
;;  Javadoc: (javadoc java-object-or-class)
;;     Exit: <C-c C-q>
;;  Results: Stored in vars *1, *2, *3, an exception in *e;
"
          (plist-get nrepl-endpoint :host)
          (plist-get nrepl-endpoint :port)
          (cider--version)
          (cider--babashka-nrepl-version)
          (cider--babashka-version)))

(defun cider-repl--basic-banner ()
  "Generate a basic banner with minimal info."
  (format ";; Connected to nREPL server - nrepl://%s:%s
;; CIDER %s
"
          (plist-get nrepl-endpoint :host)
          (plist-get nrepl-endpoint :port)
          (cider--version)))

(defun cider-repl--help-banner ()
  "Generate the help banner."
  (substitute-command-keys
   ";; ======================================================================
;; If you're new to CIDER it is highly recommended to go through its
;; user manual first. Type <M-x cider-view-manual> to view it.
;; In case you're seeing any warnings you should consult the manual's
;; \"Troubleshooting\" section.
;;
;; Here are a few tips to get you started:
;;
;; * Press <\\[describe-mode]> to see a list of the keybindings available (this
;;   will work in every Emacs buffer)
;; * Press <\\[cider-repl-handle-shortcut]> to quickly invoke some REPL command
;; * Press <\\[cider-switch-to-last-clojure-buffer]> to switch between the REPL and a Clojure file
;; * Press <\\[cider-find-var]> to jump to the source of something (e.g. a var, a
;;   Java method)
;; * Press <\\[cider-doc]> to view the documentation for something (e.g.
;;   a var, a Java method)
;; * Print CIDER's refcard and keep it close to your keyboard.
;;
;; CIDER is super customizable - try <M-x customize-group cider> to
;; get a feel for this. If you're thirsty for knowledge you should try
;; <M-x cider-drink-a-sip>.
;;
;; If you think you've encountered a bug (or have some suggestions for
;; improvements) use <M-x cider-report-bug> to report it.
;;
;; Above all else - don't panic! In case of an emergency - procure
;; some (hard) cider and enjoy it responsibly!
;;
;; You can remove this message with the <M-x cider-repl-clear-help-banner> command.
;; You can disable it from appearing on start by setting
;; `cider-repl-display-help-banner' to nil.
;; ======================================================================
"))


;;; REPL interaction

(defun cider-repl--in-input-area-p ()
  "Return t if in input area."
  (<= cider-repl-input-start-mark (point)))

(defun cider-repl--current-input (&optional until-point-p)
  "Return the current input as string.
The input is the region from after the last prompt to the end of
buffer.  If UNTIL-POINT-P is non-nil, the input is until the current
point."
  (buffer-substring-no-properties cider-repl-input-start-mark
                                  (if until-point-p
                                      (point)
                                    (point-max))))

(defun cider-repl-previous-prompt ()
  "Move backward to the previous prompt."
  (interactive)
  (cider-repl--find-prompt t))

(defun cider-repl-next-prompt ()
  "Move forward to the next prompt."
  (interactive)
  (cider-repl--find-prompt))

(defun cider-repl--find-prompt (&optional backward)
  "Find the next prompt.
If BACKWARD is non-nil look backward."
  (let ((origin (point))
        (cider-repl-prompt-property 'field))
    (while (progn
             (cider-search-property-change cider-repl-prompt-property backward)
             (not (or (cider-end-of-proprange-p cider-repl-prompt-property) (bobp) (eobp)))))
    (unless (cider-end-of-proprange-p cider-repl-prompt-property)
      (goto-char origin))))

(defun cider-search-property-change (prop &optional backward)
  "Search forward for a property change to PROP.
If BACKWARD is non-nil search backward."
  (cond (backward
         (goto-char (previous-single-char-property-change (point) prop)))
        (t
         (goto-char (next-single-char-property-change (point) prop)))))

(defun cider-end-of-proprange-p (property)
  "Return t if at the the end of a property range for PROPERTY."
  (and (get-char-property (max (point-min) (1- (point))) property)
       (not (get-char-property (point) property))))

(defun cider-repl--mark-input-start ()
  "Mark the input start."
  (set-marker cider-repl-input-start-mark (point) (current-buffer)))

(defun cider-repl--mark-output-start ()
  "Mark the output start."
  (set-marker cider-repl-output-start (point))
  (set-marker cider-repl-output-end (point)))

(defun cider-repl-mode-beginning-of-defun (&optional arg)
  "Move to the beginning of defun.
If given a negative value of ARG, move to the end of defun."
  (if (and arg (< arg 0))
      (cider-repl-mode-end-of-defun (- arg))
    (dotimes (_ (or arg 1))
      (cider-repl-previous-prompt))))

(defun cider-repl-mode-end-of-defun (&optional arg)
  "Move to the end of defun.
If given a negative value of ARG, move to the beginning of defun."
  (if (and arg (< arg 0))
      (cider-repl-mode-beginning-of-defun (- arg))
    (dotimes (_ (or arg 1))
      (cider-repl-next-prompt))))

(defun cider-repl-beginning-of-defun ()
  "Move to beginning of defun."
  (interactive)
  ;; We call `beginning-of-defun' if we're at the start of a prompt
  ;; already, to trigger `cider-repl-mode-beginning-of-defun' by means
  ;; of the locally bound `beginning-of-defun-function', in order to
  ;; jump to the start of the previous prompt.
  (if (and (not (cider-repl--at-prompt-start-p))
           (cider-repl--in-input-area-p))
      (goto-char cider-repl-input-start-mark)
    (beginning-of-defun-raw)))

(defun cider-repl-end-of-defun ()
  "Move to end of defun."
  (interactive)
  ;; C.f. `cider-repl-beginning-of-defun'
  (if (and (not (= (point) (point-max)))
           (cider-repl--in-input-area-p))
      (goto-char (point-max))
    (end-of-defun)))

(defun cider-repl-bol-mark ()
  "Set the mark and go to the beginning of line or the prompt."
  (interactive)
  (unless mark-active
    (set-mark (point)))
  (move-beginning-of-line 1))

(defun cider-repl--at-prompt-start-p ()
  "Return t if point is at the start of prompt.
This will not work on non-current prompts."
  (= (point) cider-repl-input-start-mark))

(defmacro cider-save-marker (marker &rest body)
  "Save MARKER and execute BODY."
  (declare (debug t))
  (let ((pos (make-symbol "pos")))
    `(let ((,pos (marker-position ,marker)))
       (prog1 (progn . ,body)
         (set-marker ,marker ,pos)))))

(put 'cider-save-marker 'lisp-indent-function 1)

(defun cider-repl-prompt-default (namespace)
  "Return a prompt string that mentions NAMESPACE."
  (format "%s> " namespace))

(defun cider-repl-prompt-abbreviated (namespace)
  "Return a prompt string that abbreviates NAMESPACE."
  (format "%s> " (cider-abbreviate-ns namespace)))

(defun cider-repl-prompt-lastname (namespace)
  "Return a prompt string with the last name in NAMESPACE."
  (format "%s> " (cider-last-ns-segment namespace)))

(defcustom cider-repl-prompt-function #'cider-repl-prompt-default
  "A function that returns a prompt string.
Takes one argument, a namespace name.
For convenience, three functions are already provided for this purpose:
`cider-repl-prompt-lastname', `cider-repl-prompt-abbreviated', and
`cider-repl-prompt-default'."
  :type '(choice (const :tag "Full namespace" cider-repl-prompt-default)
                 (const :tag "Abbreviated namespace" cider-repl-prompt-abbreviated)
                 (const :tag "Last name in namespace" cider-repl-prompt-lastname)
                 (function :tag "Custom function"))
  :package-version '(cider . "0.9.0"))

(defun cider-repl--insert-prompt (namespace)
  "Insert the prompt (before markers!), taking into account NAMESPACE.
Set point after the prompt.
Return the position of the prompt beginning."
  (goto-char cider-repl-input-start-mark)
  (cider-save-marker cider-repl-output-start
    (cider-save-marker cider-repl-output-end
      (unless (bolp) (insert-before-markers "\n"))
      (let ((prompt-start (point))
            (prompt (funcall cider-repl-prompt-function namespace)))
        (cider-propertize-region
            '(font-lock-face cider-repl-prompt-face read-only t intangible t
                             field cider-repl-prompt
                             rear-nonsticky (field read-only font-lock-face intangible))
          (insert-before-markers prompt))
        (set-marker cider-repl-prompt-start-mark prompt-start)
        prompt-start))))

(defun cider-repl--ansi-color-apply (string)
  "Like `ansi-color-apply', but does not withhold non-SGR seqs found in STRING.

Workaround for Emacs bug#53808 whereby partial ANSI control seqs present in
the input stream may block the whole colorization process."
  (let* ((result (ansi-color-apply string))

         ;; The STRING may end with a possible incomplete ANSI control seq which
         ;; the call to `ansi-color-apply' stores in the `ansi-color-context'
         ;; fragment. If the fragment is not an incomplete ANSI color control
         ;; sequence (aka SGR seq) though then flush it out and appended it to
         ;; the result.
         (fragment-flush?
          (when-let (fragment (and ansi-color-context (cadr ansi-color-context)))
            (save-match-data
              ;; Check if fragment is indeed an SGR seq in the making. The SGR
              ;; seq is defined as starting with ESC followed by [ followed by
              ;; zero or more [:digit:]+; followed by one or more digits and
              ;; ending with m.
              (when (string-match
                     (rx (sequence ?\e
                                   (? (and (or ?\[ eol)
                                           (or (+ (any (?0 . ?9))) eol)
                                           (* (sequence ?\; (+ (any (?0 . ?9)))))
                                           (or ?\; eol)))))
                     fragment)
                (let* ((sgr-end-pos (match-end 0))
                       (fragment-matches-whole? (or (= sgr-end-pos 0)
                                                    (= sgr-end-pos (length fragment)))))
                  (when (not fragment-matches-whole?)
                    ;; Definitely not an partial SGR seq, flush it out of
                    ;; `ansi-color-context'.
                    t)))))))

    (if (not fragment-flush?)
        result

      (progn
        ;; Temporarily replace the ESC char in the fragment so that is flushed
        ;; out of `ansi-color-context' by `ansi-color-apply' and append it to
        ;; the result.
        (aset (cadr ansi-color-context) 0 ?\0)
        (let ((result-fragment (ansi-color-apply "")))
          (aset result-fragment 0 ?\e)
          (concat result result-fragment))))))

(defvar-local cider-repl--ns-forms-plist nil
  "Plist holding ns->ns-form mappings within each connection.")

(defun cider-repl--ns-form-changed-p (ns-form connection)
  "Return non-nil if NS-FORM for CONNECTION changed since last eval."
  (when-let* ((ns (cider-ns-from-form ns-form)))
    (not (string= ns-form
                  (cider-plist-get
                   (buffer-local-value 'cider-repl--ns-forms-plist connection)
                   ns)))))

(defvar cider-repl--root-ns-highlight-template "\\_<\\(%s\\)[^$/: \t\n()]+"
  "Regexp used to highlight root ns in REPL buffers.")

(defvar-local cider-repl--root-ns-regexp nil
  "Cache of root ns regexp in REPLs.")

(defvar-local cider-repl--ns-roots nil
  "List holding all past root namespaces seen during interactive eval.")

(defun cider-repl--cache-ns-form (ns-form connection)
  "Given NS-FORM cache root ns in CONNECTION."
  (with-current-buffer connection
    (when-let* ((ns (cider-ns-from-form ns-form)))
      ;; cache ns-form
      (setq cider-repl--ns-forms-plist
            (cider-plist-put cider-repl--ns-forms-plist ns ns-form))
      ;; cache ns roots regexp
      (when (string-match "\\([^.]+\\)" ns)
        (let ((root (match-string-no-properties 1 ns)))
          (unless (member root cider-repl--ns-roots)
            (push root cider-repl--ns-roots)
            (let ((roots (mapconcat
                          ;; Replace _ or - with regexp pattern to accommodate "raw" namespaces
                          (lambda (r) (replace-regexp-in-string "[_-]+" "[_-]+" r))
                          cider-repl--ns-roots "\\|")))
              (setq cider-repl--root-ns-regexp
                    (format cider-repl--root-ns-highlight-template roots)))))))))

(defvar cider-repl-spec-keywords-regexp
  (concat
   (regexp-opt '("In:" " val:"
                 " at:" "fails at:"
                 " spec:" "fails spec:"
                 " predicate:" "fails predicate:"))
   "\\|^"
   (regexp-opt '(":clojure.spec.alpha/spec"
                 ":clojure.spec.alpha/value")
               "\\("))
  "Regexp matching clojure.spec `explain` keywords.")

(defun cider-repl-highlight-spec-keywords (string)
  "Highlight clojure.spec `explain` keywords in STRING.
Foreground of `clojure-keyword-face' is used for highlight."
  (cider-add-face cider-repl-spec-keywords-regexp
                  'clojure-keyword-face t nil string)
  string)

(defun cider-repl-highlight-current-project (string)
  "Fontify project's root namespace to make stacktraces more readable.
Foreground of `cider-stacktrace-ns-face' is used to propertize matched
namespaces.  STRING is REPL's output."
  (cider-add-face cider-repl--root-ns-regexp 'cider-stacktrace-ns-face
                  t nil string)
  string)

(defun cider-repl-add-locref-help-echo (string)
  "Set help-echo property of STRING to `cider-locref-help-echo'."
  (put-text-property 0 (length string) 'help-echo 'cider-locref-help-echo string)
  string)

(defvar cider-repl-preoutput-hook `(,(if (< emacs-major-version 29)
                                         'cider-repl--ansi-color-apply
                                       'ansi-color-apply)
                                    cider-repl-highlight-current-project
                                    cider-repl-highlight-spec-keywords
                                    cider-repl-add-locref-help-echo)
  "Hook run on output string before it is inserted into the REPL buffer.
Each functions takes a string and must return a modified string.  Also see
`cider-run-chained-hook'.")

(defcustom cider-repl-buffer-size-limit nil
  "The max size of the REPL buffer.
Setting this to nil removes the limit."
  :group 'cider
  :type 'integer
  :package-version '(cider . "0.26.0"))

(defun cider-start-of-next-prompt (point)
  "Return the position of the first char of the next prompt from POINT."
  (let ((next-prompt-or-input (next-single-char-property-change point 'field)))
    (if (eq (get-char-property next-prompt-or-input 'field) 'cider-repl-prompt)
        next-prompt-or-input
      (next-single-char-property-change next-prompt-or-input 'field))))

(defun cider-repl-trim-top-of-buffer (buffer)
  "Trims REPL output from beginning of BUFFER.
Trims by one fifth of `cider-repl-buffer-size-limit'.
Also clears remaining partial input or results."
  (with-current-buffer buffer
    (let* ((to-trim (ceiling (* cider-repl-buffer-size-limit 0.2)))
           (start-of-next-prompt (cider-start-of-next-prompt to-trim))
           (inhibit-read-only t))
      (cider-repl--clear-region (point-min) start-of-next-prompt))))

(defun cider-repl-trim-buffer ()
  "Trim the currently visited REPL buffer partially from the top.
See also `cider-repl-clear-buffer'."
  (interactive)
  (if cider-repl-buffer-size-limit
      (cider-repl-trim-top-of-buffer (current-buffer))
    (user-error "The variable `cider-repl-buffer-size-limit' is not set")))

(defun cider-repl-maybe-trim-buffer (buffer)
  "Clear portion of printed output in BUFFER.
Clear the part where `cider-repl-buffer-size-limit' is exceeded."
  (when (> (buffer-size) cider-repl-buffer-size-limit)
    (cider-repl-trim-top-of-buffer buffer)))

(defun cider-repl--emit-output (buffer string face)
  "Using BUFFER, emit STRING as output font-locked using FACE.
Before inserting, run `cider-repl-preoutput-hook' on STRING."
  (with-current-buffer buffer
    (save-excursion
      (cider-save-marker cider-repl-output-start
        (goto-char cider-repl-output-end)
        (setq string (propertize string
                                 'font-lock-face face
                                 'rear-nonsticky '(font-lock-face)))
        (setq string (cider-run-chained-hook 'cider-repl-preoutput-hook string))
        (insert-before-markers string))
      (when (and (= (point) cider-repl-prompt-start-mark)
                 (not (bolp)))
        (insert-before-markers "\n")
        (set-marker cider-repl-output-end (1- (point))))))
  (when cider-repl-display-output-before-window-boundaries
    ;; FIXME: The code below is super slow, that's why it's disabled by default.
    (when-let* ((window (get-buffer-window buffer t)))
      ;; If the prompt is on the first line of the window, then scroll the window
      ;; down by a single line to make the emitted output visible.
      (when (and (pos-visible-in-window-p cider-repl-prompt-start-mark window)
                 (< 1 cider-repl-prompt-start-mark)
                 (not (pos-visible-in-window-p (1- cider-repl-prompt-start-mark) window)))
        (with-selected-window window
          (scroll-down 1))))))

(defun cider-repl--emit-interactive-output (string face)
  "Emit STRING as interactive output using FACE."
  (cider-repl--emit-output (cider-current-repl) string face))

(defun cider-repl-emit-interactive-stdout (string)
  "Emit STRING as interactive output."
  (cider-repl--emit-interactive-output string 'cider-repl-stdout-face))

(defun cider-repl-emit-interactive-stderr (string)
  "Emit STRING as interactive err output."
  (cider-repl--emit-interactive-output string 'cider-repl-stderr-face))

(defun cider-repl-emit-stdout (buffer string)
  "Using BUFFER, emit STRING as standard output."
  (cider-repl--emit-output buffer string 'cider-repl-stdout-face))

(defun cider-repl-emit-stderr (buffer string)
  "Using BUFFER, emit STRING as error output."
  (cider-repl--emit-output buffer string 'cider-repl-stderr-face))

(defun cider-repl-emit-prompt (buffer)
  "Emit the REPL prompt into BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (cider-repl--insert-prompt cider-buffer-ns))))

(defun cider-repl-emit-result (buffer string show-prefix &optional bol)
  "Emit into BUFFER the result STRING and mark it as an evaluation result.
If SHOW-PREFIX is non-nil insert `cider-repl-result-prefix' at the beginning
of the line.  If BOL is non-nil insert at the beginning of the line."
  (with-current-buffer buffer
    (save-excursion
      (cider-save-marker cider-repl-output-start
        (goto-char cider-repl-output-end)
        (when (and bol (not (bolp)))
          (insert-before-markers "\n"))
        (when show-prefix
          (insert-before-markers (propertize cider-repl-result-prefix 'font-lock-face 'font-lock-comment-face)))
        (if cider-repl-use-clojure-font-lock
            (insert-before-markers (cider-font-lock-as-clojure string))
          (cider-propertize-region
              '(font-lock-face cider-repl-result-face rear-nonsticky (font-lock-face))
            (insert-before-markers string)))))))

(defun cider-repl-newline-and-indent ()
  "Insert a newline, then indent the next line.
Restrict the buffer from the prompt for indentation, to avoid being
confused by strange characters (like unmatched quotes) appearing
earlier in the buffer."
  (interactive)
  (save-restriction
    (narrow-to-region cider-repl-prompt-start-mark (point-max))
    (insert "\n")
    (lisp-indent-line)))

(defun cider-repl-indent-and-complete-symbol ()
  "Indent the current line and perform symbol completion.
First indent the line.  If indenting doesn't move point, complete
the symbol."
  (interactive)
  (let ((pos (point)))
    (lisp-indent-line)
    (when (= pos (point))
      (if (save-excursion (re-search-backward "[^() \n\t\r]+\\=" nil t))
          (completion-at-point)))))

(defun cider-repl-kill-input ()
  "Kill all text from the prompt to point."
  (interactive)
  (cond ((< (marker-position cider-repl-input-start-mark) (point))
         (kill-region cider-repl-input-start-mark (point)))
        ((= (point) (marker-position cider-repl-input-start-mark))
         (cider-repl-delete-current-input))))

(defun cider-repl--input-complete-p (start end)
  "Return t if the region from START to END is a complete sexp."
  (save-excursion
    (goto-char start)
    (cond ((looking-at-p "\\s *[@'`#]?[(\"]")
           (ignore-errors
             (save-restriction
               (narrow-to-region start end)
               ;; Keep stepping over blanks and sexps until the end of
               ;; buffer is reached or an error occurs. Tolerate extra
               ;; close parens.
               (cl-loop do (skip-chars-forward " \t\r\n)")
                        until (eobp)
                        do (forward-sexp))
               t)))
          (t t))))

(defun cider-repl--display-image (buffer image &optional show-prefix bol)
  "Insert IMAGE into BUFFER at the current point.

For compatibility with the rest of CIDER's REPL machinery, supports
SHOW-PREFIX and BOL."
  (with-current-buffer buffer
    (save-excursion
      (cider-save-marker cider-repl-output-start
        (goto-char cider-repl-output-end)
        (when (and bol (not (bolp)))
          (insert-before-markers "\n"))
        (when show-prefix
          (insert-before-markers
           (propertize cider-repl-result-prefix 'font-lock-face 'font-lock-comment-face)))
        ;; The below is inlined from `insert-image' and changed to use
        ;; `insert-before-markers' rather than `insert'
        (let ((start (point))
              (props (nconc `(display ,image rear-nonsticky (display))
                            (when (boundp 'image-map)
                              `(keymap ,image-map)))))
          (insert-before-markers " ")
          (add-text-properties start (point) props)))))
  t)

(defcustom cider-repl-image-margin 10
  "Specifies the margin to be applied to images displayed in the REPL.
Either a single number of pixels - interpreted as a symmetric margin, or
pair of numbers `(x . y)' encoding an arbitrary margin."
  :type '(choice integer (vector integer integer))
  :package-version '(cider . "0.17.0"))

(defun cider-repl--image (data type datap)
  "A helper for creating images with CIDER's image options.
DATA is either the path to an image or its base64 coded data.  TYPE is a
symbol indicating the image type.  DATAP indicates whether the image is the
raw image data or a filename.  Returns an image instance with a margin per
`cider-repl-image-margin'."
  (create-image data type datap
                :margin cider-repl-image-margin))

(defun cider-repl-handle-jpeg (_type buffer image &optional show-prefix bol)
  "A handler for inserting a jpeg IMAGE into a repl BUFFER.
Part of the default `cider-repl-content-type-handler-alist'."
  (cider-repl--display-image buffer
                             (cider-repl--image image 'jpeg t)
                             show-prefix bol))

(defun cider-repl-handle-png (_type buffer image &optional show-prefix bol)
  "A handler for inserting a png IMAGE into a repl BUFFER.
Part of the default `cider-repl-content-type-handler-alist'."
  (cider-repl--display-image buffer
                             (cider-repl--image image 'png t)
                             show-prefix bol))

(defun cider-repl-handle-svg (_type buffer image &optional show-prefix bol)
  "A handler for inserting an svg IMAGE into a repl BUFFER.
Part of the default `cider-repl-content-type-handler-alist'."
  (cider-repl--display-image buffer
                             (cider-repl--image image 'svg t)
                             show-prefix bol))

(defun cider-repl-handle-external-body (type buffer _ &optional _show-prefix _bol)
  "Handler for slurping external content into BUFFER.
Handles an external-body TYPE by issuing a slurp request to fetch the content."
  (if-let* ((args        (cadr type))
            (access-type (nrepl-dict-get args "access-type")))
      (nrepl-send-request
       (list "op" "slurp" "url" (nrepl-dict-get args access-type))
       (cider-repl-handler buffer)
       (cider-current-repl)))
  nil)

(defvar cider-repl-content-type-handler-alist
  `(("message/external-body" . ,#'cider-repl-handle-external-body)
    ("image/jpeg" . ,#'cider-repl-handle-jpeg)
    ("image/png" . ,#'cider-repl-handle-png)
    ("image/svg+xml" . ,#'cider-repl-handle-svg))
  "Association list from content-types to handlers.
Handlers must be functions of two required and two optional arguments - the
REPL buffer to insert into, the value of the given content type as a raw
string, the REPL's show prefix as any and an `end-of-line' flag.

The return value of the handler should be a flag, indicating whether or not
the REPL is ready for a prompt to be displayed.  Most handlers should return
t, as the content-type response is (currently) an alternative to the
value response.  However for handlers which themselves issue subsequent
nREPL ops, it may be convenient to prevent inserting a prompt.")

(defun cider--maybe-get-state-cljs ()
  "Invokes `cider/get-state' when it's possible to do so."
  (when-let ((conn (cider-current-repl 'cljs)))
    (when (nrepl-op-supported-p "cider/get-state" conn)
      (nrepl-send-request '("op" "cider/get-state")
                          (lambda (_response)
                            ;; No action is necessary: this request results in `cider-repl--state-handler` being called.
                            )
                          conn))))

(defun cider--maybe-get-state-for-shadow-cljs (buffer &optional err)
  "Refresh the changed namespaces metadata given BUFFER and ERR (stderr string).

This is particularly necessary for shadow-cljs because:

* it has a particular nREPL implementation; and
* one may have saved files (which triggers recompilation,
  and therefore the need for recomputing changed namespaces)
  without sending a nREPL message (this can particularly happen
  if the file was edited outside Emacs)."
  (with-current-buffer buffer
    (when (and (eq cider-repl-type 'cljs)
               (eq cider-cljs-repl-type 'shadow)
               (not cider-repl-cljs-upgrade-pending)
               (if err
                   (string-match-p "Build completed\\." err)
                 t))
      (cider--maybe-get-state-cljs))))

(defun cider--maybe-get-state-for-figwheel-main (buffer out)
  "Refresh the changed namespaces metadata given BUFFER and OUT (stdout string)."
  (with-current-buffer buffer
    (when (and (eq cider-repl-type 'cljs)
               (eq cider-cljs-repl-type 'figwheel-main)
               (not cider-repl-cljs-upgrade-pending)
               (string-match-p "Successfully compiled build" out))
      (cider--maybe-get-state-cljs))))

(defun cider--shadow-cljs-handle-stderr (buffer err)
  "Refresh the changed namespaces metadata given BUFFER and ERR."
  (cider--maybe-get-state-for-shadow-cljs buffer err))

(defun cider--shadow-cljs-handle-done (buffer)
  "Refresh the changed namespaces metadata given BUFFER."
  (cider--maybe-get-state-for-shadow-cljs buffer))

(defvar cider--repl-stdout-functions (list #'cider--maybe-get-state-for-figwheel-main)
  "Functions to be invoked each time new stdout is received on a repl buffer.

Good for, for instance, monitoring specific strings that may be logged,
and responding to them.")

(defvar cider--repl-stderr-functions (list #'cider--shadow-cljs-handle-stderr)
  "Functions to be invoked each time new stderr is received on a repl buffer.

Good for, for instance, monitoring specific strings that may be logged,
and responding to them.")

(defvar cider--repl-done-functions (list #'cider--shadow-cljs-handle-done)
  "Functions to be invoked each time a given REPL interaction is complete.")

(defun cider-repl-handler (buffer)
  "Make an nREPL evaluation handler for the REPL BUFFER."
  (let ((show-prompt t))
    (nrepl-make-response-handler
     buffer
     (lambda (buffer value)
       (cider-repl-emit-result buffer value t))
     (lambda (buffer out)
       (dolist (f cider--repl-stdout-functions)
         (funcall f buffer out))
       (cider-repl-emit-stdout buffer out))
     (lambda (buffer err)
       (dolist (f cider--repl-stderr-functions)
         (funcall f buffer err))
       (cider-repl-emit-stderr buffer err))
     (lambda (buffer)
       (when show-prompt
         (cider-repl-emit-prompt buffer))
       (when cider-repl-buffer-size-limit
         (cider-repl-maybe-trim-buffer buffer))
       (dolist (f cider--repl-done-functions)
         (funcall f buffer)))
     nrepl-err-handler
     (lambda (buffer value content-type)
       (if-let* ((content-attrs (cadr content-type))
                 (content-type* (car content-type))
                 (handler (cdr (assoc content-type*
                                      cider-repl-content-type-handler-alist))))
           (setq show-prompt (funcall handler content-type buffer value nil t))
         (cider-repl-emit-result buffer value t t)))
     (lambda (buffer warning)
       (cider-repl-emit-stderr buffer warning)))))

(defun cider--repl-request-plist ()
  "Plist to be merged into REPL eval requests."
  `(,@(cider--nrepl-print-request-plist fill-column)
    ,@(unless cider-repl-use-pretty-printing
        `("nrepl.middleware.print/print" "cider.nrepl.pprint/pr"))
    ,@(when cider-repl-use-content-types
        `("content-type" "true"))))

(defun cider-repl--send-input (&optional newline)
  "Go to the end of the input and send the current input.
If NEWLINE is true then add a newline at the end of the input."
  (unless (cider-repl--in-input-area-p)
    (error "No input at point"))
  (let ((input (cider-repl--current-input)))
    (if (string-blank-p input)
        ;; don't evaluate a blank string, but erase it and emit
        ;; a fresh prompt to acknowledge to the user.
        (progn
          (cider-repl--replace-input "")
          (cider-repl-emit-prompt (current-buffer)))
      ;; otherwise evaluate the input
      (goto-char (point-max))
      (let ((end (point)))              ; end of input, without the newline
        (cider-repl--add-to-input-history input)
        (when newline
          (insert "\n"))
        (let ((inhibit-modification-hooks t))
          (add-text-properties cider-repl-input-start-mark
                               (point)
                               `(cider-old-input
                                 ,(cl-incf cider-repl-old-input-counter))))
        (unless cider-repl-use-clojure-font-lock
          (let ((overlay (make-overlay cider-repl-input-start-mark end)))
            ;; These properties are on an overlay so that they won't be taken
            ;; by kill/yank.
            (overlay-put overlay 'read-only t)
            (overlay-put overlay 'font-lock-face 'cider-repl-input-face))))
      (let ((input-start (save-excursion (cider-repl-beginning-of-defun) (point))))
        (goto-char (point-max))
        (cider-repl--mark-input-start)
        (cider-repl--mark-output-start)
        (cider-nrepl-request:eval
         input
         (cider-repl-handler (current-buffer))
         (cider-current-ns)
         (line-number-at-pos input-start)
         (cider-column-number-at-pos input-start)
         (cider--repl-request-plist))))))

(defun cider-repl-return (&optional end-of-input)
  "Evaluate the current input string, or insert a newline.
Send the current input only if a whole expression has been entered,
i.e. the parenthesis are matched.
When END-OF-INPUT is non-nil, send the input even if the parentheses
are not balanced."
  (interactive "P")
  (cond
   (end-of-input
    (cider-repl--send-input))
   ((and (get-text-property (point) 'cider-old-input)
         (< (point) cider-repl-input-start-mark))
    (cider-repl--grab-old-input end-of-input))
   ((cider-repl--input-complete-p cider-repl-input-start-mark (point-max))
    (cider-repl--send-input t))
   (t
    (cider-repl-newline-and-indent)
    (message "[input not complete]"))))

(defun cider-repl--grab-old-input (replace)
  "Resend the old REPL input at point.
If REPLACE is non-nil the current input is replaced with the old
input; otherwise the new input is appended.  The old input has the
text property `cider-old-input'."
  (cl-multiple-value-bind (beg end) (cider-property-bounds 'cider-old-input)
    (let ((old-input (buffer-substring beg end)) ;;preserve
          ;;properties, they will be removed later
          (offset (- (point) beg)))
      ;; Append the old input or replace the current input
      (cond (replace (goto-char cider-repl-input-start-mark))
            (t (goto-char (point-max))
               (unless (eq (char-before) ?\ )
                 (insert " "))))
      (delete-region (point) (point-max))
      (save-excursion
        (insert old-input)
        (when (equal (char-before) ?\n)
          (delete-char -1)))
      (forward-char offset))))

(defun cider-repl-closing-return ()
  "Evaluate the current input string after closing input.
Closes all open parentheses or bracketed expressions."
  (interactive)
  (goto-char (point-max))
  (save-restriction
    (narrow-to-region cider-repl-input-start-mark (point))
    (let ((matching-delimiter nil))
      (while (ignore-errors
               (save-excursion
                 (backward-up-list 1)
                 (setq matching-delimiter (cdr (syntax-after (point)))))
               t)
        (insert-char matching-delimiter))))
  (cider-repl-return))

(defun cider-repl-toggle-pretty-printing ()
  "Toggle pretty-printing in the REPL."
  (interactive)
  (setq cider-repl-use-pretty-printing (not cider-repl-use-pretty-printing))
  (message "Pretty printing in REPL %s."
           (if cider-repl-use-pretty-printing "enabled" "disabled")))

(defun cider-repl-toggle-content-types ()
  "Toggle content-type rendering in the REPL."
  (interactive)
  (setq cider-repl-use-content-types (not cider-repl-use-content-types))
  (message "Content-type support in REPL %s."
           (if cider-repl-use-content-types "enabled" "disabled")))

(defun cider-repl-toggle-clojure-font-lock ()
  "Toggle pretty-printing in the REPL."
  (interactive)
  (setq cider-repl-use-clojure-font-lock (not cider-repl-use-clojure-font-lock))
  (message "Clojure font-locking in REPL %s."
           (if cider-repl-use-clojure-font-lock "enabled" "disabled")))

(defun cider-repl-switch-to-other ()
  "Switch between the Clojure and ClojureScript REPLs for the current project."
  (interactive)
  ;; FIXME: implement cycling as session can hold more than two REPLs
  (let* ((this-repl (cider-current-repl 'infer 'ensure))
         (other-repl (car (seq-remove (lambda (r) (eq r this-repl)) (cider-repls nil t)))))
    (if other-repl
        (switch-to-buffer other-repl)
      (user-error "No other REPL in current session (%s)"
                  (car (sesman-current-session 'CIDER))))))

(defvar cider-repl-clear-buffer-hook)

(defun cider-repl--clear-region (start end)
  "Delete the output and its overlays between START and END."
  (mapc #'delete-overlay (overlays-in start end))
  (delete-region start end))

(defun cider-repl-clear-buffer ()
  "Clear the currently visited REPL buffer completely.
See also the related commands `cider-repl-clear-output' and
`cider-find-and-clear-repl-output'."
  (interactive)
  (let ((inhibit-read-only t))
    (cider-repl--clear-region (point-min) cider-repl-prompt-start-mark)
    (cider-repl--clear-region cider-repl-output-start cider-repl-output-end)
    (when (< (point) cider-repl-input-start-mark)
      (goto-char cider-repl-input-start-mark))
    (recenter t))
  (run-hooks 'cider-repl-clear-buffer-hook))

(defun cider-repl-clear-output (&optional clear-repl)
  "Delete the output inserted since the last input.
With a prefix argument CLEAR-REPL it will clear the entire REPL buffer instead."
  (interactive "P")
  (if clear-repl
      (cider-repl-clear-buffer)
    (let ((inhibit-read-only t))
      (cider-repl--clear-region cider-repl-output-start cider-repl-output-end)
      (save-excursion
        (goto-char cider-repl-output-end)
        (insert-before-markers
         (propertize ";; output cleared\n" 'font-lock-face 'font-lock-comment-face))))))

(defun cider-repl-clear-banners ()
  "Delete the REPL banners."
  (interactive)
  ;; TODO: Improve the boundaries detecting logic
  ;; probably it should be based on text properties
  ;; the current implementation will clear warnings as well
  (let ((start (point-min))
        (end (save-excursion
               (goto-char (point-min))
               (cider-repl-next-prompt)
               (forward-line -1)
               (end-of-line)
               (point))))
    (when (< start end)
      (let ((inhibit-read-only t))
        (cider-repl--clear-region start (1+ end))))))

(defun cider-repl-clear-help-banner ()
  "Delete the help REPL banner."
  (interactive)
  ;; TODO: Improve the boundaries detecting logic
  ;; probably it should be based on text properties
  (let ((start (save-excursion
                 (goto-char (point-min))
                 (search-forward ";; =")
                 (beginning-of-line)
                 (point)))
        (end (save-excursion
               (goto-char (point-min))
               (cider-repl-next-prompt)
               (search-backward ";; =")
               (end-of-line)
               (point))))
    (when (< start end)
      (let ((inhibit-read-only t))
        (cider-repl--clear-region start (1+ end))))))

(defun cider-repl-switch-ns-handler (buffer)
  "Make an nREPL evaluation handler for the REPL BUFFER's ns switching."
  (nrepl-make-response-handler buffer
                               (lambda (_buffer _value))
                               (lambda (buffer out)
                                 (cider-repl-emit-stdout buffer out))
                               (lambda (buffer err)
                                 (cider-repl-emit-stderr buffer err))
                               (lambda (buffer)
                                 (cider-repl-emit-prompt buffer))))

(defun cider-repl-set-ns (ns)
  "Switch the namespace of the REPL buffer to NS.
If called from a cljc buffer act on both the Clojure and ClojureScript REPL
if there are more than one REPL present.  If invoked in a REPL buffer the
command will prompt for the name of the namespace to switch to."
  (interactive (list (if (or (derived-mode-p 'cider-repl-mode)
                             (null (cider-ns-form)))
                         (completing-read "Switch to namespace: "
                                          (cider-sync-request:ns-list))
                       (cider-current-ns))))
  (when (or (not ns) (equal ns ""))
    (user-error "No namespace selected"))
  (cider-map-repls :auto
    (lambda (connection)
      ;; NOTE: `require' and `in-ns' are special forms in ClojureScript.
      ;; That's why we eval them separately instead of combining them with `do'.
      (when cider-repl-require-ns-on-set
        (cider-sync-tooling-eval (format "(require '%s)" ns) nil connection))
      (let ((f (if (equal 'cljs
                          (with-current-buffer connection
                            cider-repl-type))
                   ;; For cljs, don't use cider-tooling-eval, because Piggieback will later change the ns (issue #3503):
                   #'cider-nrepl-request:eval
                 ;; When possible, favor cider-tooling-eval because it preserves *1, etc (commit 5f705b):
                 #'cider-tooling-eval)))
        (funcall f (format "(in-ns '%s)" ns)
                 (cider-repl-switch-ns-handler connection))))))


;;; Location References

(defcustom cider-locref-regexp-alist
  '((stdout-stacktrace "[ \t]\\(at \\([^$(]+\\).*(\\([^:()]+\\):\\([0-9]+\\))\\)" 1 2 3 4)
    (aviso-stacktrace  "^[ \t]*\\(\\([^$/ \t]+\\).*? +\\([^:]+\\): +\\([0-9]+\\)\\)" 1 2 3 4)
    (print-stacktrace  "\\[\\([^][$ \t]+\\).* +\\([^ \t]+\\) +\\([0-9]+\\)\\]" 0 1 2 3)
    (timbre-log        "\\(TRACE\\|INFO\\|DEBUG\\|WARN\\|ERROR\\) +\\(\\[\\([^:]+\\):\\([0-9]+\\)\\]\\)" 2 3 nil 4)
    (cljs-message      "at line \\([0-9]+\\) +\\(.*\\)$" 0 nil 2 1)
    (warning           "warning,? +\\(\\([^\n:]+\\):\\([0-9]+\\):[0-9]+\\)" 1 nil 2 3)
    (compilation       ".*compiling:(\\([^\n:)]+\\):\\([0-9]+\\):[0-9]+)" 0 nil 1 2))
  "Alist holding regular expressions for inline location references.
Each element in the alist has the form (NAME REGEXP HIGHLIGHT VAR FILE
LINE), where NAME is the identifier of the regexp, REGEXP - regexp matching
a location, HIGHLIGHT - sub-expression matching region to highlight on
mouse-over, VAR - sub-expression giving Clojure VAR to look up.  FILE is
currently only used when VAR is nil and must be full resource path in that
case."
  :type '(alist :key-type sexp)
  :package-version '(cider. "0.16.0"))

(defun cider--locref-at-point-1 (reg-list)
  "Workhorse for getting locref at point.
REG-LIST is an entry in `cider-locref-regexp-alist'."
  (beginning-of-line)
  (when (re-search-forward (nth 1 reg-list) (point-at-eol) t)
    (let ((ix-highlight (or (nth 2 reg-list) 0))
          (ix-var (nth 3 reg-list))
          (ix-file (nth 4 reg-list))
          (ix-line (nth 5 reg-list)))
      (list
       :type (car reg-list)
       :highlight (cons (match-beginning ix-highlight) (match-end ix-highlight))
       :var  (and ix-var
                  (replace-regexp-in-string "_" "-"
                                            (match-string-no-properties ix-var)
                                            nil t))
       :file (and ix-file (match-string-no-properties ix-file))
       :line (and ix-line (string-to-number (match-string-no-properties ix-line)))))))

(defun cider-locref-at-point (&optional pos)
  "Return a plist of components of the location reference at POS.
Limit search to current line only and return nil if no location has been
found.  Returned keys are :type, :highlight, :var, :file, :line, where
:highlight is a cons of positions, :var and :file are strings or nil, :line
is a number.  See `cider-locref-regexp-alist' for how to specify regexes
for locref look up."
  (save-excursion
    (goto-char (or pos (point)))
    ;; Regexp lookup on long lines can result in significant hangs #2532. We
    ;; assume that lines longer than 300 don't contain source references.
    (when (< (- (point-at-eol) (point-at-bol)) 300)
      (seq-some (lambda (rl) (cider--locref-at-point-1 rl))
                cider-locref-regexp-alist))))

(defun cider-jump-to-locref-at-point (&optional pos)
  "Identify location reference at POS and navigate to it.
This function is used from help-echo property inside REPL buffers and uses
regexes from `cider-locref-regexp-alist' to infer locations at point."
  (interactive)
  (if-let* ((loc (cider-locref-at-point pos)))
      (let* ((var (plist-get loc :var))
             (line (plist-get loc :line))
             (file (or
                    ;; 1) retrieve from info middleware
                    (when var
                      (or (cider-sync-request:ns-path var)
                          (nrepl-dict-get (cider-sync-request:info var) "file")))
                    (when-let* ((file (plist-get loc :file)))
                      ;; 2) file detected by the regexp
                      (let ((file-from-regexp (if (file-name-absolute-p file)
                                                  file
                                                ;; when not absolute, expand within the current project
                                                (when-let* ((proj (clojure-project-dir)))
                                                  (expand-file-name file proj)))))
                        (or (when (file-readable-p file-from-regexp)
                              file-from-regexp)
                            ;; 3) infer ns from the abbreviated path
                            ;;    (common in reflection warnings)
                            (let ((ns (cider-path-to-ns file)))
                              (cider-sync-request:ns-path ns))))))))
        (if file
            (cider--jump-to-loc-from-info (nrepl-dict "file" file "line" line) t)
          (error "No source location for %s - you may need to adjust `cider-locref-regexp-alist' to match your logging format" var)))
    (user-error "No location reference at point")))

(defvar cider-locref-hoover-overlay
  (let ((o (make-overlay 1 1)))
    (overlay-put o 'category 'cider-error-hoover)
    ;; (overlay-put o 'face 'highlight)
    (overlay-put o 'pointer 'hand)
    (overlay-put o 'mouse-face 'highlight)
    (overlay-put o 'follow-link 'mouse)
    (overlay-put o 'keymap
                 (let ((map (make-sparse-keymap)))
                   (define-key map [return]  #'cider-jump-to-locref-at-point)
                   (define-key map [mouse-2] #'cider-jump-to-locref-at-point)
                   map))
    o)
  "Overlay used during hoovering on location references in REPL buffers.
One for all REPLs.")

(defun cider-locref-help-echo (_win buffer pos)
  "Function for help-echo property in REPL buffers.
WIN, BUFFER and POS are the window, buffer and point under mouse position."
  (with-current-buffer buffer
    (if-let* ((hl (plist-get (cider-locref-at-point pos) :highlight)))
        (move-overlay cider-locref-hoover-overlay (car hl) (cdr hl) buffer)
      (delete-overlay cider-locref-hoover-overlay))
    nil))


;;; History

(defcustom cider-repl-wrap-history nil
  "T to wrap history around when the end is reached."
  :type 'boolean)

;; These two vars contain the state of the last history search.  We
;; only use them if `last-command' was `cider-repl--history-replace',
;; otherwise we reinitialize them.

(defvar cider-repl-input-history-position -1
  "Newer items have smaller indices.")

(defvar cider-repl-history-pattern nil
  "The regexp most recently used for finding input history.")

(defvar cider-repl-input-history '()
  "History list of strings read from the REPL buffer.")

(defun cider-repl--add-to-input-history (string)
  "Add STRING to the input history.
Empty strings and duplicates are ignored."
  (unless (or (equal string "")
              (equal string (car cider-repl-input-history)))
    (push string cider-repl-input-history)))

(defun cider-repl-delete-current-input ()
  "Delete all text after the prompt."
  (goto-char (point-max))
  (delete-region cider-repl-input-start-mark (point-max)))

(defun cider-repl--replace-input (string)
  "Replace the current REPL input with STRING."
  (cider-repl-delete-current-input)
  (insert-and-inherit string))

(defun cider-repl--position-in-history (start-pos direction regexp)
  "Return the position of the history item starting at START-POS.
Search in DIRECTION for REGEXP.
Return -1 resp the length of the history if no item matches."
  ;; Loop through the history list looking for a matching line
  (let* ((step (cl-ecase direction
                 (forward -1)
                 (backward 1)))
         (history cider-repl-input-history)
         (len (length history)))
    (cl-loop for pos = (+ start-pos step) then (+ pos step)
             if (< pos 0) return -1
             if (<= len pos) return len
             if (string-match-p regexp (nth pos history)) return pos)))

(defun cider-repl--history-replace (direction &optional regexp)
  "Replace the current input with the next line in DIRECTION.
DIRECTION is 'forward' or 'backward' (in the history list).
If REGEXP is non-nil, only lines matching REGEXP are considered."
  (setq cider-repl-history-pattern regexp)
  (let* ((min-pos -1)
         (max-pos (length cider-repl-input-history))
         (pos0 (cond ((cider-history-search-in-progress-p)
                      cider-repl-input-history-position)
                     (t min-pos)))
         (pos (cider-repl--position-in-history pos0 direction (or regexp "")))
         (msg nil))
    (cond ((and (< min-pos pos) (< pos max-pos))
           (cider-repl--replace-input (nth pos cider-repl-input-history))
           (setq msg (format "History item: %d" pos)))
          ((not cider-repl-wrap-history)
           (setq msg (cond ((= pos min-pos) "End of history")
                           ((= pos max-pos) "Beginning of history"))))
          (cider-repl-wrap-history
           (setq pos (if (= pos min-pos) max-pos min-pos))
           (setq msg "Wrapped history")))
    (when (or (<= pos min-pos) (<= max-pos pos))
      (when regexp
        (setq msg (concat msg "; no matching item"))))
    (message "%s%s" msg (cond ((not regexp) "")
                              (t (format "; current regexp: %s" regexp))))
    (setq cider-repl-input-history-position pos)
    (setq this-command 'cider-repl--history-replace)))

(defun cider-history-search-in-progress-p ()
  "Return t if a current history search is in progress."
  (eq last-command 'cider-repl--history-replace))

(defun cider-terminate-history-search ()
  "Terminate the current history search."
  (setq last-command this-command))

(defun cider-repl-previous-input ()
  "Cycle backwards through input history.
If the `last-command' was a history navigation command use the
same search pattern for this command.
Otherwise use the current input as search pattern."
  (interactive)
  (cider-repl--history-replace 'backward (cider-repl-history-pattern t)))

(defun cider-repl-next-input ()
  "Cycle forwards through input history.
See `cider-previous-input'."
  (interactive)
  (cider-repl--history-replace 'forward (cider-repl-history-pattern t)))

(defun cider-repl-forward-input ()
  "Cycle forwards through input history."
  (interactive)
  (cider-repl--history-replace 'forward (cider-repl-history-pattern)))

(defun cider-repl-backward-input ()
  "Cycle backwards through input history."
  (interactive)
  (cider-repl--history-replace 'backward (cider-repl-history-pattern)))

(defun cider-repl-previous-matching-input (regexp)
  "Find the previous input matching REGEXP."
  (interactive "sPrevious element matching (regexp): ")
  (cider-terminate-history-search)
  (cider-repl--history-replace 'backward regexp))

(defun cider-repl-next-matching-input (regexp)
  "Find then next input matching REGEXP."
  (interactive "sNext element matching (regexp): ")
  (cider-terminate-history-search)
  (cider-repl--history-replace 'forward regexp))

(defun cider-repl-history-pattern (&optional use-current-input)
  "Return the regexp for the navigation commands.
If USE-CURRENT-INPUT is non-nil, use the current input."
  (cond ((cider-history-search-in-progress-p)
         cider-repl-history-pattern)
        (use-current-input
         (cl-assert (<= cider-repl-input-start-mark (point)))
         (let ((str (cider-repl--current-input t)))
           (cond ((string-match-p "^[ \n]*$" str) nil)
                 (t (concat "^" (regexp-quote str))))))
        (t nil)))

;;; persistent history
(defcustom cider-repl-history-size 500
  "The maximum number of items to keep in the REPL history."
  :type 'integer
  :safe #'integerp)

(defcustom cider-repl-history-file nil
  "File to save the persistent REPL history to.
If this is set to a path the history will be global to all projects.  If this is
set to `per-project', the history will be stored in a file (.cider-history) at
the root of each project."
  :type '(choice string symbol))

(defun cider-repl--history-read-filename ()
  "Ask the user which file to use, defaulting `cider-repl-history-file'."
  (read-file-name "Use CIDER REPL history file: "
                  cider-repl-history-file))

(defun cider-repl--history-read (filename)
  "Read history from FILENAME and return it.
It does not yet set the input history."
  (if (file-readable-p filename)
      (with-temp-buffer
        (insert-file-contents filename)
        (when (> (buffer-size (current-buffer)) 0)
          (read (current-buffer))))
    '()))

(defun cider-repl--find-dir-for-history ()
  "Find the first suitable directory to store the project's history."
  (seq-find
   (lambda (dir) (and (not (null dir)) (not (tramp-tramp-file-p dir))))
   (list nrepl-project-dir (clojure-project-dir) default-directory)))

(defun cider-repl-history-load (&optional filename)
  "Load history from FILENAME into current session.
FILENAME defaults to the value of `cider-repl-history-file' but user
defined filenames can be used to read special history files.

The value of `cider-repl-input-history' is set by this function."
  (interactive (list (cider-repl--history-read-filename)))
  (cond
   (filename (setq cider-repl-history-file filename))
   ((equal 'per-project cider-repl-history-file)
    (make-local-variable 'cider-repl-input-history)
    (when-let ((dir (cider-repl--find-dir-for-history)))
      (setq-local
       cider-repl-history-file (expand-file-name ".cider-history" dir)))))
  (when cider-repl-history-file
    (condition-case nil
        ;; TODO: probably need to set cider-repl-input-history-position as
        ;; well. In a fresh connection the newest item in the list is
        ;; currently not available.  After sending one input, everything
        ;; seems to work.
        (setq
         cider-repl-input-history
         (cider-repl--history-read cider-repl-history-file))
      (error
       (message
        "Malformed cider-repl-history-file: %s" cider-repl-history-file)))
    (add-hook 'kill-buffer-hook #'cider-repl-history-just-save t t)
    (add-hook 'kill-emacs-hook #'cider-repl-history-save-all)))

(defun cider-repl--history-write (filename)
  "Write history to FILENAME.
Currently coding system for writing the contents is hardwired to
utf-8-unix."
  (let* ((end (min (length cider-repl-input-history) cider-repl-history-size))
         ;; newest items are at the beginning of the list, thus 0
         (hist (cl-subseq cider-repl-input-history 0 end)))
    (unless (file-writable-p filename)
      (error (format "History file not writable: %s" filename)))
    (let ((print-length nil) (print-level nil))
      (with-temp-file filename
        ;; TODO: really set cs for output
        ;; TODO: does cs need to be customizable?
        (insert ";; -*- coding: utf-8-unix -*-\n")
        (insert ";; Automatically written history of CIDER REPL session\n")
        (insert ";; Edit at your own risk\n\n")
        (prin1 (mapcar #'substring-no-properties hist) (current-buffer))))))

(defun cider-repl-history-save (&optional filename)
  "Save the current REPL input history to FILENAME.
FILENAME defaults to the value of `cider-repl-history-file'."
  (interactive (list (cider-repl--history-read-filename)))
  (let* ((file (or filename cider-repl-history-file)))
    (cider-repl--history-write file)))

(defun cider-repl-history-just-save ()
  "Just save the history to `cider-repl-history-file'.
This function is meant to be used in hooks to avoid lambda
constructs."
  (cider-repl-history-save cider-repl-history-file))

(defun cider-repl-history-save-all ()
  "Save all histories."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (equal major-mode 'cider-repl-mode)
        (cider-repl-history-just-save)))))


;;; REPL shortcuts
(defcustom cider-repl-shortcut-dispatch-char ?\,
  "Character used to distinguish REPL commands from Lisp forms."
  :type '(character))

(defvar cider-repl-shortcuts (make-hash-table :test 'equal))

(defun cider-repl-add-shortcut (name handler)
  "Add a REPL shortcut command, defined by NAME and HANDLER."
  (puthash name handler cider-repl-shortcuts))

(declare-function cider-toggle-trace-ns "cider-tracing")
(declare-function cider-undef "cider-eval")
(declare-function cider-browse-ns "cider-browse-ns")
(declare-function cider-classpath "cider-classpath")
(declare-function cider-repl-history "cider-repl-history")
(declare-function cider-run "cider-mode")
(declare-function cider-ns-refresh "cider-ns")
(declare-function cider-ns-reload "cider-ns")
(declare-function cider-find-var "cider-find")
(declare-function cider-version "cider")
(declare-function cider-test-run-loaded-tests "cider-test")
(declare-function cider-test-run-project-tests "cider-test")
(cider-repl-add-shortcut "clear-output" #'cider-repl-clear-output)
(cider-repl-add-shortcut "clear" #'cider-repl-clear-buffer)
(cider-repl-add-shortcut "clear-banners" #'cider-repl-clear-banners)
(cider-repl-add-shortcut "clear-help-banner" #'cider-repl-clear-help-banner)
(cider-repl-add-shortcut "trim" #'cider-repl-trim-buffer)
(cider-repl-add-shortcut "ns" #'cider-repl-set-ns)
(cider-repl-add-shortcut "toggle-pprint" #'cider-repl-toggle-pretty-printing)
(cider-repl-add-shortcut "toggle-font-lock" #'cider-repl-toggle-clojure-font-lock)
(cider-repl-add-shortcut "toggle-content-types" #'cider-repl-toggle-content-types)
(cider-repl-add-shortcut "browse-ns" (lambda () (interactive) (cider-browse-ns (cider-current-ns))))
(cider-repl-add-shortcut "classpath" #'cider-classpath)
(cider-repl-add-shortcut "history" #'cider-repl-history)
(cider-repl-add-shortcut "trace-ns" #'cider-toggle-trace-ns)
(cider-repl-add-shortcut "undef" #'cider-undef)
(cider-repl-add-shortcut "refresh" #'cider-ns-refresh)
(cider-repl-add-shortcut "reload" #'cider-ns-reload)
(cider-repl-add-shortcut "find-var" #'cider-find-var)
(cider-repl-add-shortcut "doc" #'cider-doc)
(cider-repl-add-shortcut "help" #'cider-repl-shortcuts-help)
(cider-repl-add-shortcut "test-ns" #'cider-test-run-ns-tests)
(cider-repl-add-shortcut "test-all" #'cider-test-run-loaded-tests)
(cider-repl-add-shortcut "test-project" #'cider-test-run-project-tests)
(cider-repl-add-shortcut "test-ns-with-filters" #'cider-test-run-ns-tests-with-filters)
(cider-repl-add-shortcut "test-all-with-filters" (lambda () (interactive) (cider-test-run-loaded-tests 'prompt-for-filters)))
(cider-repl-add-shortcut "test-project-with-filters" (lambda () (interactive) (cider-test-run-project-tests 'prompt-for-filters)))
(cider-repl-add-shortcut "test-report" #'cider-test-show-report)
(cider-repl-add-shortcut "run" #'cider-run)
(cider-repl-add-shortcut "conn-info" #'cider-describe-connection)
(cider-repl-add-shortcut "version" #'cider-version)
(cider-repl-add-shortcut "require-repl-utils" #'cider-repl-require-repl-utils)
;; So many ways to quit :-)
(cider-repl-add-shortcut "adios" #'cider-quit)
(cider-repl-add-shortcut "sayonara" #'cider-quit)
(cider-repl-add-shortcut "quit" #'cider-quit)
(cider-repl-add-shortcut "restart" #'cider-restart)

(defconst cider-repl-shortcuts-help-buffer "*CIDER REPL Shortcuts Help*")

(defun cider-repl-shortcuts-help ()
  "Display a help buffer."
  (interactive)
  (ignore-errors (kill-buffer cider-repl-shortcuts-help-buffer))
  (with-current-buffer (get-buffer-create cider-repl-shortcuts-help-buffer)
    (insert "CIDER REPL shortcuts:\n\n")
    (maphash (lambda (k v) (insert (format "%s:\n\t%s\n" k v))) cider-repl-shortcuts)
    (goto-char (point-min))
    (help-mode)
    (display-buffer (current-buffer) t))
  (cider-repl-handle-shortcut)
  (current-buffer))

(defun cider-repl--available-shortcuts ()
  "Return the available REPL shortcuts."
  (cider-util--hash-keys cider-repl-shortcuts))

(defun cider-repl-handle-shortcut ()
  "Execute a REPL shortcut."
  (interactive)
  (if (> (point) cider-repl-input-start-mark)
      (insert (string cider-repl-shortcut-dispatch-char))
    (let ((command (completing-read "Command: "
                                    (cider-repl--available-shortcuts))))
      (if (not (equal command ""))
          (let ((command-func (gethash command cider-repl-shortcuts)))
            (if command-func
                (call-interactively command-func)
              (error "Unknown command %S.  Available commands: %s"
                     command-func
                     (mapconcat #'identity (cider-repl--available-shortcuts) ", "))))
        (error "No command selected")))))

(defun cider--sesman-friendly-session-p (session &optional debug)
  "Check if SESSION is a friendly session, DEBUG optionally.

The checking is done as follows:

* If the current buffer's name equals to the value of `cider-test-report-buffer',
  only accept the given session's repl if it equals `cider-test--current-repl'
* Consider if the buffer belongs to `cider-ancillary-buffers'
* Consider the buffer's filename, strip any Docker/TRAMP details from it
* Check if that filename belongs to the classpath,
  or to the classpath roots (e.g. the project root dir)
* As a fallback, check if the buffer's ns form
  matches any of the loaded namespaces."
  (setcdr session (seq-filter #'buffer-live-p (cdr session)))
  (when-let ((repl (cadr session)))
    (cond
     ((equal (buffer-name)
             cider-test-report-buffer)
      (or (not cider-test--current-repl)
          (not (buffer-live-p cider-test--current-repl))
          (equal repl
                 cider-test--current-repl)))

     ((member (buffer-name) cider-ancillary-buffers)
      t)

     (t
      (when-let* ((proc (get-buffer-process repl))
                  (file (file-truename (or (buffer-file-name) default-directory))))
        ;; With avfs paths look like /path/to/.avfs/path/to/some.jar#uzip/path/to/file.clj
        (when (string-match-p "#uzip" file)
          (let ((avfs-path (directory-file-name (expand-file-name (or (getenv "AVFSBASE")  "~/.avfs/")))))
            (setq file (replace-regexp-in-string avfs-path "" file t t))))
        (when-let ((tp (cider-tramp-prefix (current-buffer))))
          (setq file (string-remove-prefix tp file)))
        (when (process-live-p proc)
          (let* ((classpath (or (process-get proc :cached-classpath)
                                (let ((cp (with-current-buffer repl
                                            (cider-classpath-entries))))
                                  (process-put proc :cached-classpath cp)
                                  cp)))
                 (ns-list (when (nrepl-op-supported-p "ns-list" repl)
                            (or (process-get proc :all-namespaces)
                                (let ((ns-list (with-current-buffer repl
                                                 (cider-sync-request:ns-list))))
                                  (process-put proc :all-namespaces ns-list)
                                  ns-list))))
                 (classpath-roots (or (process-get proc :cached-classpath-roots)
                                      (let ((cp (thread-last classpath
                                                             (seq-filter (lambda (path) (not (string-match-p "\\.jar$" path))))
                                                             (mapcar #'file-name-directory)
                                                             (seq-remove  #'null)
                                                             (seq-uniq))))
                                        (process-put proc :cached-classpath-roots cp)
                                        cp))))
            (or (seq-find (lambda (path) (string-prefix-p path file))
                          classpath)
                (seq-find (lambda (path) (string-prefix-p path file))
                          classpath-roots)
                (when-let* ((cider-path-translations (cider--all-path-translations))
                            (translated (cider--translate-path file 'to-nrepl :return-all)))
                  (seq-find (lambda (translated-path)
                              (or (seq-find (lambda (path)
                                              (string-prefix-p path translated-path))
                                            classpath)
                                  (seq-find (lambda (path)
                                              (string-prefix-p path translated-path))
                                            classpath-roots)))
                            translated))
                (when-let ((ns (condition-case nil
                                   (substring-no-properties (cider-current-ns :no-default
                                                                              ;; important - don't query the repl,
                                                                              ;; avoiding a recursive invocation of `cider--sesman-friendly-session-p`:
                                                                              :no-repl-check))
                                 (error nil))))
                  ;; if the ns form matches with a ns of all runtime namespaces, we can consider the buffer to match
                  ;; (this is a bit lax, but also quite useful)
                  (with-current-buffer repl
                    (or (when cider-repl-ns-cache ;; may be nil on repl startup
                          (member ns (nrepl-dict-keys cider-repl-ns-cache)))
                        (member ns ns-list))))
                (when debug
                  (list file "was not determined to belong to classpath:" classpath "or classpath-roots:" classpath-roots))))))))))

(defun cider-debug-sesman-friendly-session-p ()
  "`message's debugging information relative to friendly sessions.

This is useful for when one sees 'No linked CIDER sessions'
in an unexpected place."
  (interactive)
  (message (prin1-to-string (mapcar (lambda (session)
                                      (cider--sesman-friendly-session-p session t))
                                    (sesman--all-system-sessions 'CIDER)))))

(cl-defmethod sesman-friendly-session-p ((_system (eql CIDER)) session)
  "Check if SESSION is a friendly session."
  (cider--sesman-friendly-session-p session))


;;;;; CIDER REPL mode
(defvar cider-repl-mode-hook nil
  "Hook executed when entering `cider-repl-mode'.")

(defvar cider-repl-mode-syntax-table
  (copy-syntax-table clojure-mode-syntax-table))

(declare-function cider-eval-last-sexp "cider-eval")
(declare-function cider-toggle-trace-ns "cider-tracing")
(declare-function cider-toggle-trace-var "cider-tracing")
(declare-function cider-find-resource "cider-find")
(declare-function cider-find-ns "cider-find")
(declare-function cider-find-keyword "cider-find")
(declare-function cider-find-var "cider-find")
(declare-function cider-switch-to-last-clojure-buffer "cider-mode")
(declare-function cider-macroexpand-1 "cider-macroexpansion")
(declare-function cider-macroexpand-all "cider-macroexpansion")
(declare-function cider-selector "cider-selector")
(declare-function cider-jack-in-clj "cider")
(declare-function cider-jack-in-cljs "cider")
(declare-function cider-connect-clj "cider")
(declare-function cider-connect-cljs "cider")

(defvar cider-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-d") 'cider-doc-map)
    (define-key map (kbd "C-c ,")   'cider-test-commands-map)
    (define-key map (kbd "C-c C-t") 'cider-test-commands-map)
    (define-key map (kbd "M-.") #'cider-find-var)
    (define-key map (kbd "C-c C-.") #'cider-find-ns)
    (define-key map (kbd "C-c C-:") #'cider-find-keyword)
    (define-key map (kbd "M-,") #'cider-pop-back)
    (define-key map (kbd "C-c M-.") #'cider-find-resource)
    (define-key map (kbd "RET") #'cider-repl-return)
    (define-key map (kbd "TAB") #'cider-repl-tab)
    (define-key map (kbd "C-<return>") #'cider-repl-closing-return)
    (define-key map (kbd "C-j") #'cider-repl-newline-and-indent)
    (define-key map (kbd "C-c C-o") #'cider-repl-clear-output)
    (define-key map (kbd "C-c M-n") #'cider-repl-set-ns)
    (define-key map (kbd "C-c C-u") #'cider-repl-kill-input)
    (define-key map (kbd "C-S-a") #'cider-repl-bol-mark)
    (define-key map [S-home] #'cider-repl-bol-mark)
    (define-key map (kbd "C-<up>") #'cider-repl-backward-input)
    (define-key map (kbd "C-<down>") #'cider-repl-forward-input)
    (define-key map (kbd "M-p") #'cider-repl-previous-input)
    (define-key map (kbd "M-n") #'cider-repl-next-input)
    (define-key map (kbd "M-r") #'cider-repl-previous-matching-input)
    (define-key map (kbd "M-s") #'cider-repl-next-matching-input)
    (define-key map (kbd "C-c C-n") #'cider-repl-next-prompt)
    (define-key map (kbd "C-c C-p") #'cider-repl-previous-prompt)
    (define-key map (kbd "C-c C-b") #'cider-interrupt)
    (define-key map (kbd "C-c C-c") #'cider-interrupt)
    (define-key map (kbd "C-c C-m") #'cider-macroexpand-1)
    (define-key map (kbd "C-c M-m") #'cider-macroexpand-all)
    (define-key map (kbd "C-c C-s") #'sesman-map)
    (define-key map (kbd "C-c C-z") #'cider-switch-to-last-clojure-buffer)
    (define-key map (kbd "C-c M-o") #'cider-repl-switch-to-other)
    (define-key map (kbd "C-c M-s") #'cider-selector)
    (define-key map (kbd "C-c M-d") #'cider-describe-connection)
    (define-key map (kbd "C-c C-q") #'cider-quit)
    (define-key map (kbd "C-c M-r") #'cider-restart)
    (define-key map (kbd "C-c M-i") #'cider-inspect)
    (define-key map (kbd "C-c M-p") #'cider-repl-history)
    (define-key map (kbd "C-c M-t v") #'cider-toggle-trace-var)
    (define-key map (kbd "C-c M-t n") #'cider-toggle-trace-ns)
    (define-key map (kbd "C-c C-x") 'cider-start-map)
    (define-key map (kbd "C-x C-e") #'cider-eval-last-sexp)
    (define-key map (kbd "C-c C-r") 'clojure-refactor-map)
    (define-key map (kbd "C-c C-v") 'cider-eval-commands-map)
    (define-key map (kbd "C-c M-j") #'cider-jack-in-clj)
    (define-key map (kbd "C-c M-J") #'cider-jack-in-cljs)
    (define-key map (kbd "C-c M-c") #'cider-connect-clj)
    (define-key map (kbd "C-c M-C") #'cider-connect-cljs)

    (define-key map (string cider-repl-shortcut-dispatch-char) #'cider-repl-handle-shortcut)
    (easy-menu-define cider-repl-mode-menu map
      "Menu for CIDER's REPL mode"
      `("REPL"
        ["Complete symbol" complete-symbol]
        "--"
        ,cider-doc-menu
        "--"
        ("Find"
         ["Find definition" cider-find-var]
         ["Find namespace" cider-find-ns]
         ["Find resource" cider-find-resource]
         ["Find keyword" cider-find-keyword]
         ["Go back" cider-pop-back])
        "--"
        ["Switch to Clojure buffer" cider-switch-to-last-clojure-buffer]
        ["Switch to other REPL" cider-repl-switch-to-other]
        "--"
        ("Macroexpand"
         ["Macroexpand-1" cider-macroexpand-1]
         ["Macroexpand-all" cider-macroexpand-all])
        "--"
        ,cider-test-menu
        "--"
        ["Run project (-main function)" cider-run]
        ["Inspect" cider-inspect]
        ["Toggle var tracing" cider-toggle-trace-var]
        ["Toggle ns tracing" cider-toggle-trace-ns]
        ["Refresh loaded code" cider-ns-refresh]
        "--"
        ["Set REPL ns" cider-repl-set-ns]
        ["Toggle pretty printing" cider-repl-toggle-pretty-printing]
        ["Toggle Clojure font-lock" cider-repl-toggle-clojure-font-lock]
        ["Toggle rich content types" cider-repl-toggle-content-types]
        ["Require REPL utils" cider-repl-require-repl-utils]
        "--"
        ["Browse classpath" cider-classpath]
        ["Browse classpath entry" cider-open-classpath-entry]
        ["Browse namespace" cider-browse-ns]
        ["Browse all namespaces" cider-browse-ns-all]
        ["Browse spec" cider-browse-spec]
        ["Browse all specs" cider-browse-spec-all]
        "--"
        ["Next prompt" cider-repl-next-prompt]
        ["Previous prompt" cider-repl-previous-prompt]
        ["Clear output" cider-repl-clear-output]
        ["Clear buffer" cider-repl-clear-buffer]
        ["Trim buffer" cider-repl-trim-buffer]
        ["Clear banners" cider-repl-clear-banners]
        ["Clear help banner" cider-repl-clear-help-banner]
        ["Kill input" cider-repl-kill-input]
        "--"
        ["Interrupt evaluation" cider-interrupt]
        "--"
        ["Connection info" cider-describe-connection]
        "--"
        ["Close ancillary buffers" cider-close-ancillary-buffers]
        ["Quit" cider-quit]
        ["Restart" cider-restart]
        "--"
        ["Clojure Cheatsheet" cider-cheatsheet]
        "--"
        ["A sip of CIDER" cider-drink-a-sip]
        ["View user manual" cider-view-manual]
        ["View quick reference card" cider-view-refcard]
        ["Report a bug" cider-report-bug]
        ["Version info" cider-version]))
    map))

(sesman-install-menu cider-repl-mode-map)

(defun cider-repl-wrap-fontify-function (func)
  "Return a function that will call FUNC narrowed to input region."
  (lambda (beg end &rest rest)
    (when (and cider-repl-input-start-mark
               (> end cider-repl-input-start-mark))
      (save-restriction
        (narrow-to-region cider-repl-input-start-mark (point-max))
        (let ((font-lock-dont-widen t))
          (apply func (max beg cider-repl-input-start-mark) end rest))))))

(declare-function cider-complete-at-point "cider-completion")
(defvar cider--static-font-lock-keywords)

(defun cider-repl-setup-paredit ()
  "Override the paredit-RET binding in cider-repl-mode."
  (let ((oldmap (cdr (assoc 'paredit-mode minor-mode-map-alist)))
        (newmap (make-sparse-keymap)))
    (set-keymap-parent newmap oldmap)
    (define-key newmap (kbd "RET") nil)
    (make-local-variable 'minor-mode-overriding-map-alist)
    (push `(paredit-mode . ,newmap) minor-mode-overriding-map-alist)))

(define-derived-mode cider-repl-mode fundamental-mode "REPL"
  "Major mode for Clojure REPL interactions.

\\{cider-repl-mode-map}"
  (clojure-mode-variables)
  (clojure-font-lock-setup)
  (font-lock-add-keywords nil cider--static-font-lock-keywords)
  (setq-local sesman-system 'CIDER)
  (setq-local font-lock-fontify-region-function
              (cider-repl-wrap-fontify-function font-lock-fontify-region-function))
  (setq-local font-lock-unfontify-region-function
              (cider-repl-wrap-fontify-function font-lock-unfontify-region-function))
  (set-syntax-table cider-repl-mode-syntax-table)
  (cider-eldoc-setup)
  ;; At the REPL, we define beginning-of-defun and end-of-defun to be
  ;; the start of the previous prompt or next prompt respectively.
  ;; Notice the interplay with `cider-repl-beginning-of-defun'.
  (setq-local beginning-of-defun-function #'cider-repl-mode-beginning-of-defun)
  (setq-local end-of-defun-function #'cider-repl-mode-end-of-defun)
  (setq-local prettify-symbols-alist clojure--prettify-symbols-alist)
  ;; apply dir-local variables to REPL buffers
  (hack-dir-local-variables-non-file-buffer)
  (cider-repl-history-load)
  (add-hook 'completion-at-point-functions #'cider-complete-at-point nil t)
  (add-hook 'paredit-mode-hook (lambda () (clojure-paredit-setup cider-repl-mode-map)))
  (cider-repl-setup-paredit))

(provide 'cider-repl)

;;; cider-repl.el ends here
