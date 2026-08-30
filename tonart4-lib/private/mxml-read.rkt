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

;; the tonart-source text of a <direction> (its <direction-type><words>)
(define (direction-words d)
  (let ([dt (find-first d 'direction-type)])
    (and dt (let ([w (find-first dt 'words)]) (and w (text w))))))

;; --- one raw note (with a tie field, pre-merge) ---
;; (list rest? step alter octave type duration chord? tie directions)
;; `directions` are tonart-source strings: preceding <direction> words
;; (verbatim) plus this note's lyrics wrapped as `lyric "syllable"`.
(define (parse-note n pre-dirs)
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
                    (format "lyric ~s" (text (find-first l 'text)))))
  (list is-rest step alter octave type dur chord? tie (append pre-dirs lyrics)))

;; walk a measure's children in order, attaching preceding <direction>
;; words to the note that follows them
(define (parse-measure-notes m)
  (let loop ([cs (kids m)] [dirs '()] [acc '()])
    (cond
      [(null? cs) (reverse acc)]
      [(tag=? (car cs) 'direction)
       (define w (direction-words (car cs)))
       (loop (cdr cs) (if w (cons w dirs) dirs) acc)]
      [(tag=? (car cs) 'note)
       (loop (cdr cs) '() (cons (parse-note (car cs) (reverse dirs)) acc))]
      [else (loop (cdr cs) dirs acc)])))

;; --- collapse tied groups (start -> continue* -> stop) into one note ---
;; Per-pitch merge: ties are tracked in a table keyed by pitch (step alter
;; octave), so several ties opening at one instant -- a tied *chord* -- are
;; paired correctly instead of interleaving.  A tie start opens the pitch's
;; slot (the start note's box, kept in the output); continue folds in
;; duration; stop writes the summed duration back into the start note and
;; drops itself.  Rests (no pitch) can't be tied.
(define (note-pitch n)
  (and (not (car n)) (list (list-ref n 1) (list-ref n 2) (list-ref n 3))))
(define (merge-tied notes-per-measure)
  (define boxed (for/list ([m (in-list notes-per-measure)])
                  (for/list ([n (in-list m)]) (box n))))
  (define flat (apply append boxed))
  (define dropped (make-hasheq))
  (define pending (make-hash))       ; pitch -> (cons start-box accumulated-dur)
  (define (finish! b total)
    (set-box! b (list-set (unbox b) 5 total)))
  (for ([b (in-list flat)])
    (define n (unbox b))
    (define tie (list-ref n 7))
    (define dur (or (list-ref n 5) 0))
    (define key (note-pitch n))
    (define open (and key (hash-ref pending key #f)))
    (cond
      [(and key (eq? tie 'start))
       (hash-set! pending key (cons b dur))]
      [(and open (eq? tie 'continue))
       (hash-set! pending key (cons (car open) (+ (cdr open) dur)))
       (hash-set! dropped b #t)]
      [(and open (eq? tie 'stop))
       (finish! (car open) (+ (cdr open) dur))
       (hash-remove! pending key)
       (hash-set! dropped b #t)]
      [else (void)]))
  ;; dangling starts (no matching stop): keep them with the summed duration
  (for ([(key bd) (in-hash pending)]) (finish! (car bd) (cdr bd)))
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
        (list divisions time-sig (parse-measure-notes m))))
    ;; merge ties across this part, then reattach measure headers
    (define merged (merge-tied (map caddr raw)))
    (list pid
          (for/list ([rm (in-list raw)] [notes (in-list merged)])
            (list (car rm) (cadr rm) notes)))))
