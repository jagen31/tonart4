#lang racket/base

;; Run a batch of LilyPond engravings in parallel.
;;
;; Engraving is the slow part of realizing a program, and every score is an
;; independent lilypond process -- so instead of running them one at a time,
;; write all the `.ly` files, launch lilypond on them concurrently (capped so
;; we don't spawn dozens at once), and wait for the batch.  Returns each
;; job's `.cropped.png` path, in order.
;;
;; jobs : (listof (list src-string dir-string name-string))

(require racket/system
         racket/file
         racket/list
         racket/port
         (only-in racket/future processor-count))

(provide engrave-all-cropped)

(define (cpu-cap)
  (max 2 (min 12 (processor-count))))

(define (engrave-all-cropped jobs [k (cpu-cap)])
  ;; Classify each job.  A job is a CACHE HIT when its `.ly` is already on disk
  ;; byte-identical to what we would write AND its `.cropped.png` exists -- then
  ;; LilyPond need not run.  This is what keeps drilling into nested programs
  ;; from re-engraving the same unchanged scores over and over: only a score
  ;; whose music actually changed (or is new) is engraved.
  (define specs
    (for/list ([j (in-list jobs)])
      (define src (car j)) (define dir (cadr j)) (define name (caddr j))
      (make-directory* dir)
      (define ly (build-path dir (string-append name ".ly")))
      (define crop (build-path dir (string-append name ".cropped.png")))
      (define cached?
        (and (file-exists? crop)
             (file-exists? ly)
             (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
               (string=? (file->string ly) src))))
      (unless cached?
        (call-with-output-file ly #:exists 'truncate/replace
          (lambda (o) (write-string src o))))
      (list dir name ly crop cached?)))
  ;; run LilyPond only on the jobs that are not cache hits, in chunks of k
  (define todo (filter (lambda (s) (not (list-ref s 4))) specs))
  (let loop ([rest todo])
    (unless (null? rest)
      (define batch (if (> (length rest) k) (take rest k) rest))
      (define procs
        (for/list ([s (in-list batch)])
          (define dir (car s)) (define name (cadr s)) (define ly (caddr s))
          ;; process* avoids a shell; drain its ports so a chatty run can't stall
          (define-values (sp out in err)
            (subprocess #f #f #f (find-lilypond)
                        "--png" "-dcrop=#t" "-dresolution=200"
                        "-o" (path->string (build-path dir name))
                        (path->string ly)))
          (close-output-port in)
          (thread (lambda () (port->string out)))
          (thread (lambda () (port->string err)))
          sp))
      (for ([sp (in-list procs)]) (subprocess-wait sp))
      (loop (if (> (length rest) k) (drop rest k) '()))))
  ;; the cropped PNGs, in the original order (cached or freshly engraved)
  (for/list ([s (in-list specs)])
    (path->string (list-ref s 3))))

;; lilypond, from PATH (with the usual GUI-launched fallbacks)
(define (find-lilypond)
  (or (find-executable-path "lilypond")
      (for/or ([d (in-list '("/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin"))])
        (define p (build-path d "lilypond"))
        (and (file-exists? p) p))
      "lilypond"))
