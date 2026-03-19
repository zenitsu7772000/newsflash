;;; newsflash.el --- Viral news & magazine reader for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: You <your@email.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: news, rss, magazine, reader, feeds
;; URL: https://github.com/yourusername/newsflash.el
;;
;; ─────────────────────────────────────────────
;;  Support development:
;;  BTC: 1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7
;;  ETH: 0xe1c6864fdddcef5b5c63b2ea62af91395b569e36
;; ─────────────────────────────────────────────
;;
;;; Commentary:
;;
;; newsflash.el is a viral news & magazine reader for Emacs.
;; Aggregates RSS/Atom feeds across categories:
;;   Tech, Crypto/DeFi, World News, Science,
;;   Business, Entertainment, Dev Tips & Tricks
;;
;; No API key needed. Zero external dependencies.
;;
;; Usage:
;;   M-x newsflash           → open the dashboard
;;   M-x newsflash-category  → browse a specific category
;;   M-x newsflash-refresh   → refresh all feeds
;;   M-x newsflash-search    → search loaded articles
;;
;;; Code:

(require 'url)
(require 'gnutls)
(require 'xml)
(require 'cl-lib)
(require 'seq)
(require 'button)

;;; ─── Submodule loader ────────────────────────────────────────────────────────

(defvar newsflash--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing newsflash.el files.")

(defun newsflash--load (name)
  "Load newsflash submodule NAME."
  (let ((path (expand-file-name (concat name ".el") newsflash--dir)))
    (if (file-exists-p path)
        (load path nil t)
      (message "newsflash: submodule %s not found" name))))

;;; ─── Forward declarations for newsflash-fetch.el ─────────────────────────────

(declare-function newsflash--fetch-all-feeds "newsflash-fetch" ())
(declare-function newsflash--fetch-all-feeds-sync "newsflash-fetch" ())

;;; ─── Customization ───────────────────────────────────────────────────────────

(defgroup newsflash nil
  "Viral news and magazine reader for Emacs."
  :group 'applications
  :prefix "newsflash-")

(defcustom newsflash-refresh-interval 300
  "Auto-refresh interval in seconds (default 5 min). nil = disabled."
  :type '(choice integer (const nil))
  :group 'newsflash)

(defcustom newsflash-max-items-per-feed 3
  "Maximum articles to load per feed (lower = faster)."
  :type 'integer
  :group 'newsflash)

(defcustom newsflash-max-dashboard-items 6
  "Max items to show per category on the dashboard."
  :type 'integer
  :group 'newsflash)

(defcustom newsflash-quick-start t
  "If non-nil, load only top 3 feeds per category initially for faster startup."
  :type 'boolean
  :group 'newsflash)

(defcustom newsflash-fetch-timeout 5
  "Timeout in seconds for each feed fetch (lower = faster failures)."
  :type 'integer
  :group 'newsflash)

(defcustom newsflash-reading-speed-wpm 200
  "Your reading speed in words per minute (for ETA calculation)."
  :type 'integer
  :group 'newsflash)

(defcustom newsflash-open-links-in 'eww
  "How to open article links: `eww' (in Emacs) or `browser'."
  :type '(choice (const :tag "Emacs eww" eww)
                 (const :tag "System browser" browser))
  :group 'newsflash
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (boundp 'newsflash-open-links-in)
           (setq newsflash-open-links-in value))))

(defcustom newsflash-eww-in-side-window t
  "Open EWW in a side window for better reading experience."
  :type 'boolean
  :group 'newsflash)

(defcustom newsflash-saved-file
  (expand-file-name "~/.emacs.d/newsflash-saved.el")
  "File to persist saved/bookmarked articles."
  :type 'file
  :group 'newsflash)

;;; ─── Feed registry ───────────────────────────────────────────────────────────

(defvar newsflash-feeds
  '((:category "Tech & Programming"
     :icon "[TECH]"
     :feeds
     (("Hacker News Top"      . "https://hnrss.org/frontpage")
      ("Hacker News Best"     . "https://hnrss.org/best")
      ("TechCrunch"           . "https://techcrunch.com/feed/")
      ("The Verge"            . "https://www.theverge.com/rss/index.xml")
      ("Ars Technica"         . "https://feeds.arstechnica.com/arstechnica/index")
      ("Wired"                . "https://www.wired.com/feed/rss")
      ("MIT Tech Review"      . "https://www.technologyreview.com/feed/")))

    (:category "Dev Tips & Tricks"
     :icon "[DEV]"
     :feeds
     (("dev.to"               . "https://dev.to/feed")
      ("CSS-Tricks"           . "https://css-tricks.com/feed/")
      ("Smashing Magazine"    . "https://www.smashingmagazine.com/feed/")
      ("freeCodeCamp"         . "https://www.freecodecamp.org/news/rss/")
      ("Tania Rascia"         . "https://www.taniarascia.com/rss.xml")
      ("Julia Evans"          . "https://jvns.ca/atom.xml")
      ("Martin Fowler"        . "https://martinfowler.com/feed.atom")))

    (:category "Crypto & DeFi"
     :icon "[CRYPTO]"
     :feeds
     (("CoinDesk"             . "https://www.coindesk.com/arc/outboundfeeds/rss/")
      ("CoinTelegraph"        . "https://cointelegraph.com/rss")
      ("Decrypt"              . "https://decrypt.co/feed")
      ("The Defiant"          . "https://thedefiant.io/feed")
      ("DeFi Pulse Blog"      . "https://blog.defipulse.com/rss/")
      ("Bitcoin Magazine"     . "https://bitcoinmagazine.com/.rss/full/")))

    (:category "World News"
     :icon "[NEWS]"
     :feeds
     (("BBC World"            . "https://feeds.bbci.co.uk/news/world/rss.xml")
      ("The Guardian"         . "https://www.theguardian.com/world/rss")
      ("Al Jazeera"           . "https://www.aljazeera.com/xml/rss/all.xml")
      ("Associated Press"     . "https://feeds.apnews.com/rss/apf-topnews")))

    (:category "Science"
     :icon "[SCIENCE]"
     :feeds
     (("Nature"               . "https://www.nature.com/nature.rss")
      ("Science Daily"        . "https://www.sciencedaily.com/rss/all.xml")
      ("New Scientist"        . "https://www.newscientist.com/feed/home/")
      ("NASA Breaking News"   . "https://www.nasa.gov/rss/dyn/breaking_news.rss")
      ("arXiv CS"             . "https://arxiv.org/rss/cs")))

    (:category "Business & Finance"
     :icon "[BUSINESS]"
     :feeds
     (("Financial Times"      . "https://www.ft.com/rss/home/uk")
      ("Forbes Tech"          . "https://www.forbes.com/innovation/feed2")
      ("Bloomberg Tech"       . "https://feeds.bloomberg.com/technology/news.rss")
      ("MarketWatch"          . "https://feeds.marketwatch.com/marketwatch/topstories/")
      ("Business Insider"     . "https://www.businessinsider.com/rss")))

    (:category "Entertainment & Viral"
     :icon "[ENTERTAINMENT]"
     :feeds
     (("Hacker News Show HN"  . "https://hnrss.org/show")
      ("Hacker News Ask HN"   . "https://hnrss.org/ask")
      ("Mashable"             . "https://mashable.com/feeds/rss/all")
      ("BuzzFeed"             . "https://www.buzzfeed.com/index.xml")
      ("The Guardian Tech"    . "https://www.theguardian.com/technology/rss"))))
  "Master feed registry. Each entry is a plist with :category, :icon, :feeds.")

;;; ─── Article data structure ──────────────────────────────────────────────────
;;
;; Each article is an alist:
;;   (title . "...")  (url . "...")  (source . "...")
;;   (category . "...") (date . "...") (summary . "...")
;;   (read . nil/t)   (saved . nil/t)

;;; ─── Global state ────────────────────────────────────────────────────────────

(defvar newsflash--articles (make-hash-table :test 'equal)
  "Hash: category-string → list of article alists.")

(defvar newsflash--saved '()
  "List of saved/bookmarked article alists.")

(defvar newsflash--read-urls (make-hash-table :test 'equal)
  "Set of URLs the user has opened (marked as read).")

(defvar newsflash--refresh-timer nil
  "Auto-refresh timer.")

(defvar newsflash--last-refresh nil
  "Time of last full refresh.")

(defvar newsflash--fetch-pending 0
  "Number of pending async fetches.")

(defvar newsflash--fetch-total 0
  "Total fetches started in current refresh cycle.")

;;; ─── Faces ───────────────────────────────────────────────────────────────────

(defface newsflash-header
  '((t :foreground "#ff6b9d" :weight bold))
  "Dashboard header.")

(defface newsflash-category
  '((t :foreground "#ffcc00" :weight bold))
  "Category label.")

(defface newsflash-title
  '((t :foreground "#c9d1ff"))
  "Article title (unread).")

(defface newsflash-title-read
  '((t :foreground "#556677"))
  "Article title (read).")

(defface newsflash-source
  '((t :foreground "#55ccff" :slant italic))
  "Feed source name.")

(defface newsflash-date
  '((t :foreground "#778899"))
  "Article date.")

(defface newsflash-summary
  '((t :foreground "#aabbcc"))
  "Article summary text.")

(defface newsflash-new-badge
  '((t :foreground "#000000" :background "#00ff88" :weight bold))
  "NEW badge.")

(defface newsflash-hot-badge
  '((t :foreground "#000000" :background "#ff4444" :weight bold))
  "HOT badge.")

(defface newsflash-saved-badge
  '((t :foreground "#ffcc00" :weight bold))
  "Saved/bookmarked badge.")

(defface newsflash-separator
  '((t :foreground "#223344"))
  "Separator lines.")

(defface newsflash-key
  '((t :foreground "#55ccff"))
  "Keybinding hints.")

(defface newsflash-label
  '((t :foreground "#556677"))
  "Dim label text.")

(defface newsflash-donation
  '((t :foreground "#ffaa00" :slant italic))
  "Donation footer.")

(defface newsflash-reading-time
  '((t :foreground "#aa88ff"))
  "Reading time estimate.")

(defface newsflash-count
  '((t :foreground "#00ff88" :weight bold))
  "Article count badge.")

;;; ─── Persistence ─────────────────────────────────────────────────────────────

(defun newsflash--save-state ()
  "Persist saved articles and read URLs."
  (condition-case err
      (with-temp-file newsflash-saved-file
        (let ((print-length nil) (print-level nil))
          (prin1 (list :saved newsflash--saved
                       :read  (let (urls)
                                (maphash (lambda (k _) (push k urls))
                                         newsflash--read-urls)
                                urls))
                 (current-buffer))))
    (error (message "newsflash: could not save state: %s" err))))

(defun newsflash--load-state ()
  "Load persisted saved articles and read URLs."
  (when (file-exists-p newsflash-saved-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents newsflash-saved-file)
          (let ((data (read (current-buffer))))
            (setq newsflash--saved (plist-get data :saved))
            (dolist (url (plist-get data :read))
              (puthash url t newsflash--read-urls))))
      (error (message "newsflash: could not load state: %s" err)))))

;;; ─── Dashboard mode ──────────────────────────────────────────────────────────

(defvar newsflash-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r")   #'newsflash-refresh)
    (define-key map (kbd "g")   #'newsflash-refresh)
    (define-key map (kbd "s")   #'newsflash-search)
    (define-key map (kbd "S")   #'newsflash-show-saved)
    (define-key map (kbd "c")   #'newsflash-category)
    (define-key map (kbd "a")   #'newsflash-show-all)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keymap for newsflash dashboard.")

(define-derived-mode newsflash-mode special-mode "NewsFlash"
  "Major mode for the newsflash.el news dashboard."
  (setq buffer-read-only t
        truncate-lines   t))

;;; ─── Dashboard render ────────────────────────────────────────────────────────

(defun newsflash--buffer ()
  "Return or create the main dashboard buffer."
  (get-buffer-create "*newsflash*"))

(defun newsflash--total-unread ()
  "Count total unread articles across all categories."
  (let ((n 0))
    (maphash
     (lambda (_ articles)
       (dolist (a articles)
         (unless (gethash (cdr (assq 'url a)) newsflash--read-urls)
           (cl-incf n))))
     newsflash--articles)
    n))

(defun newsflash--render-dashboard ()
  "Render the full dashboard buffer."
  (with-current-buffer (newsflash--buffer)
    (let ((inhibit-read-only t)
          (saved-pt (point)))
      (erase-buffer)
      (unless (eq major-mode 'newsflash-mode)
        (newsflash-mode))

      ;; ── Header ──────────────────────────────────────────────────────────────
      (insert "╔══════════════════════════════════════════════════════════════╗\n")
      (insert (propertize "║  NEWSFLASH — Viral News & Magazine Reader for Emacs        ║\n" 'face 'newsflash-header))
      (insert "╚══════════════════════════════════════════════════════════════╝\n")
      (insert "\n")

      ;; Loading progress bar
      (when (and newsflash--fetch-total (> newsflash--fetch-pending 0))
        (let* ((done (- newsflash--fetch-total newsflash--fetch-pending))
               (pct (/ (* 100 done) newsflash--fetch-total))
               (filled (/ (* pct 40) 100))
               (bar (concat (make-string filled ?█) (make-string (- 40 filled) ?░))))
          (insert (propertize (format " Loading: [%s] %d/%d (%d%%)\n" bar done newsflash--fetch-total pct)
                              'face 'newsflash-new-badge))))

      ;; Stats row
      (let ((unread (newsflash--total-unread))
            (total  0)
            (last   (if newsflash--last-refresh
                        (format-time-string "%H:%M:%S" newsflash--last-refresh)
                      "never")))
        (maphash (lambda (_ arts) (cl-incf total (length arts))) newsflash--articles)
        (insert (format " %s articles loaded  "
                        (propertize (number-to-string total) 'face 'newsflash-count)))
        (insert (propertize (format "%d unread  " unread) 'face 'newsflash-new-badge))
        (insert (format "updated: %s\n" last)))
      (insert "\n")

      ;; Keys
      (insert (propertize " [r]efresh  [c]ategory  [a]ll articles  [s]earch  [S]aved  [q]uit\n" 'face 'newsflash-key))
      (insert " ────────────────────────────────────────────────────────────────\n")
      (insert "\n")

      ;; ── Per-category sections ────────────────────────────────────────────────
      (if (= (hash-table-count newsflash--articles) 0)
          (progn
            (insert " No articles loaded yet.\n\n")
            (insert " Press ")
            (insert (propertize "[r]" 'face 'newsflash-key))
            (insert " to fetch the latest news from all feeds.\n"))
        (dolist (cat-def newsflash-feeds)
          (let* ((cat-name (plist-get cat-def :category))
                 (icon     (plist-get cat-def :icon))
                 (articles (gethash cat-name newsflash--articles))
                 (unread   (seq-count
                            (lambda (a)
                              (not (gethash (cdr (assq 'url a)) newsflash--read-urls)))
                            (or articles '()))))
            (when (and articles (> (length articles) 0))
              ;; Category header
              (insert (propertize
                       (format " %s  %s" icon cat-name)
                       'face 'newsflash-category))
              (insert (format " [%d unread]  " unread))
              (insert-button "[see all]"
                             'action (lambda (b)
                                       (newsflash--show-category (button-get b 'cat)))
                             'cat cat-name
                             'face 'newsflash-key
                             'follow-link t)
              (insert "\n")
              (insert " ────────────────────────────────────────────────────────────────\n")
              ;; Top N articles for this category
              (dolist (article (seq-take articles newsflash-max-dashboard-items))
                (newsflash--insert-article-row article))
              (insert "\n")))))

      ;; ── Saved section ────────────────────────────────────────────────────────
      (when newsflash--saved
        (insert (propertize " SAVED ARTICLES\n" 'face 'newsflash-category))
        (insert " ────────────────────────────────────────────────────────────────\n")
        (dolist (a (seq-take newsflash--saved 5))
          (newsflash--insert-article-row a))
        (insert "\n"))

      ;; ── Footer ───────────────────────────────────────────────────────────────
      (insert " ────────────────────────────────────────────────────────────────\n")
      (insert (propertize " Support newsflash.el:\n" 'face 'newsflash-donation))
      (insert (propertize "    BTC: 1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7\n" 'face 'newsflash-donation))
      (insert (propertize "    ETH: 0xe1c6864fdddcef5b5c63b2ea62af91395b569e36\n" 'face 'newsflash-donation))
      (insert " ────────────────────────────────────────────────────────────────\n")

      (goto-char (min saved-pt (point-max))))))

;;; ─── Article row renderer ────────────────────────────────────────────────────

(defun newsflash--reading-time (text)
  "Estimate reading time for TEXT in minutes (returns string)."
  (let* ((words (length (split-string (or text "") "\\W+" t)))
         (mins  (ceiling (/ (float words) newsflash-reading-speed-wpm))))
    (if (< mins 1) "<1 min" (format "%d min" mins))))

(defun newsflash--age-string (date-str)
  "Return human-friendly age string for DATE-STR."
  (condition-case _
      (let* ((parsed (date-to-time date-str))
             (delta  (float-time (time-subtract (current-time) parsed)))
             (mins   (/ delta 60))
             (hours  (/ delta 3600))
             (days   (/ delta 86400)))
        (cond
         ((< mins 60)   (format "%.0fm ago" mins))
         ((< hours 24)  (format "%.0fh ago" hours))
         ((< days 7)    (format "%.0fd ago" days))
         (t             (format-time-string "%b %d" parsed))))
    (error "")))

(defun newsflash--insert-article-row (article)
  "Insert a single article row with button and metadata."
  (let* ((title   (or (cdr (assq 'title   article)) "Untitled"))
         (url     (or (cdr (assq 'url     article)) ""))
         (source  (or (cdr (assq 'source  article)) ""))
         (date    (or (cdr (assq 'date    article)) ""))
         (summary (or (cdr (assq 'summary article)) ""))
         (saved   (member url (mapcar (lambda (a) (cdr (assq 'url a)))
                                      newsflash--saved)))
         (read    (gethash url newsflash--read-urls))
         (age     (newsflash--age-string date))
         (rt      (newsflash--reading-time summary))
         (title-face (if read 'newsflash-title-read 'newsflash-title)))
    ;; Badge
    (insert "  ")
    (insert (if saved (propertize "[SAVED] " 'face 'newsflash-saved-badge) "  "))
    ;; Title button
    (insert-button
     (truncate-string-to-width title 65 nil nil "…")
     'action      (lambda (b)
                    (let ((u (button-get b 'url))
                          (a (button-get b 'article)))
                      (puthash u t newsflash--read-urls)
                      (newsflash--open-url u)
                      (newsflash--save-state)))
     'url         url
     'article     article
     'face        title-face
     'follow-link t)
    (insert "\n")
    ;; Meta row - simplified
    (insert (format "     %s  %s  %s  "
                    (propertize source 'face 'newsflash-source)
                    (propertize age    'face 'newsflash-date)
                    (propertize rt     'face 'newsflash-reading-time)))
    ;; Save/unsave button
    (if saved
        (insert-button "[unsave]"
                       'action  (lambda (b)
                                  (newsflash--unsave-article (button-get b 'url))
                                  (newsflash--render-dashboard))
                       'url     url
                       'face    'newsflash-key
                       'follow-link t)
      (insert-button "[save]"
                     'action  (lambda (b)
                                (newsflash--save-article (button-get b 'article))
                                (newsflash--render-dashboard))
                     'article article
                     'face    'newsflash-key
                     'follow-link t))
    (insert "  ")
    (insert-button "[copy url]"
                   'action  (lambda (b)
                               (kill-new (button-get b 'url))
                               (message "newsflash: URL copied to clipboard"))
                   'url     url
                   'face    'newsflash-key
                   'follow-link t)
    (insert "\n")
    ;; Summary (first 120 chars)
    (unless (string-empty-p summary)
      (insert (propertize
               (concat "     "
                       (truncate-string-to-width
                        (replace-regexp-in-string "[\n\r]+" " " summary)
                        100 nil nil "…")
                       "\n")
               'face 'newsflash-summary)))
    (insert "\n")))

;;; ─── URL opener ──────────────────────────────────────────────────────────────

(defun newsflash--open-url (url)
  "Open URL in browser or eww per `newsflash-open-links-in'."
  (pcase newsflash-open-links-in
    ('eww     (if newsflash-eww-in-side-window
                  (let ((dashboard-window (selected-window))
                        (dashboard-buffer (current-buffer)))
                    ;; Prevent eww from using current window
                    (let ((display-buffer-alist
                           '(("\\*eww\\*"
                              (display-buffer-in-side-window)
                              (side . right)
                              (window-width . 0.5)
                              (inhibit-same-window . t))))
                          (eww-auto-select-mode 'never))
                      (eww url))
                    ;; Ensure focus stays on dashboard
                    (select-window dashboard-window)
                    (switch-to-buffer dashboard-buffer))
                (eww url)))
    (_        (browse-url url))))

;;; ─── Save / unsave ───────────────────────────────────────────────────────────

(defun newsflash--save-article (article)
  "Save ARTICLE to bookmarks."
  (let ((url (cdr (assq 'url article))))
    (unless (member url (mapcar (lambda (a) (cdr (assq 'url a))) newsflash--saved))
      (push article newsflash--saved)
      (newsflash--save-state)
      (message "newsflash: article saved"))))

(defun newsflash--unsave-article (url)
  "Remove article with URL from saved list."
  (setq newsflash--saved
        (seq-remove (lambda (a) (equal (cdr (assq 'url a)) url))
                    newsflash--saved))
  (newsflash--save-state)
  (message "newsflash: article removed from saved"))

;;; ─── Category view ───────────────────────────────────────────────────────────

(defun newsflash--show-category (cat-name)
  "Show all articles for CAT-NAME in a dedicated buffer."
  (let* ((articles (gethash cat-name newsflash--articles))
         (buf      (get-buffer-create (format "*newsflash: %s*" cat-name))))
    (switch-to-buffer buf)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (insert (propertize (format " %s\n" cat-name) 'face 'newsflash-category))
      (insert (propertize (format " %d articles\n\n" (length articles)) 'face 'newsflash-label))
      (if (null articles)
          (insert (propertize " No articles. Press [r] to refresh.\n" 'face 'newsflash-label))
        (dolist (a articles)
          (newsflash--insert-article-row a)))
      (insert (propertize "\n [q] Back to dashboard  [r] Refresh\n" 'face 'newsflash-key))
      (local-set-key (kbd "q") #'quit-window)
      (local-set-key (kbd "r") #'newsflash-refresh)
      (goto-char (point-min)))))

;;;###autoload
(defun newsflash-category ()
  "Interactively pick a category to browse."
  (interactive)
  (let* ((cats   (mapcar (lambda (c) (plist-get c :category)) newsflash-feeds))
         (chosen (completing-read "Browse category: " cats nil t)))
    (newsflash--show-category chosen)))

;;;###autoload
(defun newsflash-show-all ()
  "Show every loaded article across all categories."
  (interactive)
  (let ((buf (get-buffer-create "*newsflash: All Articles*"))
        (all '()))
    (maphash (lambda (_ arts) (setq all (append all arts))) newsflash--articles)
    (switch-to-buffer buf)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (insert (propertize (format " All Articles (%d)\n\n" (length all)) 'face 'newsflash-category))
      (dolist (a all) (newsflash--insert-article-row a))
      (insert (propertize "\n [q] Back  [r] Refresh\n" 'face 'newsflash-key))
      (local-set-key (kbd "q") #'quit-window)
      (local-set-key (kbd "r") #'newsflash-refresh)
      (goto-char (point-min)))))

;;;###autoload
(defun newsflash-show-saved ()
  "Show saved/bookmarked articles."
  (interactive)
  (let ((buf (get-buffer-create "*newsflash: Saved*")))
    (switch-to-buffer buf)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (insert (propertize (format " Saved Articles (%d)\n\n" (length newsflash--saved))
                          'face 'newsflash-category))
      (if (null newsflash--saved)
          (insert (propertize " No saved articles yet. Press [save] on any article.\n"
                              'face 'newsflash-label))
        (dolist (a newsflash--saved)
          (newsflash--insert-article-row a)))
      (insert (propertize "\n [q] Back\n" 'face 'newsflash-key))
      (local-set-key (kbd "q") #'quit-window)
      (goto-char (point-min)))))

;;;###autoload
(defun newsflash-search ()
  "Search loaded articles by title or summary."
  (interactive)
  (let* ((query   (read-string "Search articles: "))
         (query-l (downcase query))
         (results '()))
    (when (string-empty-p query)
      (user-error "newsflash: search query cannot be empty"))
    (maphash
     (lambda (_ arts)
       (dolist (a arts)
         (when (or (string-match-p query-l (downcase (or (cdr (assq 'title   a)) "")))
                   (string-match-p query-l (downcase (or (cdr (assq 'summary a)) "")))
                   (string-match-p query-l (downcase (or (cdr (assq 'source  a)) ""))))
           (push a results))))
     newsflash--articles)
    (let ((buf (get-buffer-create "*newsflash: Search*")))
      (switch-to-buffer buf)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize (format " Search: \"%s\" — %d results\n\n" query (length results))
                            'face 'newsflash-category))
        (if (null results)
            (insert (propertize " No results found.\n" 'face 'newsflash-label))
          (dolist (a results) (newsflash--insert-article-row a)))
        (insert (propertize "\n [q] Back\n" 'face 'newsflash-key))
        (local-set-key (kbd "q") #'quit-window)
        (goto-char (point-min))))))

;;; ─── Auto-refresh ────────────────────────────────────────────────────────────

(defun newsflash--start-refresh-timer ()
  "Start auto-refresh timer."
  (newsflash--stop-refresh-timer)
  (when newsflash-refresh-interval
    (setq newsflash--refresh-timer
          (run-with-timer newsflash-refresh-interval
                          newsflash-refresh-interval
                          #'newsflash-refresh))))

(defun newsflash--stop-refresh-timer ()
  "Stop auto-refresh timer."
  (when (timerp newsflash--refresh-timer)
    (cancel-timer newsflash--refresh-timer)
    (setq newsflash--refresh-timer nil)))

;;; ─── Entry points ────────────────────────────────────────────────────────────

;;;###autoload
(defun newsflash ()
  "Open the newsflash.el news dashboard."
  (interactive)
  (newsflash--load-state)
  (newsflash--load "newsflash-fetch")
  (if (= (hash-table-count newsflash--articles) 0)
      ;; First time: fetch synchronously before showing dashboard
      (progn
        (message "newsflash: loading feeds, please wait...")
        (newsflash--fetch-all-feeds-sync)
        (message "newsflash: loaded %d articles"
                 (let ((n 0))
                   (maphash (lambda (_ arts) (cl-incf n (length arts)))
                            newsflash--articles)
                   n))))
  ;; Show dashboard with articles
  (switch-to-buffer (newsflash--buffer))
  (newsflash--render-dashboard)
  (message "newsflash: press [r] to refresh feeds")
  (newsflash--start-refresh-timer))

;;;###autoload
(defun newsflash-refresh ()
  "Refresh all feeds."
  (interactive)
  (message "newsflash: refreshing all feeds (async)...")
  (newsflash--load "newsflash-fetch")
  (newsflash--fetch-all-feeds))

;;;###autoload
(defun newsflash-refresh-sync ()
  "Refresh all feeds synchronously (blocking)."
  (interactive)
  (message "newsflash: refreshing all feeds, please wait...")
  (newsflash--load "newsflash-fetch")
  (newsflash--fetch-all-feeds-sync)
  (switch-to-buffer (newsflash--buffer))
  (newsflash--render-dashboard)
  (message "newsflash: loaded %d articles"
           (let ((n 0))
             (maphash (lambda (_ arts) (cl-incf n (length arts)))
                      newsflash--articles)
             n)))

(provide 'newsflash)
;;; newsflash.el ends here
