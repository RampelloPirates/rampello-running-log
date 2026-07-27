# ai-parse edge function

Server-side model calls for the nutrition tracker (`nutrition.html`). The browser
can't call `api.anthropic.com` directly — CORS blocks it on iOS and the API key
must stay server-side — so all parsing routes through here.

## Deploy

Requires the Supabase CLI, linked to this project (`dprmpgjgjppvdlyxlubr`).

```bash
# one-time: log in + link
supabase login
supabase link --project-ref dprmpgjgjppvdlyxlubr

# set the Anthropic key as a secret (never commit it)
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

# deploy
supabase functions deploy ai-parse
```

The function verifies the caller's Supabase JWT by default, so the front end
passes the signed-in user's access token. No extra config needed.

## Modes

`POST` JSON with a `mode` field:

| mode      | body                              | returns                                            |
|-----------|-----------------------------------|----------------------------------------------------|
| `meal`    | `{ text }`                        | `{ items: [...], note }`                            |
| `recipe`  | `{ text }`                        | `{ ingredients: [...], note }`                      |
| `scrape`  | `{ url }`                         | `{ name, servings, total_minutes, instructions, source_url, ingredients: [...], note, parsed_by }` |
| `label`   | `{ image (base64), media_type }`  | `{ productName, caloriesPerServing, ... }`          |
| `barcode` | `{ barcode }`                     | food per-100g shape (via Open Food Facts)          |

### `scrape` (used by `recipes.html`)

Fetches the page here rather than in the browser, because recipe sites send no
CORS headers. It reads schema.org JSON-LD when the site publishes a `Recipe` —
exact amounts, no model call — and only falls back to Claude reading the
stripped page text when it doesn't. `parsed_by` says which route ran
(`"schema"` or `"model"`) so the page can tell you whether the amounts were
read or estimated. Either way the ingredient lines then go through the same
estimator as `recipe` mode, so the result has grams and macros per ingredient.

Server-side fetching means the URL is checked before it's followed: http/https
only, a denylist of loopback/private/link-local hosts (including the cloud
metadata address), and redirects followed by hand so every hop is re-checked.
It does **not** defend against a public hostname that resolves to a private
address — that needs resolving DNS ourselves and pinning the connection, which
Deno's `fetch` won't do. Proportionate for a personal app reading recipe sites;
worth knowing before this function is pointed at anything less friendly.

Model: `claude-sonnet-4-6` (chosen in the nutrition build plan for high-volume
extraction). Change `MODEL` in `index.ts` to adjust.
