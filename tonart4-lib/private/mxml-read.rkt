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
;;   note    = (list rest? step alter octave type duration)
;;             step/type: strings (step lowercased) or #f; the rest: numbers/#f

(require xml racket/path)
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
;; direct text of an element (concatenation of its string children)
(define (text x)
  (apply string-append (filter string? (kids x))))
(define (num-of x)      ; string->number of an element's text, or #f
  (and x (string->number (text x))))

(define (parse-musicxml path)
  (define doc
    (call-with-input-file path
      (lambda (in) (xml->xexpr (document-element (read-xml in))))))
  (for/list ([part (in-list (find-all doc 'part))])
    (define pid (attr part 'id))
    (define measures
      (for/list ([m (in-list (find-all part 'measure))])
        (define attrs-el  (find-first m 'attributes))
        (define divisions (and attrs-el (num-of (find-first attrs-el 'divisions))))
        (define time-el   (and attrs-el (find-first attrs-el 'time)))
        (define time-sig
          (and time-el
               (list (num-of (find-first time-el 'beats))
                     (num-of (find-first time-el 'beat-type)))))
        (define notes
          (for/list ([n (in-list (find-all m 'note))])
            (define is-rest (and (find-first n 'rest) #t))
            (define pitch   (find-first n 'pitch))
            (define step    (and pitch (let ([s (find-first pitch 'step)])
                                         (and s (string-downcase (text s))))))
            (define alter   (or (and pitch (num-of (find-first pitch 'alter))) 0))
            (define octave  (and pitch (num-of (find-first pitch 'octave))))
            (define type    (let ([t (find-first n 'type)]) (and t (text t))))
            (define dur     (num-of (find-first n 'duration)))
            (list is-rest step alter octave type dur)))
        (list divisions time-sig notes)))
    (list pid measures)))
