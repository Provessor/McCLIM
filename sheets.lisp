;;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-

;;;  (c) copyright 1998,1999,2000 by Michael McDonald (mikemac@mikemac.com), 
;;;  (c) copyright 2000 by 
;;;           Iban Hatchondo (hatchond@emi.u-bordeaux.fr)
;;;           Julien Boninfante (boninfan@emi.u-bordeaux.fr)
;;;           Robert Strandh (strandh@labri.u-bordeaux.fr)
;;;  (c) copyright 2001 by
;;;           Arnaud Rouanet (rouanet@emi.u-bordeaux.fr)
;;;           Lionel Salabartan (salabart@emi.u-bordeaux.fr)

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the 
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, 
;;; Boston, MA  02111-1307  USA.



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; The sheet protocol

(in-package :CLIM-INTERNALS)

(defgeneric sheet-parent (sheet)
  (:documentation
   "Returns the parent of the sheet SHEET or nil if the sheet has
no parent"))

(defgeneric sheet-children (sheet)
  (:documentation
   "Returns a list of sheets that are the children of the sheet SHEET.
Some sheet classes support only a single child; in this case, the
result of sheet-children will be a list of one element. This
function returns objects that reveal CLIM's internal state ; do not
modify those objects."))

(defgeneric sheet-adopt-child (sheet child)
  (:documentation
   "Adds the child sheet child to the set of children of the sheet SHEET,
and makes the sheet the child's parent. If child already has a parent, 
the sheet-already-has-parent error will be signalled.

Some sheet classes support only a single child. For such sheets, 
attempting to adopt more than a single child will cause the 
sheet-supports-only-one-child error to be signalled."))

(defgeneric sheet-disown-child (sheet child &key errorp))
(defgeneric sheet-enabled-children (sheet))
(defgeneric sheet-ancestor-p (sheet putative-ancestor))
(defgeneric raise-sheet (sheet))

;;; not for external use
(defgeneric raise-sheet-internal (sheet parent))

(defgeneric bury-sheet (sheet))

;;; not for external use
(defgeneric bury-sheet-internal (sheet parent))

(defgeneric reorder-sheets (sheet new-ordering))
(defgeneric sheet-enabled-p (sheet))
(defgeneric (setf sheet-enabled-p) (enabled-p sheet))
(defgeneric sheet-viewable-p (sheet))
(defgeneric sheet-occluding-sheets (sheet child))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Sheet geometry

(defgeneric sheet-transformation (sheet))
(defgeneric (setf sheet-transformation) (transformation sheet))
(defgeneric sheet-region (sheet))
(defgeneric (setf sheet-region) (region sheet))
(defgeneric map-sheet-position-to-parent (sheet x y))
(defgeneric map-sheet-position-to-child (sheet x y))
(defgeneric map-sheet-rectangle*-to-parent (sheet x1 y1 x2 y2))
(defgeneric map-sheet-rectangle*-to-child (sheet x1 y1 x2 y2))
(defgeneric child-containing-position (sheet x y))
(defgeneric children-overlapping-region (sheet region))
(defgeneric children-overlapping-rectangle* (sheet x1 y1 x2 y2))
(defgeneric sheet-delta-transformation (sheet ancestor))
(defgeneric sheet-allocated-region (sheet child))

;;these are now in decls.lisp --GB
;;(defgeneric sheet-native-region (sheet)) 
;;(defgeneric sheet-device-region (sheet))
;;(defgeneric invalidate-cached-regions (sheet))

;;(defgeneric sheet-native-transformation (sheet))
;;(defgeneric sheet-device-transformation (sheet))
;;(defgeneric invalidate-cached-transformations (sheet))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; input protocol

(defgeneric dispatch-event (client event))
(defgeneric queue-event (client event))
(defgeneric handle-event (client event))
(defgeneric event-read (client))
(defgeneric event-read-no-hang (client))
(defgeneric event-peek (client &optional event-type))
(defgeneric event-unread (client event))
(defgeneric event-listen (client))
(defgeneric sheet-direct-mirror (sheet))
(defgeneric sheet-mirrored-ancestor (sheet))
(defgeneric sheet-mirror (sheet))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; repaint protocol

(defgeneric dispatch-repaint (sheet region))
(defgeneric queue-repaint (sheet region))
(defgeneric handle-repaint (sheet region))
(defgeneric repaint-sheet (sheet region))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; notification protocol

(defgeneric note-sheet-grafted (sheet))
(defgeneric note-sheet-degrafted (sheet))
(defgeneric note-sheet-adopted (sheet))
(defgeneric note-sheet-disowned (sheet))
(defgeneric note-sheet-enabled (sheet))
(defgeneric note-sheet-disabled (sheet))
(defgeneric note-sheet-region-changed (sheet))
(defgeneric note-sheet-transformation-changed (sheet))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;
;;;; sheet protocol class

(define-protocol-class sheet (bounding-rectangle)
  ())

(defclass basic-sheet (sheet)
  ((region :type region
	   :initarg :region
	   :initform (make-bounding-rectangle 0 0 100 100)
	   :accessor sheet-region)
   (native-transformation :type transformation
			  :initform nil)
   (native-region :type region
		  :initform nil)
   (device-transformation :type transformation
			  :initform nil)
   (device-region :type region
		  :initform nil)
   (enabled-p :type boolean
              :initform t
              :accessor sheet-enabled-p)))
; Native region is volatile, and is only computed at the first request when it's equal to nil.
; Invalidate-cached-region method sets the native-region to nil.

(defmethod sheet-parent ((sheet basic-sheet))
  nil)

(defmethod sheet-children ((sheet basic-sheet))
  nil)

(defmethod sheet-adopt-child ((sheet basic-sheet) (child sheet))
  (error "~S attempting to adopt ~S" sheet child))

(defmethod sheet-adopt-child :after ((sheet basic-sheet) (child sheet))
  (note-sheet-adopted child)
  (when (sheet-grafted-p sheet)
    (note-sheet-grafted child)))

(define-condition sheet-is-not-child (error) ())

(defmethod sheet-disown-child :before ((sheet basic-sheet) (child sheet) &key (errorp t))
  (when (and (not (member child (sheet-children sheet))) errorp)
    (error 'sheet-is-not-child)))

(defmethod sheet-disown-child :after ((sheet basic-sheet) (child sheet) &key (errorp t))
  (declare (ignore errorp))
  (note-sheet-disowned child)
  (when (sheet-grafted-p sheet)
    (note-sheet-degrafted child)))

(defmethod sheet-siblings ((sheet basic-sheet))
  (when (not (sheet-parent sheet))
    (error 'sheet-is-not-child))
  (remove sheet (sheet-children (sheet-parent sheet))))

(defmethod sheet-enabled-children ((sheet basic-sheet))
  (delete-if-not #'sheet-enabled-p (copy-list (sheet-children sheet))))

(defmethod sheet-ancestor-p ((sheet basic-sheet)
			     (putative-ancestor sheet))
  (or (eq sheet putative-ancestor)
      (and (sheet-parent sheet)
	   (sheet-ancestor-p (sheet-parent sheet) putative-ancestor))))

(defmethod raise-sheet ((sheet basic-sheet))
  (error 'sheet-is-not-child))

(defmethod bury-sheet ((sheet basic-sheet))
  (error 'sheet-is-not-child))

(define-condition sheet-ordering-underspecified (error) ())

(defmethod reorder-sheets ((sheet basic-sheet) new-ordering)
  (when (set-difference (sheet-children sheet) new-ordering)
    (error 'sheet-ordering-underspecified))
  (when (set-difference new-ordering (sheet-children sheet))
    (error 'sheet-is-not-child))
  (setf (sheet-children sheet) new-ordering)
  sheet)

(defmethod sheet-viewable-p ((sheet basic-sheet))
  (and (sheet-parent sheet)
       (sheet-viewable-p (sheet-parent sheet))
       (sheet-enabled-p sheet)))

(defmethod sheet-occluding-sheets ((sheet basic-sheet) (child sheet))
  (labels ((fun (l)
		(cond ((eq (car l) child) '())
		      ((and (sheet-enabled-p (car l))
                            (region-intersects-region-p
                             (sheet-region (car l)) (sheet-region child)))
		       (cons (car l) (fun (cdr l))))
		      (t (fun (cdr l))))))
    (fun (sheet-children sheet))))

(defmethod map-over-sheets (function (sheet basic-sheet))
  (funcall function sheet)
  (mapc #'(lambda (child) (map-over-sheets function child))
        (sheet-children sheet))
  nil)

(defmethod (setf sheet-enabled-p) :after (enabled-p (sheet basic-sheet))
  (if enabled-p
      (note-sheet-enabled sheet)
      (note-sheet-disabled sheet)))

(defmethod sheet-transformation ((sheet basic-sheet))
  (error "Attempting to get the TRANSFORMATION of a SHEET that doesn't contain one"))

(defmethod (setf sheet-transformation) (transformation (sheet basic-sheet))
  (declare (ignore transformation))
  (error "Attempting to set the TRANSFORMATION of a SHEET that doesn't contain one"))

(defmethod move-sheet ((sheet basic-sheet) x y)
  (let ((transform (sheet-transformation sheet)))
    (multiple-value-bind (old-x old-y)
        (transform-position transform 0 0)
      (setf (sheet-transformation sheet)
            (compose-translation-with-transformation
              transform (- x old-x) (- y old-y))))))

(defmethod resize-sheet ((sheet basic-sheet) width height)
  (setf (sheet-region sheet)
        (make-bounding-rectangle 0 0 width height)))

(defmethod move-and-resize-sheet ((sheet basic-sheet) x y width height)
  (move-sheet sheet x y)
  (resize-sheet sheet width height))

(defmethod map-sheet-position-to-parent ((sheet basic-sheet) x y)
  (declare (ignore x y))
  (error "Sheet has no parent"))

(defmethod map-sheet-position-to-child ((sheet basic-sheet) x y)
  (declare (ignore x y))
  (error "Sheet has no parent"))

(defmethod map-sheet-rectangle*-to-parent ((sheet basic-sheet) x1 y1 x2 y2)
  (declare (ignore x1 y1 x2 y2))
  (error "Sheet has no parent"))

(defmethod map-sheet-rectangle*-to-child ((sheet basic-sheet) x1 y1 x2 y2)
  (declare (ignore x1 y1 x2 y2))
  (error "Sheet has no parent"))

(defmethod map-over-sheets-containing-position (function (sheet basic-sheet) x y)
  (map-over-sheets #'(lambda (child)
                       (multiple-value-bind (tx ty) (map-sheet-position-to-child child x y)
                         (when (region-contains-position-p (sheet-region child) tx ty)
                           (funcall function child))))
                   sheet))


(defmethod map-over-sheets-overlapping-region (function (sheet basic-sheet) region)
  (map-over-sheets #'(lambda (child)
                       (when (region-intersects-region-p
                              region
                              (transform-region (sheet-transformation child)
                                                (sheet-region child)))
                         (funcall function child)))
                   sheet))

(defmethod child-containing-position ((sheet basic-sheet) x y)
  (loop for child in (sheet-children sheet)
      do (multiple-value-bind (tx ty) (map-sheet-position-to-child child x y)
	    (if (and (sheet-enabled-p child)
		     (region-contains-position-p (sheet-region child) tx ty))
		(return child)))))

(defmethod children-overlapping-region ((sheet basic-sheet) (region region))
  (loop for child in (sheet-children sheet)
      if (and (sheet-enabled-p child)
	      (region-intersects-region-p 
	       region 
	       (transform-region (sheet-transformation child)
				 (sheet-region child))))
      collect child))

(defmethod children-overlapping-rectangle* ((sheet basic-sheet) x1 y1 x2 y2)
  (children-overlapping-region sheet (make-rectangle* x1 y1 x2 y2)))

(defmethod sheet-delta-transformation ((sheet basic-sheet) (ancestor (eql nil)))
  (cond ((sheet-parent sheet)
	 (compose-transformations (sheet-transformation sheet)
				  (sheet-delta-transformation
				   (sheet-parent sheet) ancestor)))
	(t +identity-transformation+)))
  
(define-condition sheet-is-not-ancestor (error) ())

(defmethod sheet-delta-transformation ((sheet basic-sheet) (ancestor sheet))
  (cond ((eq sheet ancestor) +identity-transformation+)
	((sheet-parent sheet)
	 (compose-transformations (sheet-transformation sheet)
				  (sheet-delta-transformation
				   (sheet-parent sheet) ancestor)))
	(t (error 'sheet-is-not-ancestor))))

(defmethod sheet-allocated-region ((sheet basic-sheet) (child sheet))
  (reduce #'region-difference
	  (mapcar #'(lambda (child)
                      (transform-region (sheet-transformation child)
                                        (sheet-region child)))
                  (cons child (sheet-occluding-sheets sheet child)))))

(defmethod sheet-direct-mirror ((sheet basic-sheet))
  nil)

(defmethod sheet-mirrored-ancestor ((sheet basic-sheet))
  (if (sheet-parent sheet)
      (sheet-mirrored-ancestor (sheet-parent sheet))))

(defmethod sheet-mirror ((sheet basic-sheet))
  (let ((mirrored-ancestor (sheet-mirrored-ancestor sheet)))
    (if mirrored-ancestor
	(sheet-direct-mirror mirrored-ancestor))))

(defmethod graft ((sheet basic-sheet))
  nil)

(defmethod note-sheet-grafted ((sheet basic-sheet))
  (mapc #'note-sheet-grafted (sheet-children sheet)))

(defmethod note-sheet-degrafted ((sheet basic-sheet))
  (mapc #'note-sheet-degrafted (sheet-children sheet)))

(defmethod note-sheet-adopted ((sheet basic-sheet))
  (declare (ignorable sheet))
  nil)

(defmethod note-sheet-disowned ((sheet basic-sheet))
  (declare (ignorable sheet))
  nil)

(defmethod note-sheet-enabled ((sheet basic-sheet))
  (declare (ignorable sheet))
  nil)

(defmethod note-sheet-disabled ((sheet basic-sheet))
  (declare (ignorable sheet))
  nil)

(defmethod note-sheet-region-changed ((sheet basic-sheet))
  nil) ;have to change

(defmethod note-sheet-transformation-changed ((sheet basic-sheet))
  nil)

(defmethod sheet-native-transformation ((sheet basic-sheet))
  (with-slots (native-transformation) sheet
    (unless native-transformation
        (setf native-transformation
              (let ((parent (sheet-parent sheet)))
                 (if parent
                     (compose-transformations
                      (sheet-native-transformation parent)
                      (sheet-transformation sheet))
                     +identity-transformation+))))
    native-transformation))

(defmethod sheet-native-region ((sheet basic-sheet))
  (with-slots (native-region) sheet
    (unless native-region
      (setf native-region (region-intersection
                           (transform-region
                            (sheet-native-transformation sheet)
                            (sheet-region sheet))
                           (sheet-native-region (sheet-parent sheet)))))
    native-region))

(defmethod sheet-device-transformation ((sheet basic-sheet))
  (with-slots (device-transformation) sheet
    (unless device-transformation
      (setf device-transformation
            (let ((medium (sheet-medium sheet)))
              (compose-transformations
               (sheet-native-transformation sheet)
               (if medium
                   (medium-transformation medium)
                   +identity-transformation+)))))
    device-transformation))

(defmethod sheet-device-region ((sheet basic-sheet))
  (with-slots (device-region) sheet
    (unless device-region
      (setf device-region
            (let ((medium (sheet-medium sheet)))
              (region-intersection
               (sheet-native-region sheet)
               (if medium
                   (transform-region
                    (sheet-device-transformation sheet)
                    (medium-clipping-region medium))
                   +everywhere+)))))
    device-region))

(defmethod invalidate-cached-transformations ((sheet basic-sheet))
  (with-slots (native-transformation device-transformation) sheet
    (setf native-transformation nil
          device-transformation nil))
  (loop for child in (sheet-children sheet)
        do (invalidate-cached-transformations child)))

(defmethod invalidate-cached-regions ((sheet basic-sheet))
  (with-slots (native-region device-region) sheet
    (setf native-region nil
          device-region nil))
  (loop for child in (sheet-children sheet)
        do (invalidate-cached-regions child)))

(defmethod (setf sheet-transformation) :after (transformation (sheet basic-sheet))
  (declare (ignore transformation))
  (note-sheet-transformation-changed sheet)
  (invalidate-cached-transformations sheet)
  (invalidate-cached-regions sheet))

(defmethod (setf sheet-region) :after (region (sheet basic-sheet))
  (declare (ignore region))
  (note-sheet-region-changed sheet)
  (invalidate-cached-regions sheet))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; sheet parent mixin


(defclass sheet-parent-mixin ()
  ((parent :initform nil :accessor sheet-parent)))

(define-condition sheet-already-has-parent (error) ())
(define-condition sheet-is-ancestor (error) ())

(defmethod sheet-adopt-child :before (sheet (child sheet-parent-mixin))
  (when (sheet-parent child) (error 'sheet-already-has-parent))
  (when (sheet-ancestor-p sheet child) (error 'sheet-is-ancestor)))

(defmethod sheet-adopt-child :after (sheet (child sheet-parent-mixin))
  (setf (sheet-parent child) sheet))

(defmethod sheet-disown-child :after (sheet
				      (child sheet-parent-mixin)
				      &key (errorp t))
  (declare (ignore sheet errorp))
  (setf (sheet-parent child) nil))

(defmethod raise-sheet ((sheet sheet-parent-mixin))
  (when (not (sheet-parent sheet))
    (error 'sheet-is-not-child))
  (raise-sheet-internal sheet (sheet-parent sheet)))

(defmethod bury-sheet ((sheet sheet-parent-mixin))
  (when (not (sheet-parent sheet))
    (error 'sheet-is-not-child))
  (bury-sheet-internal sheet (sheet-parent sheet)))

(defmethod graft ((sheet sheet-parent-mixin))
  (graft (sheet-parent sheet)))

(defmethod (setf sheet-transformation) :after (newvalue (sheet sheet-parent-mixin))
  (declare (ignore newvalue))
  (note-sheet-transformation-changed sheet))

(defmethod map-sheet-position-to-parent ((sheet sheet-parent-mixin) x y)
  (transform-position (sheet-transformation sheet) x y))

(defmethod map-sheet-position-to-child ((sheet sheet-parent-mixin) x y)
  (untransform-position (sheet-transformation sheet) x y))

(defmethod map-sheet-rectangle*-to-parent ((sheet sheet-parent-mixin) x1 y1 x2 y2)
  (transform-rectangle* (sheet-transformation sheet) x1 y1 x2 y2))

(defmethod map-sheet-rectangle*-to-child ((sheet sheet-parent-mixin) x1 y1 x2 y2)
  (untransform-rectangle* (sheet-transformation sheet) x1 y1 x2 y2))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; sheet leaf mixin

(defclass sheet-leaf-mixin () ())

(defmethod sheet-children ((sheet sheet-leaf-mixin))
  nil)

(defmethod sheet-adopt-child ((sheet sheet-leaf-mixin) (child sheet))
  (describe (class-of sheet) *debug-io*)
  (error "Leaf sheet attempting to adopt a child"))

(defmethod sheet-disown-child ((sheet sheet-leaf-mixin) (child sheet) &key (errorp t))
  (declare (ignorable errorp))
  (error "Leaf sheet attempting to disown a child"))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; sheet single child mixin

(defclass sheet-single-child-mixin ()
  ((child :initform nil :accessor sheet-child)))

(defmethod sheet-children ((sheet sheet-single-child-mixin))
  (list (sheet-child sheet)))

(define-condition sheet-supports-only-one-child (error) ())

(defmethod sheet-adopt-child :before ((sheet sheet-single-child-mixin)
				      (child sheet-parent-mixin))
  (when (sheet-child sheet)
    (error 'sheet-supports-only-one-child)))

(defmethod sheet-adopt-child ((sheet sheet-single-child-mixin)
			      (child sheet-parent-mixin))
  (setf (sheet-child sheet) child))

(defmethod sheet-disown-child ((sheet sheet-single-child-mixin)
			       (child sheet-parent-mixin)
			       &key (errorp t))
  (declare (ignore errorp))
  (setf (sheet-child sheet) nil))

(defmethod raise-sheet-internal (sheet (parent sheet-single-child-mixin))
  (declare (ignorable sheet parent))
  (values))

(defmethod bury-sheet-internal (sheet (parent sheet-single-child-mixin))
  (declare (ignorable sheet parent))
  (values))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; sheet multiple child mixin

(defclass sheet-multiple-child-mixin ()
  ((children :initform nil :initarg :children :accessor sheet-children)))

(defmethod sheet-adopt-child ((sheet sheet-multiple-child-mixin)
			      (child sheet-parent-mixin))
  (push child (sheet-children sheet)))

(defmethod sheet-disown-child ((sheet sheet-multiple-child-mixin)
			       (child sheet-parent-mixin)
			       &key (errorp t))
  (declare (ignore errorp))
  (setf (sheet-children sheet) (delete child (sheet-children sheet))))

(defmethod raise-sheet-internal (sheet (parent sheet-multiple-child-mixin))
  (setf (sheet-children parent)
	(cons sheet (delete sheet (sheet-children parent)))))

(defmethod bury-sheet-internal (sheet (parent sheet-multiple-child-mixin))
  (setf (sheet-children parent)
	(append (delete sheet (sheet-children parent)) (list  sheet))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; sheet geometry classes

(defclass sheet-identity-transformation-mixin ()
  ())

(defmethod sheet-transformation ((sheet sheet-identity-transformation-mixin))
  +identity-transformation+)

(defclass sheet-transformation-mixin ()
  ((transformation :initform +identity-transformation+
		   :initarg :transformation
		   :accessor sheet-transformation)))

(defclass sheet-translation-transformation-mixin (sheet-transformation-mixin)
  ())

(defmethod (setf sheet-transformation) :before ((transformation transformation)
						(sheet sheet-translation-transformation-mixin))
  (if (not (translation-transformation-p transformation))
      (error "Attempting to set the SHEET-TRANSFORMATION of a SHEET-TRANSLATION-TRANSFORMATION-MIXIN to a non translation transformation")))

(defclass sheet-y-inverting-transformation-mixin (sheet-transformation-mixin)
  ()
  (:default-initargs :transformation (make-transformation 1 0 0 -1 0 0)))

(defmethod (setf sheet-transformation) :before ((transformation transformation)
						(sheet sheet-y-inverting-transformation-mixin))
  (if (not (y-inverting-transformation-p transformation))
      (error "Attempting to set the SHEET-TRANSFORMATION of a SHEET-Y-INVERTING-TRANSFORMATION-MIXIN to a non Y inverting transformation")))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; mirrored sheet

(defclass mirrored-sheet-mixin ()
  ((port :initform nil :initarg :port :accessor port)
   (mirror-transformation
    :initform nil
    :accessor sheet-mirror-transformation)))

(defmethod sheet-direct-mirror ((sheet mirrored-sheet-mixin))
  (port-lookup-mirror (port sheet) sheet))

(defmethod (setf sheet-direct-mirror) (mirror (sheet mirrored-sheet-mixin))
  (port-register-mirror (port sheet) sheet mirror))

(defmethod sheet-mirrored-ancestor ((sheet mirrored-sheet-mixin))
  sheet)

(defmethod sheet-mirror ((sheet mirrored-sheet-mixin))
  (sheet-direct-mirror sheet))

(defmethod note-sheet-grafted :before ((sheet mirrored-sheet-mixin))
  (unless (port sheet)
    (error "~S called on sheet ~S, which has no port?!" 'note-sheet-grafted sheet))
  (realize-mirror (port sheet) sheet))

(defmethod note-sheet-degrafted :after ((sheet mirrored-sheet-mixin))
  (destroy-mirror (port sheet) sheet))

(defmethod (setf sheet-region) :after (region (sheet mirrored-sheet-mixin))
  (port-set-sheet-region (port sheet) sheet region))

(defmethod (setf sheet-transformation) :after (transformation (sheet mirrored-sheet-mixin))
  (port-set-sheet-transformation (port sheet) sheet transformation))

(defmethod sheet-native-transformation ((sheet mirrored-sheet-mixin))
  (with-slots (native-transformation) sheet
    (unless native-transformation
      (setf native-transformation
            (compose-transformations
             (invert-transformation
              (mirror-transformation (port sheet)
                                     (sheet-direct-mirror sheet)))
             (compose-transformations
              (sheet-native-transformation (sheet-parent sheet))
              (sheet-transformation sheet)))))
      native-transformation))

(defmethod sheet-native-region ((sheet mirrored-sheet-mixin))
  (with-slots (native-region) sheet
    (unless native-region
      (setf native-region
            (region-intersection
             (transform-region
              (sheet-native-transformation sheet)
              (sheet-region sheet))
             (transform-region
              (invert-transformation
               (mirror-transformation (port sheet)
                                      (sheet-direct-mirror sheet)))
              (sheet-native-region (sheet-parent sheet))))))
    native-region))

(defmethod (setf sheet-enabled-p) :after (new-value (sheet mirrored-sheet-mixin))
  (when (sheet-direct-mirror sheet)     ;only do this if the sheet actually has a mirror
    (if new-value
        (port-enable-sheet (port sheet) sheet)
        (port-disable-sheet (port sheet) sheet))))

;;; Sheets as bounding rectangles

;; Somewhat hidden in the spec, we read (section 4.1.1 "The Bounding
;; Rectangle Protocol")
;;

;; | bounding-rectangle* region [Generic Function]
;; | 
;; |      [...] The argument region must be either a bounded region [...] or
;; |      some other object that obeys the bounding rectangle protocol, such
;; |      as a sheet or an output record. [...]

(defmethod bounding-rectangle* ((sheet sheet))
  (bounding-rectangle* (sheet-region sheet)))

;;; The null sheet

(defclass null-sheet (basic-sheet) ())

