#lang racket/base

;; mxml-read -- parse a MusicXML file into plain data for tonart4's
;; `load_musicxml` (Rhombus) to assemble into art forms.  Kept in Racket
;; because the XML lives here (Racket's `xml`), and plain lists/strings
;; cross into Rhombus far more cleanly than classic syntax objects do.
;;
;; Shape returned by `parse-musicxml`:
;;   parts   = (list part ...)
;;   part    = (list id-string (list measure ...))
;;   measure = (list divisions-or-#f time-sig-or-#f (list note ...))
;;   time-sig= (list beats beat-type)
;;   note    = (list rest? step alter octave type duration chord? (list lyric ...))
;;             step/type/lyric: strings (step lowercased) or #f; the rest:
;;             numbers/#f/booleans.  Tied notes are already merged away.

(require xml racket/path racket/list)
(provide parse-musicxml resolve-file)

;; resolve `file` relative to the directory of `src` (a source path, or #f)
(define (resolve-file src file)
  (if (and (path? src) (relative-path? (string->path file)))
      (path->string (build-path (or (path-only src) (current-directory)) file))
      file))

;; --- xexpr helpers (xexpr = (tag (list (list attr val) ...) child ...)) ---
(define (elem? x) (and (pair? x) (symbol? (car x))))
(define (kids x) (if (elem? x) (cddr x) '()))
(define (attrs x) (if (elem? x) (cadr x) '()))
(define (tag=? x t) (and (elem? x) (eq? (car x) t)))
(define (find-all x t) (filter (lambda (c) (tag=? c t)) (kids x)))
(define (find-first x t)
  (let ([r (find-all x t)]) (and (pair? r) (car r))))
(define (attr x k)
  (let ([a (assq k (attrs x))]) (and a (cadr a))))
(define (text x) (apply string-append (filter string? (kids x))))
(define (num-of x) (and x (string->number (text x))))

;; --- one raw note (with a tie field, pre-merge) ---
;; (list rest? step alter octave type duration chord? tie lyrics)
(define (parse-note n)
  (define is-rest (and (find-first n 'rest) #t))
  (define pitch   (find-first n 'pitch))
  (define step    (and pitch (let ([s (find-first pitch 'step)])
                               (and s (string-downcase (text s))))))
  (define alter   (or (and pitch (num-of (find-first pitch 'alter))) 0))
  (define octave  (and pitch (num-of (find-first pitch 'octave))))
  (define type    (let ([t (find-first n 'type)]) (and t (text t))))
  (define dur     (num-of (find-first n 'duration)))
  (define chord?  (and (find-first n 'chord) #t))
  (define ties    (find-all n 'tie))
  (define tie     (cond [(null? ties) #f]
                        [(= (length ties) 2) 'continue]
                        [else (string->symbol (attr (car ties) 'type))]))
  (define lyrics  (for/list ([l (in-list (find-all n 'lyric))]
                             #:when (find-first l 'text))
                    (text (find-first l 'text))))
  (list is-rest step alter octave type dur chord? tie lyrics))

;; --- collapse tied groups (start -> continue* -> stop) into one note ---
;; Sequential (single-voice) merge: a tie start opens; continue folds in
;; duration; stop finalizes the start note's duration.  Merged notes are
;; dropped.  (Tied *chords* -- several ties open at one instant -- are not
;; handled; that needs per-pitch tracking.)
(define (merge-tied notes-per-measure)
  (define boxed (for/list ([m (in-list notes-per-measure)])
                  (for/list ([n (in-list m)]) (box n))))
  (define flat (apply append boxed))
  (define dropped (make-hasheq))
  (let loop ([bs flat] [pending #f] [acc 0])
    (cond
      [(null? bs) (void)]
      [else
       (define b (car bs))
       (define n (unbox b))
       (define tie (list-ref n 7))
       (define dur (or (list-ref n 5) 0))
       (cond
         [(eq? tie 'start) (loop (cdr bs) b dur)]
         [(and pending (eq? tie 'continue))
          (hash-set! dropped b #t) (loop (cdr bs) pending (+ acc dur))]
         [(and pending (eq? tie 'stop))
          (set-box! pending (list-set (unbox pending) 5 (+ acc dur)))
          (hash-set! dropped b #t) (loop (cdr bs) #f 0)]
         [else (loop (cdr bs) pending acc)])]))
  ;; regroup, dropping merged notes and the tie field
  (for/list ([m (in-list boxed)])
    (for/list ([b (in-list m)] #:unless (hash-ref dropped b #f))
      (define n (unbox b))
      (list (list-ref n 0) (list-ref n 1) (list-ref n 2) (list-ref n 3)
            (list-ref n 4) (list-ref n 5) (list-ref n 6) (list-ref n 8)))))

(define (parse-musicxml path)
  (define doc
    (call-with-input-file path
      (lambda (in) (xml->xexpr (document-element (read-xml in))))))
  (for/list ([part (in-list (find-all doc 'part))])
    (define pid (attr part 'id))
    (define raw
      (for/list ([m (in-list (find-all part 'measure))])
        (define attrs-el  (find-first m 'attributes))
        (define divisions (and attrs-el (num-of (find-first attrs-el 'divisions))))
        (define time-el   (and attrs-el (find-first attrs-el 'time)))
        (define time-sig
          (and time-el
               (list (num-of (find-first time-el 'beats))
                     (num-of (find-first time-el 'beat-type)))))
        (list divisions time-sig (map parse-note (find-all m 'note)))))
    ;; merge ties across this part, then reattach measure headers
    (define merged (merge-tied (map caddr raw)))
    (list pid
          (for/list ([rm (in-list raw)] [notes (in-list merged)])
            (list (car rm) (cadr rm) notes)))))
