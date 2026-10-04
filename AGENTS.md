# rubichiver — Unified Booru Media Archiver

## System Overview
A Ruby CLI tool that downloads media from e621.net and Gelbooru, fetches post metadata via their respective JSON APIs, keeps files in original format, and writes XMP sidecar files (.xmp) carrying categorized keywords, rating, artist, dates, sources and post page. Runs as a one-shot batch job reading tag queries from a file. Every post's full detail is also recorded in a shared SQLite database. Unified from separate `rubichiver-e621` and `rubichiver-gelbooru` gems.

## Tech Stack
- **Language:** Ruby 3.x
- **Gems:** `sqlite3` (archive database). Everything else is stdlib.
- **External Tools:** ExifTool (XMP sidecar writing)
- **APIs:**
  - e621.net v2 JSON API (`/posts.json?page=N&limit=320&v2=true&mode=extended`)
    - From <https://e621.net/help/api>: "a hard rate limit of **two requests per second**... if you are hitting it, you are already going way too fast. Hitting the rate limit will result in a **503** HTTP response code." Best effort requested: **≤1 req/s sustained**.
    - A descriptive `User-Agent` is **required**, and e621 asks that it carry the account name so you can be contacted. `user_agent` includes it.
    - For bulk/tens-of-thousands of lookups e621 points at the daily database exports: <https://e621.net/db_export/>
  - Gelbooru API (`/index.php?page=dapi&s=post&q=index&pid=N&limit=100&json=1`)
    - From <https://gelbooru.com/index.php?page=wiki&s=view&id=18780>: authentication is required "to mitigate abusive behavior", and "your requests will not be limited if you have contributed to the Patreon in the past" — i.e. non-Patreon accounts are throttled.

## Directory Structure
```
rubichiver/
├── rubichiver.rb          # Unified entry point (--site e621|gelbooru)
├── version.rb             # Rubichiver::VERSION
├── archiver_base.rb        # Base Archiver class with shared logic
├── archiver_e621.rb        # e621-specific API/search/download/sidecar
├── archiver_gelbooru.rb    # Gelbooru-specific API/search/download/sidecar
├── blacklist.rb            # Blacklist parser (e621 syntax)
├── archive_db.rb           # SQLite store of file provenance + full post metadata
├── logger.rb               # Structured logging (JSON + human) + Logging mixin
├── dns_cache.rb            # Cached DNS resolution + TCPSocket patch
├── post_processor.rb       # Worker pool + Stats
├── rate_limiter.rb         # Thread-safe API rate limiter + per-worker pool (monotonic clock)
├── Rakefile                # rake test
├── Gemfile                 # sqlite3
├── .github/workflows/      # CI: test on Ruby 3.1-3.4
├── e621-api-credentials.txt     # e621: USERNAME= / API_KEY= (gitignored)
├── gelbooru-api-credentials.txt # Gelbooru: USER_ID= / API_KEY= / USERNAME= (gitignored)
├── tags.txt                # Tag queries (gitignored)
├── blacklist.txt           # Blacklist rules (gitignored)
└── test/                   # Minitest suite
```

## API Reference: e621

### Base URL & Auth
- `https://e621.net` — all endpoints use `/posts.json`, `/uploads.json`, etc.
- Auth: Basic auth via `Authorization` header, or `login`+`api_key` query params
- API key generated at Account > My profile
- **User-Agent required** — custom descriptive string, never impersonate a browser
- **Rate limit:** 2 req/s hard cap, best effort ≤1 req/s sustained
- **CORS:** GET + POST simple requests allowed cross-origin; PATCH/PUT/DELETE not

### Source Code
- e621: `https://github.com/e621ng/e621ng` (Rails, MIT, 544★, 12,469 commits)
- Danbooru (upstream): `https://github.com/danbooru/danbooru` (Rails, 2.8k★, 14,571 commits)

### v1/v2 Response Format Migration
- **Phase 1 (Now — Dec 2026):** Legacy (v1) default, `v2=true` opts in
- **Phase 2 (Dec 2026 — May 2027):** New (v2) default, `v1=true` keeps legacy
- **Phase 3 (May 2027+):** Legacy format removed entirely
- Affects all post endpoints: `/posts.json`, show, random, md5 lookups

### v2 Format Details
- No more `{ "posts": [...] }` wrapper — raw array/object directly
- `mode` parameter controls tag detail:
  - `mode=basic` — tags as flat array (default, faster)
  - `mode=extended` — tags grouped by category (legacy-compatible)
  - `mode=thumbnails` — lightweight for grid views
- Fields grouped into `files`, `stats`, `flags`, `has`, `relationships` objects
- Legacy `only` parameter removed

### v2 Post Response Structure
```json
{
  "id": 4149486,
  "created_at": "2023-07-04T01:21:33.766-07:00",
  "updated_at": "2026-05-06T07:49:00.191-07:00",
  "change_seq": 70845555,
  "files": {
    "meta": { "md5": "...", "ext": "png", "size": 6749159, "duration": null, "has_sample": true },
    "original": { "width": 1874, "height": 1970, "url": "https://static1.e621.net/data/..." },
    "preview": { "width": 256, "height": 269, "jpg": "...", "webp": "..." },
    "sample": { "width": 850, "height": 894, "jpg": "...", "webp": "..." }
  },
  "uploader_id": 509791,
  "uploader_name": "gattonero2001",
  "approver_id": 12286,
  "stats": { "score": { "up": 3992, "down": -29, "total": 3963 }, "fav_count": 6125, "is_favorited": false, "comment_count": 81 },
  "flags": { "pending": false, "flagged": false, "note_locked": false, "status_locked": false, "rating_locked": false, "deleted": false },
  "has": { "parent": false, "children": false, "active_children": false, "notes": false, "sample": true },
  "relationships": { "parent_id": null, "children": [] },
  "pools": [],
  "rating": "s",
  "locked_tags": [],
  "sources": ["https://..."],
  "description": "",
  "tags": []
}
```

### e621 Endpoints
| Function | Endpoint | Method |
|----------|----------|--------|
| Search posts | `/posts.json` | GET |
| Upload | `/uploads.json` | POST |
| Update post | `/posts/<id>.json` | PATCH |
| Search flags | `/post_flags.json` | GET |
| Create flag | `/post_flags.json` | POST |
| Vote | `/posts/<id>/votes.json` | POST |
| Favorite | `/favorites.json` | POST |
| Delete favorite | `/favorites/<id>.json` | DELETE |
| Search notes | `/notes.json` | GET |
| Create note | `/notes.json` | POST |
| Update note | `/notes/<id>.json` | PUT |
| Delete note | `/notes/<id>.json` | DELETE |
| Revert note | `/notes/<id>/revert.json` | PUT |
| Search pools | `/pools.json` | GET |
| Show pool | `/pools/<id>.json` | GET |
| Create pool | `/pools.json` | POST |
| Update pool | `/pools/<id>.json` | PUT |
| Revert pool | `/pools/<id>/revert.json` | PUT |

### e621 Tag Categories
- `0` general, `1` artist, `2` contributor, `3` copyright, `4` character, `5` species, `6` invalid, `7` meta, `8` lore

### e621 Tag Search Parameters
- `search[name_matches]` — wildcard with `*`
- `search[category]` — numeric category filter
- `search[order]` — `date`, `count`, `name`
- `search[hide_empty]` — `true`/`false`
- `search[has_wiki]` — `true`/`false`/blank
- `search[has_artist]` — `true`/`false`/blank
- `limit` — max 320
- `page` — `a<id>` (after), `b<id>` (before), or numeric

### e621 Pools
- A post carries `pools` (array of pool ids) in both v1 and v2 responses.
- `GET /pools/<id>.json` returns the members as `post_ids`, with `post_count`,
  `is_active` and `name`. v1 wraps it in `{"pool": {...}}` and calls the list
  `posts`; `E621Archiver#parse_pool` accepts both.
- Members are fetched with the comma-separated `id:` search, 100 ids per request
  (`POOL_POST_BATCH`), and never through the API response cache.
- Pool names are slugified for the directory name; the slug is frozen in the
  archive database the first time a pool is seen.

### e621 HTTP Status Codes
- `200` OK, `204` No Content (delete), `400` unavailable feature, `401` bad auth, `403` forbidden (missing UA), `404` not found, `405` wrong method, `406` format not allowed, `410` gone (invalid pagination), `412` precondition failed (upload invalid/duplicate), `422` invalid param, `429` rate limited, `500` server error, `502` bad gateway, `503` unavailable/rate limit, `520` unknown, `522` CF timeout, `524` CF timeout, `525` SSL failure

### OpenAPI Spec
- Community maintained at `https://e621.wiki/openapi.yaml`

## API Reference: Gelbooru

### Base URL & Auth
- `https://gelbooru.com/index.php?page=dapi&s=post&q=index`
- Auth via query params: `api_key=...&user_id=...`
- Rate throttling enforced for non-Patreon supporters

### Gelbooru Endpoints
| Function | Endpoint |
|----------|----------|
| Search posts | `?page=dapi&s=post&q=index` with `tags`, `pid`, `limit`, `json=1` |
| Search tags | `?page=dapi&s=tag&q=index` with `name`, `name_pattern`, `order`, `orderby` |
| Search users | `?page=dapi&s=user&q=index` with `name`, `name_pattern` |
| Get comments | `?page=dapi&s=comment&q=index` with `post_id` |
| Deleted images | `?page=dapi&s=post&q=index&deleted=show` with `last_id` |

### Gelbooru Post Parameters
- `limit` — default 100
- `pid` — page number (0-indexed)
- `tags` — tag search (same as web)
- `cid` — change ID (Unix time)
- `id` — specific post ID
- `json=1` — JSON response

### Gelbooru Tag Parameters
- `id` — specific tag
- `limit` — default 100
- `after_id` — tags with ID > this value
- `name` — exact name search
- `names` — space-separated multi-tag lookup
- `name_pattern` — LIKE wildcard (`_` single, `%` multi)
- `order` / `orderby` — `date`, `count`, `name`; `ASC`/`DESC`

## How to Run
```bash
ruby rubichiver.rb --site e621 [OPTIONS]
ruby rubichiver.rb --site gelbooru [OPTIONS]
ruby rubichiver.rb --help        # authoritative option list
```

| Flag | Description |
|------|-------------|
| `-s, --site SITE` | Target site: `e621` or `gelbooru` (required) |
| `-o, --output DIR` | Output directory |
| `-t, --tags FILE` | Tags file (default: ./tags.txt) |
| `-b, --blacklist FILE` | Blacklist file (e621 syntax, default: ./blacklist.txt) |
| `-C, --cache-dir DIR` | API response cache directory (default: $output/cache) |
| `-c, --credentials FILE` | Credentials file (default: ./<site>-api-credentials.txt) |
| `--dry-run` | Preview posts that would be archived, writing nothing |
| `--recache-post-tags` | Refresh cached tags of every archived post, no downloads |
| `--[no-]pools` | Bundle a whole pool when a found post belongs to one (default on) |
| `--[no-]repair-missing` | Re-fetch posts that have a sidecar but no media (default on) |
| `--db FILE` | Archive database (default: `/mnt/hdd/rubichiver-database.db`, or `$RUBICHIVER_DB`) |
| `--cache-max-age DAYS` | Drop cached API pages older than DAYS (default: 90, 0 disables) |
| `--verify-md5` | Re-hash archived files against the database on startup (slow) |
| `--notify URL` | POST a JSON run report on completion |
| `-j, --threads N` | Worker threads (default: 2) |
| `--rate-limit N` | Requests per second **per worker thread** (default: 8; run total is this × `-j`). A ceiling that does not bind: a measured run issued 2,856 requests in 10 hours (0.08 req/s), so the run is bound by exiftool and disk seeks, not the API. It matters for request-bound work — Gelbooru recache is one request per archived post. Going over the site's limit is therefore not the risk it looks like; the real protection is e621's own 503 plus the adaptive back-off |
| `-v, --verbose` | Verbose output |
| `--json` | JSON log output |
| `--version` | Print the version |

## Key Conventions
- **Unified runner** — `--site e621|gelbooru` dispatches to the correct archiver subclass
- **Scheduling** — systemd *user* timers (`rubichiver-archive.timer` weekly, `rubichiver-recheck.timer` monthly), both `Persistent=true`. The scripts they call run the two sites sequentially; `Conflicts=` keeps the two passes off the database at the same time
- **ArchiverBase** — shared run loop: load credentials → lock output dir → build post list → enqueue → process → report
- **Post discovery** — per-line tag queries from `tags.txt` (`#` comments ignored), paginated via `fetch_all_posts_for_query`
- **Locations** — `post_locations` maps a post to one `Location` per place it belongs: `posts/` (`POSTS_DIR`, the root location), or one bundle directory per e621 pool. A post in two pools has two locations. The archive root itself holds only the lock file, the database, `posts/` and `pools/`
- **Layout migration** — `migrate_loose_files_to_posts` runs before the scan and moves any `\A\d+\.` files left at the archive root (media, sidecars, `.part`, `.damaged-*`) into `posts/`, then `ArchiveDb#relocate_root_files` points their rows (`dir '.'` → `dir 'posts/'`) at the new location. Pool rows are untouched. Skipped on `--dry-run` like every other write; a no-op once migrated
- **Pool bundling** — `expand_pools` pulls in every member of a pool a found post belongs to; claimed once per pool, members pinned to that pool via `POOL_MEMBER` so bundling cannot cascade
- **Pool slugs** — a directory slug is frozen in the database the first time a pool is seen, *including* when that first sighting is a failed lookup (it falls back to `pool-<id>`). A directory must never move, or every file already bundled in it is stranded
- **Placement** — `place_existing_media` hard-links (or copies) a copy already in the archive instead of fetching it again
- **Work tracking** — the processor counts outstanding items rather than using sentinels, because a worker can enqueue more work (a bundle) while it drains
- **Sidecar payload** — `sidecar_payload(post)` is the single structure that is both written and validated, keyed by `SIDECAR_FIELDS`. A field cannot be written but not checked, or checked but not written
- **Sidecar drift** — `sidecar_valid?` compares keywords as a *set*, so a tag deleted upstream invalidates the sidecar and is cleaned out. Dates are compared as instants because exiftool re-renders them on read
- **Flat tag lists** — a `mode=basic` response has no categories. Sidecar keywords are withheld (`:uncategorized`) rather than guessed; the database still records the tags under `general`
- **Integrity check** — a file that is *larger* than recorded was edited on purpose and is left alone; anything else (empty, truncated, same-size hash mismatch under `--verify-md5`) is moved to `<name>.damaged-<stamp>` and re-fetched. The check never deletes
- **Container variants** — a site's served extension can differ from the post's own `ext`. Gelbooru serves `.mp4` for posts whose `image` says `.webm` (it is the only site that derives the served ext from the URL), and e621 converts some animated `.png` to `.jpg`. The archive keeps what was served, so its digest will *not* match `posts.md5`. `post_processor.rb` therefore drops the expected MD5 whenever `served_ext != orig_ext`, and `backfill_file_md5` must not refill it afterwards — a digest is only meaningful for the container it was computed over. The download already hashes the bytes as they stream past, so that digest is captured and recorded: variants stay under `--verify-md5` instead of accumulating as rows nothing can verify. A whole-archive MD5 sweep must filter on `files.ext = posts.ext` first, or nearly every video reads as corrupt
- **Replaced posts** — a *different* cause of `files.ext != posts.ext`, and not a container conversion at all: e621 can replace a post's file (Replacements Beta), so a later recache records the new extension and MD5 while the archive still holds what was fetched at archive time. Those files are historical and no longer reproducible from the API. The same guard applies, and the archived copy is the correct one to keep
- **Archive database** — `ArchiveDb` is SQLite, shared by both sites and keyed by `site`, at `/mnt/hdd/rubichiver-database.db`. It holds `posts`, `tags`, `post_sources`, `pools`, `pool_posts`, `files` and `tag_types`
- **Database durability** — WAL plus `synchronous = NORMAL` and a batched transaction (flushed every 500 statements or 5s, and on close). Pool records commit immediately, because a lost slug moves a bundle
- **Database cost** — `WAL_CHECKPOINT_BYTES` / `WAL_SIZE_LIMIT_BYTES` (16 MB) keep the log from creeping up over a multi-hour import, which on a slow encrypted spinning disk turns into `xlog_wait_on_iclog` stalls. Tags and sources are inserted in chunks, and a post already in the store keeps its tag rows unless the caller passes `refresh: true` (which recache does)
- **Database failure** — an unreadable, corrupt or non-database file is moved aside as `.corrupt-<stamp>` and replaced; an unwritable path falls back to in-memory. Neither is ever fatal
- **Atomic post writes** — a post's row, tag rows and sources commit as one unit. `hold_batch` defers the batch commit across a multi-statement write, so a crash can never leave a torn tag set that the next run mistakes for complete
- **Schema migration** — older databases gain missing columns in place (`migrate_columns!` runs before the indexes, because an index on a missing column aborts the open and silently strands the data in-memory). The live file upgrades without a rebuild
- **Filesystem is authoritative** — every run reconciles the database against a directory scan, adopting unrecorded files and dropping entries whose file is gone
- **Self-recovery** — every damaged state is repaired by rerunning: killed runs, deleted/truncated media, missing sidecars, corrupt caches, a corrupt or missing database
- **Orphan sidecars** — a sidecar with no media beside it is the signature of a run killed part-way. Nothing else would ever revisit such a post, because a post is only re-fetched when a tag query returns it, so `repair_missing_media` finds them at startup and asks for them by id
- **Recache** — `--recache-post-tags` is the only pass that visits every archived post, so it refreshes the stored metadata *and* regenerates missing sidecars. It checks every location of a post, because a post in two pools has two sidecars
- **Offline repair** — `repair_sidecars_from_db` rebuilds any sidecar that is missing **or no longer agrees with the stored record**, with no API call. "No longer agrees" is as important as "missing": an earlier version wrote keywords only, and those files still exist — nothing else would ever revisit them, since a post is only re-fetched when a tag query happens to return it, so one outside every query would keep its short sidecar forever. The comparison is against the database rather than the live site so an unqueried post still converges; one the queries *do* reach is re-checked against the site during the run and corrected if the stored copy has fallen behind. A record with no stored post is left alone rather than guessed at. `stored_post` rebuilds the site-shaped hash the payload logic already validates; a record filed from a flat tag list (`uncategorized`) is never guessed into keywords
- **Store efficiency** — tags are inserted in chunks rather than one statement per tag, and a post already in the store does not have its tag rows rewritten unless `refresh: true` (which recache passes)
- **Stall watchdog** — a run that records no progress for `STALL_WARN_SECONDS` warns, because a wedged run is indistinguishable from a slow one from the outside
- **Concurrency caveat** — the database handles two runs, but two archivers on one spinning disk saturate it and both stall. Run them one at a time
- **API base override** — `RUBICHIVER_E621_API` / `RUBICHIVER_GELBOORU_API` point the CLI at another host so the end-to-end tests can drive the real binary against a local server. `RUBICHIVER_DB` does the same for the database, so the test suite never touches the real one
- **API results** — `Archiver::ApiResult` (`posts`/`total`/`error`/`payload`); `posts` is nil on failure so a failed request is never read as an empty page
- **v1/v2 tolerance** — e621 responses are accepted both bare (v2) and `{"posts": [...]}` (v1); anything else is a logged failure
- **Cache freshness** — page 1 is read from cache *before* the live fetch; any change invalidates every cached page for that query. The per-post tag cache is gone: the database supersedes it
- **Credential scoping** — `Authorization` and `Referer` are only sent to the host they were minted for, so a cross-host 302 cannot capture the API key
- **Fault handling** — `NETWORK_ERRORS` deliberately includes `Net::HTTPBadResponse` and `Net::ProtocolError`, which is what a truncated chunked body looks like. `api_get` and `download_media` also catch anything else, and a worker's `rescue` counts the failure so a run cannot report success having dropped a post
- **Concurrency** — `PostProcessor` worker pool plus a reentrant `Monitor` guarding the shared media index and the database connection
- **Deduplication** — `@existing_posts` hash map (post_id + pool + dir → file_path) scanned at startup; per-run `Set` of seen IDs
- **Existing file handling** — sidecar missing or drifted → regenerate; sidecar current → skip
- **Sidecar reads** — existing sidecars are indexed up front in batches of 500 (one exiftool per batch), not one process per post. A batch that will not read is retried at half the size, splitting on the batch that actually arrived
- **Sidecar temp names** — must end in `.xmp`, because exiftool picks the output format from the extension. With any other suffix it falls back to the input format and cannot write webm at all. The `.part` marker sits before it so a killed run is still skipped by the media scan
- **Partial files** — downloads write `<id>.<ext>.part`; stale ones are deleted at startup and never indexed as media
- **Single writer** — `flock` on `<output>/.rubichiver.lock`; a second run exits 1 rather than racing
- **Dry run purity** — `--dry-run` writes no media, sidecars, caches or database records
- **Interrupt handling** — first Ctrl+C graceful shutdown, second force exit
- **Rate limiting** — `RateLimiter` schedules on the monotonic clock; `RateLimiterPool` hands each worker its **own** limiter, so `--rate-limit` is a per-thread budget and the run's ceiling is that times `-j`. A single shared limiter capped the whole run regardless of worker count, which made widening the pool buy nothing. The worker's index is threaded through `download_media` → `expand_pools` → `bundle_pool`/`fetch_posts_for_pool` → `api_search_posts` → `api_get`, keyed by index when known and by `Thread.current` otherwise. The pool's `request_count` sums every limiter so the summary still reports one total
- **Being over a site's limit** — e621 signals this with **503**, not 429, and the request never reaches the application. `RATE_LIMIT_STATUSES` (`429`, `503`) is therefore handled apart from ordinary 5xx. Left as a generic blip, a refusal burns the 3 retries in ~7s and drops the post; left silent, it fails invisibly hours later
- **Adaptive back-off** — a refusal calls `RateLimiterPool#note_refusal`, which answers `[stage, escalated]`. Stage 1 = 1 req/s per worker, stage 2 = 1 req/s **shared by the whole run** (the budget is divided by the thread count, so workers still get a fair share instead of queueing behind one). Each stage is held `RATE_LIMIT_COOLDOWN` (60s) and then lifts itself. Escalation is gated on the current stage having been held a full window, because one refused request is retried several times over — without that gate a single unlucky request walks through every stage in a second and leaves the run crawling at the floor for minutes. Only a real escalation is logged at WARN and alerted; the rest stay at debug
- **Alerts** — `--notify` POSTs a start report (`notify_start`) and an end-of-run report; `notify_event` sends ad-hoc alerts, and a throttle escalation uses it mid-run because the end-of-run report is hours away. The start report exists to bound the silence: the work takes hours and the only other notification is the final report, so a start with no matching finish is the sole signal that the process died part way. It is called after the startup log block, once every startup step that can abort the run (credentials, `mkdir_p`, `flock`, db load, scan, reconcile, sidecar index) has already succeeded, so a run that never started never claims it did and a run locked out by a concurrent one is silent. `run_mode_label` / `run_mode_tag` distinguish archive, recache and dry run, and `run_start_summary` follows the end-of-run report's rule that only counters and settings travel — no tags, filenames, paths or credentials. ntfy needs a special shape: it only parses `title`/`message`/`priority`/`tags` from a JSON body when the **topic travels in that body**, which means posting to the server root (`notification_target`). The same JSON posted to the topic URL arrives as one raw string — worse than no alert, because it looks delivered and reads as noise. A failed notification is logged and never fatal. Credentials ride in the notify URL as standard userinfo (`https://user:pass@host/topic`) and go out as basic auth via `apply_notification_auth`, read from `@notify_url` rather than the request target — `notification_target` rebuilds it from scheme/host/port and has already dropped them. `URI#password` hands back the still-encoded form, so it is percent-decoded; a URL without credentials must send no `Authorization` header at all, because servers reject an empty one. Nothing logs the password. The systemd units read `EnvironmentFile=-%h/.config/rubichiver/notify.env` (mode 600) rather than carrying `Environment=` inline
- **Original formats preserved** — media kept as-is alongside XMP sidecars
- **Unsupported formats** — SWF files skipped
- **Notification** — `--notify URL` POSTs JSON report; failures logged without aborting
- **Exit codes** — `0` success, `1` interrupted or any failure

## Testing
- Framework: Minitest (stdlib)
- Run: `rake test` or `ruby -Itest test/all.rb`
- Tests: blacklist parser, rate limiter, post/sidecar processing, API pagination and cache freshness, v1/v2 response shapes, retry bounds, output directory scan and locking, download verification/redirects, HTTP redirects, the SQLite archive database (including corrupt and unwritable stores), post metadata capture per site, robustness regressions (lost posts, credential replay, pool slug stability, cache pruning, concurrent placement), pool expansion and bundling, integration stubs, full `run` loop, and self-recovery (damaged media, corrupt caches/database, SIGKILL and SIGINT against the real CLI)
