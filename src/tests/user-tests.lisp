(in-package :potato-tests)

(declaim (optimize (speed 0) (safety 3) (debug 3)))

(define-test user-register-test (:contexts #'all-context :tags '(couchdb))
  (let ((email "palle@bar.com")
        (description "Palle Bar")
        (password "foo"))
    (let ((user (make-and-save-unregistered-user email description password)))
      (assert-false (null user))
      (let ((loaded (potato.core::load-user-by-email email)))
        (assert-equal email (potato.core::user/primary-email loaded))
        (assert-equal description (potato.core::user/description loaded))
        (assert-true (potato.core::user/match-password loaded password))
        (assert-false (potato.core::user/activated-p loaded))
        ;; Test activation
        (let ((activate-code (potato.core::user/activate-code loaded)))
          (assert-true (and activate-code (string/= activate-code "")))
          (potato.core::activate-user loaded)
          (let ((active (potato.core::load-user-by-email email)))
            (assert-true (potato.core::user/activated-p active))
            (assert-equal "" (potato.core::user/activate-code active))))))))

(define-test user-image-test (:contexts #'user-context :tags '(couchdb))
  (let ((image-data (make-array 1000 :element-type '(unsigned-byte 8) :initial-element 122)))
    (labels ((load-and-test ()
               (let* ((loaded-image (potato.user-image:user-load-image (potato.core::current-user))))
                 (assert-true (compare-arrays image-data loaded-image)))))
      (potato.user-image:user-save-image (potato.core::current-user) image-data)
      (cl-memcached:mc-flush-all)
      (load-and-test)
      ;; Run again to make sure the cached version is compared properly
      (load-and-test))))

(defun load-image-name-for-user-id (user-id)
  (let ((user (potato.core:load-user user-id)))
    (potato.core:user/image-name user)))

(define-test user-image-update-test (:contexts #'user-context :tags '(couchdb))
  (let ((email "bar@abc.com"))
    (let* ((user (make-and-save-activated-user email "Bar user"))
           (user-id (potato.core::user/id user)))
      (let ((image-data (make-array 1000 :element-type '(unsigned-byte 8) :initial-element 123)))
        (potato.user-image:user-save-image user image-data)
        (let* ((content (potato.user-image:user-load-image user-id))
               (name (load-image-name-for-user-id user-id)))
          (assert-true (compare-arrays image-data content))
          (assert-true (and (stringp name) (plusp (length name))))
          (let ((loaded-user (potato.core::load-user-by-email email))
                (updated-image-data (make-array 2100 :element-type '(unsigned-byte 8) :initial-element 124)))
            (potato.user-image:user-save-image loaded-user updated-image-data)
            (let* ((updated-image-results (potato.user-image:user-load-image user-id))
                   (updated-name (load-image-name-for-user-id user-id)))
              (assert-true (compare-arrays updated-image-data updated-image-results))
              (assert-true (and (stringp updated-name) (plusp (length updated-name))))
              (assert-false (equal name updated-name))
              ;; Functions called when downloading an image
              (let* ((user (potato.core:load-user user-id))
                     (cached-image-content (potato.user-image:user-load-image user))
                     (cached-image-name (potato.core:user/image-name user)))
                (assert-equal updated-name cached-image-name)
                (assert-true (compare-arrays updated-image-data cached-image-content))))))))))