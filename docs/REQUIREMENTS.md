# Mah Bucket — Requirements Specification

This document describes the complete functional and non-functional requirements
of Mah Bucket, sufficient to re-implement the application from scratch in any
language or framework.

## 1. Overview

Mah Bucket is a small, single-user-style web application that acts as a personal
file library. It provides upload, browse, view, edit, delete, tag and search
operations for arbitrary files (with first-class support for images), backed by
Amazon S3 for object storage and a relational database for metadata. The
reference implementation is a Ruby on Rails 6.1 monolith, but the requirements
below are framework-agnostic.

### 1.1 Goals

- Allow an authenticated user to upload files of any type to a private library.
- Treat images as a special case: generate fixed-size derivative versions
  (thumbnails, etc.) and expose width/height metadata.
- Allow each file to be annotated with a free-form list of tags, and let users
  browse files via tags or search across both filenames and tag names.
- Restrict access to a configured Google Workspace domain (Google OAuth) and
  optionally to a list of allow-listed source IP addresses.
- Be operable as a hobby/SMB deployment: a single web process, a single SQL
  database, an S3 bucket, and a handful of environment variables.

### 1.2 Non-goals

- Multi-user collaboration features (sharing, permissions, ACLs per file).
- Per-user libraries — there is one shared library for all authenticated
  users in the configured OAuth domain.
- Versioning of files. Replacing the file on an Item replaces the underlying
  S3 object; previous versions are not retained.
- Full-text search of file *contents*. Search is limited to filenames and tag
  names.
- A REST/JSON public API. JSON responses exist for items but are intended for
  ad-hoc use behind the same authentication, not as a public API surface.

## 2. Glossary

- **Item**: a stored file plus its metadata. The fundamental unit of the
  library. One Item corresponds to one underlying file/object in S3.
- **Tag**: a short, case-sensitive string that can be attached to any number
  of Items. Tags exist independently of Items and are de-duplicated by name.
- **Tagging**: the join between an Item and a Tag.
- **Fingerprint**: a content hash (MD5 in the reference implementation) of the
  uploaded file's bytes. Used to detect duplicate uploads.
- **Style** (image-only): a named derivative version of an image (e.g.
  `thumbnail`, `small`, `display`) generated server-side after upload.
- **Theme**: a named bundle of layout partials and static assets used to
  re-skin the UI without code changes.

## 3. Actors and Authentication

### 3.1 Actors

There is exactly one role: **authenticated user**. There is no concept of
admin vs. non-admin, no concept of file ownership, and no per-user data
partitioning.

### 3.2 Authentication

- Authentication MUST be performed via Google OAuth 2.0.
- The OAuth client ID and secret are supplied via environment variables
  (`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`).
- A successful OAuth callback MUST verify that the email address returned by
  Google has a domain matching the value of the `GOOGLE_OAUTH_DOMAIN`
  environment variable. If it does not match, the user MUST be rejected with
  an HTTP 401 response and a short "Unauthorised" message; no session is
  created.
- On a successful login, the application MUST persist at least the user's
  email address and display name in a server-managed session (cookie-based
  session store in the reference implementation). No user record is written
  to the database.
- Every request other than the OAuth callback flow itself MUST require an
  authenticated session. Unauthenticated requests MUST be redirected (via
  HTTP POST, with CSRF token) to the Google OAuth start URL
  (`/auth/google_oauth2`). A plain GET-based redirect is not acceptable
  because OmniAuth's CSRF protection only allows POSTs.
- There MUST be a test-only escape hatch: when running in the test
  environment with the `SKIP_AUTH` environment variable set, the
  authentication filter MUST set the session to a fixed dummy email
  (`admin@example.com`) and proceed without OAuth. This MUST NOT be active
  outside the test environment.
- There is no explicit logout action in the reference implementation;
  re-implementations MAY add one but it is not required.

### 3.3 IP allow-listing

In addition to OAuth, the application MUST support an optional IP allow-list
applied as a global before-filter, ahead of authentication.

- Configured via the `PERMITTED_IPS` environment variable. If empty/unset,
  the IP check is disabled and all source IPs are allowed (subject to OAuth).
- The development environment MUST bypass the IP check entirely.
- The list format MUST accept all of the following on input:
  - A single IP: `127.0.0.1`
  - A comma- or space-separated list: `127.0.0.1, 10.0.0.1 192.168.1.1`
  - An IP followed by a parenthesised label: `127.0.0.1 (localhost)` —
    the label is stripped and ignored.
  - A multi-line list with `#` comments at end of line:
    ```
    127.0.0.1  # localhost
    192.168.0.1 # internal range
    ```
- IPv4 and IPv6 addresses MUST both be parseable (the parser accepts the
  hex digits, dots and colons used in either form).
- By default, the source IP MUST be taken from the request's remote address.
  When the `CLIENT_IP_HEADER` environment variable is set, the value of that
  HTTP request header MUST be used instead (this is to support deployments
  behind a CDN such as Cloudflare, e.g. `CF-Connecting-Ip`).
- A request whose source IP is not in the allow-list MUST be rejected with
  HTTP 401 and a plain-text body of `Access Denied`. No further processing
  (including authentication) is performed.

## 4. Domain Model

### 4.1 Item

An Item represents one stored file. Required fields:

| Field             | Type      | Notes                                                                 |
|-------------------|-----------|-----------------------------------------------------------------------|
| `id`              | integer   | Primary key, auto-incrementing.                                       |
| `created_at`      | timestamp | Set on insert. Not null.                                              |
| `updated_at`      | timestamp | Set on insert and on every update. Not null.                          |
| `file_file_name`  | string    | Original filename as uploaded by the user (e.g. `holiday.jpg`).       |
| `file_content_type` | string  | MIME type as detected at upload time (e.g. `image/jpeg`).             |
| `file_file_size`  | integer   | Size of the original file in bytes.                                   |
| `file_updated_at` | timestamp | Time the underlying file was last (re)uploaded.                       |
| `file_fingerprint`| string    | Content hash of the original file (MD5 hex string in the reference). |
| `file_meta`       | text      | Serialised metadata blob — image dimensions per style. May be null.   |

Constraints:

- `file_fingerprint` MUST be unique across all Items. Attempts to create or
  update an Item to a file whose fingerprint already exists in the database
  MUST be rejected with the validation error message: `Error: This file has
  already been uploaded - please try searching for it by filename or by tag.`
- An Item MUST always have an attached file. There is no concept of an Item
  without a backing object.
- The combination of `file_*` columns is the schema produced by the
  reference implementation's attachment library (Paperclip). A re-implementation
  MAY collapse these into a different shape (e.g. a single `file` JSON
  column) but MUST preserve the same logical fields.

### 4.2 Tag

A Tag is a free-form short string. Required fields:

| Field            | Type    | Notes                                              |
|------------------|---------|----------------------------------------------------|
| `id`             | integer | Primary key.                                       |
| `name`           | string  | Unique. Indexed.                                   |
| `taggings_count` | integer | Cached count of how many Items reference this tag. |

Constraints:

- Tag `name` MUST be unique (a single shared tag namespace).
- Tags that have no Items associated with them MUST be deleted automatically
  (the reference uses `acts-as-taggable-on`'s `remove_unused_tags = true`).

### 4.3 Tagging (join)

A Tagging is the link between an Item and a Tag. The reference implementation
uses the `taggings` table from `acts-as-taggable-on`, which carries:

- `tag_id` (FK to `tags`)
- `taggable_type` and `taggable_id` (polymorphic FK; in this app always
  `Item`/`<item id>`)
- `tagger_type`, `tagger_id` (unused — there is no per-user tagging)
- `context` (string; this app uses the default `tags` context)
- `created_at`

A re-implementation MAY use a simple two-column join table
`(item_id, tag_id)` so long as the externally-visible behaviour matches.

### 4.4 Relationships

- One Item has many Tags through Taggings.
- One Tag has many Items through Taggings.
- The relationship is many-to-many; deleting an Item MUST remove its
  associated Taggings; tags whose `taggings_count` then reaches zero MUST be
  deleted.

## 5. File Storage

### 5.1 Backing store

- Files MUST be stored in Amazon S3 (or an S3-compatible object store).
- The bucket name, region, access key ID, secret key and a public DNS host
  alias for the bucket MUST be configurable via environment variables:
  `S3_BUCKET`, `S3_REGION` (default `eu-west-1`), `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `S3_HOST_ALIAS`.
- Stored objects MUST be uploaded with public-read ACL — i.e. anyone with
  the URL can fetch the object directly from S3 without going through the
  application. Access control of the *application* is handled by OAuth and
  IP allow-listing only.
- All object URLs returned to clients MUST be served over HTTPS via the
  configured `S3_HOST_ALIAS` rather than the raw S3 endpoint.
- Stored objects MUST be uploaded with cache headers indicating they are
  immutable for a long period (the reference uses `Cache-Control:
  max-age=315576000` and an `Expires` header ten years in the future).
- The S3 object key MUST follow a deterministic, collision-free pattern
  derived from the Item id, attachment name, style and original filename.
  The reference implementation uses:
  `/items/file/<id_partitioned>/<style>/<filename>`
  where `<id_partitioned>` is the Item id zero-padded to nine digits and
  split into three groups of three (e.g. `000/000/123` for id 123). A
  re-implementation MAY choose a different deterministic key scheme as long
  as it cleanly partitions ids and uses the original filename in the leaf.

### 5.2 Image processing

If — and only if — an uploaded file's content type matches the regular
expression `^(image|(x-)?application)/(bmp|gif|jpeg|jpg|pjpeg|png|x-png)$`
the application MUST treat it as an image. For images:

- The application MUST generate three additional derivative versions, each
  resized to fit within the given bounding box while preserving aspect ratio
  and never enlarging:
  - `display`   — `800x800` bounding box
  - `small`     — `400x400` bounding box
  - `thumbnail` — `100x100` bounding box
- The original file MUST also be retained as the `original` style.
- For each derivative and the original, the application MUST record the
  image's pixel width and height and make these available to the views (the
  reference stores these in the `file_meta` text column via the
  `paperclip-meta` plug-in).
- For non-image files, no derivatives are generated and no width/height
  metadata is recorded; only the original is stored.
- ImageMagick (or an equivalent capable of producing the same outputs) is a
  system dependency for any deployment that intends to accept image uploads.

### 5.3 Duplicate detection

- On every create or update, the application MUST compute the fingerprint
  (content hash) of the uploaded bytes and compare it against the
  `file_fingerprint` of all existing Items.
- If a match is found, the create/update MUST fail with a validation error
  (see §4.1) and the form MUST be re-rendered with the error visible to the
  user. No file is uploaded to S3 in this case.

## 6. HTTP Interface

### 6.1 Routes

The application MUST expose the following routes (the reference uses Rails
conventional resource routing — equivalents in other frameworks are
acceptable as long as method/path match):

| Method | Path                          | Action                                |
|--------|-------------------------------|---------------------------------------|
| GET    | `/`                           | Item index (root). Same as `/items`.  |
| GET    | `/items`                      | List items (paginated).               |
| GET    | `/items/new`                  | Show upload form.                     |
| POST   | `/items`                      | Create a new item from upload.        |
| GET    | `/items/:id`                  | Show one item with all derivative URLs and tags. |
| GET    | `/items/:id/edit`             | Show edit form (replace file / change tags). |
| PATCH or PUT | `/items/:id`            | Update an item (file and/or tags).    |
| DELETE | `/items/:id`                  | Delete an item and its S3 objects.    |
| GET    | `/tags`                       | List all tags.                        |
| GET    | `/tags/:id`                   | Show one tag and the items tagged with it. |
| GET    | `/search?q=...`               | Search items by filename and tags by name. |
| GET    | `/auth/google_oauth2`         | Begin OAuth (provided by OmniAuth).   |
| GET    | `/auth/google_oauth2/callback`| OAuth callback; creates the session.  |

The `/items` and `/items/:id` routes MUST also support a `.json` suffix
returning a JSON view of the same resource (see §6.4).

There is no separate `/sessions` or `/logout` route in the reference
implementation.

### 6.2 Item index — `GET /items`

- Lists all items in the library, ordered by `created_at` descending
  (newest first).
- Paginated at 20 items per page. The current page is selected by a `page`
  query string parameter (1-indexed). Pagination controls MUST be rendered
  below the list.
- Each item in the listing MUST display:
  - For images: the `thumbnail` derivative as an `<img>` linking to the
    item's show page.
  - For non-images: a generic file-icon image (from the active theme's
    `images/default-file-icon.png`) linking to the show page.
  - The original filename, also linked to the show page.
  - Three action links: `Show`, `Edit`, and `Delete`. The `Delete` link
    MUST require a Javascript confirmation prompt (`Are you sure?`) before
    submitting.
- If there are zero items, instead of the listing, the message `You have
  not added any items yet.` MUST be shown.
- A button labelled `Upload new file` MUST be shown beneath the list (or
  the empty-state message), navigating to `/items/new`.

### 6.3 Item show — `GET /items/:id`

- Displays the item's filename.
- For images: displays the `display` derivative inline.
- For non-images: displays the theme's default file icon.
- Lists the item's tags as comma-separated links to each tag's show page.
- Displays a read-only text input containing the public URL of the
  `original` file (so it can be copy-pasted).
- For images, after the original-URL input, displays one read-only text
  input per derivative style (`Display`, `Small`, `Thumbnail`), each
  showing the pixel dimensions and the public URL of that derivative.
- Provides `Edit` and `Back` links.

### 6.4 Item create / update / delete

- `GET /items/new` and `GET /items/:id/edit` MUST render an HTML form with:
  - A `file` field (multipart file upload).
  - A `tag_list` text field containing the current tags as a comma-separated
    string. The form MUST default the field's value to `tags.join(', ')`.
  - A submit button.
  - A list of validation errors, if any, at the top of the form when
    re-rendering after a failed submit.
- The form MUST be enctype `multipart/form-data` and MUST be CSRF protected.
- Only the `file` and `tag_list` parameters MUST be accepted from the form
  (parameter allow-listing). Any other field on `item[*]` MUST be ignored.
- `POST /items` (create) behaviour:
  - On success: HTTP 302 redirect to `/items/:id` with a flash notice
    `Item was created.`
  - On failure: HTTP 200 re-rendering of the new form with the errors.
- `PATCH/PUT /items/:id` (update) behaviour:
  - On success: HTTP 302 redirect to `/items/:id` with flash notice
    `Item was updated.`
  - On failure: HTTP 200 re-rendering of the edit form with the errors.
- `DELETE /items/:id` behaviour:
  - Destroys the Item, its Taggings, and the underlying S3 object(s)
    (original and all derivatives).
  - HTTP 302 redirect to `/items` with flash notice `Item was deleted.`
- A successful update with a new file MUST replace the underlying S3 object
  and regenerate any derivatives. The Item id (and therefore the URL path)
  MUST remain the same; the `file_file_name`, `file_content_type`,
  `file_file_size`, `file_fingerprint`, `file_updated_at` and `file_meta`
  fields MUST all be refreshed.

### 6.5 JSON responses

The item index and item show actions MUST also respond to `Accept:
application/json` (or the `.json` suffix) and return a JSON representation
of the resource(s). Each item MUST be serialised with at minimum:

- `id`
- `filename`
- `created_at`
- `updated_at`
- `url` — a fully-qualified URL to the JSON show page

Create and update with `Accept: application/json` MUST return the same
JSON shape with the appropriate status (`201 Created` / `200 OK`) and a
`Location` header. Validation errors MUST be returned as
`422 Unprocessable Entity` with a JSON error body. Delete MUST respond
with `204 No Content`.

### 6.6 Tags index — `GET /tags`

- Lists all tags in the system, ordered alphabetically by name.
- Each tag is rendered as a link to its show page.
- A search input form is rendered at the top, posting to `/search` with
  the query in `q`.

### 6.7 Tag show — `GET /tags/:id`

- Displays the tag name.
- Lists all items tagged with that tag, rendered using the same item
  partial used by the index (thumbnail / icon, filename, action links).
- Provides a `Back` link to `/tags`.

### 6.8 Search — `GET /search`

- Renders a search form (`q` parameter, GET, posts to `/search`).
- If `q` is present and non-empty:
  - Performs a case-insensitive substring match (`ILIKE %q%` in PostgreSQL,
    or equivalent) against tag names; results are listed under a `Tags`
    heading, ordered by name, each as a link to the tag's show page.
  - Performs a case-insensitive substring match against item filenames;
    results are listed under a `Files` heading, ordered by filename, each
    rendered using the standard item partial.
  - Sections with zero results MUST be omitted from the page entirely
    (rather than shown empty).
- If `q` is absent or empty, only the search form is shown.
- The search MUST happen on every form submission (no AJAX is required).

## 7. Layout, Theming and Static Assets

### 7.1 Themes

- The application MUST support multiple visual themes selectable at deploy
  time via a `THEME` environment variable (default `default`).
- A theme is a directory of layout partials and a directory of static
  assets. The reference ships two themes: `default` and `38degrees`.
- Each theme MUST provide three layout partials:
  - `head` — content rendered inside the HTML `<head>` (e.g. extra link
    tags, favicons, theme stylesheets).
  - `header` — content rendered above the main page yield (typically site
    title, navigation links, flash-notice region).
  - `footer` — content rendered below the main page yield.
- Each theme MUST provide a `default-file-icon.png` static image, served
  from `/themes/<theme>/images/default-file-icon.png`. This icon is used
  in listings whenever an item is not an image.
- Themes MAY provide additional static assets under
  `/themes/<theme>/images/` (e.g. logos).
- The active theme name MUST be exposed to views via a helper (the
  reference exposes `theme` as an `ApplicationHelper` method backed by
  `Rails.application.secrets.theme`).

### 7.2 Default theme

- Renders an `<h1>` of `Mah Bucket!`.
- Renders a flash-notice region.
- Renders a top navigation bar with three links: `files` (`/`), `tags`
  (`/tags`), `search` (`/search`).
- Empty footer.

### 7.3 38degrees theme

- Renders the 38 Degrees orange logo at the top of every page.
- Renders a flash-notice region.
- Renders a top navigation bar with four links: `View files` (`/`),
  `Add new file` (`/items/new`), `Tags` (`/tags`), `Search` (`/search`).
- Empty footer.

### 7.4 Layout

- The application layout MUST emit a CSRF meta tag, the application
  stylesheet, and the application Javascript bundle in the `<head>`,
  followed by the theme `head` partial.
- The body MUST be: theme `header` partial, then the page yield, then the
  theme `footer` partial.

## 8. Configuration

The following environment variables MUST be honoured. Unless otherwise
noted, they have no default and MUST be supplied for production use.

| Variable                    | Required          | Purpose                                              |
|-----------------------------|-------------------|------------------------------------------------------|
| `AWS_ACCESS_KEY_ID`         | yes               | S3 credentials.                                      |
| `AWS_SECRET_ACCESS_KEY`     | yes               | S3 credentials.                                      |
| `S3_BUCKET`                 | yes               | Bucket name.                                         |
| `S3_REGION`                 | no (default `eu-west-1`) | AWS region of the bucket.                     |
| `S3_HOST_ALIAS`             | yes               | Public DNS name used in returned object URLs.        |
| `DATABASE_URL`              | yes (production)  | SQL connection string.                               |
| `GOOGLE_OAUTH_CLIENT_ID`    | yes               | OAuth client identifier.                             |
| `GOOGLE_OAUTH_CLIENT_SECRET`| yes               | OAuth client secret.                                 |
| `GOOGLE_OAUTH_DOMAIN`       | yes               | Allowed email domain (e.g. `example.com`).           |
| `PERMITTED_IPS`             | no                | IP allow-list; if unset, no IP filtering is applied. |
| `CLIENT_IP_HEADER`          | no                | If set, take source IP from this header instead of the socket peer. |
| `THEME`                     | no (default `default`) | Selects which theme to render.                  |
| `SECRET_KEY_BASE`           | yes (production)  | Used to sign session cookies.                        |
| `SKIP_AUTH`                 | test only         | When set in the test env, bypass OAuth.              |
| `RAILS_MAX_THREADS`         | no                | Web server thread pool size.                         |
| `PORT`                      | no                | TCP port to listen on (default 3000).                |
| `NEW_RELIC_APP_NAME` / `NEW_RELIC_LICENSE_KEY` | optional | New Relic monitoring.                |
| `SENTRY_DSN`                | optional          | Sentry error reporting (if Sentry is configured).    |

The reference implementation also supports loading variables from a `.env`
file via Foreman or `export $(cat .env | grep -v ^# | xargs)`.

## 9. Deployment and Runtime

- The reference implementation runs as a single web process under Puma,
  with a configurable thread pool. There are no background workers, no
  queues, no scheduled jobs, no caching layer.
- The HTTP server MUST listen on `PORT` (default 3000).
- The application MUST work behind an HTTPS-terminating reverse proxy or
  load balancer; in particular, redirect URLs and OAuth callbacks must
  honour the proxied protocol.
- The application MUST run cleanly under Ruby 3.3.5 with Rails ~> 6.1.7
  (the reference) — but a re-implementation in any language/framework is
  acceptable as long as it satisfies the behavioural requirements in
  this document.
- Database creation/migration MUST be runnable as a one-shot command
  (the reference uses `rails db:setup`).
- A Docker Compose configuration suitable for running tests and serving
  the app locally MUST be provided.

## 10. Security Requirements

- All non-public routes MUST be protected by both the IP allow-list (if
  configured) and Google OAuth.
- Cross-Site Request Forgery protection MUST be enabled for all
  state-changing requests, including the OAuth start-of-flow redirect.
- Sessions MUST be stored in signed (and ideally encrypted) cookies. The
  cookie name in the reference is `_mahbucket_session`.
- The OAuth callback MUST refuse any user whose email domain does not
  match `GOOGLE_OAUTH_DOMAIN`. There is no per-user allow-list beyond
  domain matching.
- Uploaded files are publicly accessible from S3 by URL. Re-implementations
  MUST clearly document this in their README so operators do not store
  sensitive material in a public bucket without intending to.
- Parameters from the request body MUST be safelisted: only `item[file]`
  and `item[tag_list]` are accepted by the create/update actions.
- Filename validation: the application does NOT enforce a content-type
  allow-list (the reference explicitly disables it with
  `do_not_validate_attachment_file_type :file`). Re-implementations MAY
  add such a list but it is not required for parity.
- The application MUST set long-lived cache headers on uploaded objects,
  taking advantage of the immutable per-Item key path scheme.

## 11. Error Pages and User Feedback

- HTTP 403, 404, 422 and 500 MUST be served as static HTML pages from
  `public/` so they continue to work when the application is unavailable.
- All flash notices set by controllers MUST be rendered by the theme's
  header partial.
- Validation errors on the item form MUST be rendered as a list at the top
  of the form, prefixed with `<n> error(s) prohibited this item from being
  saved:`.
- Unauthorised OAuth attempts MUST receive a short HTML 401 response.

## 12. Observability

The application SHOULD support optional integration with:

- New Relic APM (via the `newrelic_rpm` gem in the reference; controlled
  by `NEW_RELIC_APP_NAME` and `NEW_RELIC_LICENSE_KEY`).
- Sentry for error reporting.

These are optional; the application MUST start cleanly with neither
configured.

## 13. Testing Requirements

A re-implementation MUST be accompanied by an automated test suite that,
at minimum, covers the behaviours below. The reference uses RSpec with
Capybara plus Selenium for JS tests.

### 13.1 Authentication / access tests

- A request from no source IP filter is allowed through.
- A request from a single permitted IP is allowed through.
- A request from a permitted IP given as `<ip> (label)` is allowed through.
- A request from a permitted IP listed in a multi-line `#`-commented list
  is allowed through.
- A request from a non-permitted IP receives `Access Denied`.
- When `CLIENT_IP_HEADER` is set, the IP is read from that header, and a
  matching value is allowed while a non-matching value is rejected.
- An unauthenticated user visiting `/` is redirected to start OAuth.
- A successful OAuth callback whose email domain matches creates a session.
- A successful OAuth callback whose email domain does NOT match returns
  HTTP 401.

### 13.2 Item CRUD tests

- `GET /items/new` shows a form with a file field.
- `GET /items/:id/edit` shows a form with a file field, and a heading
  including the current filename.
- `POST /items` with a valid file creates the item, redirects to the show
  page, and shows the `Item was created.` flash on the next page.
- `POST /items` with a duplicate file (matching fingerprint) re-renders
  the form with the duplicate-upload error message.
- `PUT /items/:id` with a new file replaces the file, redirects to the
  show page, and shows `Item was updated.`
- `PUT /items/:id` with a file that duplicates another item's file fails
  with the duplicate-upload error.
- `DELETE /items/:id` removes the item, redirects to the index, and shows
  `Item was deleted.`

### 13.3 Item index tests

- An empty library shows the `You have not added any items yet` message.
- A library with items renders one entry per item, including a link
  containing the item's filename.

### 13.4 Test fixtures

The test suite MUST ship with at least:

- A small JPEG image fixture (the reference uses `mah-bucket.jpg`).
- A small non-image text fixture (the reference uses `test.txt`).

### 13.5 Test mode for OAuth

The test suite MUST be able to bypass the live OAuth flow by using a
mock authentication provider that returns a fixed email at the configured
`GOOGLE_OAUTH_DOMAIN`. The reference uses `OmniAuth.config.test_mode` and
`mock_auth[:google_oauth2]`.

## 14. Out-of-scope clarifications

Re-implementers should explicitly NOT implement the following, as they are
absent from the reference and treated as non-features:

- File ownership / per-user libraries.
- Sharing or per-file permissions.
- File versioning or undelete.
- Bulk upload of multiple files in a single form submission.
- Folders, collections, or any hierarchical organisation other than tags.
- Editing of file *contents* (rotation, cropping, etc.).
- Renaming files. The filename is whatever the user uploaded; updating
  the file replaces it wholesale.
- Logout. (Sessions expire with the cookie.)
- A public read API; all routes require authentication.
- Tag editing or merging. Tags are created implicitly when used and
  destroyed implicitly when their last reference is removed.
- Background image processing. Derivatives are produced synchronously
  during the upload request.

## 15. Reference Implementation Summary

For convenience, a re-implementer can map the requirements above onto the
reference Rails 6.1 codebase as follows:

- Routing: `config/routes.rb`
- Authentication and IP filter: `app/controllers/application_controller.rb`
- OAuth callback handling: `app/controllers/sessions_controller.rb`
- Item CRUD: `app/controllers/items_controller.rb`
- Tag listings: `app/controllers/tags_controller.rb`
- Search: `app/controllers/search_controller.rb`
- Item model, image detection, fingerprint uniqueness, image styles:
  `app/models/item.rb`
- S3/Paperclip configuration: `config/initializers/paperclip.rb`
- OmniAuth configuration: `config/initializers/omniauth.rb`
- Tagging configuration: `config/initializers/acts_as_taggable_on.rb`
- Theme selection: `app/helpers/application_helper.rb`,
  `config/secrets.yml`
- Database schema (authoritative): `db/schema.rb`
- Specs covering the above: `spec/requests/`, `spec/features/`
