;;; obs-websocket.el --- Interact with Open Broadcaster Software through a websocket   -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Sacha Chua
;; Copyright (C) 2025  Charlie McMackin

;; Author: Sacha Chua <sacha@sachachua.com>
;;      Charlie McMackin <charlie.mac@gmail.com>
;; Maintainer: Charlie McMackin <charlie.mac@gmail.com>
;; Keywords: recording streaming
;; Version: 0.10
;; Homepage: https://github.com/obs-websocket-el/obs-websocket-el
;; Package-Requires: ((emacs "26.1") (websocket))

;; This file is not part of GNU Emacs

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; You will also need to install:
;; OBS: https://obsproject.com/
;; obs-websocket: https://github.com/obsproject/obs-websocket
;; websocket.el: https://github.com/ahyatt/emacs-websocket

;;; Code:

;;;; Requirements
(require 'websocket)
(require 'json)
(require 'map)
(require 'svg)

;;;; Variables
(defvar obs-websocket-url "ws://localhost:4455" "URL for OBS instance.  Use wss:// if secured by TLS.")
(defvar obs-websocket-password nil "Password for OBS.")
(defvar obs-websocket nil "Socket for communicating with OBS.")
(defvar obs-websocket-messages nil "Messages from OBS.")
(defvar obs-websocket-message-id 0 "Starting message ID.")
(defvar obs-websocket-rpc-version 1 "Lastest OBS RPC version supported.")
(defvar obs-websocket-obs-websocket-version nil "Connected OBS' Web Socket Version.")
(defvar obs-websocket-obs-studio-version nil "Connected OBS' Studio Version.")
(defvar obs-websocket-on-message-payload-functions '(obs-websocket-log-response obs-websocket-marshal-message)
  "Functions to call when messages arrive.")
(defvar obs-websocket-event-functions (list #'obs-websocket-report-status)
  "Functions that handle OBS event responses.")
(defvar obs-websocket-debug nil "Debug messages.")
(defvar obs-websocket-message-callbacks nil "Alist of (message-id . callback-func).")
(defvar obs-websocket-streaming-p nil "Non-nil if streaming.")
(defvar obs-websocket-recording-p nil "Non-nil if recording.")
(defvar obs-websocket-status "" "Modeline string.")
(defvar obs-websocket-scene "" "Current scene.")
(defvar obs-websocket-scene-list nil "List of OBS scenes.")
(defvar obs-websocket-scene-item-list nil "List of OBS scene items.")
(defvar obs-websocket-recording-filename nil "Filename of current or most recent recording.")

;;;; Functions
(defun obs-websocket--next-request-id ()
  "Generate a new request id."
  (prog1 (number-to-string obs-websocket-message-id)
    (cl-incf obs-websocket-message-id)))

(defun obs-websocket-connected-p ()
  "Return T when Emacs is connected to OBS Studio via WebSocket."
  (and obs-websocket (websocket-openp obs-websocket)))

(defun obs-websocket-update-mode-line ()
  "Update the text for the mode line."
  (let ((info
         (concat "OBS:"
                 obs-websocket-scene
                 (if (or obs-websocket-streaming-p obs-websocket-recording-p)
                     (concat
                      "*"
                      (if obs-websocket-streaming-p "Str" "")
                      (if obs-websocket-recording-p "Rec" "")
                      "*")
                   ""))))
    (setq obs-websocket-status info)
    (force-mode-line-update)))

;;;###autoload
(define-minor-mode obs-websocket-minor-mode
  "Minor mode for OBS Websocket."
  :init-value nil
  :lighter " OBS"
  :global t
  (let ((info '(obs-websocket-minor-mode obs-websocket-status " ")))
    (if obs-websocket-minor-mode
        ;; put in modeline
        (add-to-list 'mode-line-front-space info)
      ;; remove from modeline
      (setq mode-line-front-space
            (seq-remove (lambda (x)
                          (and (listp x) (equal (car x) 'obs-websocket-minor-mode)))
                        mode-line-front-space)))))

(defun obs-websocket-report-status (payload)
  "Print friendly messages for PAYLOAD."
  (when-let
      ((msg
        (pcase (plist-get payload :eventType)
          ("CurrentProgramSceneChanged"
           (when-let* ((event-data (plist-get payload :eventData))
                       (scene-name (plist-get event-data :sceneName)))
             (setq obs-websocket-scene scene-name)
             (obs-websocket-update-mode-line)
             (format "Switched scene to %s" scene-name)))
          ("StreamStateChanged"
           (let* ((event-data (plist-get payload :eventData))
                  (streaming-p (eq (plist-get event-data :outputActive) t))
                  (state (plist-get event-data :outputState)))
             (setq obs-websocket-streaming-p streaming-p)
             (obs-websocket-update-mode-line)
             (pcase state
               ("OBS_WEBSOCKET_OUTPUT_STARTING" "Stream starting...")
               ("OBS_WEBSOCKET_OUTPUT_STARTED" "Started streaming.")
               ("OBS_WEBSOCKET_OUTPUT_STOPPING" "Stream stopping...")
               ("OBS_WEBSOCKET_OUTPUT_STOPPED" "Stopped streaming."))))
          ("RecordStateChanged"
           (let* ((event-data (plist-get payload :eventData))
                  (recording-p (eq (plist-get event-data :outputActive) t))
                  (recording-path (plist-get event-data :outputPath))
                  (state (plist-get event-data :outputState)))
             (setq obs-websocket-recording-p recording-p
                   obs-websocket-recording-filename recording-path)
             (obs-websocket-update-mode-line)
             (pcase state
               ("OBS_WEBSOCKET_OUTPUT_STARTING" "Recording starting...")
               ("OBS_WEBSOCKET_OUTPUT_STARTED" "Started recording.")
               ("OBS_WEBSOCKET_OUTPUT_STOPPING" "Recording stopping...")
               ("OBS_WEBSOCKET_OUTPUT_STOPPED" "Stopped recording."))))
          ("ExitStarted"
           (prog1
               "OBS application exiting..."
             (obs-websocket-disconnect))))))
    (message "OBS: %s" msg)))

(cl-defun obs-websocket--auth-string
    (&key salt challenge password &allow-other-keys)
  "Creates an OBS-expected authentication string from an `:authentication'
plist."
  (cl-flet ((obs-encode (string-1 string-2)
              (base64-encode-string
               (secure-hash 'sha256 (concat string-1 string-2) nil nil t))))
    (obs-encode (obs-encode password salt)
                challenge)))

(defun obs-websocket-authenticate-if-needed (payload)
  "Authenticate if PAYLOAD asks for it."
  (when-let ((auth-data (plist-get payload :authentication)))
    (let* ((password (or obs-websocket-password
                         (read-passwd "OBS websocket password:")))
           (auth (apply #'obs-websocket--auth-string
                        (append auth-data (list :password password)))))
      (when obs-websocket-debug
        (push (list :authenticating auth) obs-websocket-messages))
      (obs-websocket-send-identify auth))))

(defun obs-websocket-on-identified (payload)
  "Handle OBS Identified repsonse."

  ;; Even non-authentication requests will receive this event /
  ;; response. Let's run the initial information requests here.
  (obs-websocket-send-batch
   `(("GetStreamStatus"
      :callback
      ,(lambda (payload)
         (let ((data (plist-get payload :responseData)))
           (setq obs-websocket-streaming-p
                 (eq (plist-get data :outputActive) t))
           (obs-websocket-update-mode-line))))
     ("GetRecordStatus"
      :callback
      ,(lambda (payload)
         (let ((data (plist-get payload :responseData)))
           (setq obs-websocket-recording-p
                 (eq (plist-get data :outputActive) t))
           (obs-websocket-update-mode-line))))
     ("GetSceneList"
      :callback
      ,(lambda (payload)
         (map-let ((:currentProgramSceneName scene)
                   (:scenes scene-list))
             (plist-get payload :responseData)
           (setq obs-websocket-scene scene
                 obs-websocket-scene-list scene-list))
         (obs-websocket-update-mode-line)))))
  (obs-websocket-minor-mode 1))

(defun obs-websocket-log-response (payload)
  (when obs-websocket-debug
    (map-let ((:op op-code)) payload
      (push (list (cl-ecase op-code
                    (0 :hello)
                    (2 :identified)
                    (5 :event)
                    (7 :requestResponse)
                    (9 :batchResponse))
                  payload)
            obs-websocket-messages))))

(defun obs-websocket-on-response (message-data)
  (let ((request-id (plist-get message-data :requestId))
        (request-status (plist-get message-data :requestStatus)))
    (if (eq (plist-get request-status :result) :false)
        (error "OBS: Error code %d -- %s"
               (plist-get request-status :code)
               (plist-get request-status :comment))
      (when-let ((callback (assoc request-id obs-websocket-message-callbacks)))
        (catch 'err
          (funcall (cdr callback) message-data))
        (setf obs-websocket-message-callbacks
              (assoc-delete-all request-id obs-websocket-message-callbacks))))))

(defun obs-websocket-on-batch-response (message-data)
  (map-let ((:results results)) message-data
    (mapc #'obs-websocket-on-response results)))

(defun obs-websocket-marshal-message (payload)
  (let ((opcode (plist-get payload :op))
        (message-data (plist-get payload :d)))
    (cl-check-type opcode (integer 0 *) "positive integer op code expected")
    ;; TODO: replace magic-number opcodes
    (cl-ecase opcode
      (0 (obs-websocket-authenticate-if-needed message-data))
      (2 (obs-websocket-on-identified payload))
      (5 (run-hook-with-args 'obs-websocket-event-functions message-data))
      (7 (obs-websocket-on-response message-data))
      (9 (obs-websocket-on-batch-response message-data)))))

(defun obs-websocket-on-message (websocket frame)
  "Handle OBS WEBSOCKET sending FRAME."
  (when obs-websocket-debug
    (push frame obs-websocket-messages))
  (let* ((payload (json-parse-string (websocket-frame-payload frame)
                                     :object-type 'plist :array-type 'list)))
    (run-hook-with-args 'obs-websocket-on-message-payload-functions payload)))

(defun obs-websocket-on-close (&rest args)
  "Display a message when the connection has closed."
  (setq obs-websocket nil
        obs-websocket-scene nil
        obs-websocket-status "")
  (unless obs-websocket-debug
    (setq obs-websocket-messages nil))
  (obs-websocket-update-mode-line)
  (message "OBS connection closed."))

(defun obs-websocket-format-request (request-type &rest args)
  (let ((request-id (obs-websocket--next-request-id)))
    (when-let ((callback (plist-get args :callback)))
      (add-to-list 'obs-websocket-message-callbacks
                   (cons request-id callback))
      (cl-remf args :callback))

    (append (list :requestType request-type
                  :requestId request-id)
            (when (car args)
              (list :requestData args)))))

(defun obs-websocket-send (request-type &rest args)
  "Send a request of type REQUEST-TYPE."
  (let ((msg (json-encode-plist
              (list :op 6
                    :d (apply #'obs-websocket-format-request
                              request-type args)))))
    (websocket-send-text obs-websocket msg)
    (when obs-websocket-debug (prin1 msg))))

(defun obs-websocket-send-identify (auth-string)
  (let ((msg (json-encode-plist
              (list :op 1
                    :d (list :rpcVersion obs-websocket-rpc-version
                             :authentication auth-string)))))
    (when obs-websocket-debug
      (push (list :identifying msg) obs-websocket-messages))
    (websocket-send-text obs-websocket msg)))

(defun obs-websocket-send-batch (requests)
  "Send a batch of requests from list of REQUESTS"
  (let* ((requests (map-apply (lambda (key vals)
                                (apply #'obs-websocket-format-request key vals))
                              requests))
         (msg (json-encode
               (list :op 8
                     :d (list
                         :requestId (obs-websocket--next-request-id)
                         ;; :haltOnFailure
                         ;; :executionType
                         :requests `[,@requests])))))
    (websocket-send-text obs-websocket msg)
    (when obs-websocket-debug (prin1 msg))))

(defun obs-websocket--image-from-uri-string (base64-uri-string &rest props)
  "Parse a base64 data URI formatted string. Return the Emacs image or NIL."
  (cl-flet ((data-uri-p (uri-string)
              (string-match-p (rx line-start "data:") uri-string)))
    (let ((clean-string (string-trim base64-uri-string))
          (dissect-mime-image-regex (rx line-start
                                        "data:"
                                        (group (one-or-more (not ";")))
                                        ";base64,"
                                        (group (one-or-more not-newline))
                                        line-end)))
      (if (data-uri-p clean-string)
          (save-match-data
            (when (string-match dissect-mime-image-regex clean-string)
              (when-let* ((mime-type (match-string 1 clean-string))
                          (base64-data (match-string 2 clean-string))
                          (image-data (ignore-errors
                                        (base64-decode-string base64-data)))
                          (image--type (image-type-from-data image-data)))
                (apply #'create-image image-data image--type t props))))
        (error "Invalid base64 data: %s" clean-string)))))

(defun obs-websocket--svg-image-from-uri-string (base64-uri-string &rest props)
  "Return a SVG image created from BASE64-URI-STRING."
  (let* ((trimmed-uri (string-trim base64-uri-string))
         (svg (svg-create (or (plist-get props :width) 300)
                          (or (plist-get props :height) 300))))
    (apply #'svg-node svg 'image :xlink:href trimmed-uri props)
    (svg-image svg)))

(cl-defun obs-websocket--display-base64-images
    (data-uri-strings &optional (create-image-funarg #'obs-websocket--svg-image-from-uri-string))
  "Display all base64 data URIs in DATA-URI-STRINGS a-list in a new buffer."
  (condition-case err
      (let* ((buffer-name "*OBS Scene Image*")
             (image-buffer (get-buffer-create buffer-name)))
        (with-current-buffer image-buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (cl-loop for (label . data) in data-uri-strings
                     for image = (funcall create-image-funarg data)
                     do (insert-image image label)
                     do (insert label))
            (read-only-mode 1)
            (image-mode))
          (pop-to-buffer image-buffer)))
    (error (message "Error displaying image: %s" (error-message-string err)))))

(cl-defun obs-websocket-display-source
    (payload &optional (label "source") (image-fn #'obs-websocket--svg-image-from-uri-string))
  "Display the image data from an OBS Websocket response PAYLOAD in a new buffer."
  (when-let ((image-data
              (plist-get (plist-get payload :responseData) :imageData)))
    (obs-websocket--display-base64-images (list (cons label image-data)) image-fn)))

;;;; Commands

(defun obs-websocket-disconnect ()
  "Disconnect from an OBS instance."
  (interactive)
  (when obs-websocket (websocket-close obs-websocket)))

;;;###autoload
(defun obs-websocket-connect (&optional url password)
  "Connect to an OBS instance."
  (interactive (list (or obs-websocket-url (read-string "URL: ")) nil))
  (let ((obs-websocket-password (or password obs-websocket-password)))
    (setq obs-websocket (websocket-open (or url obs-websocket-url)
                                        :on-message #'obs-websocket-on-message
                                        :on-close #'obs-websocket-on-close))))

;;;###autoload
(defun obs-websocket-start-recording ()
  "Start recording."
  (interactive)
  (obs-websocket-send "StartRecord"))

;;;###autoload
(defun obs-websocket-stop-recording ()
  "Stop recording."
  (interactive)
  (obs-websocket-send "StopRecord"))

;;;###autoload
(defun obs-websocket-start-streaming ()
  "Start streaming."
  (interactive)
  (obs-websocket-send "StartStream"))

;;;###autoload
(defun obs-websocket-stop-streaming ()
  "Stop streaming."
  (interactive)
  (obs-websocket-send "StopStream"))

(defun obs-websocket-get-scene-item-list (&optional callback scene-name)
  (obs-websocket-send-batch
   `(("GetSceneItemList"
      :sceneName ,(or scene-name obs-websocket-scene)
      :callback
      ,(lambda (payload)
         (let ((data (plist-get payload :responseData)))
           (setq obs-websocket-scene-item-list (plist-get data :sceneItems))
           (when callback
             (funcall callback obs-websocket-scene-item-list))))))))

(defun obs-websocket-set-scene-item-enabled (scene-item value &optional scene-name)
  "Set SCENE-ITEM to VALUE.
SCENE-ITEM can be a numeric ID or a string name.
Enable if VALUE is non-nil and disable if nil."
  (unless value (setq value json-false))
  (if (numberp scene-item)
      (obs-websocket-send
       "SetSceneItemEnabled"
       :sceneItemId scene-item
       :sceneName (or scene-name obs-websocket-scene)
       :sceneItemEnabled value)
    (let ((found (seq-find (lambda (o) (string= (plist-get o :sourceName) scene-item))
                           obs-websocket-scene-item-list)))
      (if found
          (obs-websocket-send
           "SetSceneItemEnabled"
           :sceneItemId (plist-get found :sceneItemId)
           :sceneName (or scene-name obs-websocket-scene)
           :sceneItemEnabled value)
        (obs-websocket-get-scene-item-list
         (lambda (list)
           (let ((found (seq-find (lambda (o) (string= (plist-get o :sourceName) scene-item))
                                  list)))
             (if found
                 (obs-websocket-send
                  "SetSceneItemEnabled"
                  :sceneItemId (plist-get found :sceneItemId)
                  :sceneName (or scene-name obs-websocket-scene)
                  :sceneItemEnabled value)
               (error "Scene item %s not found." scene-item)))))))))

(provide 'obs-websocket)
;;; obs-websocket.el ends here
