;; Copyright 2012-2018 Ryan Culpepper
;; Copyright 2007-2009 Dimitris Vyzovitis <vyzo at media.mit.edu>
;; 
;; This library is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;; 
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public License
;; along with this library.  If not, see <http://www.gnu.org/licenses/>.

#lang racket/base
(require racket/class
         racket/match
         racket/contract/base
         racket/string
         racket/random
         racket/string
         "catalog.rkt"
         "interfaces.rkt"
         "error.rkt"
         "factory.rkt"
         "ufp.rkt")
(provide impl-base%
         ctx-base%
         state-mixin
         state-ctx%
         factory-base%
         digest-impl%
         digest-ctx%
         cipher-impl-base%
         multikeylen-cipher-impl%
         cipher-ctx%
         pk-impl-base%
         pk-params-base%
         pk-key-base%
         process-input
         to-impl
         to-info
         to-spec
         shrink-bytes
         config/c
         check-config
         config-ref
         config:pbkdf2
         config:scrypt
         config:argon2
         config:rsa-keygen
         config:dsa-paramgen
         config:ec-paramgen
         version->list
         version->string
         version>=?
         crypto-random-bytes)

;; Convention: methods starting with `-` (eg, `-digest-buffer`) are
;; hooks for overrriding. They receive pre-checked arguments, and they
;; are called within the appropriate mutex and state, if applicable.

;; ============================================================

(define impl-base%
  (class* object% (impl<%>)
    (init-field spec factory)
    (define/public (about) (format "~a ~a" (send (get-factory) get-name) (get-spec)))
    (define/public (get-info) #f)
    (define/public (get-spec) spec)
    (define/public (get-factory) factory)
    (super-new)))

(define info-impl-base%
  (class* object% (impl<%>)
    (init-field info factory)
    (define/public (about) (format "~a ~a" (send (get-factory) get-name) (get-spec)))
    (define/public (get-info) info)
    (define/public (get-spec) (send info get-spec))
    (define/public (get-factory) factory)
    (super-new)))

(define ctx-base%
  (class* object% (ctx<%>)
    (init-field impl)
    (define/public (about) (format "~a context" (send impl about)))
    (define/public (get-impl) impl)
    (super-new)))

;; ----------------------------------------

(define state-mixin
  (mixin () (state<%>)
    (init-field state)
    (field [sema (make-semaphore 1)])
    (super-new)

    (define/public (with-state #:ok [ok-states #f]
                     #:pre  [pre-state #f]
                     #:post [post-state #f]
                     #:msg  [msg #f]
                     proc)
      (call-with-semaphore sema
        (lambda ()
          (when ok-states (unless (memq state ok-states) (bad-state state ok-states msg)))
          (when pre-state (set-state pre-state))
          (begin0 (proc)
            (when post-state (set-state post-state))))))

    (define/public (set-state new-state)
      (unless (equal? state new-state) (set! state new-state)))

    (define/public (bad-state state ok-states msg)
      (crypto-error "wrong state\n  state: ~s~a" state (or msg "")))
    ))

(define state-ctx% (state-mixin ctx-base%))

;; ============================================================
;; Factory

(define factory-base%
  (class* object% (factory<%>)
    (init-field [ok? #t])
    (super-new)

    (define/public (get-name) #f)
    (define/public (get-version) (and ok? '()))

    (define/public (info key)
      (case key
        [(version) (and ok? (get-version))]
        [(all-digests) (filter (lambda (s) (get-digest s)) (list-known-digests))]
        [(all-ciphers) (filter (lambda (x) (get-cipher x)) (list-known-ciphers))]
        [(all-pks)     (filter (lambda (x) (get-pk x)) '(rsa dsa dh ec))]
        [(all-curves)  #f]
        [else #f]))

    (define/public (print-info)
      (void))

    (define/public (print-avail)
      (printf "Available digests:\n")
      (for ([di (in-list (info 'all-digests))])  (printf " ~v\n" di))
      (printf "Available ciphers:\n")
      (for ([ci (in-list (info 'all-ciphers))])  (printf " ~v\n" ci))
      (printf "Available PK:\n")
      (for ([pk (in-list (info 'all-pks))])      (printf " ~v\n" pk))
      (let ([all-curves (info 'all-curves)])
        (when all-curves
          (printf "Available EC named curves:\n")
          (for ([curve (in-list all-curves)]) (printf " ~v\n" curve)))))

    ;; table : Hash[*Spec => *Impl]
    ;; Note: assumes different *Spec types have disjoint values!
    ;; Only cache successful lookups to keep table size bounded.
    (field [table (make-hash)])

    (define-syntax-rule (get/table spec spec->key get-impl)
      ;; Note: spec should be variable reference
      (cond [(not ok?) #f]
            [(hash-ref table spec #f) => values]
            [(spec->key spec)
             => (lambda (key)
                  (cond [(get-impl key)
                         => (lambda (impl)
                              (hash-set! table (send impl get-spec) impl)
                              impl)]
                        [else #f]))]
            [else #f]))

    (define/public (get-digest spec)
      (get/table spec digest-spec->info -get-digest))
    (define/public (get-cipher spec)
      (get/table spec cipher-spec->info -get-cipher0))
    (define/public (get-pk spec)
      (get/table spec values -get-pk))
    (define/public (get-kdf spec)
      (get/table spec values -get-kdf))
    (define/public (get-pk-reader)
      (get/table '*pk-reader* values (lambda (k) (-get-pk-reader))))

    (define/public (-get-cipher0 info)
      (define ci (-get-cipher info))
      (cond [(cipher-impl? ci) ci]
            [(and (list? ci) (pair? ci) (andmap cdr ci))
             (new multikeylen-cipher-impl% (info info) (factory this) (impls ci))]
            [else #f]))

    ;; -get-digest : digest-info -> (U #f digest-impl)
    (define/public (-get-digest info) #f)

    ;; -get-cipher : cipher-info -> (U #f cipher-impl (listof (cons Nat cipher-impl)))
    (define/public (-get-cipher info) #f)

    ;; -get-pk : pk-spec -> (U pk-impl #f)
    (define/public (-get-pk spec) #f)

    ;; -get-pk-reader : -> (U pk-read-key #f)
    (define/public (-get-pk-reader) #f)

    ;; -get-kdf : -> (U kdf-impl #f)
    (define/public (-get-kdf spec) #f)
    ))

;; ============================================================
;; Digest

(define digest-impl%
  (class* info-impl-base% (digest-impl<%>)
    (inherit-field info)
    (inherit get-spec)
    (super-new)

    ;; Info methods
    (define/override (about) (format "~a digest" (super about)))
    (define/public (get-size) (send info get-size))
    (define/public (get-block-size) (send info get-block-size))
    (define/public (key-size-ok? keysize) (send info key-size-ok? keysize))

    (define/public (sanity-check #:size [size #f] #:block-size [block-size #f])
      ;; Use info::get-{block-,}size directly so that subclasses can
      ;; override get-size and get-block-size.
      (when size
        (unless (= size (send info get-size))
          (internal-error "digest size: expected ~s but got ~s\n  digest: ~a"
                          (send info get-size) size (about))))
      (when block-size
        (unless (= block-size (send info get-block-size))
          (internal-error "block size: expected ~s but got ~s\n  digest: ~a"
                          (send info get-block-size) block-size (about)))))

    (define/public (new-ctx key)
      (when key (check-key-size (bytes-length key)))
      (-new-ctx key))

    (define/public (check-key-size keysize)
      (unless (key-size-ok? keysize)
        (crypto-error "bad key size\n  key: ~s bytes\n  digest: ~a"
                      keysize (about))))

    (abstract -new-ctx)       ;; Bytes/#f -> digest-ctx<%>
    (abstract new-hmac-ctx)   ;; Bytes -> digest-ctx<%>

    (define/public (digest src key)
      (define (fallback) (send (new-ctx key) digest src))
      (when key (check-key-size (bytes-length key)))
      (cond [key (fallback)]
            [else
             (match src
               [(? bytes?) (or (-digest-buffer src 0 (bytes-length src)) (fallback))]
               [(bytes-range buf start end) (or (-digest-buffer buf start end) (fallback))]
               [_ (fallback)])]))

    (define/public (hmac key src)
      (define (fallback) (send (new-hmac-ctx key) digest src))
      (match src
        [(? bytes?) (or (-hmac-buffer key src 0 (bytes-length src)) (fallback))]
        [(bytes-range buf start end) (or (-hmac-buffer key buf start end) (fallback))]
        [_ (fallback)]))

    ;; {-digest,-hmac}-buffer : ... -> Bytes/#f
    ;; Return bytes if can compute digest/hmac directly, #f to fall back
    ;; to default ctx code.
    (define/public (-digest-buffer src src-start src-end) #f)
    (define/public (-hmac-buffer key src src-start src-end) #f)
    ))

(define digest-ctx%
  (class* (state-mixin ctx-base%) (digest-ctx<%>)
    (super-new [state 'open])
    (inherit get-impl with-state)

    (define/public (digest src)
      (update src)
      (final))

    (define/public (update src)
      (with-state #:ok '(open)
        (lambda () (void (process-input src (lambda (buf start end) (-update buf start end)))))))

    (define/public (final)
      (with-state #:ok '(open) #:post 'closed
        (lambda ()
          (define dest (make-bytes (send (get-impl) get-size)))
          (-final! dest)
          dest)))

    (define/public (copy)
      (with-state #:ok '(open) (lambda () (-copy))))

    (abstract -update) ;; Bytes Nat Nat -> Void
    (abstract -final!) ;; Bytes -> Void
    (define/public (-copy) #f) ;; -> digest-ctx<%> or #f
    ))

;; ============================================================
;; Cipher

(define cipher-impl-base%
  (class* info-impl-base% (cipher-impl<%>)
    (inherit-field info)
    (inherit get-spec)
    (super-new)

    ;; Info methods
    (define/override (about) (format "~a cipher" (super about)))
    (define/public (get-cipher-name) (send info get-cipher-name))
    (define/public (get-mode) (send info get-mode))
    (define/public (get-type) (send info get-type))
    (define/public (aead?) (send info aead?))
    (define/public (get-block-size) (send info get-block-size))
    (define/public (get-chunk-size) (send info get-chunk-size))
    (define/public (get-key-size) (send info get-key-size))
    (define/public (get-key-sizes) (send info get-key-sizes))
    (define/public (key-size-ok? size) (size-set-contains? (get-key-sizes) size))
    (define/public (get-iv-size) (send info get-iv-size))
    (define/public (iv-size-ok? size) (send info iv-size-ok? size))
    (define/public (get-auth-size) (send info get-auth-size))
    (define/public (auth-size-ok? size) (send info auth-size-ok? size))
    (define/public (uses-padding?) (send info uses-padding?))

    (define/public (sanity-check #:block-size [block-size #f]
                                 #:chunk-size [chunk-size #f]
                                 #:iv-size [iv-size #f])
      (when block-size
        (unless (= block-size (send info get-block-size))
          (internal-error "block-size expected ~s but got ~s\n  cipher: ~a"
                          (send info get-block-size) block-size (about))))
      (when chunk-size
        (unless (= chunk-size (send info get-chunk-size))
          (internal-error "chunk-size expected ~s but got ~s\n  cipher: ~a"
                          (send info get-chunk-size) chunk-size (about))))
      (when iv-size
        (unless (iv-size-ok? iv-size)
          (internal-error "iv-size ~s not ok\n  cipher: ~a" iv-size (about))))
      (void))

    (define/public (new-ctx key iv enc? pad? auth-len0 attached-tag?)
      (check-key-size (bytes-length key))
      (check-iv-size (bytes-length (or iv #"")))
      (define auth-len (or auth-len0 (get-auth-size)))
      (check-auth-size auth-len)
      (let ([pad? (and pad? (uses-padding?))])
        (-new-ctx key iv enc? pad? auth-len attached-tag?)))

    (abstract -new-ctx)

    (define/public (check-key-size size)
      (unless (key-size-ok? size)
        (crypto-error "bad key size for cipher\n  cipher: ~a\n  given: ~e\n  allowed: ~a"
                      (about) size
                      (match (get-key-sizes)
                        [(? list? allowed)
                         (string-join (map number->string allowed) ", ")]
                        [(varsize min max step)
                         (format "from ~a to ~a in multiples of ~a" min max step)]))))

    (define/public (check-iv-size iv-size)
      (unless (iv-size-ok? iv-size)
        (crypto-error "bad IV size for cipher\n  cipher: ~a\n  expected: ~s bytes\n  got: ~s bytes"
                      (about) iv-size (get-iv-size))))

    (define/public (check-auth-size auth-size)
      (unless (auth-size-ok? auth-size)
        (crypto-error "bad authentication tag size\n  cipher: ~a\n  given: ~e"
                      (about) auth-size)))
    ))

(define multikeylen-cipher-impl%
  (class cipher-impl-base%
    (init-field impls) ;; (nonempty-listof (cons nat cipher-impl%))
    (inherit-field info)
    (inherit about get-spec check-key-size)
    (super-new)

    (define/override (get-key-size) (caar impls))
    (define/override (get-key-sizes) (map car impls))

    (define/override (new-ctx key . args)
      (cond [(assoc (bytes-length key) impls)
             => (lambda (keylen+impl)
                  (send/apply (cdr keylen+impl) new-ctx key args))]
            [else
             (check-key-size (bytes-length key))
             (internal-error (string-append "no implementation for key length"
                                            "\n  cipher: ~a\n  given: ~s bytes\n  available: ~a")
                             (about) (bytes-length key)
                             (string-join (map number->string (map car impls)) ", "))]))
    (define/override (-new-ctx . args) (internal-error "unreachable"))
    ))

;; ----------------------------------------

;; cipher-ctx%
;; - enforces update-aad -> update -> final state machine
;; - accepts data from varied input in varied sizes, passes to underlying
;;   crypt routines in multiples of chunk-size (except last call)
;; - handles PKCS7 padding
;; - handles attached authentication tags

(define cipher-ctx%
  (class* state-ctx% (cipher-ctx<%>)
    (init-field encrypt? pad? auth-len attached-tag?)
    ;; auth-len : Nat -- 0 means no tag
    (inherit-field impl state)
    (field [auth-tag-out #f]
           [out (open-output-bytes)])
    (inherit with-state set-state about)
    (super-new [state 1])

    (set-state (if (send impl aead?) 1 2))

    ;; State is Nat
    ;; 1 - ready for AAD
    ;; 2 - AAD done, ready for {plain,cipher}text
    ;; 3 - closed (but can read auth tag)
    (define/override (bad-state state ok-states msg)
      (crypto-error "wrong state\n  state: ~a~a"
                    (case state
                      [(1) "ready for AAD or input"]
                      [(2) "ready for input"]
                      [(3) "closed"])
                    msg))

    (define/public (get-encrypt?) encrypt?)
    (define/public (get-block-size) (send impl get-block-size))
    (define/public (get-chunk-size) (send impl get-chunk-size))
    (define/public (get-output) (get-output-bytes out #t))

    (define/public (update-aad src)
      (unless (null? src)
        (with-state #:ok '(1) #:pre 1
          (lambda ()
            (process-input src (lambda (buf start end) (-update-aad buf start end)))))))

    (define/public (update src)
      (with-state #:ok '(1 2) #:post 2
        (lambda ()
          (when (member state '(1)) (-finish-aad))
          (set-state 3)
          (process-input src (lambda (buf start end) (-update buf start end))))))

    (define/public (final tag)
      (cond [encrypt?
             (when tag
               (crypto-error "cannot set authentication tag for encryption context"))]
            [attached-tag? ;; decrypt w/ attached tag
             (when tag
               (crypto-error "cannot set authentication tag for decryption context with attached tag"))]
            [else ;; decrypt w/ detached tag
             (let ([tag (or tag #"")])
               (unless (= (bytes-length tag) auth-len)
                 (crypto-error "wrong authentication tag size\n  expected: ~s\n  given: ~s\n  cipher: ~a"
                               auth-len (bytes-length tag) (about))))])
      (with-state #:ok '(1 2) #:post 3
        (lambda ()
          (when (member state '(1)) (-finish-aad))
          (set-state 3)
          (begin0 (-final (if encrypt? #f (or tag #"")))
            (-close)))))

    (define/public (get-auth-tag)
      (cond [encrypt?
             ;; -final sets auth-tag-out for encryption context
             ;; #"" for non-AEAD cipher
             (with-state #:ok '(3)
               (lambda () auth-tag-out))]
            [else ;; decrypt
             (crypto-error "cannot get authentication tag for decryption context")]))

    ;; ----------------------------------------

    ;; -update-aad : Bytes Nat Nat -> Void
    (define/public (-update-aad buf start end)
      (send aad-ufp update buf start end))

    ;; -finish-aad : -> Void
    (define/public (-finish-aad)
      (send aad-ufp finish 'ignored))

    ;; -update : Bytes Nat Nat -> Void
    (define/public (-update buf start end)
      (send crypt-ufp update buf start end))

    ;; -final : #f/Bytes -> Void
    (define/public (-final tag)
      (send crypt-ufp finish tag))

    ;; -close : -> Void
    (define/public (-close) (void))

    ;; -make-crypt-sink : -> UFP[#f/AuthTag => ]
    (define/public (-make-crypt-sink)
      (sink-ufp (lambda (buf start end) (write-bytes buf out start end))
                (lambda (result) (set! auth-tag-out result))))

    ;; -make-aad-sink : -> UFP[#f => ]
    (define/public (-make-aad-sink)
      (define (update inbuf instart inend) (-do-aad inbuf instart inend))
      (define (finish _ignored) (void))
      (sink-ufp update finish))

    (abstract -do-aad) ;; Bytes Nat Nat -> Void

    ;; -make-crypt-ufp : Boolean UFP -> UFP[Bytes,#f/AuthTag => AuthTag/#f]
    (define/public (-make-crypt-ufp enc? next)
      (define (update inbuf instart inend)
        ;; with block aligned and padding disabled, outlen = inlen... check, tighten (FIXME)
        (define outlen0 (+ (- inend instart) (get-block-size)))
        (define outbuf (make-bytes outlen0))
        (define outlen (-do-crypt enc? #f inbuf instart inend outbuf))
        (unless (= outlen (- inend instart))
          (internal-error "outlen = ~s, inlen = ~s" outlen (- inend instart)))
        (send next update outbuf 0 outlen))
      (define (finish partial auth-tag)
        ;; with block aligned and padding disabled, outlen = inlen... check, tighten (FIXME)
        (define outlen0 (* 2 (get-chunk-size)))
        (define outbuf (make-bytes outlen0))
        (define outlen (-do-crypt enc? #t partial 0 (bytes-length partial) outbuf))
        (unless (= outlen (bytes-length partial))
          (internal-error "outlen = ~s, partial = ~s" outlen (bytes-length partial)))
        (send next update outbuf 0 outlen)
        (cond [enc?
               (send next finish (-do-encrypt-end auth-len))]
              [else
               (unless (= (bytes-length auth-tag) auth-len)
                 (crypto-error "wrong authentication tag size\n  expected: ~s\n  given: ~s\n  cipher: ~a"
                               auth-len (bytes-length auth-tag) (about)))
               (-do-decrypt-end auth-tag)
               (send next finish #f)]))
      (sink-ufp update finish))

    (abstract -do-crypt) ;; Enc? Final? Bytes Nat Nat Bytes -> Nat
    (abstract -do-encrypt-end) ;; Nat -> Tag      -- fetch auth tag
    (abstract -do-decrypt-end) ;; Nat Tag -> Void -- check auth tag

    ;; ----------------------------------------
    ;; Initialization

    ;; It's most convenient if we know the auth-length up front. That
    ;; simplifies the creation of the split-right-ufp for decrypting with
    ;; attached tag.

    (define aad-ufp
      ;; update-aad
      ;;   source -> chunk -> add-right -> update-aad
      ;;          #f       buf,#f       #f
      (let* ([ufp (-make-aad-sink)]
             [ufp (add-right-ufp ufp)]
             [ufp (chunk-ufp (get-chunk-size) ufp)])
        ufp))

    (define crypt-ufp
      (cond [encrypt?
             ;; encrypt (detached tag) =
             ;;   source -> chunk -> pad  -> auth-encrypt -> sink
             ;;          #f       buf,#f  buf,#f          tag
             ;;
             ;; encrypt/attached-tag =
             ;;   source -> chunk -> pad  -> auth-encrypt -> add-right -> push #f -> sink
             ;;          #f       buf,#f  buf,#f          tag          ()         #f
             (let* ([ufp (-make-crypt-sink)]
                    [ufp (if attached-tag? (add-right-ufp (push-ufp #f ufp)) ufp)]
                    [ufp (-make-crypt-ufp #t ufp)]
                    [ufp (if pad? (pad-ufp (get-block-size) ufp) ufp)]
                    [ufp (chunk-ufp (get-chunk-size) ufp)])
               ufp)]
            [else ;; decrypt
             ;; decrypt (detached tag) =
             ;;   source -> chunk -> auth-decrypt -> split-right -> unpad -> add-right -> sink
             ;;          tag      buf,tag         #f             buf,#f   buf,#f       #f
             ;;
             ;; decrypt/attached-tag = 
             ;;   source -> pop -> split-right -> chunk -> pad  -> auth-decrypt -> (...see above)
             ;;          #""    ()             tag      buf,tag buf,tag         #f
             (let* ([ufp (-make-crypt-sink)]
                    [ufp (cond [pad?
                                (let* ([ufp (add-right-ufp ufp)]
                                       [ufp (unpad-ufp ufp)]
                                       [ufp (split-right-ufp (get-block-size) ufp)])
                                  ufp)]
                               [else ufp])]
                    [ufp (-make-crypt-ufp #f ufp)]
                    [ufp (chunk-ufp (get-chunk-size) ufp)]
                    ;; FIXME: need to delay until we have auth-len ...
                    [ufp (if (and attached-tag? (positive? auth-len))
                             (pop-ufp (split-right-ufp auth-len ufp))
                             ufp)])
               ufp)]))
    ))

;; ============================================================
;; PK

(define pk-impl-base%
  (class* impl-base% (pk-impl<%>)
    (inherit about get-spec get-factory)
    (super-new)
    (define/public (generate-key config)
      (crypto-error (string-append "direct key generation not supported;\n"
                                   " generate parameters, then generate key\n"
                                   "  algorithm: ~e")
                    (get-spec)))
    (define/public (generate-params config)
      (crypto-error "parameters not supported\n  algorithm: ~a" (about)))
    (define/public (can-encrypt? pad) #f)
    (define/public (can-sign? pad dspec) #f)
    (define/public (can-key-agree?) #f)
    (define/public (has-params?) #f)
    ))

(define pk-params-base%
  (class* ctx-base% (pk-params<%>)
    (inherit-field impl)
    (super-new)
    (define/override (about) (format "~a parameters" (send impl about)))
    (abstract generate-key)
    (define/public (write-params fmt)
      (or (-write-params fmt)
          (crypto-error "parameters format not supported\n  format: ~e\n  parameters: ~a"
                        fmt (about))))
    (define/public (-write-params fmt) #f)
    ))

(define pk-key-base%
  (class* ctx-base% (pk-key<%>)
    (inherit-field impl)
    (super-new)

    (define/override (about)
      (format "~a ~a key" (send impl about) (if (is-private?) 'private 'public)))
    (define/public (get-spec) (send impl get-spec))

    (abstract is-private?)
    (abstract get-public-key)
    (abstract equal-to-key?)

    (define/public (get-params)
      (crypto-error "key parameters not supported"))

    (define/public (write-key fmt)
      (or (-write-key fmt)
          (crypto-error "key format not supported\n  format: ~e\n  key: ~a"
                        fmt (about))))
    (define/public (-write-key fmt)
      (cond [(or (eq? fmt 'SubjectPublicKeyInfo) (not (is-private?)))
             (-write-public-key fmt)]
            [else
             (-write-private-key fmt)]))
    (define/public (-write-public-key fmt) #f)
    (define/public (-write-private-key fmt) #f)

    ;; ----

    (define/public (sign digest digest-spec pad)
      (-check-sign pad digest-spec)
      (unless (is-private?)
        (crypto-error "signing requires private key\n  key: ~a" (about)))
      (-check-digest-size digest digest-spec)
      (-sign digest digest-spec pad))

    (define/public (verify digest digest-spec pad sig)
      (-check-sign pad digest-spec)
      (-check-digest-size digest digest-spec)
      (-verify digest digest-spec pad sig))

    (define/private (-check-sign pad digest-spec)
      (unless (send impl can-sign? #f #f)
        (crypto-error "sign/verify not supported\n  key: ~a" (about)))
      (unless (send impl can-sign? pad digest-spec)
        (crypto-error "sign/verify options not supported\n  key: ~a\n  padding: ~e\n  digest: ~e"
                      (about) pad digest-spec)))

    (define/private (-check-digest-size digest digest-spec)
      (unless (= (bytes-length digest) (digest-spec-size digest-spec))
        (crypto-error "wrong size for digest\n  digest: ~e\n  expected:  ~s\n  given: ~s"
                      digest-spec (digest-spec-size digest-spec) (bytes-length digest))))

    (define/public (-sign digest digest-spec pad) (err/no-impl this))
    (define/public (-verify digest digest-spec pad sig) (err/no-impl this))

    ;; ----

    (define/public (encrypt buf pad)
      (-check-encrypt pad)
      (-encrypt buf pad))
    (define/public (decrypt buf pad)
      (-check-encrypt pad)
      (unless (is-private?)
        (crypto-error "decryption requires private key\n  key: ~a" (about)))
      (-decrypt buf pad))

    (define/public (compute-secret peer-pubkey)
      (-check-key-agree)
      (when (pk-key? peer-pubkey)
        (unless (eq? (send peer-pubkey get-impl) impl)
          (crypto-error "peer key has different implementation\n  key: ~a\n  peer: ~a"
                        (about) (send peer-pubkey about))))
      (-compute-secret peer-pubkey))

    (define/private (-check-encrypt pad)
      (unless (send impl can-encrypt? #f)
        (crypto-error "encrypt/decrypt not supported\n  key: ~a" (about)))
      (unless (send impl can-encrypt? pad)
        (crypto-error "encrypt/decrypt not supported\n  key: ~a\n  padding: ~e"
                      (about) pad)))

    (define/public (-encrypt buf pad) (err/no-impl this))
    (define/public (-decrypt buf pad) (err/no-impl this))

    ;; ----

    (define/private (-check-key-agree)
      (unless (send impl can-key-agree?)
        (crypto-error "key agreement not supported\n  key: ~a" (about))))

    (define/public (-compute-secret peer-pubkey) (err/no-impl))
    ))

;; ============================================================
;; Input

;; process-input : Input (Bytes Nat Nat -> Void) -> Void
(define (process-input src process)
  (let loop ([src src])
    (match src
      [(? bytes?) (process src 0 (bytes-length src))]
      [(bytes-range buf start end) (process buf start end)]
      [(? input-port?)
       (process-input-port src process)]
      [(? string?)
       ;; Alternative: could process string in chunks like process-input.
       ;; Note: open-input-bytes makes copy, so can't just use that.
       (loop (string->bytes/utf-8 src))]
      [(? list?) (for ([sub (in-list src)]) (loop sub))])))

;; process-input-port : InputPort (Bytes Nat Nat -> Void) -> Void
(define DEFAULT-CHUNK 1000)
(define (process-input-port in process #:chunk [chunk-size DEFAULT-CHUNK])
  (define buf (make-bytes chunk-size))
  (let loop ()
    (define len (read-bytes! buf in))
    (unless (eof-object? len)
      (process buf 0 len)
      (loop))))

;; ============================================================

(define (to-impl src0 [fail-ok? #f] #:lookup [lookup #f] #:what [what #f])
  (let loop ([src src0])
    (cond [(is-a? src impl<%>) src]
          [(is-a? src ctx<%>) (loop (send src get-impl))]
          [(and lookup (lookup src)) => values]
          [fail-ok? #f]
          [else (crypto-error "could not get implementation\n  ~a: ~e"
                              (or what "given") src0)])))

(define (to-info src [fail-ok? #f] #:lookup [lookup #f] #:what [what #f])
  ;; assumes impl<%> is also info<%>
  (cond [(to-impl src #t) => values]
        [(and lookup (lookup src)) => values]
        [fail-ok? #f]
        [else (crypto-error "could not get info\n  ~a: ~e" (or what "given") src)]))

(define (to-spec src)
  ;; Assumes src is Spec | Impl | Ctx
  (cond [(to-impl src #t) => (lambda (impl) (send impl get-spec))]
        [else src]))

(define (shrink-bytes bs len)
  (if (< len (bytes-length bs))
    (subbytes bs 0 len)
    bs))

;; ----

;; A Config is (listof (list Symbol Any))
(define config/c (listof (list/c symbol? any/c)))

;; A ConfigSpec is (listof (list Symbol Required? Predicate String/#f))

(define (check-config config spec what)
  ;; Assume already checked config/c, now check entries
  (for ([entry (in-list config)])
    (match-define (list key value) entry)
    (cond [(assq key spec)
           => (lambda (aentry)
                (match-define (list _ required? pred? expected) aentry)
                (unless (pred? value)
                  (crypto-error "bad option value for ~a\n  key: ~e\n  expected: ~a\n  given: ~e"
                                what key (or expected (object-name pred?)) value)))]
          [else
           (crypto-error "unsupported option for ~a\n  key: ~e\n  value: ~e"
                         key value)]))
  (for ([aentry (in-list spec)] #:when (match aentry [(list _ required? _ _) required?]))
    (match-define (list key required? pred? expected) aentry)
    (unless (assq key config)
      (crypto-error "missing required option for ~a\n  key: ~e\n  given: ~e"
                    key config)))
  (void))

(define (config-ref spec key [default #f])
  (cond [(assq key spec) => cadr] [else default]))

;; ----

(define config:pbkdf2
  `((iterations #t ,exact-positive-integer? #f)
    (key-size   #t ,exact-positive-integer? #f)))

(define config:scrypt
  `((N #t ,exact-positive-integer? #f)
    (p #f ,exact-positive-integer? #f)
    (r #f ,exact-positive-integer? #f)
    (key-size #f ,exact-positive-integer? #f)))

(define config:argon2
  `((t #t ,exact-positive-integer? #f)
    (m #t ,exact-positive-integer? #f)
    (p #f ,exact-positive-integer? #f)
    (key-size #f ,exact-positive-integer? #f)))

(define config:rsa-keygen
  `((nbits #f ,exact-positive-integer? #f)
    (e     #f ,exact-positive-integer? #f)))

(define config:dsa-paramgen
  `((nbits #f ,exact-positive-integer? "exact-positive-integer?")
    (qbits #f ,(lambda (x) (member x '(160 256))) "(or/c 160 256)")))

(define config:ec-paramgen
  `((curve #t ,(lambda (x) (or (symbol? x) (string? x))) "(or/c symbol? string?)")))

;; ----------------------------------------

;; version->list : String/#f -> (Listof Nat)/#f
(define (version->list str)
  (and str
       (if (regexp-match? #rx"^[0-9]+(?:[.][0-9]+)*$" str)
           (map string->number (string-split str #rx"[.]"))
           (internal-error "invalid version string: ~e" str))))

;; version->string : (Listof Nat)/#f -> String/#f
(define (version->string v)
  (and v (string-join (map number->string v) ".")))

;; version>=? : (Listof Nat)/#f (Listof Nat) -> Boolean
(define (version>=? v1 v2)
  (match* [v1 v2]
    [[#f _] #f]
    [[(cons p1 v1*) (cons p2 v2*)]
     (or (> p1 p2)
         (and (= p1 p2) (version>=? v1* v2*)))]
    [[(cons p1 v1*) '()] #t]
    ;; FIXME: currently 1.0 < 1.0.0; maybe consider equal?
    [['() (cons p2 v2*)] #f]))