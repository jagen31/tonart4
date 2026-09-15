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
         file/sha1
         (only-in racket/future processor-count))

(provide engrave-all-cropped cache-key-source find-lilypond lilypond-exe ensure-lilypond-path!)

(define (cpu-cap)
  (max 2 (min 12 (processor-count))))

;; The `.ly` references image files (dance figures, etc.) only by PATH, so a
;; changed figure leaves the `.ly` text identical and the byte-identical cache
;; would serve a stale engraving.  Prefix the source with a comment hashing the
;; CONTENT of every image it references, so the cache key tracks those files:
;; an unchanged score still hits, a redrawn figure misses.  (LilyPond ignores
;; `%` comments, so this does not affect the output.)
;; EPS carries a `%%CreationDate` that changes every render even when the figure
;; is identical; drop it so an unchanged figure hashes stably (and still hits).
(define creation-date-rx (byte-pregexp #"(?m:^%%CreationDate:[^\r\n]*)"))
(define (image-bytes-for-hash p)
  (if (file-exists? p)
      (regexp-replace* creation-date-rx (file->bytes p) #"")
      #""))

(define (cache-key-source src)
  (define paths
    (sort (remove-duplicates
           (regexp-match* #px"#\"([^\"]+\\.(?:eps|png))\"" src #:match-select cadr))
          string<?))
  (cond
    [(null? paths) src]
    [else
     (define blob
       (apply bytes-append
              (for/list ([p (in-list paths)])
                (bytes-append (string->bytes/utf-8 p) #"\0"
                              (image-bytes-for-hash p) #"\0"))))
     (string-append "% image-deps " (sha1 (open-input-bytes blob)) "\n" src)]))

(define (engrave-all-cropped jobs [k (cpu-cap)])
  (ensure-lilypond-path!)
  ;; Classify each job.  A job is a CACHE HIT when its `.ly` is already on disk
  ;; byte-identical to what we would write AND its `.cropped.png` exists -- then
  ;; LilyPond need not run.  This is what keeps drilling into nested programs
  ;; from re-engraving the same unchanged scores over and over: only a score
  ;; whose music actually changed (or is new) is engraved.
  (define specs
    (for/list ([j (in-list jobs)])
      ;; key on the source PLUS the content of any images it references
      (define src (cache-key-source (car j))) (define dir (cadr j)) (define name (caddr j))
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

;; lilypond, from PATH (with the usual GUI-launched fallbacks): a
;; DrRacket/Finder-launched process has a minimal PATH that misses
;; /opt/homebrew/bin etc., so a bare `lilypond` shells out to "command not
;; found" -- always resolve through here instead.
(define (find-lilypond)
  (or (find-executable-path "lilypond")
      (for/or ([d (in-list '("/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin"))])
        (define p (build-path d "lilypond"))
        (and (file-exists? p) p))
      "lilypond"))
;; ... as a string (for building a shell command)
(define (lilypond-exe)
  (define p (find-lilypond))
  (if (path? p) (path->string p) p))

;; Ensure lilypond's own directory is on PATH.  lilypond's `--png` shells out
;; to `gs` (ghostscript), a sibling in the same dir (e.g. /opt/homebrew/bin);
;; a Finder/DrRacket-launched process misses that dir, so lilypond is found by
;; full path yet then fails to find gs.  Prepend the dir (idempotent) so both
;; resolve.  Matches what the realizer preview does to its subprocess PATH.
(define lilypond-path-ensured? (box #f))
(define (ensure-lilypond-path!)
  (unless (unbox lilypond-path-ensured?)
    (set-box! lilypond-path-ensured? #t)
    (define p (find-lilypond))
    (when (path? p)
      (define-values (dir name must-be-dir?) (split-path p))
      (when (path? dir)
        (define ds (path->string dir))
        (define cur (or (getenv "PATH") ""))
        (unless (regexp-match? (regexp (regexp-quote ds)) cur)
          (putenv "PATH" (string-append ds ":" cur)))))))
