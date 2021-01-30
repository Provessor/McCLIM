(in-package :clim-gtk)

(defmacro with-medium-mirror ((mirror-sym medium) &body body)
  (check-type mirror-sym symbol)
  (alexandria:once-only (medium)
    (alexandria:with-gensyms (mirror-copy-sym)
      `(let ((,mirror-copy-sym (sheet-direct-mirror (sheet-mirrored-ancestor (medium-sheet ,medium)))))
         (unless ,mirror-copy-sym
           (log:warn "Trying to use null mirror"))
         (when ,mirror-copy-sym
           (let ((,mirror-sym ,mirror-copy-sym))
             ,@body))))))

(defun update-mirror-if-needed (medium mirror)
  (let ((requested-width (gtk-mirror/requested-image-width mirror))
        (requested-height (gtk-mirror/requested-image-height mirror)))
    (when (and requested-width requested-height)
      (cairo:cairo-surface-destroy (gtk-mirror/image mirror))
      (setf (gtk-mirror/image mirror) (make-backing-image (medium-background medium) requested-width requested-height))
      (setf (gtk-mirror/requested-image-width mirror) nil)
      (setf (gtk-mirror/requested-image-height mirror) nil))))

(defmacro with-medium-cairo-image ((image-sym medium) &body body)
  (check-type image-sym symbol)
  (alexandria:once-only (medium)
    (alexandria:with-gensyms (mirror-sym image)
      `(with-medium-mirror (,mirror-sym ,medium)
         (let ((,image (bordeaux-threads:with-lock-held ((gtk-mirror/lock ,mirror-sym))
                         (update-mirror-if-needed ,medium ,mirror-sym)
                         (let ((,image (gtk-mirror/image ,mirror-sym)))
                           (cairo:cairo-surface-reference ,image)))))
           (unwind-protect
                (let ((,image-sym ,image))
                  ,@body)
             (cairo:cairo-surface-destroy ,image)))))))

(defun region->clipping-values (region)
  (with-bounding-rectangle* (min-x min-y max-x max-y) region
    ;; We don't use here round-coordinate because clipping rectangle
    ;; must cover the whole region. It is especially important when we
    ;; draw arcs (ellipses without filling) which are not drawn if any
    ;; part is outside the clipped area. -- jd 2019-06-17
    (let ((clip-x (floor min-x))
          (clip-y (floor min-y)))
      (values clip-x
              clip-y
              (- (ceiling max-x) clip-x)
              (- (ceiling max-y) clip-y)))))

(defun clipping-region->rect-seq (clipping-region)
  (typecase clipping-region
    (area (multiple-value-list (region->clipping-values clipping-region)))
    (t (loop
         for region in (nreverse (mapcan
                                  (lambda (v) (unless (eq v +nowhere+) (list v)))
                                  (region-set-regions clipping-region :normalize :y-banding)))
         nconcing (multiple-value-list (region->clipping-values region))))))

(defun set-clipping-region (cr medium)
  (cairo:cairo-reset-clip cr)
  (let ((clipping-region (climi::medium-device-region medium)))
    (typecase clipping-region
      (climi::nowhere-region
       (cairo:cairo-rectangle cr 0 0 1 1)
       (cairo:cairo-clip cr))
      (clim:standard-rectangle
       (multiple-value-bind (x1 y1 width height)
           (region->clipping-values clipping-region)
         (cairo:cairo-rectangle cr x1 y1 width height)
         (cairo:cairo-clip cr)))
      (climi::standard-rectangle-set
       (let ((se (clipping-region->rect-seq clipping-region)))
         (loop
           for (x y width height) on se by (lambda (sequence) (nthcdr 4 sequence))
           do (cairo:cairo-rectangle cr x y width height)
           finally (cairo:cairo-clip cr))))
      (t
       (break)))))

(defun call-with-computed-transformation (tr fn)
  (unless (eq tr 'clim:+identity-transformation+)
    (multiple-value-bind (mxx mxy myx myy tx ty)
        (climi::get-transformation tr)
      (cffi:with-foreign-object (matrix '(:struct cairo::cairo-matrix-t))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::xx) (coerce mxx 'double-float))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::xy) (coerce mxy 'double-float))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::yx) (coerce myx 'double-float))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::yy) (coerce myy 'double-float))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::x0) (coerce tx 'double-float))
        (setf (cffi:foreign-slot-value matrix '(:struct cairo::cairo-matrix-t) 'cairo::y0) (coerce ty 'double-float))
        (funcall fn matrix)))))

(defgeneric context-apply-ink (cr ink))

(defun apply-colour-from-ink (cr ink)
  (check-type ink clim:color)
  (multiple-value-bind (red green blue alpha)
       (clime::color-rgba ink)
    (cairo:cairo-set-source-rgba cr red green blue alpha)))

(defun resolve-indirect-ink (ink)
  (etypecase ink
    (clim:color ink)
    (clime:indirect-ink (clime:indirect-ink-ink ink))))

(defmethod context-apply-ink (cr (ink clim:color))
  (apply-colour-from-ink cr ink))

(defmethod context-apply-ink (cr (ink climi::standard-flipping-ink))
  (apply-colour-from-ink cr (resolve-indirect-ink (slot-value ink 'climi::design1)))
  (cairo:cairo-set-operator cr :over))

(defmethod context-apply-ink (cr (ink clime:indirect-ink))
  (context-apply-ink cr (clime:indirect-ink-ink ink)))

(defmethod context-apply-ink (cr (ink clime:transformed-design))
  (let ((transformation (clime:transformed-design-transformation ink)))
    (apply-pattern cr (clime:transformed-design-design ink) transformation)))

(defmethod context-apply-ink (cr (pattern clime:pattern))
  (apply-pattern cr pattern nil))

(defmethod context-apply-ink :around (cr pattern)
  (handler-bind ((error (lambda (condition)
                          (log:info "Got error: ~a" condition)
                          (break))))
    (call-next-method)))

(defun apply-pattern (cr pattern transform)
  (let* ((width (truncate (clim:pattern-width pattern)))
         (height (truncate (clim:pattern-height pattern)))
         (data (climi::pattern-array pattern)))
    (assert (and (= height (array-dimension data 0))
                 (= width (array-dimension data 1))))
    #+nil
    (cffi:with-foreign-array (native-buf (make-array (* height width)
                                                     :element-type (array-element-type data)
                                                     :displaced-to data)
                                         `(:array :uint32 ,(* height width)))
      (let ((image (cairo:cairo-image-surface-create-for-data native-buf :argb32 width height (* width 4))))
        (cairo:cairo-set-source-surface cr image 0 0)))
    (let ((image (cairo:cairo-image-surface-create :argb32 width height)))
      (loop
        with image-data = (cairo:cairo-image-surface-get-data image)
        with stride-in-words = (let ((v (/ (cairo:cairo-image-surface-get-stride image) 4)))
                                 (assert (integerp v))
                                 v)
        for y of-type fixnum from 0 below height
        do (loop
             for x of-type fixnum from 0 below width
             do (setf (cffi:mem-aref image-data :uint32 (+ (* y stride-in-words) x))
                      (logior (aref data y x) #xff000000))))
      (cairo:cairo-surface-mark-dirty image)
      (let ((cairo-pattern (cairo:cairo-pattern-create-for-surface image)))
        (when transform
          (call-with-computed-transformation transform
                                             (lambda (matrix)
                                               (cairo:cairo-pattern-set-matrix cairo-pattern matrix))))
        (cairo:cairo-set-source cr cairo-pattern))
      (cairo:cairo-surface-destroy image))))

(defun update-attrs (cr medium)
  (set-clipping-region cr medium)
  (context-apply-ink cr (medium-ink medium))
  (let ((line-style (medium-line-style medium)))
    (cairo:cairo-set-line-width cr (line-style-thickness line-style))
    (cairo:cairo-set-line-join cr (ecase (line-style-joint-shape line-style)
                                    (:miter :miter)
                                    (:round :round)
                                    (:bevel :bevel)
                                    (:none :miter)))))

(defun call-with-cairo-context (medium update-style transform fn)
  (with-medium-cairo-image (image medium)
    (let ((context (cairo:cairo-create image)))
      (unwind-protect
           (progn
             (when update-style
               (update-attrs context medium))
             (cond
               ((eq transform t)
                (call-with-computed-transformation (sheet-native-transformation (medium-sheet medium))
                                                   (lambda (matrix)
                                                     (cairo:cairo-set-matrix context matrix))))
               (transform
                (call-with-computed-transformation transform
                                                   (lambda (matrix)
                                                     (cairo:cairo-set-matrix context matrix)))))
             (funcall fn context))
        (cairo:cairo-destroy context)))))

(defmacro with-cairo-context ((context-sym medium &key (update-style t) (transform nil)) &body body)
  (check-type context-sym symbol)
  (alexandria:once-only (medium update-style transform)
    `(call-with-cairo-context ,medium ,update-style ,transform
                              (lambda (,context-sym) ,@body))))

(defun call-with-fallback-cairo-context (port fn)
  (let* ((image (gtk-port/image-fallback port))
         (context (cairo:cairo-create image)))
    (unwind-protect
         (funcall fn context)
      (cairo:cairo-destroy context))))

(defmacro with-fallback-cairo-context ((context-sym port) &body body)
  (alexandria:once-only (port)
    `(call-with-fallback-cairo-context ,port (lambda (,context-sym) ,@body))))

(defun call-with-cairo-context-measure (medium fn)
  (let ((image (alexandria:if-let ((mirror (sheet-direct-mirror (sheet-mirrored-ancestor (medium-sheet medium)))))
                 (bordeaux-threads:with-lock-held ((gtk-mirror/lock mirror))
                   (let ((image (gtk-mirror/image mirror)))
                     (cairo:cairo-surface-reference image)))
                 ;; ELSE: No mirror, use the dedicated image
                 (let ((image (gtk-port/image-fallback (port medium))))
                   (cairo:cairo-surface-reference image)))))
    (unwind-protect
         (let ((context (cairo:cairo-create image)))
           (unwind-protect
                (funcall fn context)
             (cairo:cairo-destroy context)))
      (cairo:cairo-surface-destroy image))))

(defmacro with-cairo-context-measure ((context-sym medium) &body body)
  (check-type context-sym symbol)
  (alexandria:once-only (medium)
    `(call-with-cairo-context-measure ,medium (lambda (,context-sym) ,@body))))

(defclass gtk-medium (font-rendering-medium-mixin basic-medium)
  ((buffering-output-p :accessor medium-buffering-output-p)))

(defclass gtk-medium-font ()
  ((port             :initarg :port
                     :initform (alexandria:required-argument :port)
                     :reader gtk-medium-font/port)
   (font-description :initarg :font-description
                     :reader gtk-medium-font/font-description)))

(defun set-current-font (layout font)
  (pango:pango-layout-set-font-description layout (gtk-medium-font/font-description font)))

(defmethod climi::open-font ((port gtk-port) font-designator)
  (break)
  (make-instance 'gtk-medium-font))

(defmethod text-style-mapping ((port gtk-port) (text-style text-style) &optional character-set)
  (declare (ignore character-set))
  (multiple-value-bind (family face size)
      (text-style-components text-style)
    (let ((desc (pango:pango-font-description-new)))
      (cond
        ((stringp family)
         (pango:pango-font-description-set-family desc family))
        ((eq family :fix)
         (pango:pango-font-description-set-family desc "Monospace"))
        ((eq family :sans-serif)
         (pango:pango-font-description-set-family desc "DejaVu Sans"))
        ((eq family :serif)
         (pango:pango-font-description-set-family desc "DejaVu Serif"))
        (t (pango:pango-font-description-set-family desc "DejaVu Sans")))
      (dolist (f (alexandria:ensure-list face))
        (case f
          (:roman
           (pango:pango-font-description-set-style desc :normal))
          (:italic
           (pango:pango-font-description-set-style desc :italic))
          (:bold
           (pango:pango-font-description-set-weight desc :bold))
          ((t)
           nil)))
      (when size
        (let ((size-num (coerce (* (climb:normalize-font-size size) pango:+pango-scale+) 'double-float)))
          (pango:pango-font-description-set-absolute-size desc size-num)))
      (make-instance 'gtk-medium-font :port port :font-description desc))))

(defmethod (setf text-style-mapping) (font-name
                                      (port gtk-port)
                                      (text-style text-style)
                                      &optional character-set)
  (declare (ignore font-name text-style character-set))
  (error "Can't set mapping"))

#+nil ; FIXME: PIXMAP class
(progn
  (defmethod medium-copy-area ((from-drawable gtk-medium)
			       from-x from-y width height
			       (to-drawable pixmap)
			       to-x to-y)
    (declare (ignore from-x from-y width height to-x to-y))
    nil)

  (defmethod medium-copy-area ((from-drawable pixmap)
			       from-x from-y width height
			       (to-drawable gtk-medium)
			       to-x to-y)
    (declare (ignore from-x from-y width height to-x to-y))
    nil)

  (defmethod medium-copy-area ((from-drawable pixmap)
			       from-x from-y width height
			       (to-drawable pixmap)
			       to-x to-y)
    (declare (ignore from-x from-y width height to-x to-y))
    nil))

#+nil
(defmethod text-style-ascent (text-style (medium gtk-medium))
  (declare (ignore text-style))
  20)

#+nil
(defmethod text-style-descent (text-style (medium gtk-medium))
  (declare (ignore text-style))
  5)

#+nil
(defmethod text-style-height (text-style (medium gtk-medium))
  (+ (text-style-ascent text-style medium)
     (text-style-descent text-style medium)))

#+nil
(defmethod text-style-character-width (text-style (medium gtk-medium) char)
  (declare (ignore text-style char))
  10)

#+nil
(defmethod text-style-width (text-style (medium gtk-medium))
  (text-style-character-width text-style medium #\m))

(defun measure-text-bounds-from-font (cr string font)
  (let ((layout (pango:pango-cairo-create-layout cr)))
    ;; LAYOUT has no g-object-unref...
    (set-current-font layout font)
    (pango:pango-layout-set-text layout string)
    (multiple-value-bind (ink-rect logical-rect)
        (pango:pango-layout-get-pixel-extents layout)
      (let ((baseline (/ (pango:pango-layout-get-baseline layout) pango:+pango-scale+)))
        (values ink-rect logical-rect baseline)))))

(defun measure-text-bounds (medium string text-style)
  (with-cairo-context-measure (cr medium)
    (let ((font (clim:text-style-mapping (port medium) (or text-style (clim:medium-text-style medium)))))
      (measure-text-bounds-from-font cr string font))))

(defmethod climb:font-ascent ((font gtk-medium-font))
  (with-fallback-cairo-context (cr (gtk-medium-font/port font))
    (multiple-value-bind (ink-rect logical-rect baseline)
        (measure-text-bounds-from-font cr "A" font)
      (declare (ignore ink-rect))
      (- baseline (pango:pango-rectangle-y logical-rect)))))

(defmethod climb:font-descent ((font gtk-medium-font))
  (with-fallback-cairo-context (cr (gtk-medium-font/port font))
    (multiple-value-bind (ink-rect logical-rect baseline)
        (measure-text-bounds-from-font cr "g" font)
      (declare (ignore ink-rect))
      (- (+ (pango:pango-rectangle-y logical-rect) (pango:pango-rectangle-height logical-rect)) baseline))))

(defmethod climb:font-character-width ((font gtk-medium-font) character)
  (with-fallback-cairo-context (cr (gtk-medium-font/port font))
    (multiple-value-bind (ink-rect logical-rect baseline)
        (measure-text-bounds-from-font cr (string character) font)
      (declare (ignore ink-rect baseline))
      (pango:pango-rectangle-width logical-rect))))

(defmethod text-size ((medium gtk-medium) string &key text-style (start 0) end)
  (setf string (etypecase string
		 (character (string string))
		 (string string)))
  (let ((fixed-string (subseq string (or start 0) (or end (length string)))))
    (multiple-value-bind (ink-rect logical-rect baseline)
        (measure-text-bounds medium fixed-string text-style)
      (values (pango:pango-rectangle-width logical-rect)
              (pango:pango-rectangle-height logical-rect)
              (pango:pango-rectangle-width ink-rect)
              0
              baseline))))

(defmethod climb:text-bounding-rectangle*
    ((medium gtk-medium) string &key text-style (start 0) end align-x align-y direction)
  (declare (ignore align-x align-y direction))
  (let ((fixed-string (subseq string (or start 0) (or end (length string)))))
    (multiple-value-bind (ink-rect logical-rect baseline)
        (measure-text-bounds medium fixed-string text-style)
      (declare (ignore ink-rect))
      (let ((x (pango:pango-rectangle-x logical-rect))
            (y (pango:pango-rectangle-y logical-rect))
            (width (pango:pango-rectangle-width logical-rect))
            (height (pango:pango-rectangle-height logical-rect)))
       (values x
               (- y baseline)
               (+ x width)
               (- height baseline))))))

(defmethod (setf medium-text-style) :before (text-style (medium gtk-medium))
  (declare (ignore text-style))
  nil)

(defmethod (setf medium-line-style) :before (line-style (medium gtk-medium))
  (declare (ignore line-style))
  nil)

(defmethod (setf medium-clipping-region) :after (region (medium gtk-medium))
  (declare (ignore region))
  nil)

(defmethod medium-draw-text* ((medium gtk-medium) string x y
                              start end
                              align-x align-y
                              toward-x toward-y transform-glyphs)
  (declare (ignore toward-x toward-y transform-glyphs))
  (let ((merged-transform (sheet-device-transformation (medium-sheet medium))))
    (when (characterp string)
      (setq string (make-string 1 :initial-element string)))
    (let ((fixed-string (subseq string (or start 0) (or end (length string)))))
      (multiple-value-bind (transformed-x transformed-y)
          (transform-position merged-transform x y)
        #+nil (log:info "displaying string at (~s,~s): ~s" transformed-x transformed-y fixed-string)
        (with-cairo-context (cr medium)
          (let ((layout (pango:pango-cairo-create-layout cr)))
            (set-current-font layout (clim:text-style-mapping (port medium) (clim:medium-text-style medium)))
            (unwind-protect
                 (progn
                   (pango:pango-layout-set-text layout fixed-string)
                   (let ((baseline (/ (pango:pango-layout-get-baseline layout) pango:+pango-scale+)))
                     (cairo:cairo-move-to cr transformed-x (- transformed-y baseline)))
                   (pango:pango-cairo-show-layout cr layout))
              (gobject:g-object-unref (gobject:pointer layout)))))))))

#+nil
(defmethod medium-buffering-output-p ((medium gtk-medium))
  t)

#+nil
(defmethod (setf medium-buffering-output-p) (buffer-p (medium gtk-medium))
  buffer-p)

(defmethod medium-copy-area ((from-drawable gtk-medium)
			     from-x from-y width height
                             (to-drawable gtk-medium)
			     to-x to-y)
  (declare (ignore from-x from-y width height to-x to-y))
  nil)

(defvar *repainting-medium* nil)

(defmethod repaint-sheet :around ((sheet sheet) region)
  (labels ((fn ()
             (call-next-method)))
    (let ((medium (let ((root (sheet-mirrored-ancestor sheet)))
                    (and root (sheet-medium root)))))
      (if medium
          (progn
            (let ((*repainting-medium* medium))
              (fn))
            (medium-finish-output medium))
          (fn)))))

(defmethod medium-finish-output ((medium gtk-medium))
  (unless (eq medium *repainting-medium*)
    (with-medium-mirror (mirror medium)
      (bordeaux-threads:with-lock-held ((gtk-mirror/lock mirror))
        (setf (gtk-mirror/need-redraw mirror) t))
      (let ((widget (gtk-mirror/drawing-area mirror)))
        (in-gtk-thread (:no-wait t)
          (gtk:gtk-widget-queue-draw widget))))))

(defmethod medium-force-output ((medium gtk-medium))
  nil)

(defmethod medium-clear-area ((medium gtk-medium) left top right bottom)
  (let ((tr (sheet-native-transformation (medium-sheet medium))))
    (climi::with-transformed-position (tr top left)
      (climi::with-transformed-position (tr right bottom)
        (with-cairo-context (cr medium :update-style nil)
          (apply-colour-from-ink cr (medium-background medium))
          (cairo:cairo-rectangle cr left top right bottom)
          (cairo:cairo-fill cr))))))

(defmethod medium-beep ((medium gtk-medium))
  nil)

(defmethod medium-miter-limit ((medium gtk-medium))
  0)

(defmethod clim:medium-draw-line* ((medium gtk-medium) x1 y1 x2 y2)
  (with-cairo-context (cr medium :transform t)
    (cairo:cairo-move-to cr x1 y1)
    (cairo:cairo-line-to cr x2 y2)
    (cairo:cairo-stroke cr)))

(defmethod medium-draw-lines* ((medium gtk-medium) coord-seq)
  (let ((tr (sheet-native-transformation (medium-sheet medium))))
    (with-cairo-context (cr medium)
      (iterate-over-4-blocks (x1 y1 x2 y2 coord-seq)
        (multiple-value-bind (x y)
            (climi::transform-position tr x1 y1)
          (cairo:cairo-move-to cr x y))
        (multiple-value-bind (x y)
            (climi::transform-position tr x2 y2)
          (cairo:cairo-line-to cr x y)))
      (cairo:cairo-stroke cr))))

(defparameter *draw-count* 0)

(defmethod medium-draw-rectangle* ((medium gtk-medium) left top right bottom filled)
  (let ((tr (sheet-native-transformation (medium-sheet medium))))
    (climi::with-transformed-position (tr left top)
      (climi::with-transformed-position (tr right bottom)
        (with-cairo-context (cr medium)
          (when (< right left) (rotatef left right))
          (when (< bottom top) (rotatef top bottom))
          (let ((left   (round-coordinate left))
                (top    (round-coordinate top))
                (right  (round-coordinate right))
                (bottom (round-coordinate bottom)))
            (cairo:cairo-rectangle cr left top (- right left) (- bottom top))
            (if filled
                (cairo:cairo-fill cr)
                (cairo:cairo-stroke cr))))))))

(defmethod medium-draw-rectangles* ((medium gtk-medium) position-seq filled)
  (declare (ignore position-seq filled))
  (log:trace "not implemented")
  (break)
  nil)

(defmethod medium-draw-point* ((medium gtk-medium) x y)
  (with-cairo-context (cr medium :transform t)
    (cairo:cairo-rectangle cr (- x 0.5) (- y 0.5) (+ x 0.5) (+ y 0.5))))

(defmethod medium-draw-points* ((medium gtk-medium) coord-seq)
  (with-cairo-context (cr medium :transform t)
    (loop
      for (x y) on (coerce coord-seq 'list) by #'cddr
      do (cairo:cairo-rectangle cr (- x 0.5) (- y 0.5) (+ x 0.5) (+ y 0.5)))))

(defmethod medium-draw-polygon* ((medium gtk-medium) coord-seq closed filled)
  (let ((tr (sheet-native-transformation (medium-sheet medium))))
    (with-cairo-context (cr medium)
      (iterate-over-seq-pairs (x y coord-seq)
          (climi::with-transformed-position (tr x y)
            (cairo:cairo-move-to cr x y))
        (climi::with-transformed-position (tr x y)
          (cairo:cairo-line-to cr x y)))
      (when closed
        (cairo:cairo-close-path cr))
      (if filled
          (cairo:cairo-fill cr)
          (cairo:cairo-stroke cr)))))

(defmethod medium-draw-ellipse* ((medium gtk-medium) centre-x centre-y
				 radius-1-dx radius-1-dy
				 radius-2-dx radius-2-dy
				 start-angle end-angle filled)
  (with-cairo-context (cr medium :transform t)
    (let ((ellipse (make-ellipse* centre-x centre-y
                                  radius-1-dx radius-1-dy
				  radius-2-dx radius-2-dy
                                  :start-angle start-angle
                                  :end-angle end-angle)))
      (multiple-value-bind (new-centre-x new-centre-y horizontal-size vertical-size angle)
          (climi::ellipse-simplified-representation ellipse)
        (cairo:cairo-save cr)
        (cairo:cairo-translate cr new-centre-x new-centre-y)
        (cairo:cairo-rotate cr angle)
        (cairo:cairo-scale cr horizontal-size vertical-size)
        (cairo:cairo-arc cr 0 0 1 (or start-angle 0) (or end-angle (* pi 2)))
        (when (and filled (/= (mod start-angle (* pi 2)) (mod end-angle (* pi 2))))
          (cairo:cairo-line-to cr 0 0))
        (cairo:cairo-restore cr)
        (if filled
            (cairo:cairo-fill cr)
            (cairo:cairo-stroke cr))))))

(defmethod medium-draw-circle* ((medium gtk-medium)
				center-x center-y radius start-angle end-angle
				filled)
  (declare (ignore center-x center-y radius
		   start-angle end-angle filled))
  (break)
  nil)
