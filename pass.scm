

(declare (unit pass)
         (uses nodes munch utils))

(use matchable)
(use srfi-1)

(include "class-syntax")

;; do some macro expansion

(define (expand e)
   (match e
     (('let (bindings ...) body ...)
      (expand
       `((lambda ,(map car bindings)
           (begin ,@body))
         ,@(map (lambda (binding) (car (cdr binding))) bindings))))
     (('begin) '())
     (('begin body)
      (expand body))
     (('begin body1 body2 ...)
      (expand
       (let ((a (gensym)))
         `((lambda (,a)
             (begin ,@body2)) ,body1))))
     (('or) #f)         
     (('or clause)
      (expand
       (let ((a (gensym)))
         `(let ((,a ,clause))
            (if ,a ,a ,a)))))
     (('or clause1 clause2 ...)
      (expand
       (let ((a (gensym)))
         `(let ((,a ,clause1))
            (if ,a
                ,a
                (or ,@clause2))))))
     (('and) #t)
     (('and clause)
      (expand
       (let ((a (gensym)))
         `(let ((,a ,clause))
            (if ,a ,a ,a)))))
     (('and clause1 clause2 ...)
      (expand
       (let ((a (gensym)))
         `(let ((,a ,clause1))
            (if ,a
                (and ,@clause2)
                ,a)))))
     (('lambda (bindings ...) e1 e2 rest ...)
      (expand `(lambda (,@bindings)
                 (begin ,e1 ,e2 ,@rest))))
     ((combination ...)
      (map expand combination))
     (_ e)))


;; convert to high-level AST
;;
  
(define *primitives*
  '(fx+ fx- fx* fx/ fx< fx> fx<= fx>= fx= car cdr cons null? pair? list? boolean? integer? string?))

(define (primitive? op)
  (if (memq op *primitives*) #t #f))

(define (convert-source e)
  (define (cs e)
    (match e
      (('if x y)
       (make-if (cs x) (cs y) '()))
      (('if x y z)
       (make-if (cs x) (cs y) (cs z)))
      (('if _ ...)
       (error cs "ill-formed conditional expression"))
      (('lambda (bindings ...) body)
       (make-lambda (gensym 'f) bindings (cs body) '()))
      (('lambda _ ...)
       (error cs "ill-formed conditional expression"))
      ((? null?)
       (make-constant e))
      ((? boolean?)
       (make-constant e))
      ((? number?)
       (make-constant e))
      ((_ ...)
       (make-comb (map cs e)))
      ((? symbol?)
       (make-variable e))))
  (cs e))


(define select-matching
  (lambda (fn lst)
    (reverse
     (fold (lambda (x acc)
             (if (fn x)
                 (cons x acc)
                 acc))
           (list)
           lst))))

(define (find-mapping name scopes)
  (let f ((scopes scopes))
    (if (null? scopes)
        (if (primitive? name)
            name
            (error 'alpha-convert "symbol not found" name))
        (let ((mapping (assq name (car scopes))))
          (if mapping
              (cdr mapping)
              (f (cdr scopes)))))))

(define (alpha-convert node)
  (define (alpha-convert node scopes)
    (struct-case node
      ((lambda name args body)
       (let ((mappings (map (lambda (arg) (cons arg (gensym 't))) args)))
         (make-lambda
           name
           (map cdr mappings)
           (alpha-convert body (cons mappings scopes))
           '())))
      ((if test conseq altern)
       (make-if
         (alpha-convert test scopes)
         (alpha-convert conseq scopes)
         (alpha-convert altern scopes)))
      ((prim name args cexp)
       (make-prim
         name
         (map (lambda (arg) (alpha-convert arg scopes)) args)
         (alpha-convert cexp scopes)))
      ((comb args)
       (make-comb
         (map (lambda (arg) (alpha-convert arg scopes)) args)))
      ((variable name)
       (make-variable (find-mapping name scopes)))
      (else node)))
  (alpha-convert node (list)))

(define (cps-convert node)
  (define (cps-convert node cont)
    (struct-case node
      ((constant)
       (if (null? cont)
           node
           (make-comb (list cont node))))
      ((variable)
       (if (null? cont)
           node
           (make-comb (list cont node))))
      ((lambda name args body)
       (let* ((cn (gensym 'c))
              (node-cps (make-lambda
                          name
                          `(,@args ,cn)
                          (cps-convert body (make-variable cn))
                          '())))
         (if (null? cont)
             node-cps
             (make-comb (list cont node-cps)))))
      ((comb args)
       ;; x - combination args
       ;; y - new args for combination (x -> y)
       ;; z - args which are not atoms
       ;; w - names for continuations
       (let f ((x args) (y '()) (z '()) (u '()) (w '()))
         (cond
          ((null? x)
           (let g ((form (make-comb (reverse (cons cont y)))) (y y) (z z) (u u) (w w))
             (if (null? z)
                 form
                 (g
                  (cps-convert (car z)
                               (make-lambda
                                 (car w)
                                 (list (car u))
                                 form
                                 '()))
                  (cdr y)
                  (cdr z)
                  (cdr u)
                  (cdr w)))))
          ((constant? (car x))
           (f (cdr x) (cons (car x) y) z u w))
          ((variable? (car x))
           (f (cdr x) (cons (car x) y) z u w))
          ((lambda? (car x))
           (f (cdr x) (cons (cps-convert (car x) '()) y) z u w))
          (else
           (let ((nm (gensym 't)))
             (f (cdr x) (cons (make-variable nm) y) (cons (car x) z) (cons nm u) (cons (gensym 't) w)))))))
      ((if test conseq altern)
       (let ((kn (gensym 't))
             (fn (gensym 'f))
             (cn (gensym 'f))
             (tn (gensym 't)))
         (make-comb
           (list (make-lambda fn (list kn)
                       (cps-convert test
                                    (make-lambda cn (list tn)
                                          (make-if
                                            (make-variable tn)
                                            (cps-convert conseq (make-variable kn))
                                            (cps-convert altern (make-variable kn)))
                                          '()))
                       '())
                 cont))))
      (else (error 'cps-convert "not an AST node" node))))
  (let ((cn (gensym 'f))
        (tn (gensym 't)))
    (cps-convert
      node
      (make-lambda cn (list tn)
            (make-prim
              (make-variable 'return)
              (list (make-variable tn))
              (make-variable tn) (make-nil))
            '()))))

(define (identify-primitives cexp)
  (struct-case cexp
    ((variable)
     cexp)
    ((constant)
     cexp)
    ((if test conseq altern)
     (make-if
        (identify-primitives test)
        (identify-primitives conseq)
        (identify-primitives altern)))
    ((lambda name args body)
     (make-lambda
      name
      args
      (identify-primitives body)
      '()))
    ((comb args)
     (if (and (variable? (car args)) (primitive? (variable-name (car args))))
         (let* ((cont (car (reverse args)))
                (result (cond
                         ((lambda? cont)
                          (make-variable (car (lambda-args cont))))
                         ((variable? cont)
                          (make-variable (gensym 't)))
                         (else (error 'identify-primitives))))
                (new-cont (cond
                           ((lambda? cont)
                            (identify-primitives (lambda-body cont)))
                           ((variable? cont)
                            (make-app cont (list result)))
                           (else (error 'identify-primitives)))))
           (make-prim
             (car args)
             (cdr (reverse (cdr args)))
             result
             new-cont))
         (make-app (identify-primitives (car args)) (map identify-primitives (cdr args)))))
      ((prim)
       cexp)
      (else (error 'identify-primitives "not an AST node" cexp))))


(define (basic-lambda-lift node)
  ;; raise all lambda definitions to the top of the this lambda body
  (define (filter lst)
    (select-matching
      (lambda (x)
        (lambda? x))
      lst))
  (define (collect node)
    ;; collect nested lambda nodes in this scope
    (struct-case node
      ((lambda)
       (list node))
      ((prim name args result cexp)
       (append (filter args) (collect cexp)))
      ((if test conseq altern)
       (append (collect test) (collect conseq) (collect altern)))
      ((app name args)
       (filter (cons name args)))
      (else (list))))
  (define (rewrite node)
    ;; rewrite tree, replacing lambda nodes with their names
    (struct-case node
      ((lambda name)
       (make-variable name))
      ((prim name args result cexp)
       (make-prim name (map rewrite args) result (rewrite cexp)))
      ((if test conseq altern)
       (make-if (rewrite test) (rewrite conseq) (rewrite altern)))
      ((app name args)
       (make-app (rewrite name) (map rewrite args)))
      (else node)))
  (define (normalize node)
    (if (lambda? node)
        (let* ((name (lambda-name node))
               (args (lambda-args node))
               (body (lambda-body node))
               (defs (map normalize (collect body))))
          (if (null? defs)
              node
              (make-lambda name args (make-fix defs (rewrite body)) '())))
        (let* ((name (gensym 'f))
               (args (list))
               (body node)
               (defs (map normalize (collect body))))
          (if (null? defs)
              node
              (make-lambda name args (make-fix defs (rewrite body)) '())))))
  (let ((node (normalize node)))
    (make-fix (list node)
          (make-app
            (make-variable (lambda-name node)) (list)))))


(define (analyze-free-vars node)
  (let ((union (lambda lists
                 (apply lset-union (cons eq? lists))))
        (diff  (lambda lists
                 (apply lset-difference (cons eq? lists)))))
    (struct-case node
      ((variable name)
       (diff (list name) *primitives*))
      ((constant) '())
      ((if test conseq altern)
       (union
        (analyze-free-vars test)
        (analyze-free-vars conseq)
        (analyze-free-vars altern)))
      ((app name args)
       (let f ((x '()) (args (cons name args)))
         (if (null? args)
             x
             (f (union x (analyze-free-vars (car args))) (cdr args)))))
      ((prim name args result cexp)
       (let f ((x (list)) (args args))
         (if (null? args)
             (union x (diff (analyze-free-vars cexp) (list (variable-name result))))
             (f (union x (analyze-free-vars (car args))) (cdr args)))))
      ((fix defs body)
       (apply union (append (map analyze-free-vars defs)
                            (list (diff (analyze-free-vars body)
                                        (map (lambda (def)
                                               (lambda-name def))
                                             defs))))))
      ((lambda name args body)
       (lambda-free-vars-set! node
                              (diff (analyze-free-vars body) args))
       (lambda-free-vars node))
      ((label)
       (list))
      ((nil)
       (list))
      (else (error 'analyze-free-vars "not an AST node" node)))))

(define (closure-index name names)
  (let f ((i 1) (names names))
    (if (null? names)
        (error "should not reach here") 
        (if (eq? name (car names))
            i
            (f (+ i 1) (cdr names))))))


(define (primitive-application args)
  (let ((fun (car args)))
    (if (memq (variable-name fun) *primitives*)
        (error 'primitive-application "should not reach here" (variable-name fun))
        (let ((fn (gensym 't)))
          (make-select 0 fun (make-variable fn)
                (make-app (make-variable fn) (cons fun (cdr args))))))))

;;
;; assume all functions escape -> each function takes a closure arg
;; optimize application of known functions by jumping directly to the function's label instead of using the function ptr stored in the function's closure. 
;;

#| * 1. create closure record for each lambda
   * 2. In fix body, replace each lambda reference (those not in the operator position) with closure reference
   * 3. rewrite lambda applications. Extract function label from closure and apply function to closure + args
 |#

(define (closure-convert-body node c-name free-vars)
  (struct-case node
    ((fix defs body)
     (let ((old-names (map (lambda (def)
                             (lambda-name def))
                           defs))
           (x (map (lambda (def)
                     (closure-convert-body def c-name free-vars))
                   defs)))
       (make-fix
         x       
         (closure-convert-body
          (let f ((x x) (y old-names) (form body))
            (if (null? x)
                form
                (f (cdr x)
                   (cdr y)
                   #| when making the closure record, we use a label node to represent the lambda's function ptr |#
                   (make-record
                     (cons (make-label (lambda-name (car x)))
                           (map (lambda (v) (make-variable v))
                                (lambda-free-vars (car x))))
                     (make-variable (car y))
                     form))))
          c-name free-vars))))
    ((lambda name args body free-vars)
     (let* ((cn (gensym 'c))
            (converted (make-lambda (gensym 'f) (cons cn args) (closure-convert-body body cn free-vars) '())))
       (lambda-free-vars-set! converted free-vars)
       converted))
    ((app name args)
     (let f ((x (cons name args)) (y '()) (z '()))
       (cond
        ((null? x)
         (let g ((cexp (primitive-application (reverse y))) (z z))
           (if (null? z)
               cexp
               (g (make-select
                    (closure-index (caar z) free-vars)
                    (make-variable c-name)
                    (make-variable (cdar z))
                    cexp)
                  (cdr z)))))
         ((variable? (car x))
          (let ((name (variable-name (car x))))
            (if (memq name free-vars)
                (let ((exists (assq name z)) (temp (gensym 't)))   
                  (if exists
                    (f (cdr x) (cons (make-variable (cdr exists)) y) z)
                    (f (cdr x) (cons (make-variable temp) y) (cons (cons name temp) z))))
                (f (cdr x) (cons (car x) y) z))))
         (else (f (cdr x) (cons (closure-convert-body (car x) #f '()) y) z)))))
   ((prim name args result cexp)
     (let f ((x args) (y (list)) (z (list)))
       (if (null? x)
           (let g ((cexp (make-prim name (reverse y) result (closure-convert-body cexp c-name free-vars))) (z z))
             (if (null? z)
                 cexp
                 (g (make-select
                      (closure-index (caar z) free-vars)
                      (make-variable c-name)
                      (make-variable (cdar z))
                      cexp)
                    (cdr z))))
           (if (variable? (car x))
               (let ((name (variable-name (car x))))
                 (if (memq name free-vars)
                     (let ((exists (assq name z)) (temp (gensym 't)))   
                       (if exists
                    (f (cdr x) (cons (make-variable (cdr exists)) y) z)
                    (f (cdr x) (cons (make-variable temp) y) (cons (cons name temp) z))))
                     (f (cdr x) (cons (car x) y) z)))
               (f (cdr x) (cons (closure-convert-body (car x) #f '()) y) z)))))
   ((record values name cexp)
     (let f ((x values) (y (list)) (z (list)))
       (if (null? x)
           (let g ((cexp (make-record (reverse y) name (closure-convert-body cexp c-name free-vars))) (z z))
             (if (null? z)
                 cexp
                 (g (make-select
                      (closure-index (caar z) free-vars)
                      (make-variable c-name)
                      (make-variable (cdar z))
                      cexp)
                    (cdr z))))
           (struct-case (car x)
             ((variable name)
              (if (memq name free-vars)
                  (let ((exists (assq name z)) (temp (gensym 't)))
                    (if exists
                        (f (cdr x) (cons (make-variable (cdr exists)) y) z)
                        (f (cdr x) (cons (make-variable temp) y) (cons (cons name temp) z))))
                  (f (cdr x) (cons (car x) y) z)))
             ((label name)
              (f (cdr x) (cons (car x) y) z))
             (else (error 'closure-convert-body (car x)))))))
    ((variable name)
     (if (memq name free-vars)
         (let ((temp (gensym 't)))
           (make-select
             (closure-index name free-vars)
             (make-variable c-name)
             (make-variable temp)
             (make-variable temp)))
         node))
    ((if test conseq altern)
     (make-if
       (closure-convert-body test c-name free-vars)
       (closure-convert-body conseq c-name free-vars)
       (closure-convert-body altern c-name free-vars)))
    ((constant)
     node)
    ((label)
     node)
    ((nil)
     node)
    (else (error 'closure-convert "node" node))))

(define (closure-convert node)
  (analyze-free-vars node)
  (closure-convert-body node #f '()))

(define (flatten node)
  (letrec ((queue (list))
           (queue-push! (lambda (node)
                          (set! queue
                                (append queue (list node)))))
           (queue-pop!  (lambda ()
                          (let ((front (car queue)))
                            (set! queue
                                  (cdr queue))
                           front)))
           (queue-empty? (lambda ()
                           (null? queue)))
           (flatten-node (lambda (node)
                           (struct-case node
                             ((fix defs body)
                              (let f ((x defs))
                                (if (null? x) 
                                    body
                                    (begin
                                      (queue-push! (car x))
                                      (f (cdr x))))))
                             (else node)))))
    (map queue-push! (fix-defs node))
    (let f ((labels (list)))
      (if (queue-empty?)
          (make-fix labels (fix-body node))
          (let* ((node (queue-pop!)))
            (f (cons (make-lambda
                       (lambda-name node)
                       (lambda-args node)
                       (flatten-node (lambda-body node))
                       '())
                     labels)))))))


(define (rtl-convert-lambda node)

  (define (V e)
    (struct-case e
      ((constant value)
       (immediate-rep value))
      ((variable name)
       name)
      ((label name)
       `(label ,name))
      (else e)))

  (define sn
    (lambda (op . args)
      (make-selection-node op args)))

  (define (rtl-convert-node node)
    (struct-case node
      ((select index record name cexp)
       (append
        (let* ((t1 (sn 'ldq (V record) (* index 8)))
               (t2 (sn 'mov t1 (V name))))
          (list t2))
        (rtl-convert-node cexp)))
      ((record values name cexp)
       (append
        (let f ((v values) (trees '()) (i 0))
          (if (null? v)
              (cons
               (sn 'alloc (V name) (* (length values) 8)) 
               (reverse trees))
              (f (cdr v)
                 (cons
                  (sn 'stq (V (car v)) (V name) (* i 8))
                  trees)
                 (+ i 1))))
        (rtl-convert-node cexp)))
      ((app name args)
       (list (sn 'call (V name) (map V args)) (list)))
      ((nil)
       (list))
      ((if test conseq altern)
       (let* ((LT (convert-basic-block conseq (gensym 'L)))
              (LF (convert-basic-block altern (gensym 'L)))
              (t1 (sn 'cmpeq (V test) (immediate-rep #f)))
              (t2 (sn 'brc t1 `(label ,LT) `(label ,LF))))
         (list t2 (list LT LF))))
      ((prim name args result cexp)
       (append
        (case (variable-name name)
          ((fx+)
           (match-let (((e1 e2) args))
             (let* ((t1 (sn 'shr 2 (V e1)))
                    (t2 (sn 'shr 2 (V e2)))
                    (t3 (sn 'add t1 t2))
                    (t4 (sn 'shl 2 t3))
                    (t5 (sn 'or  *fixnum-shift* t4))
                    (t6 (sn 'mov t5 (V result))))
               (list t6))))
          ((fx-)
           (match-let (((e1 e2) args))
             (let* ((t1 (sn 'shr 2 (V e1)))
                    (t2 (sn 'shr 2 (V e2)))
                    (t3 (sn 'sub t1 t2))
                    (t4 (sn 'shl 2 t3))
                    (t5 (sn 'or  *fixnum-shift* t4))
                    (t6 (sn 'mov t5 (V result))))
               (list t6))))
          ((fx<=)
           (match-let (((e1 e2) args))
             (let* ((t1 (sn 'shr 2 (V e1)))
                    (t2 (sn 'shr 2 (V e2)))
                    (t3 (sn 'cmple t1 t2))
                    (t4 (sn 'shl *boolean-shift* t3))
                    (t5 (sn 'or *boolean-tag* t4))
                    (t6 (sn 'mov t5 (V result))))
               (list t6))))
          ((return)
           (list (sn 'call `(label EXIT)  '()) (list)))
          (else
           (error)))
        (rtl-convert-node cexp)))
      (else (error 'rtl-convert-node node))))
  
  (define basic-blocks (list))

  (define (convert-basic-block node label)
    (match (rtl-convert-node node)
      ((instr* ... (successor* ...))
       (set! basic-blocks
             (cons (list label successor* instr*)
                  basic-blocks))
        label)
      (_ (error 'convert-basic-block))))

  (struct-case node
    ((lambda name args body free-vars)
     (convert-basic-block body name)
     (make-context args (caar basic-blocks) basic-blocks))
    (else (error 'rtl-convert-lambda))))

(define (rtl-convert node)
  (struct-case node
    ((fix defs body)
     (let ((definitions (cons (make-lambda 'MAIN '() body '()) defs)))
       (make-module
        (map rtl-convert-lambda definitions))))
    (else (error 'rtl-convert node))))

(define (select-instructions module)
  (struct-case module
    ((module contexts)
     (make-module
      (map select-instructions-for-context contexts)))
    (else (error 'select-instructions))))

(define (select-instructions-for-context context)
  (struct-case context
    ((context formals start blocks)
     (make-context formals start
       (map (lambda (block)
              (match block
                ((label (successors* ...) instr*)
                 (let* ((instructions (box '())))
                   (for-each
                    (lambda (stm)
                      (munch-expr stm instructions))
                    instr*)
                   (list label successors* (box-ref instructions))))))
            blocks)))
    (else (error 'select-instructions-for-context))))

(define *fixnum-shift*    2)
(define *fixnum-mask*   #x3)
(define *fixnum-tag*    #x0)

(define *boolean-shift*   3)
(define *boolean-mask*  #x7)
(define *boolean-tag*   #x3)

(define *null-value*    #x1)

(define (immediate-rep x)
  (cond
   ((integer? x)
    (bitwise-ior
      (arithmetic-shift x *fixnum-shift*)
      *fixnum-tag*))
   ((boolean? x)
    (bitwise-ior
      (arithmetic-shift (if x 1 0) *boolean-shift*)
      *boolean-tag*))
    ((null? x)
     *null-value*)
   (else (error 'immediate-rep "type not recognized"))))




    
 