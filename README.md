# Biology Student Portal · Al-Anjal

Student and teacher portal for Mr. Reda Elsayed's biology classes (Grades 9B–12):
ID + PIN login, McGraw Hill course map, interactive lessons (CER launch, lab, simulations,
practice, flashcards, Lesson Check with AI marking), calendar, notes and live progress reports.

## How it is built
| Part | Where |
|---|---|
| Website (one static page) | `index.html` — served by Cloudflare Pages / Vercel / Netlify |
| Database, logins, live results | Supabase project `biology-portal` (region ap-south-1) |
| Database schema | `supabase/migrations/` |
| AI marking | Supabase Edge Function `supabase/functions/mark` |

No student names, IDs or PINs are stored in this repository. They live only in the Supabase database.

## Turning on hosting (Cloudflare Pages)
1. pages.cloudflare.com → Create → Pages → Connect to Git → choose this repository.
2. Framework preset: **None**. Build command: *(leave empty)*. Output directory: `/`.
3. Deploy. Every push to `main` then goes live automatically.
4. Custom domain: Pages project → Custom domains → add your domain and follow the DNS step.

## Turning on AI marking
Supabase → Project Settings → Edge Functions → Secrets → add `ANTHROPIC_API_KEY`
(from console.anthropic.com). Optional: `ANTHROPIC_MODEL`. Without a key the portal
marks written answers with its built-in answer key instead.

## Accounts
Students log in with their 10-digit ID and a 6-digit PIN. The teacher can reset any
student's PIN from **Reports → Live lesson results**; students can change their own PIN
from their dashboard.
