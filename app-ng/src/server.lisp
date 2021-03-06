;;;; app-ng/src/server.lisp
;;;;
;;;; Author: Robert Smith
;;;;         appleby

(in-package #:qvm-app-ng)

(alexandria:define-constant +default-server-address+ "0.0.0.0"
  :test #'string=
  :documentation "The default host address on which the HTTP server will listen.")

(alexandria:define-constant +default-server-port+ 5222
  :documentation "The default port on which the HTTP server will listen.")

(defclass rpc-acceptor (tbnl:easy-acceptor)
  ()
  (:default-initargs
   :address (error "Host address must be specified.")
   :document-root nil
   :error-template-directory nil
   :persistent-connections-p t))

(defvar *rpc-acceptor* nil
  "*RPC-ACCEPTOR* holds a reference to the RPC-ACCEPTOR instance created by the last invocation of START-SERVER.")

(defun start-server-mode (&key (host +default-server-address+) (port +default-server-port+))
  "Start the HTTP server on the indicated HOST and PORT. Does not return."
  (check-type host string)
  ;; A PORT of 0 tells hunchentoot to pick a random port.
  (check-type port (integer 0 65535) "The port must be between 0 and 65535.")
  (format-log "Starting server on ~A:~D." host port)
  (start-server host port)
  (loop (sleep 60)))

(defun start-server (host port &optional debug)
  "Start the HTTP server on the indicated HOST and PORT.

If the optional DEBUG is non-NIL, show additional debug info and enter the debugger on error.

Returns the newly created and running RPC-ACCEPTOR, which is also saved in *RPC-ACCEPTOR* for REPL-debugging convenience."
  (setf tbnl:*log-lisp-backtraces-p* debug
        tbnl:*log-lisp-errors-p* debug
        tbnl:*show-lisp-errors-p* debug
        tbnl:*show-lisp-backtraces-p* debug
        tbnl:*catch-errors-p* (not debug))
  (setf *rpc-acceptor* (make-instance
                        'rpc-acceptor
                        :address host
                        :port port
                        :taskmaster (make-instance 'tbnl:one-thread-per-connection-taskmaster)))
  (pushnew #'dispatch-rpc-handlers tbnl:*dispatch-table*)
  (tbnl:reset-session-secret)
  (tbnl:start *rpc-acceptor*))

(defun stop-server (&optional (acceptor *rpc-acceptor*))
  (tbnl:stop acceptor))

(defun session-info ()
  "Return a string describing the server session info."
  (if (or (not (boundp 'tbnl:*session*))
          (null tbnl:*session*))
      ""
      (format nil
              "[~A Session:~D] "
              (tbnl:session-remote-addr tbnl:*session*)
              (tbnl:session-id tbnl:*session*))))

(defun error-response (the-error)
  "Return a JSON string representing a qvm_error response for THE-ERROR."
  (http-response
   ;; The format of this JSON response is chosen to maintain backwards compatibility with the
   ;; previous qvm-app.
   (make-json-response (list "error_type" "qvm_error"
                             "status" (princ-to-string the-error))
                       :status (or (and (typep the-error 'rpc-error)
                                        (rpc-error-http-status the-error))
                                   +http-internal-server-error+)
                       :encoder #'yason:encode-plist)))

(defun http-response (response)
  "Encode and return RESPONSE as a STRING and set the HTTP return code and content-type header appropriately."
  (when (boundp 'tbnl:*reply*)
    (setf (tbnl:return-code*) (response-status response))
    (setf (tbnl:content-type*) (response-content-type response)))
  (with-output-to-string (s)
    (encode-response response s)))

(defvar *request-json*)
(setf (documentation '*request-json* 'variable)
      "The parsed JSON request body while in the context of a request. Guaranteed to be HASH-TABLE when bound. Use the function JSON-PARAMETER to access parameter values.")

(defun json-parameter (parameter-name &optional (request-json *request-json*))
  "Return the value for PARAMETER-NAME in the REQUEST-JSON table.

REQUEST-JSON defaults to the JSON object parsed from the request body in *REQUEST-JSON*.

This function is analgous to hunchentoot's TBNL:GET-PARAMETER and and TBNL:POST-PARAMETER."
  (gethash parameter-name request-json))

(defun parse-json-or-lose (request-body)
  (let ((json (ignore-errors
               (let ((*read-default-float-format* 'double-float))
                 (yason:parse request-body)))))
    (unless (hash-table-p json)
      (rpc-bad-request-error "Failed to parse JSON object from request body: ~S" request-body))
    json))

(defmethod tbnl:acceptor-dispatch-request ((acceptor rpc-acceptor) request)
  (handler-case
      (let ((*request-json* (parse-json-or-lose (tbnl:raw-post-data :request request :force-text t))))
        (http-response (call-next-method)))
    (rpc-error (c)
      (tbnl:abort-request-handler (error-response c)))))

(defmethod tbnl:acceptor-status-message ((acceptor rpc-acceptor) http-status-code &key error &allow-other-keys)
  (if (eql http-status-code +http-internal-server-error+)
      (error-response (make-condition 'rpc-error :format-control "~A"
                                                 :format-arguments (list error)))
      (call-next-method)))

(defmethod tbnl:acceptor-log-access ((acceptor rpc-acceptor) &key return-code)
  (with-locked-log ()
    (cl-syslog:format-log *logger* ':info
                          "~:[-~@[ (~A)~]~;~:*~A~@[ (~A)~]~] ~:[-~;~:*~A~] [~A] \"~A ~A~@[?~A~] ~
                          ~A\" ~D ~:[-~;~:*~D~] \"~:[-~;~:*~A~]\" \"~:[-~;~:*~A~]\" ~S~%"
                          (tbnl::remote-addr*)
                          (tbnl::header-in* :x-forwarded-for)
                          (tbnl::authorization)
                          (tbnl::iso-time)
                          (tbnl::request-method*)
                          (tbnl::script-name*)
                          (tbnl::query-string*)
                          (tbnl::server-protocol*)
                          return-code
                          (tbnl::content-length*)
                          (tbnl::referer)
                          (tbnl::user-agent)
                          (tbnl:raw-post-data :request tbnl:*request* :force-text t))))

(defmethod tbnl:acceptor-log-message ((acceptor rpc-acceptor) log-level format-string &rest format-arguments)
  (with-locked-log ()
    (cl-syslog:format-log *logger* ':err
                          "[~A~@[ [~A]~]] ~?~%"
                          (tbnl::iso-time) log-level
                          format-string format-arguments)))
