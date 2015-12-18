(in-package :potato.api)

(declaim #.potato.common::*compile-decl*)

(alexandria:define-constant +api-url-prefix+ "/api/1.0" :test #'equal)

(potato.core:define-handler-fn-login (request-api-token-screen "/request_api_token" nil ())
  (potato.core:with-authenticated-user ()
    (let ((user (potato.core:current-user)))
      (potato.core::generate-and-modify-api-token user)
      (potato.core:save-user user))
    (hunchentoot:redirect "/settings")))

(define-condition api-error (error)
  ((message      :type string
                 :initarg :message
                 :initform "Unknown error"
                 :reader api-error/message)
   (code         :type integer
                 :initarg :code
                 :initform 500
                 :reader api-error/code)
   (extra-fields :type list
                 :initarg :extra-fields
                 :initform nil
                 :reader api-error/extra-fields))
  (:report (lambda (condition stream)
             (format stream "API error: ~a. Code: ~a" (api-error/message condition) (api-error/code condition)))))

(defmethod print-object ((obj api-error) stream)
  (print-unreadable-safely (message code) obj stream
    (format stream "MESSAGE ~s CODE ~a" message code)))

(defun raise-api-error (message &optional (code 500) extra-fields)
  (log:trace "Raising API error. message=~s, code=~s, extra-fields=~s" message code extra-fields)
  (error 'api-error :message message :code code :extra-fields extra-fields))

(defun load-user-from-api-token (req-token)
  (unless req-token
    (raise-api-error "No API token specified" hunchentoot:+http-authorization-required+))
  (let ((parts (split-sequence:split-sequence #\- req-token)))
    (unless (= (length parts) 2)
      (raise-api-error "Illegal API token format" hunchentoot:+http-forbidden+))
    (let ((user (potato.core:load-user (decode-name (first parts)) :error-if-not-found nil)))
      (cond ((not (and user
                       (potato.core:user/api-token user)
                       (string= (potato.core:user/api-token user) req-token)))
             (raise-api-error "Access denied" hunchentoot:+http-forbidden+))
            ((not (potato.core:user/activated-p user))
             (raise-api-error "User not actvated" hunchentoot:+http-forbidden+ (list "details" "not_activated"))))
      user)))

(defun verify-api-token-and-run (url fn)
  (handler-case
      (let ((potato.core::*current-auth-user* (load-user-from-api-token (hunchentoot:header-in* "api-token"))))
        (funcall fn))
    ;; Error handlers
    (api-error (condition)
      (log:debug "API error when calling ~a: ~a" url condition)
      (setf (hunchentoot:return-code*) (api-error/code condition))
      (apply #'st-json:jso
             "error" :true
             "message" (api-error/message condition)
             (api-error/extra-fields condition)))
    (potato.core:permission-error (condition)
      (log:debug "Permission error when calling ~a: ~a" url condition)
      (setf (hunchentoot:return-code*) hunchentoot:+http-forbidden+)
      (st-json:jso "error" :true
                   "error_type" "permission"
                   "message" (potato.core:potato-error/message condition)))))

(lofn:define-handler-fn (login-api-key-screesn "/login_api_key" nil ())
  (lofn:with-parameters ((key "api-key")
                         (redirect "redirect"))
    (let ((user (load-user-from-api-token key)))
      (potato.core::update-user-session user)
      (hunchentoot:redirect (or redirect "/")))))

(defmacro api-case-method (&body cases)
  (destructuring-bind (new-cases has-default-p)
      (loop
         with found = nil
         for c in cases
         unless (and (listp c)
                     (>= (length c) 2))
         do (error "Incorrectly formatted clause: ~s" c)
         when (eq (car c) t)
         do (setq found t)
         collect c into result-list
         finally (return (list result-list found)))
    (let ((method-sym (gensym)))
      `(let ((,method-sym (hunchentoot:request-method*)))
         (case ,method-sym
           ,@new-cases
           ,@(unless has-default-p
                     (list `(t (raise-api-error (format nil "Illegal request method: ~a"
                                                        (symbol-name ,method-sym))
                                                hunchentoot:+http-method-not-allowed+)))))))))

(defmacro define-api-method ((name url regexp (&rest bind-vars)) &body body)
  `(lofn:define-handler-fn (,name ,(concatenate 'string +api-url-prefix+ url) ,regexp ,bind-vars)
     (log:trace "Call to API method ~s, URL: ~s" ',name (hunchentoot:request-uri*))
     (let ((result (verify-api-token-and-run ',name #'(lambda () ,@body))))
       (lofn:with-hunchentoot-stream (out "application/json")       
         (st-json:write-json result out)
         ;; Write a final newline to made the output a bit easier to
         ;; read when using tools such as curl
         (format out "~c" #\Newline)))))

#+nil(defun api-get-channels-for-group (group-id &optional show-subscriptions-p subscribed-channels)
  (let ((result (clouchdb:invoke-view "channel" "channels_for_group" :key group-id)))
    (mapcar #'(lambda (v)
                (let ((id (getfield :|id| v)))
                  (apply #'st-json:jso
                         "id" id
                         "name" (getfield :|name| (getfield :|value| v))
                         (if show-subscriptions-p (list "joined" (if (member id subscribed-channels :test #'equal)
                                                                     "true"
                                                                     "false"))))))
            (getfield :|rows| result))))

(defun api-load-channels-for-group (group)
  (loop
     for channel in (potato.core:find-channels-for-group group)
     collect (st-json:jso "id" (potato.core:channel/id channel)
                          "name" (potato.core:channel/name channel))))


(defun api-load-domain-info (domain-id include-groups-p include-channels-p)
  (let* ((domain (potato.core:load-domain-with-check domain-id (potato.core:current-user)))
         (id (potato.core:domain/id domain)))
    (apply #'st-json:jso
           "id" id
           "name" (potato.core:domain/name domain)
           "type" (symbol-name (potato.core:domain/domain-type domain))
           (if (or include-groups-p include-channels-p)
               (list "groups" (mapcar (lambda (group)
                                        (apply #'st-json:jso
                                               "id" (potato.core:group/id group)
                                               "name" (potato.core:group/name group)
                                               "type" (symbol-name (potato.core:group/type group))
                                               (if (and include-channels-p
                                                        (potato.core:user-role-for-group group (potato.core:current-user)))
                                                   (list "channels" (api-load-channels-for-group group)))))
                                      (potato.core:find-groups-in-domain id)))))))

(defun parse-and-check-input-as-json ()
  (let ((json-text (hunchentoot:raw-post-data :force-text t)))
    (when (null json-text)
      (raise-api-error "Empty input" hunchentoot:+http-not-acceptable+))
    (let ((data (st-json:read-json-from-string json-text)))
      data)))

(defun check-message-length (length)
  (when (> length potato.core:*max-message-size*)
    (raise-api-error "Message is too large" hunchentoot:+http-request-entity-too-large+)))

(define-api-method (api-version-screen "/version" nil ())
  (api-case-method
    (:get (st-json:jso "version" "1"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Domain API calls
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-api-method (api-joined-domains-screen "/domains" nil ())
  (api-case-method
    (:get (let ((d (potato.core:load-domains-for-user (potato.core:current-user))))
            (mapcar (lambda (v) (st-json:jso "id" (first v) "name" (second v) "type" (symbol-name (third v)))) d)))))

(define-api-method (api-domain-screen "/domains/([^/]+)" t (domain-id))
  (api-case-method
    (:get (lofn:with-checked-parameters ((include-groups :type :boolean)
                                         (include-channels :type :boolean))
            (api-load-domain-info domain-id include-groups include-channels)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Message API calls
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun check-message-modification-allowed (user channel message)
  (unless (or (equal (potato.core:user/id user) (potato.core:message/from message))
              (potato.core:user-is-admin-in-group-p (potato.core:channel/group channel) user))
    (raise-api-error "Permission denied" hunchentoot:+http-forbidden+)))

(define-api-method (api-update-message-screen "/message/([a-zA-Z0-9:_.-]+)" t (message-id))
  (let* ((user (potato.core:current-user))
         (message (potato.core:load-message message-id))
         (channel (potato.core:load-channel-with-check (potato.core:message/channel message) :if-not-joined :load)))
    (api-case-method
      (:put (progn
              (check-message-modification-allowed user channel message)
              (let* ((data (parse-and-check-input-as-json))
                     (text (st-json:getjso "text" data)))
                (check-message-length (length text))
                (potato.core:save-message-modification message user text nil nil nil)
                (st-json:jso "result" "ok"
                             "id" (potato.core:message/id message)))))
      (:delete (progn
                 (log:trace "Attempting to delete message: ~s" message-id)
                 (check-message-modification-allowed user channel message)
                 (potato.core:save-message-modification message user "Deleted" nil nil t)
                 (st-json:jso "result" "ok"
                              "id" (potato.core:message/id message))))
      (:get (let* ((accept (hunchentoot:header-in* "accept"))
                   (mode (if (progn (log:info "accept=~s" accept) accept)
                             (string-case:string-case (accept)
                                                      ("text/plain" :text)
                                                      ("text/html" :html)
                                                      ("application/json" :alist)
                                                      (t :text))
                             :text)))
              (potato.core:message-detailed->json message mode (potato.core:current-user)))))))

(define-api-method (api-message-history-screen "/channel/([a-z0-9]+)/history" t (channel-id))
  (let ((channel (potato.core:load-channel-with-check channel-id :if-not-joined :load)))
    (api-case-method
      (:get (lofn:with-parameters (from num format)
              (let ((translate-function (make-translation-function format)))
                (multiple-value-bind (messages total-rows offset)
                    (potato.core:load-message-log channel
                                                  (if num (min (parse-integer num) 1000) 10)
                                                  (if (or (null from) (equal from "now")) nil from))
                  (st-json:jso "messages" (mapcar (lambda (v) (funcall translate-function v)) messages)
                               "total" total-rows
                               "offset" offset))))))))

(define-api-method (api-channel-users-screen "/channel/([a-z0-9]+)/users" t (channel-id))
  (api-case-method
    (:get (let* ((channel (potato.core:load-channel-with-check channel-id))
                 (result (potato.core:user-descriptions-for-channel-members channel)))
            (st-json:jso "members" (mapcar #'(lambda (v)
                                               (destructuring-bind (id description user-image)
                                                   v
                                                 (st-json:jso "id" id
                                                              "description" description
                                                              "image_name" user-image)))
                                           result))))))

(define-api-method (api-message-screen "/channel/([a-z0-9]+)/create" t (channel-id))
  (api-case-method
    (:post (let* ((data (parse-and-check-input-as-json))
                  (channel (potato.core:load-channel-with-check channel-id))
                  (text (st-json:getjso "text" data)))
             (check-message-length (length text))
             (let ((result (potato.workflow:send-message-to-channel (potato.core:current-user) channel text)))
               (st-json:jso "result" "ok"
                            "id" (getfield :|id| result)))))))

(define-api-method (api-channels-screen "/channels" nil ())
  (api-case-method
    (:get (loop
             for domain-user in (potato.core:load-domains-for-user (potato.core:current-user))
             for domain = (potato.db:load-instance 'potato.core:domain (potato.core:domain-user/domain domain-user))
             collect (st-json:jso "id" (potato.core:domain/id domain)
                                  "name" (potato.core:domain/name domain)
                                  "groups" (loop
                                              for group in (potato.core:find-groups-in-domain domain)
                                              when (potato.core:user-role-for-group group (potato.core:current-user))
                                              collect (st-json:jso "id" (potato.core:group/id group)
                                                                   "name" (potato.core:group/name group)
                                                                   "channels" (api-load-channels-for-group group))))))))

#+needs-rewrite(define-api-method (api-channels-joined-screen "/channels/joined" nil ())
  (api-case-method
    (:get (map-channels-for-user (current-user) #'(lambda (v)
                                                    (st-json:jso "id" (channel/id v)
                                                                 "name" (channel/name v)))))))

#+nil(define-api-method (api-channel-users-screen "/channels/([a-z0-9]+)/users" t (channel-id))
  (let ((channel (potato.core:load-channel-with-check channel-id)))
    (api-case-method
      (:get (mapcar #'(lambda (v)
                        (st-json:jso "id" (first v)
                                     "name" (second v)))
                    (potato.core:users-in-channel channel))))))

#+nil(define-api-method (api-channel-users-user-screen "/channels/([a-z0-9]+)/users/([^/]+)" t (channel-id user-id))
  (let ((channel (potato.core:load-channel-with-check channel-id)))
    (labels ((check-channel-permission ()
               (unless (or (equal (potato.core:user/id (potato.core:current-user)) user-id)
                           (and (potato.core:user-is-admin-in-group-p (potato.core:channel/group channel)
                                                                      (potato.core:current-user))
                                (potato.core:user-role-for-group (potato.core:channel/group channel) user-id)))
                 (error 'permission-error :message "Not permitted to control user"))))

      (api-case-method
        (:get (alexandria:if-let ((result (potato.core:user-is-in-channel-p channel user-id)))
                (st-json:jso "id" (getfield :|user| result)
                             "name" (getfield :|user_name| result))
                (raise-api-error "User is not in channel" hunchentoot:+http-not-found+
                                 (list "user_id" user-id))))
        (:put (progn
                (check-channel-permission)
                (potato.core::add-user-to-channel channel user-id)
                (setf (hunchentoot:return-code*) hunchentoot:+http-created+)
                (st-json:jso "result" "ok")))
        (:delete (progn
                   (check-channel-permission)
                   (potato.core:remove-user-from-channel channel user-id)
                   (setf (hunchentoot:return-code*) hunchentoot:+http-accepted+)
                   (st-json:jso "result" "ok")))))))

#+nil(defun api-format-group-as-json (group)
  (st-json:jso "id" (potato.core:group/id group)
               "name" (potato.core:group/name group)
               "users" (mapcar #'(lambda (row)
                                   (st-json:jso "user_id" (getfield :|user_id| row)
                                                "role" (getfield :|role| row)))
                               (potato.core:group/users group))))

#+needs-rewrite(define-api-method (api-groups-screen "/groups" nil ())
  (api-case-method
    (:get (mapcar #'(lambda (v)
                      (let ((group (potato.db:load-instance 'group (getfield :id v))))
                        (api-format-group-as-json group)))
                  (groups-for-user-as-template-data (current-user))))))

#+needs-rewrite(define-api-method (api-group-details-screen "/groups/([a-z0-9]+)" t (group-id))
  (let ((group (load-group-with-check group-id)))
    (api-case-method
      (:get (api-format-group-as-json group)))))

#+needs-rewrite(define-api-method (api-group-channels-screen "/groups/([a-z0-9]+)/channels" t (group-id))
  (let ((group (potato.core:load-group-with-check group-id)))
    (api-case-method
      (:get (api-get-channels-for-group (potato.core:group/id group))))))

(defun make-translation-function (format-name)
  (if format-name
      (string-case:string-case (format-name)
        ("html" #'potato.core:notification-message-cd->json-html)
        ("json" #'potato.core:notification-message-cd->json-alist)
        ("text" #'potato.core:notification-message-cd->json-text)
        (t (raise-api-error "Illegal format: ~a" format-name)))
      #'potato.core:notification-message-cd->json-html))

(defun api-get-single-update (channels event-id format-name services)
  #+nil(:content-p t :user-state-p t :user-notifications-p t :unread-p t :channel-updates-p t)
  (potato.rabbitmq-notifications:process-long-poll channels event-id services
                                                   (make-translation-function format-name)
                                                   (lambda (queue notifications)
                                                     (st-json:jso "event" queue
                                                                  "data" notifications))))

(defun parse-service-names (service-names)
  (let ((services (loop
                     for part in (split-sequence:split-sequence #\, service-names)
                     append (string-case:string-case (part)
                              ("content" '(:content-p t))
                              ("state" '(:user-state-p t))
                              ("notifications" '(:user-notifications-p t))
                              ("unread" '(:unread-p t))
                              ("channel" '(:channel-updates-p t))
                              (t (raise-api-error (format nil "Illegal service name: '~a'" part)
                                                  hunchentoot:+http-bad-request+))))))
    (unless services
      (raise-api-error "Must specify at least one service type" hunchentoot:+http-bad-request+))
    services))

(define-api-method (api-channel-updates-screen "/channel/([^/]+)/updates" t (cid))
  (lofn:with-checked-parameters ((event-id :name "event-id" :required nil)
                                 (format-name :name "format" :required nil)
                                 (service-names :name "services" :required nil))
    (let ((channel (potato.core:load-channel-with-check cid  :if-not-joined :join))
          (services (if service-names
                        (parse-service-names service-names)
                        '(:content-p t))))
      (api-case-method
        (:get (api-get-single-update (list channel) event-id format-name services))))))

(define-api-method (api-channel-updates2-screen "/channel-updates" nil ())
  (lofn:with-checked-parameters ((event-id :name "event-id" :required nil)
                                 (channel-names :name "channels" :required nil)
                                 (format-name :name "format" :required nil)
                                 (service-names :name "services" :required nil))
    (let* ((services (if service-names
                         (parse-service-names service-names)
                         '(:content-p t)))
           (cids (split-sequence:split-sequence #\, channel-names))
           (channels (mapcar (lambda (cid)
                               (potato.core:load-channel-with-check cid :if-not-joined :join))
                             cids)))
      (api-case-method
        (:get (api-get-single-update channels event-id format-name services))))))

#+nil(define-api-method (api-channel-updates-screen "/channel/([^/]+)/updates" t (channel-id))
  (api-case-method
    (:get (potato.core:start-html5-notifications-for-channel channel-id))))

#+nil
(define-api-method (api-channel-updates-screen "/channel/([^/]+)/updates" t (channel-id))
  (api-case-method
    (:get
     (lofn:with-checked-parameters ((event-id :name "event-id" :required nil)
                                    (format-name :name "format" :required nil)
                                    (initial-results :name "num-objects" :required nil :type :integer))
       (let* ((channel (potato.core:load-channel-with-check channel-id))
              (src (potato.core:find-channel-source (potato.core:channel/id channel) :create t))
              (sources (list (list src
                                   :translation-function (make-translation-function format-name)
                                   :num-objects (or initial-results 0))))
              (result (html5-notification:get-single-update event-id sources)))
         (st-json:jso "event" (first result)
                      "data" (second result)))))))

#+nil
(define-api-method (api-channel-updates2-screen "/channel/([^/]+)/updates2" t (channel-id))
  (lofn:with-parameters ((event-id "event")
                         (format-name "format"))
                        (let ((translate-function (make-translation-function format-name)))
                          (log:trace "updates requested for channel=~s, event-id=~s format=~s" channel-id event-id format-name)
                          (api-case-method
                            (:get (potato.core:poll-for-updates-and-return-from-request event-id (list channel-id) (potato.core:current-user)
                                                                                        :json-translate-function translate-function))))))

;;;
;;;  Disabled until the new rabbitmq notifications is complete
;;;
#+nil
(define-api-method (api-channel-updates3-screen "/channel/updates3" nil ())
  (lofn:with-parameters ((event-id "event")
                         (format-name "format")
                         (channels "channels")
                         (initial-results "num_results"))
    (let ((channel-list (split-sequence:split-sequence ":" channels)))
      (log:trace "multiple-channel updates requested. event-id=~s, format-name=~s, channels=~s, initial-results=~s"
                 event-id format-name channels initial-results)
      (api-case-method
        (:get (potato.core:poll-for-updates-and-return-from-request event-id channel-list (potato.core:current-user)
                                                                    :initial-results (if initial-results
                                                                                         (parse-integer initial-results)
                                                                                         0)
                                                                    :translation-function (make-translation-function format-name)))))))