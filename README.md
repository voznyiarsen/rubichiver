# rubichiver — Unified Booru Media Archiver

Downloads media from e621.net and Gelbooru, writes XMP sidecar metadata next to
every file, and records what it learned about each post in a queryable SQLite
database.

## Requirements

- Ruby 3.x
- [ExifTool](https://exiftool.org/)
- [sqlite3](https://rubygems.org/gems/sqlite3) — `gem install sqlite3`

Create credentials files (gitignored):

```
# e621-api-credentials.txt
USERNAME=your_username
API_KEY=your_api_key

# gelbooru-api-credentials.txt
USER_ID=your_user_id
API_KEY=your_api_key
USERNAME=your_username
```

## Usage

```bash
ruby rubichiver.rb --site e621 [OPTIONS]
ruby rubichiver.rb --site gelbooru [OPTIONS]
```

### Options

Run `ruby rubichiver.rb --help` for the authoritative list.

| Flag | Description |
|------|-------------|
| `-s SITE` | Target site: `e621` or `gelbooru` (required) |
| `-o DIR` | Output directory |
| `-t FILE` | Tags file (default: `./tags.txt`) |
| `-b FILE` | Blacklist file (default: `./blacklist.txt`) |
| `-C DIR` | API response cache directory (default: `<output>/cache`) |
| `-c FILE` | API credentials file (default: `./<site>-api-credentials.txt`) |
| `--db FILE` | Archive database (default: `/mnt/hdd/rubichiver-database.db`, or `$RUBICHIVER_DB`) |
| `--dry-run` | Preview posts that would be archived, writing nothing to disk |
| `--recache-post-tags` | Refresh the stored metadata of every archived post and regenerate any missing or drifted sidecar. No downloads |
| `--[no-]pools` | Bundle a whole pool when a found post belongs to one (e621, default on) |
| `--[no-]repair-missing` | Re-fetch posts that have a sidecar but no media file (default on) |
| `--verify-md5` | Re-hash archived files against the database on startup (slow) |
| `--cache-max-age DAYS` | Drop cached API pages older than DAYS (default: 90, 0 disables) |
| `--notify URL` | POST JSON report to webhook on completion |
| `-j N` | Worker threads (default: 2) |
| `--rate-limit N` | Requests/second **per worker thread** (default: 8) |
| `-v` | Verbose output |
| `--json` | JSON log output |

## Layout

Loose posts live in `posts/`, not at the archive root. The root holds the lock
file, pool bundles and `posts/` — nothing else:

```
<output>/posts/6403790.jpg
<output>/posts/6403790.xmp
<output>/pools/56729_they-said-saturnsamo/6403810.jpg
<output>/pools/56729_they-said-saturnsamo/6403810.xmp
```

A run moves any loose files left at the root by the old layout into `posts/`
and updates their database rows, so upgrading needs no manual step.

## Pools

When a post found by a tag query belongs to an e621 pool, the whole pool is
fetched and every member is archived into one bundle directory:

```
<output>/pools/56729_they-said-saturnsamo/6403790.jpg
<output>/pools/56729_they-said-saturnsamo/6403790.xmp
<output>/pools/56729_they-said-saturnsamo/6403810.jpg
<output>/pools/56729_they-said-saturnsamo/6403810.xmp
...
```

- Directory names are `<pool id>_<slug>`. The slug is frozen in the database
  the first time a pool is seen, so renaming a pool upstream never re-bundles it.
- Each pool is expanded at most once per run, and a post pulled in by a pool
  does not pull in the other pools it belongs to, so bundling cannot cascade.
- A post that is in two pools is stored in both bundles. The second copy is a
  hard link to the first, so the bytes are not duplicated on disk.
- A copy already in the archive (even in `posts/`) is linked into the
  bundle instead of being downloaded again.
- A member the API does not return is logged as a gap; the rest of the bundle
  is still written and the next run fills it in.
- `--no-pools` archives pool members in `posts/` alongside everything else.
- Bundling does not run in `--dry-run`, which stays free of extra API traffic;
  the dry-run preview still shows the bundle path each post would land in.

## Metadata

### XMP sidecar

Every media file gets a sidecar carrying the post's rating, its categorized
keywords, and enough provenance to identify the artwork offline:

| Field | Tag | Example |
|-------|-----|---------|
| Title | `XMP-dc:Title` | `cave_story — e621 #6577648` |
| Artist | `XMP-dc:Creator` | `sukiya` |
| Keywords | `XMP-dc:Subject` | `rating:explicit`, `general:anthro`, `artist:sukiya`, `pool:They Said` |
| Sources + note | `XMP-dc:Description` | `Source: https://www.pixiv.net/artworks/104093434` |
| Post page | `XMP-dc:Rights` | `https://e621.net/posts/6577648` |
| Rating | `XMP-xmp:Rating` | `3` |
| Posted / updated | `XMP-xmp:CreateDate` / `ModifyDate` | `2026-07-28T02:20:59-04:00` |
| Written by | `XMP-xmp:CreatorTool` | `rubichiver/1.0.0 (e621 media archiver, used by <you>)` |

A sidecar is rewritten when any of those fields drifts from what the post
currently says — including a tag that was *deleted* upstream, which is cleaned
out rather than left behind. `CreatorTool` carries the version and the account
name for provenance, but only the tool name is compared: upgrading rubichiver
or renaming the account does not rewrite every sidecar in the archive. A
sidecar written by anything else still invalidates, as it should.

If the site answers with a flat tag list instead of categorized ones, no
keyword sidecar is written rather than one filled with guessed categories; the
tags are still recorded in the database under `general`.

### Archive database

`/mnt/hdd/rubichiver-database.db` is a SQLite database, shared by both sites and
keyed by site, holding the full detail each API returned. Query it with any
SQLite client:

```bash
sqlite3 /mnt/hdd/rubichiver-database.db \
  "SELECT p.post_id, p.uploader_name, t.tag FROM posts p
     JOIN tags t ON t.site = p.site AND t.post_id = p.post_id
    WHERE p.site = 'e621' AND t.category = 'artist' AND t.tag = 'sukiya';"
```

| Table | Contents |
|-------|----------|
| `posts` | One row per post: rating, dates, MD5, size, dimensions, duration, uploader, approver, description, page URL, score, favourites, comments, parent/children, flags, locked tags, capability flags, sample/preview geometry, and Gelbooru's lifecycle fields |
| `post_raw` | The complete API response, verbatim, one row per post |
| `post_files` | Every rendition the site offered — original, sample and preview, each with its format, dimensions and URL |
| `post_children` | Child post ids, in the order the site listed them |
| `tags` | One row per (post, category, tag) — indexed for tag lookup |
| `post_sources` | The original source URLs, in order |
| `pools`, `pool_posts` | e621 pools, their frozen directory slug, and membership |
| `files` | Where each file lives, its MD5, size, dimensions, and whether its sidecar was current |
| `tag_types` | Gelbooru tag category lookups, so they are resolved once rather than once per run |
| `counters` | Cached per-site post and tag counts, so the summary never runs `COUNT(*)` over millions of rows |

Everything the sites return is kept. The columns are a readable projection of
`post_raw`, which holds the response exactly as it arrived — so a field this
schema has never heard of is still in the archive, and the columns can be
rebuilt from `post_raw` at any time. It is stored as its own row rather than a
column on `posts` because `posts` is rewritten for every post rediscovered on
every run, and re-serialising 2.8 KB of identical JSON tens of thousands of
times is real work on a slow disk. A post's raw record is refreshed only by
`--recache-post-tags`, so `post_raw.captured_at` doubles as a cheap "has this
changed upstream?" check. Expect roughly 3 KB per post of extra storage; a
full recache fills the new tables for every archived post.

```bash
# Every rendition of a post, without asking the site again
sqlite3 /mnt/hdd/rubichiver-database.db \
  "SELECT variant, format, width, height, url FROM post_files
    WHERE site = 'e621' AND post_id = 4149486;"

# A field no column models
sqlite3 /mnt/hdd/rubichiver-database.db \
  "SELECT json_extract(raw_json, '$.stats.hotness') FROM post_raw
    WHERE site = 'e621' AND post_id = 4149486;"
```

Gelbooru's Unix upload timestamp is normalised to ISO UTC so date queries work
across both sites; e621's original string is kept as given.

The filesystem stays authoritative for file contents; the database is there so
the archive can be queried, and so divergence can be seen and repaired. At
startup each run reconciles the two: entries whose file has disappeared are
dropped so the post is fetched again, and files that were never recorded (an
older run, a hand-copied archive) are adopted. A database that cannot be read is
a warning, never a failure — it is set aside under a `.corrupt-<timestamp>` name,
a fresh one is started, and the run continues from the filesystem alone. Delete
it at any time; it rebuilds.

Use `--db` (or `$RUBICHIVER_DB`) to keep several archives apart.

## Tags file

One query per line, space-separated tags. Blank lines and lines starting with
`#` are ignored:

```
# character queries
furry -rating:s
species:canine
character:fido
```

### Blacklist file

e621 syntax: `~OR` groups, `-negation`, `rating:`, `id:`:

```
gore -rating:e
~fox wolf
rating:explicit
id:12345
```

## Self-recovery

Every damaged state is repaired by simply running again. Nothing owned by you is
ever deleted to "fix" something.

| Damage | What happens on the next run |
|--------|-----------------------------|
| Process killed mid-download | The `.part` file is removed and the post is fetched again |
| Media file deleted | Detected by the scan, fetched again |
| Media file truncated or zero bytes | Detected against the recorded size, set aside as `<name>.damaged-<stamp>`, fetched again |
| Media file corrupted at the same length | Detected with `--verify-md5`, set aside, fetched again |
| Media file larger than recorded | Reported and **left alone** — growth means it was edited on purpose, and re-fetching would destroy that work |
| Sidecar deleted, stale or corrupt | Regenerated without re-downloading the media (or by `--recache-post-tags`) |
| Sidecar present but the media is gone | Detected at startup, re-fetched by post id (one request each) |
| Sidecar missing, post record present | Rebuilt from the stored record with no API call, at startup |
| `.part` file left in a bundle | Removed at startup |
| API cache entry corrupt | Discarded, refetched, run continues |
| API cache older than `--cache-max-age` | Dropped at startup, so the cache does not grow without bound |
| Database unreadable, corrupt or not a database | Set aside as `.corrupt-<stamp>`, a fresh one is started, run continues |
| Database path unwritable | Warned once, run continues filesystem-only |
| A pool that cannot be looked up | Its directory slug is frozen from its id, so the bundle never moves |
| A pool renamed upstream | The existing bundle directory keeps its name; the new title is recorded alongside |
| Another run holding the output directory | Refused with an error instead of racing |
| A pool member the API will not return | Logged as a gap; the rest of the bundle is written |
| A file with a different extension | Treated as a different file, not as damage |
| Database write-ahead log grown large | Checkpointed and truncated at 16 MB, and capped, so a long import cannot build it back up |

Recovery is verified by tests that run the real `rubichiver.rb` as a child
process against a local HTTP server, including `SIGKILL` delivered while a
download is in flight and `SIGINT` for a graceful drain.

## Scheduling

Runs are driven by systemd user timers, not cron:

| Unit | Schedule | Purpose |
|------|----------|---------|
| `rubichiver-archive.timer` | Sunday 01:00 (+ up to 30 min jitter) | Fetch new posts for both sites |
| `rubichiver-recheck.timer` | 1st of the month, 03:00 (+ up to 1 h jitter) | Refresh stored tags, regenerate missing sidecars |

```bash
systemctl --user list-timers 'rubichiver-*'
systemctl --user start rubichiver-archive.service    # run now
journalctl --user -u rubichiver-archive.service -f   # follow the log
```

Alerts go wherever you point them — nothing is configured out of the box, and
a run without a notification target simply logs to the journal. To receive the
start/end-of-run reports and mid-run throttle alerts, give the tool a webhook
URL:

```bash
ruby rubichiver.rb --site e621 ... --notify https://ntfy.example.com/my-topic
```

The systemd units do this with an environment file so scheduled runs report
with no flags, and so the password is not baked into a world-readable unit:

```ini
# ~/.config/systemd/user/rubichiver-archive.service
EnvironmentFile=-%h/.config/rubichiver/notify.env
```

```bash
# ~/.config/rubichiver/notify.env   (chmod 600 — it usually holds a password)
RUBICHIVER_NOTIFY_URL=https://user:password@ntfy.example.com/my-topic
```

Three things are sent, and nothing else:

| Alert | When | Priority |
|-------|------|----------|
| `<site> archive starting` | once the run is genuinely under way | 3 |
| `<site> recache starting` | ditto, for `--recache-post-tags` | 3 |
| `<site> run finished` | end of the run, with its counters | 3 or 5 |
| `<site> rate limited — slowed to …` | mid-run, on a real back-off escalation | 5 |

The start alert is what makes the silence bounded. A run takes hours and its
only other notification is the final report, so a start with no matching finish
means the process died part way — otherwise that is indistinguishable from a
run that is merely slow. It fires after every startup step that could abort the
run has already succeeded, so a run that never started never claims it did; a
run locked out of the archive by a concurrent one is silent.

Both reports carry counters and settings only — no tags, filenames, paths,
source URLs or credentials leave the machine.

ntfy is fully supported: put the topic in the URL path and subscribe with
`curl -s ntfy.example.com/my-topic/json`. Anything else that accepts a JSON
POST receives an event-shaped body (`event`, `title`, `message`, `priority`,
`tags`, `timestamp`). A notification that fails to deliver is logged and never
fails the run.

If the webhook needs credentials, put them in the URL as standard userinfo
(`https://user:password@host/topic`) and they are sent as HTTP basic auth —
percent-encoded characters are decoded first, so a password containing `@` or
`:` survives. A URL with no credentials sends no `Authorization` header at all.
Nothing logs the password. Note that an ntfy server with
`auth-default-access: deny-all` needs an account explicitly granted write access
to the topic; anonymous publishes are refused with HTTP 403.

Both timers use `Persistent=true`, so a run missed while the machine was off
fires once on the next boot. The units run `run-archive.sh` / `run-recheck.sh`,
which invoke both sites sequentially — they share one database and one disk.
The recheck unit carries `Conflicts=rubichiver-archive.service` so the two
passes can never drive the database at once.

## Behaviour notes

- Only one run may write to an output directory at a time; a second run exits
  with an error instead of racing on the same files.
- **Video and image MD5s are only comparable when the served container matches the
  post's own extension.** Gelbooru serves `.mp4` for posts whose `image` field says
  `.webm`; e621 converts some animated `.png` to `.jpg`, and can also *replace* a
  post's file outright. The archive stores what was served, so those files are
  correct on disk but cannot hash to the post's MD5. Their recorded digest is
  computed over the served bytes instead, so they stay covered by `--verify-md5`.
- **Stale sidecars are repaired offline.** A sidecar that is missing, or that no
  longer agrees with what the archive knows about its post, is rebuilt from the
  stored database record — no API call. This is what catches sidecars written in
  an older format: a post is only re-fetched when a tag query happens to return
  it, so one outside every query would otherwise keep its outdated sidecar
  forever.
- **If a site starts throttling you, the run slows itself down and tells you.**
  e621 signals this with `503`, not `429`; both are treated as a sustained
  condition, not a transient blip. The first refusal drops every worker to
  1 req/s for a minute; if it is *still* being refused after that minute, the
  whole run drops to 1 req/s shared between all workers. Either way the limit
  lifts itself afterwards, so a run recovers without you watching it — and each
  escalation is logged and pushed to your ntfy topic, because the failure mode
  is otherwise silent: requests quietly refused, posts quietly failed.
- Incomplete downloads (`.part`) left by a killed run are removed at startup, so
  a truncated file is never mistaken for a finished download.
- `--dry-run` touches no files: no downloads, no sidecars, no caches.
- `--recache-post-tags` batches 300 ids per request on e621. Gelbooru has no
  bulk id lookup, so it costs one request per archived post.
- A post is placed once per location, so a bundle that is reached from several
  directions at once is still written exactly once.
- A cross-host redirect is followed without the API key: credentials are only
  sent to the host they were minted for.
- A download gets three immediate HTTP attempts per round. If all three fail,
  its location goes to the **back of the work queue** for another round while
  other posts continue. There are ten rounds (up to 30 HTTP attempts), with
  30–300 seconds of backoff between rounds; after the tenth, it is counted as
  one failed post. Sidecar failures and API search failures are separate and
  are not retried by this download queue. A graceful interrupt cancels
  deferred retries promptly. Any fault a worker cannot anticipate is counted
  as a reported failure — a run never reports success while having quietly
  dropped a post.
- One archiver at a time on a single spinning disk. Two runs sharing the database
  saturate it and both stall; the archive database is built for concurrency, but
  the disk under it may not be.
- A run that makes no progress for five minutes says so, rather than looking like
  a slow run.
- A post's database rows commit as one unit, so a crash can never leave a
  half-written tag set that the next run mistakes for complete.
- Every state is recoverable by rerunning: missing files are fetched again,
  stale sidecars are rewritten, and unreadable cache or database entries are
  discarded and rebuilt rather than aborting the run.

## Development

```bash
rake test        # or: ruby -Itest test/all.rb
```

## License

ISC
