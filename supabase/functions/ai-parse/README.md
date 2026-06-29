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
| `label`   | `{ image (base64), media_type }`  | `{ productName, caloriesPerServing, ... }`          |
| `barcode` | `{ barcode }`                     | food per-100g shape (via Open Food Facts)          |

Model: `claude-sonnet-4-6` (chosen in the nutrition build plan for high-volume
extraction). Change `MODEL` in `index.ts` to adjust.
