;;; my-read-k-tests.el --- Compatibility loader for reader suites -*- lexical-binding: t; -*-

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'reader-epub-tests)
(require 'reader-eww-tests)
(require 'reader-kindle-tests)
(require 'reader-lookup-tests)
(require 'reader-notes-tests)
(require 'reader-pdf-tests)
(require 'reader-position-tests)
(require 'reader-speech-tests)
(require 'reader-translation-tests)
(require 'reader-ui-tests)
(require 'reader-vocabulary-tests)

(provide 'my-read-k-tests)
