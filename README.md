# newsflash.el — RSS News Reader for Emacs

A lightweight RSS/Atom feed reader that aggregates news from Tech, Crypto, World News, Science, Business, and more — all within Emacs.

![Emacs](https://img.shields.io/badge/Emacs-27.1+-7F5AB6?logo=gnuemacs)
![License](https://img.shields.io/badge/license-GPL--3.0-green)
![Zero Dependencies](https://img.shields.io/badge/dependencies-zero-brightgreen)

---

## Features

- 50+ curated feeds across 7 categories
- Trending content from Reddit, Hacker News, and more
- Reading time estimates per article
- Article age display ("2h ago", "3d ago")
- Save/bookmark articles for later
- Full-text search across loaded articles
- Copy URL to clipboard
- Split-screen reading (dashboard + article)
- Zero external dependencies

---

## Categories & Feeds

| Category | Sources |
|----------|---------|
| Tech & Programming | Hacker News, TechCrunch, The Verge, Ars Technica, Wired, MIT Tech Review |
| Dev Tips | dev.to, CSS-Tricks, Smashing Magazine, freeCodeCamp, Julia Evans, Martin Fowler |
| Crypto & DeFi | CoinDesk, CoinTelegraph, Decrypt, The Defiant, Bitcoin Magazine |
| World News | BBC, The Guardian, Al Jazeera, Associated Press |
| Science | Nature, Science Daily, New Scientist, NASA, arXiv CS |
| Business | Financial Times, Forbes Tech, Bloomberg Tech, MarketWatch |
| Entertainment | Reddit r/popular, r/programming, r/worldnews, Mashable |

---

## Installation

### Manual

```
newsflash/
├── newsflash.el
└── newsflash-fetch.el
```

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/newsflash/")
(require 'newsflash)
```

### use-package

```elisp
(use-package newsflash
  :load-path "~/.emacs.d/lisp/newsflash/"
  :commands (newsflash newsflash-refresh newsflash-search)
  :custom
  (newsflash-refresh-interval    300)
  (newsflash-max-items-per-feed  3)
  (newsflash-max-dashboard-items 8)
  (newsflash-quick-start         t)
  (newsflash-fetch-timeout       5)
  (newsflash-open-links-in       'eww)
  (newsflash-eww-in-side-window  t))
```

---

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `M-x newsflash` | Open the dashboard |
| `M-x newsflash-refresh` | Refresh all feeds |
| `M-x newsflash-category` | Browse a specific category |
| `M-x newsflash-show-all` | Show all articles |
| `M-x newsflash-search` | Search articles |
| `M-x newsflash-show-saved` | View saved articles |

### Keybindings

| Key | Action |
|-----|-------|
| `r` / `g` | Refresh feeds |
| `c` | Browse category |
| `a` | Show all articles |
| `s` | Search |
| `S` | Saved articles |
| `TAB` | Next link |
| `RET` | Open article |
| `q` | Quit |

---

## Configuration

### Basic Settings

```elisp
;; Add custom feeds
(add-to-list 'newsflash-feeds
             '(:category "My Feeds"
               :icon "★"
               :feeds
               (("My Blog" . "https://myblog.com/feed")
                ("Company" . "https://company.com/rss"))))

;; Open links in EWW (default) or system browser
(setq newsflash-open-links-in 'eww)

;; Split-screen reading (dashboard left, article right)
(setq newsflash-eww-in-side-window t)

;; Auto-refresh interval (seconds)
(setq newsflash-refresh-interval 300)

;; Articles per category on dashboard
(setq newsflash-max-dashboard-items 8)

;; Reading speed (words per minute)
(setq newsflash-reading-speed-wpm 200)
```

### Speed Settings

```elisp
;; Faster loading (fewer articles per feed)
(setq newsflash-max-items-per-feed 3)

;; Load only top 3 feeds per category (21 vs 50+)
(setq newsflash-quick-start t)

;; Timeout per feed (seconds)
(setq newsflash-fetch-timeout 5)
```

### Adding Custom Feeds

```elisp
;; Add to existing category
(let ((cat (seq-find (lambda (c)
                       (equal (plist-get c :category) "Tech & Programming"))
                     newsflash-feeds)))
  (when cat
    (plist-put cat :feeds
               (append (plist-get cat :feeds)
                       '(("My Feed" . "https://example.com/rss"))))))

;; Create new category
(push '(:category "My Stuff"
        :icon "★"
        :feeds
        (("Personal Blog" . "https://myblog.com/feed")))
      newsflash-feeds)
```

---

## Troubleshooting

### Slow loading

Enable quick-start mode:

```elisp
(setq newsflash-quick-start t)
(setq newsflash-max-items-per-feed 3)
```

### Articles opening in wrong window

Make sure split-screen is enabled:

```elisp
(setq newsflash-eww-in-side-window t)
```

### Feeds failing to load

Increase timeout for slow feeds:

```elisp
(setq newsflash-fetch-timeout 10)
```

### Reset saved state

```elisp
M-x delete-file RET ~/.emacs.d/newsflash-saved.el RET
```

---

## Support

If you find newsflash.el useful:

**Bitcoin (BTC):**
```
1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7
```

**Ethereum (ETH):**
```
0xe1c6864fdddcef5b5c63b2ea62af91395b569e36
```

---

## Roadmap

- [ ] MELPA submission
- [ ] Keyword filtering (block/highlight)
- [ ] org-mode export
- [ ] OPML import/export
- [ ] Breaking news notifications
- [ ] Feed health monitoring

---

## License

GPL-3.0
