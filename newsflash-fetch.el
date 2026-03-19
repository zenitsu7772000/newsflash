;;; newsflash-fetch.el --- RSS/Atom fetcher for newsflash.el -*- lexical-binding: t; -*-
;;; Commentary:
;; Async RSS and Atom feed fetching with XML parsing.
;; Handles RSS 2.0, Atom 1.0, and Reddit JSON feeds.
;;; Code:

(require 'url)
(require 'gnutls)
(require 'xml)
(require 'cl-lib)
(require 'seq)

;;; ─── Main fetch orchestrator ─────────────────────────────────────────────────

(defvar newsflash--fetch-queue '()
  "Queue of pending fetches.")

(defvar newsflash--fetch-in-progress nil
  "Number of currently running fetches.")

(defvar newsflash--max-concurrent-fetches 5
  "Maximum concurrent feed fetches (prevents overwhelming network).")

(defun newsflash--fetch-all-feeds ()
  "Fetch all feeds from `newsflash-feeds' asynchronously with concurrency limit."
  (clrhash newsflash--articles)
  ;; Count total feeds
  (let ((total (apply #'+ (mapcar (lambda (c) (length (plist-get c :feeds)))
                                  newsflash-feeds))))
    (setq newsflash--fetch-total   total
          newsflash--fetch-pending total
          newsflash--fetch-in-progress 0
          newsflash--fetch-queue '()))
  ;; Build queue of all feeds
  (dolist (cat-def newsflash-feeds)
    (let ((cat-name (plist-get cat-def :category))
          (feeds    (plist-get cat-def :feeds)))
      (dolist (feed feeds)
        (let ((feed-name (car feed))
              (feed-url  (cdr feed)))
          (push (list feed-url feed-name cat-name) newsflash--fetch-queue)))))
  ;; Start initial batch
  (while (and newsflash--fetch-queue
              (< newsflash--fetch-in-progress newsflash--max-concurrent-fetches))
    (newsflash--start-next-fetch)))

(defun newsflash--start-next-fetch ()
  "Start the next fetch from the queue."
  (when newsflash--fetch-queue
    (let ((job (pop newsflash--fetch-queue)))
      (cl-incf newsflash--fetch-in-progress)
      (apply #'newsflash--fetch-feed job))))

(defun newsflash--fetch-done ()
  "Called when one fetch completes. Start next or finish."
  (cl-decf newsflash--fetch-in-progress)
  (cl-decf newsflash--fetch-pending)
  ;; Update dashboard progressively
  (with-current-buffer (get-buffer "*newsflash*")
    (newsflash--render-dashboard))
  ;; Start next fetch if queue has items
  (if (and newsflash--fetch-queue
           (< newsflash--fetch-in-progress newsflash--max-concurrent-fetches))
      (newsflash--start-next-fetch)
    ;; All done?
    (when (<= newsflash--fetch-pending 0)
      (setq newsflash--last-refresh (current-time))
      (message "newsflash: loaded %d articles"
               (let ((n 0))
                 (maphash (lambda (_ arts) (cl-incf n (length arts)))
                          newsflash--articles)
                 n)))))

(defun newsflash--fetch-all-feeds-sync ()
  "Fetch all feeds synchronously (blocking). Use for initial load. OPTIMIZED."
  (clrhash newsflash--articles)
  (let ((url-request-extra-headers
         '(("User-Agent" . "Mozilla/5.0 (compatible; newsflash.el/1.0; +https://github.com/yourusername/newsflash.el)")
           ("Accept" . "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
           ("Cache-Control" . "no-cache")
           ("Connection" . "close")))
        (count 0)
        (feeds-to-fetch '()))
    ;; Collect feeds, optionally limit to quick-start mode
    (dolist (cat-def newsflash-feeds)
      (let ((cat-name (plist-get cat-def :category))
            (feeds    (plist-get cat-def :feeds)))
        (when newsflash-quick-start
          (setq feeds (seq-take feeds 3))) ;; Only top 3 per category
        (dolist (feed feeds)
          (push (list (cdr feed) (car feed) cat-name) feeds-to-fetch))))
    ;; Fetch with progress messages
    (dolist (job (nreverse feeds-to-fetch))
      (let ((url (nth 0 job))
            (name (nth 1 job))
            (cat (nth 2 job)))
        (cl-incf count)
        (message "newsflash: fetching %s (%d/%d)..." name count (length feeds-to-fetch))
        (apply #'newsflash--fetch-feed-sync job)))))

(defun newsflash--fetch-feed (url feed-name cat-name)
  "Fetch a single RSS/Atom feed at URL, tag with FEED-NAME and CAT-NAME."
  (let ((url-request-extra-headers
         '(("User-Agent"     . "Mozilla/5.0 (compatible; newsflash.el/1.0; +https://github.com/yourusername/newsflash.el)")
           ("Accept"         . "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
           ("Cache-Control"  . "no-cache")
           ("Connection"     . "close"))))
    (condition-case err
        (let ((start-time (current-time)))
          (url-retrieve
           url
           (lambda (status)
             (unwind-protect
                 (condition-case err
                     (progn
                       (if (plist-get status :error)
                           (message "newsflash: %s failed (%.1fs)" feed-name
                                    (float-time (time-subtract (current-time) start-time)))
                         ;; Skip HTTP headers
                         (goto-char (point-min))
                         (when (re-search-forward "\r?\n\r?\n" nil t)
                           (let* ((body (buffer-substring-no-properties (point) (point-max)))
                                  (trimmed (string-trim body)))
                             (unless (string-empty-p trimmed)
                               (let ((articles
                                      (cond
                                       ;; Reddit JSON feed
                                       ((string-prefix-p "{" trimmed)
                                        (newsflash--parse-reddit-json trimmed feed-name cat-name))
                                       ;; XML (RSS or Atom)
                                       ((or (string-prefix-p "<" trimmed)
                                            (string-match-p "<?xml" trimmed))
                                        (newsflash--parse-xml-feed trimmed feed-name cat-name))
                                       (t nil))))
                                 (when articles
                                   (newsflash--add-articles cat-name articles)))))))
                       (newsflash--fetch-done))
                   (error
                    (message "newsflash: %s error (%.1fs)" feed-name
                             (float-time (time-subtract (current-time) start-time)))
                    (newsflash--fetch-done)))
               (when (buffer-live-p (current-buffer))
                 (kill-buffer (current-buffer)))))
           nil t newsflash-fetch-timeout))
      (error (message "newsflash: %s failed to start" feed-name)
             (newsflash--fetch-done)))))

(defun newsflash--fetch-feed-sync (url feed-name cat-name)
  "Fetch a single RSS/Atom feed synchronously (blocking)."
  (let ((url-request-extra-headers
         '(("User-Agent" . "Mozilla/5.0 (compatible; newsflash.el/1.0; +https://github.com/yourusername/newsflash.el)")
           ("Accept" . "application/rss+xml, application/atom+xml, application/xml, text/xml, */*")
           ("Cache-Control" . "no-cache")
           ("Connection" . "close")))
        buf content start-time elapsed)
    (setq start-time (current-time))
    (condition-case err
        (progn
          (setq buf (url-retrieve-synchronously url t t newsflash-fetch-timeout))
          (when buf
            (with-current-buffer buf
              (goto-char (point-min))
              (when (re-search-forward "\r?\n\r?\n" nil t)
                (setq content (buffer-substring-no-properties (point) (point-max)))))
            (kill-buffer buf))
          (when (and content (not (string-empty-p (string-trim content))))
            (let ((articles
                   (cond
                    ;; Reddit JSON feed
                    ((string-prefix-p "{" content)
                     (newsflash--parse-reddit-json content feed-name cat-name))
                    ;; XML (RSS or Atom)
                    ((or (string-prefix-p "<" content)
                         (string-match-p "<?xml" content))
                     (newsflash--parse-xml-feed content feed-name cat-name))
                    (t nil))))
              (when articles
                (setq elapsed (float-time (time-subtract (current-time) start-time)))
                (message "newsflash: %s OK (%.1fs, %d articles)" feed-name elapsed (length articles))
                (newsflash--add-articles cat-name articles)))))
      (error (message "newsflash: %s failed (%.1fs)" feed-name
                      (float-time (time-subtract (current-time) start-time)))))))

(defun newsflash--add-articles (cat-name new-articles)
  "Add NEW-ARTICLES to CAT-NAME bucket, dedup by URL, keep latest."
  (let* ((existing (gethash cat-name newsflash--articles '()))
         (existing-urls (mapcar (lambda (a) (cdr (assq 'url a))) existing))
         (fresh (seq-remove
                 (lambda (a) (member (cdr (assq 'url a)) existing-urls))
                 new-articles))
         (combined (append fresh existing)))
    ;; Sort by date descending, keep top N
    (puthash cat-name
             (seq-take
              (sort combined
                    (lambda (a b)
                      (string> (or (cdr (assq 'date a)) "")
                               (or (cdr (assq 'date b)) ""))))
              (* newsflash-max-items-per-feed 8)) ; keep up to 8x per feed
             newsflash--articles)))

;;; ─── XML feed parser (RSS 2.0 + Atom 1.0) ───────────────────────────────────

(defun newsflash--parse-xml-feed (xml-string feed-name cat-name)
  "Parse XML-STRING as RSS or Atom. Return list of article alists."
  (condition-case err
      (let* ((xml  (with-temp-buffer
                     (insert xml-string)
                     (xml-parse-region (point-min) (point-max))))
             (root (car xml))
             (tag  (xml-node-name root)))
        (cond
         ;; RSS 2.0 — root is <rss>, items are in <channel><item>
         ((eq tag 'rss)
          (let* ((channel (car (xml-get-children root 'channel)))
                 (items   (xml-get-children channel 'item)))
            (newsflash--parse-rss-items items feed-name cat-name)))
         ;; Atom 1.0 — root is <feed>, entries are <entry>
         ((or (eq tag 'feed)
              (string-suffix-p ":feed" (symbol-name tag)))
          (let ((entries (xml-get-children root 'entry)))
            (newsflash--parse-atom-entries entries feed-name cat-name)))
         ;; RDF/RSS 1.0
         ((string-suffix-p ":RDF" (symbol-name tag))
          (let ((items (xml-get-children root 'item)))
            (newsflash--parse-rss-items items feed-name cat-name)))
         (t
          (message "newsflash: unknown feed format <%s> for %s" tag feed-name)
          nil)))
    (error
     (message "newsflash: XML parse error for %s — %s" feed-name err)
     nil)))

(defun newsflash--xml-text (node tag)
  "Extract text content of first TAG child of NODE."
  (let* ((child (car (xml-get-children node tag)))
         (text  (when child
                  (mapconcat
                   (lambda (n) (if (stringp n) n ""))
                   (xml-node-children child)
                   ""))))
    (when text (string-trim (newsflash--strip-html text)))))

(defun newsflash--xml-attr (node tag attr)
  "Get attribute ATTR from first TAG child of NODE."
  (let ((child (car (xml-get-children node tag))))
    (when child (xml-get-attribute child attr))))

(defun newsflash--strip-html (str)
  "Remove HTML tags from STR."
  (when str
    (replace-regexp-in-string
     "&#[0-9]+;" " "
     (replace-regexp-in-string
      "&amp;" "&"
      (replace-regexp-in-string
       "&lt;" "<"
       (replace-regexp-in-string
        "&gt;" ">"
        (replace-regexp-in-string
         "&quot;" "\""
         (replace-regexp-in-string
          "<[^>]+>" ""
          str))))))))

(defun newsflash--parse-rss-items (items feed-name cat-name)
  "Parse RSS <item> nodes. Return article alist list."
  (seq-filter
   #'identity
   (mapcar
    (lambda (item)
      (let* ((title   (newsflash--xml-text item 'title))
             (url     (or (newsflash--xml-text item 'link)
                          (newsflash--xml-attr item 'link 'href)))
             (date    (or (newsflash--xml-text item 'pubDate)
                          (newsflash--xml-text item 'dc:date)
                          (newsflash--xml-text item 'published)))
             (summary (or (newsflash--xml-text item 'description)
                          (newsflash--xml-text item 'content:encoded)
                          (newsflash--xml-text item 'summary))))
        (when (and title url)
          (list (cons 'title    title)
                (cons 'url      url)
                (cons 'source   feed-name)
                (cons 'category cat-name)
                (cons 'date     (or date ""))
                (cons 'summary  (or (newsflash--truncate-summary summary) ""))))))
    items)))

(defun newsflash--parse-atom-entries (entries feed-name cat-name)
  "Parse Atom <entry> nodes. Return article alist list."
  (seq-filter
   #'identity
   (mapcar
    (lambda (entry)
      (let* ((title   (newsflash--xml-text entry 'title))
             ;; Atom links: prefer rel=alternate or first href
             (url     (let ((links (xml-get-children entry 'link)))
                        (or (xml-get-attribute
                             (or (seq-find (lambda (l)
                                             (equal (xml-get-attribute l 'rel) "alternate"))
                                           links)
                                 (car links))
                             'href)
                            (newsflash--xml-text entry 'id))))
             (date    (or (newsflash--xml-text entry 'published)
                          (newsflash--xml-text entry 'updated)))
             (summary (or (newsflash--xml-text entry 'summary)
                          (newsflash--xml-text entry 'content))))
        (when (and title url)
          (list (cons 'title    title)
                (cons 'url      url)
                (cons 'source   feed-name)
                (cons 'category cat-name)
                (cons 'date     (or date ""))
                (cons 'summary  (or (newsflash--truncate-summary summary) ""))))))
    entries)))

;;; ─── Reddit JSON parser ──────────────────────────────────────────────────────

(defun newsflash--parse-reddit-json (json-str feed-name cat-name)
  "Parse Reddit JSON feed string. Return article alist list."
  (condition-case err
      (let* ((json-object-type 'alist)
             (json-array-type  'vector)
             (json-key-type    'symbol)
             (data    (json-read-from-string json-str))
             (listing (cdr (assq 'data data)))
             (posts   (cdr (assq 'children listing))))
        (seq-filter
         #'identity
         (seq-map
          (lambda (post)
            (let* ((pd      (cdr (assq 'data (if (vectorp post) (aref post 0) post))))
                   (title   (cdr (assq 'title   pd)))
                   (url     (or (cdr (assq 'url pd))
                                (cdr (assq 'permalink pd))))
                   (created (cdr (assq 'created_utc pd)))
                   (selftext (cdr (assq 'selftext pd)))
                   (score   (cdr (assq 'score pd))))
              (when (and title url)
                (list (cons 'title    title)
                      (cons 'url      (if (string-prefix-p "/" url)
                                          (concat "https://reddit.com" url)
                                        url))
                      (cons 'source   feed-name)
                      (cons 'category cat-name)
                      (cons 'date     (if created
                                          (format-time-string
                                           "%a, %d %b %Y %H:%M:%S +0000"
                                           (seconds-to-time created))
                                        ""))
                      (cons 'summary  (or (newsflash--truncate-summary selftext) ""))
                      (cons 'score    (or score 0))))))
          (if (vectorp posts) (seq-into posts 'list) posts))))
    (error
     (message "newsflash: Reddit JSON error for %s — %s" feed-name err)
     nil)))

;;; ─── Helpers ─────────────────────────────────────────────────────────────────

(defun newsflash--truncate-summary (text)
  "Clean and truncate TEXT to a reasonable summary length."
  (when (and text (not (string-empty-p (string-trim text))))
    (let* ((clean (string-trim
                   (replace-regexp-in-string
                    "\\s-+" " "
                    (newsflash--strip-html text))))
           (maxlen 280))
      (if (> (length clean) maxlen)
          (concat (substring clean 0 maxlen) "…")
        clean))))

(provide 'newsflash-fetch)
;;; newsflash-fetch.el ends here
