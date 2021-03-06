(defmacro curly-if-match (expr pattern then &optional else)
  "" (declare (indent 2))
  (cond
   ((or (keywordp pattern) (null pattern))
    `(if (eq ,pattern ,expr) ,then ,else))
   ((eq pattern '_) then)
   ((symbolp pattern)
    `(let ((,pattern ,expr)) ,then))
   ((consp pattern)
    (if (eq (car pattern) '@)
	`(let ((,(cadr pattern) ,expr)) (curly-if-match ,(cadr pattern) ,(car (cddr pattern)) ,then ,else))
      (let* ((var (if (symbolp expr) expr (make-symbol "var")))
	     (retv (make-symbol "--ret--"))
	     (body `(let (,retv)
		      (if (and (consp ,var) 
			       (curly-if-match (car ,var) ,(car pattern)
				 (curly-if-match (cdr ,var) ,(cdr pattern) (prog1 t (setq ,retv ,then)))))
			  ,retv
			,else))))
	(if (symbolp expr) body
	  `(let ((,var ,expr)) ,body)))))))

(defmacro curly-cond-match (expr &rest forms)
  "" (declare (indent 1))
  (if (null forms) nil
    (let* ((var (if (symbolp expr) expr (make-symbol "var")))
	   (body `(curly-if-match ,var ,(caar forms) (progn ,@(cdar forms)) (curly-cond-match ,var ,@(cdr forms)))))
      (if (symbolp expr) body
	`(let ((,var ,expr))
	   ,body)))))

(defmacro curly-lambda-match (&rest forms)
  (let ((var (make-symbol "var")))
    `(lambda (,var) (curly-cond-match ,var ,@forms))))

(defun curly-re-construct (&rest args)
  (curly-cond-match args
    (nil "")
    ((_ . _) (mapconcat
	      (curly-lambda-match
	       ((:many . e)
		(concat "\\(?:" (apply 'curly-re-construct e) "\\)*"))
	       ((:optional . e)
		(concat "\\(?:" (apply 'curly-re-construct e) "\\)?"))
	       ((:sep-by sep . e)
		(concat (apply 'curly-re-construct e)
			"\\(?:" (curly-re-construct sep) (apply 'curly-re-construct e) "\\)*"))
	       ((:or . e)
		(concat "\\(?:" (mapconcat 'curly-re-construct e "\\|") "\\)"))
	       ((:capture . e)
		(concat "\\(" (apply 'curly-re-construct e) "\\)"))
	       ((:partial e) (curly-re-construct e))
	       ((:partial e . es)
		(concat (curly-re-construct e) (curly-re-construct `(:optional (:partial . ,es)))))
	       (:bol "^")
	       (:eol "$")
	       (:bow "\\<")
	       (:eow "\\>")
	       (:word "\\<\\sw*[^[:blank:]:=]")
	       (:spc "\\s-*")
	       (:nbsp "\\s-+")
	       ((@ l (_ . _)) (apply 'curly-re-construct l))
	       (x x)
	       ) args ""))
    (_ args)))

(princ
 (curly-lambda-match
  ((:many . e)
   (concat "\\(?:" (apply 'curly-re-construct e) "\\)*"))
  ((:optional . e)
   (concat "\\(?:" (apply 'curly-re-construct e) "\\)?"))
  ((:sep-by sep . e)
   (concat (apply 'curly-re-construct e)
	   "\\(?:" (curly-re-construct sep) (apply 'curly-re-construct e) "\\)*"))
  ((:or . e)
   (concat "\\(?:" (mapconcat 'curly-re-construct e "\\|") "\\)"))
  ((:capture . e)
   (concat "\\(" (apply 'curly-re-construct e) "\\)"))
  ((:partial e) (curly-re-construct e))
  ((:partial e . es)
   (concat (curly-re-construct e) (curly-re-construct `(:optional (:partial . ,es)))))
  (:bol "^")
  (:eol "$")
  (:bow "\\<")
  (:eow "\\>")
  (:word "\\<\\sw*[^[:blank:]:=]")
  (:spc "\\s-*")
  (:nbsp "\\s-+")
  ((@ l (_ . _)) (apply 'curly-re-construct l))
  (x x)
  ))

(defmacro curly-regex (&rest args) (curly-re-construct args))
(defmacro curly-keyword (re &rest args)
  "" (declare (indent 1))
  `(list (curly-regex ,re) ,@args))

(provide 'curly-utils)
