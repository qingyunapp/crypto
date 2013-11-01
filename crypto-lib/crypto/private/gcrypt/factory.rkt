;; Copyright 2012 Ryan Culpepper
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
         racket/syntax
         ffi/unsafe
         "../common/interfaces.rkt"
         "../common/common.rkt"
         "ffi.rkt"
         "digest.rkt"
         "cipher.rkt")
(provide gcrypt-factory)

;; ----------------------------------------

(define digests
  `(;;[Name     AlgId               BlockSize]
    (sha1       ,GCRY_MD_SHA1       64)
    (ripemd160  ,GCRY_MD_RMD160     64) ;; Doesn't seem to be available!
    (md2        ,GCRY_MD_MD2        16)
    (sha224     ,GCRY_MD_SHA224     64)
    (sha256     ,GCRY_MD_SHA256     64)
    (sha384     ,GCRY_MD_SHA384     128)
    (sha512     ,GCRY_MD_SHA512     128)
    (md4        ,GCRY_MD_MD4        64)
    (whirlpool  ,GCRY_MD_WHIRLPOOL  64)
    #|
    (haval      ,GCRY_MD_HAVAL      128)
    (tiger      ,GCRY_MD_TIGER      #f)
    (tiger1     ,GCRY_MD_TIGER1     #f)
    (tiger2     ,GCRY_MD_TIGER2     #f)
    |#))

;; ----------------------------------------

(define ciphers
  `(;;[Name   ([KeySize AlgId] ...)]
    [cast-128 ([128 ,GCRY_CIPHER_CAST5])]
    [blowfish ([128 ,GCRY_CIPHER_BLOWFISH])]
    [aes      ([128 ,GCRY_CIPHER_AES]
               [192 ,GCRY_CIPHER_AES192]
               [256 ,GCRY_CIPHER_AES256])]
    [twofish  ([128 ,GCRY_CIPHER_TWOFISH128]
               [256 ,GCRY_CIPHER_TWOFISH])]
    [serpent  ([128 ,GCRY_CIPHER_SERPENT128]
               [192 ,GCRY_CIPHER_SERPENT192]
               [256 ,GCRY_CIPHER_SERPENT256])]
    [camellia ([128 ,GCRY_CIPHER_CAMELLIA128]
               [192 ,GCRY_CIPHER_CAMELLIA192]
               [256 ,GCRY_CIPHER_CAMELLIA256])]
    [des      ([64 ,GCRY_CIPHER_DES])] ;; takes key as 64 bits, high bits ignored
    [des-ede3 ([192 ,GCRY_CIPHER_3DES])] ;; takes key as 192 bits, high bits ignored
    ;; [rc4   ([??? ,GCRY_CIPHER_ARCFOUR])]
    ;; [idea  ([??? ,GCRY_CIPHER_IDEA])]
    ))

(define modes
  `(;[Mode ModeId]
    [ecb    ,GCRY_CIPHER_MODE_ECB]
    [cfb    ,GCRY_CIPHER_MODE_CFB]
    [cbc    ,GCRY_CIPHER_MODE_CBC]
    [ofb    ,GCRY_CIPHER_MODE_OFB]
    [ctr    ,GCRY_CIPHER_MODE_CTR]
    [stream ,GCRY_CIPHER_MODE_STREAM]))

;; ----------------------------------------

(define random-impl%
  (class* object% (random-impl<%>)
    (super-new)
    (define/public (random-bytes! who buf start end)
      ;; FIXME: better mapping to quality levels
      (gcry_randomize (ptr-add buf start) (- end start) GCRY_STRONG_RANDOM))
    (define/public (pseudo-random-bytes! who buf start end)
      (gcry_randomize (ptr-add buf start) (- end start) GCRY_STRONG_RANDOM))
    ))

(define random-impl (new random-impl%))

;; ----------------------------------------

(define gcrypt-factory%
  (class* object% (#|factory<%>|#)
    (super-new)

    (define digest-table (make-hasheq))
    (define cipher-table (make-hash))

    (define/private (intern-digest spec)
      (cond [(hash-ref digest-table spec #f)
             => values]
            [(assq spec digests)
             => (lambda (entry)
                  (match entry
                    [(list _ algid blocksize)
                     (and (gcry_md_test_algo algid)
                          (let ([di (new digest-impl%
                                         (md algid)
                                         (spec spec)
                                         (blocksize blocksize))])
                            (hash-set! digest-table spec di)
                            di))]
                    [_ #f]))]
            [else #f]))

    (define/private (intern-cipher spec)
      (cond [(hash-ref cipher-table spec #f)
             => values]
            [(and (assq (cadr spec) modes)
                  (assq (car spec) ciphers))
             => (lambda (entry)
                  (match entry
                    [(list _ keylens+algids)
                     (let ([ci (new multikeylen-cipher-impl%
                                    (spec spec)
                                    (impls
                                     (for/list ([keylen+algid (in-list keylens+algids)])
                                       (cons (quotient (car keylen+algid) 8)
                                             (new cipher-impl%
                                                  (spec spec)
                                                  (cipher (cadr keylen+algid))
                                                  (mode (cadr (assq (cadr spec) modes))))))))])
                       (hash-set! cipher-table spec ci)
                       ci)]
                    [_ #f]))]
            [else #f]))

    ;; ----

    (define/public (get-digest-by-name name)
      (intern-digest name))
    (define/public (get-cipher-by-name name)
      (intern-cipher name))
    (define/public (get-random)
      random-impl)
    ))

(define gcrypt-factory (new gcrypt-factory%))