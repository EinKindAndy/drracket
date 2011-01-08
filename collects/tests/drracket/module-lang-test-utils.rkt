#lang scheme/gui
(require "drracket-test-util.rkt" mzlib/etc framework scheme/string)

(provide test t rx run-test in-here write-test-modules)

;; utilities to use with scribble/reader
(define t string-append)
(define (rx . strs)
  (regexp (regexp-replace* #rx" *\n *" (string-append* strs) ".*")))

(define-struct test (definitions   ; string
                     interactions  ; (union #f string)
                     result        ; string
                     all?          ; boolean (#t => compare all of the text between the 3rd and n-1-st line)
                     error-ranges  ; (or/c 'dont-test
                                   ;       (-> (is-a?/c text)
                                   ;           (is-a?/c text)
                                   ;           (or/c #f (listof ...))))
                                   ;    fn => called with defs & ints, result must match get-error-ranges method's result
                      line)        ; number or #f: the line number of the test case
                      
  #:omit-define-syntaxes)

(define in-here
  (let ([here (this-expression-source-directory)])
    (lambda (file) (format "~s" (path->string (build-path (find-system-path 'temp-dir) file))))))

(define tests '())
(define-syntax (test stx)
  (syntax-case stx ()
    [(_  args ...)
     (with-syntax ([line (syntax-line stx)])
       #'(test/proc line args ...))]))
(define (test/proc line definitions interactions results [all? #f] #:error-ranges [error-ranges 'dont-test])
  (set! tests (cons (make-test (if (string? definitions) 
                                   definitions 
                                   (format "~s" definitions))
                               interactions 
                               results 
                               all? 
                               error-ranges
                               line)
                    tests)))

(define temp-files '())
(define init-temp-files void)

(define (write-test-modules* name code)
  (set! init-temp-files
        (let ([old init-temp-files])
          (λ ()
            (let ([file (build-path (find-system-path 'temp-dir) (format "~a.rkt" name))])
              (set! temp-files (cons file temp-files))
              (with-output-to-file file #:exists 'truncate
                (lambda () (printf "~s\n" code))))
            (old)))))

(define-syntax write-test-modules
  (syntax-rules (module)
    [(_ (module name lang x ...) ...)
     (begin (write-test-modules* 'name '(module name lang x ...)) ...)]))

(define (single-test test)
  (let/ec k
    (clear-definitions drs)
    (insert-in-definitions drs (test-definitions test))
    (do-execute drs)

    (let ([ints (test-interactions test)])

      (when ints
        (let ([after-execute-output
               (queue-callback/res
                (λ ()
                  (send interactions-text
                        get-text
                        (send interactions-text paragraph-start-position 2)
                        (send interactions-text paragraph-end-position 2))))])
          (unless (or (test-all? test) (string=? "> " after-execute-output))
            (fprintf (current-error-port)
                     "FAILED (line ~a): ~a\n        ~a\n        expected no output after execution, got: ~s\n"
                    (test-line test)
                    (test-definitions test)
                    (or (test-interactions test) 'no-interactions)
                    after-execute-output)
            (k (void)))
          (type-in-interactions drs ints)
          (test:keystroke #\return)
          (wait-for-computation drs)))

      (let* ([text
              (queue-callback/res
               (λ ()
                 (if (test-all? test)
                     (let* ([para (- (send interactions-text position-paragraph
                                           (send interactions-text last-position))
                                     1)])
                       (send interactions-text
                             get-text
                             (send interactions-text paragraph-start-position 2)
                             (send interactions-text paragraph-end-position para)))
                     (let* ([para (- (send interactions-text position-paragraph
                                           (send interactions-text last-position))
                                     1)])
                       (send interactions-text
                             get-text
                             (send interactions-text paragraph-start-position para)
                             (send interactions-text paragraph-end-position para))))))]
             [output-passed? (let ([r (test-result test)])
                               ((cond [(string? r) string=?]
                                      [(regexp? r) regexp-match?]
                                      [else 'module-lang-test "bad test value: ~e" r])
                                r text))])
        (unless output-passed?
          (fprintf (current-error-port)
                   "FAILED (line ~a): ~a\n        ~a\n  expected: ~s\n       got: ~s\n"
                   (test-line test)
                   (test-definitions test)
                   (or (test-interactions test) 'no-interactions)
                   (test-result test)
                   text))
        (cond
          [(eq? (test-error-ranges test) 'dont-test)
           (void)]
          [else
           (let ([error-ranges-expected
                  ((test-error-ranges test) definitions-text interactions-text)])
             (unless (equal? error-ranges-expected (send interactions-text get-error-ranges))
               (fprintf (current-error-port)
                        "FAILED (line ~a; ranges): ~a\n  expected: ~s\n       got: ~s\n"
                        (test-line test)
                        (test-definitions test)
                        error-ranges-expected
                        (send interactions-text get-error-ranges))))])))))

(define drs 'not-yet-drs-frame)
(define interactions-text 'not-yet-interactions-text)
(define definitions-text 'not-yet-definitions-text)

(define (run-test)
  (set! drs (wait-for-drscheme-frame))
  (set! interactions-text  (send drs get-interactions-text))
  (set! definitions-text (send drs get-definitions-text))
  (init-temp-files)
  
  (run-use-compiled-file-paths-tests)
  
  (set-module-language! #f)
  (test:set-radio-box-item! "Debugging")
  (let ([f (queue-callback/res (λ () (get-top-level-focus-window)))])
    (test:button-push "OK")
    (wait-for-new-frame f))

  (for-each single-test (reverse tests))
  (clear-definitions drs)
  (queue-callback/res (λ () (send (send drs get-definitions-text) set-modified #f)))
  (for ([file temp-files]) 
    (when (file-exists? file)
      (delete-file file))))

(define (run-use-compiled-file-paths-tests)
  
  (define (setup-dialog/run proc)
    (set-module-language! #f)
    (proc)
    (let ([f (get-top-level-focus-window)])
      (test:button-push "OK")
      (wait-for-new-frame f))
    (do-execute drs)
    (fetch-output drs))
    
  (define (run-one-test radio-box expected [no-check-expected #f])
    (let ([got (setup-dialog/run (λ () (test:set-radio-box-item! radio-box)))])
      (unless (spaces-equal? got (format "~s" expected))
        (error 'r-u-c-f-p-t "got ~s expected ~s"
               got
               (format "~s" expected))))
    
    (when no-check-expected
      (let ([got (setup-dialog/run 
                  (λ () 
                    (test:set-radio-box-item! radio-box)
                    (test:set-check-box! "Populate compiled/ directories (for faster loading)" #f)))])
        (unless (equal? got (format "~s" no-check-expected))
          (error 'r-u-c-f-p-t.2 "got ~s expected ~s"
                 got
                 (format "~s" no-check-expected))))))

  (define (spaces-equal? a b)
    (equal? (regexp-replace* #rx"[\n\t ]+" a " ")
            (regexp-replace* #rx"[\n\t ]+" b " ")))
  
  (define drs/compiled/et (build-path "compiled" "drracket" "errortrace"))
  (define drs/compiled (build-path "compiled" "drracket"))
  (define compiled/et (build-path "compiled" "errortrace"))
  (define compiled (build-path "compiled"))
  
  (clear-definitions drs)
  (insert-in-definitions drs "#lang scheme\n(use-compiled-file-paths)")
  (run-one-test "No debugging or profiling" (list drs/compiled compiled) (list compiled))
  (run-one-test "Debugging" (list drs/compiled/et compiled/et compiled) (list compiled/et compiled))
  (run-one-test "Debugging and profiling" (list compiled))
  (run-one-test "Syntactic test suite coverage" (list compiled)))