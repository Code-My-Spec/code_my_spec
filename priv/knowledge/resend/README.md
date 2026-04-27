# Resend — Agent Knowledge Index

How to find the right file when working with email in this project.

## When to read what

| Task | Read |
|---|---|
| Setting up the Resend CLI for manual testing or domain management | `cli.md` |
| Calling the Resend REST API directly (not via Swoosh) | `api.md` |
| Sending transactional email from Elixir, writing email modules, testing | `swoosh.md` |
| Receiving delivery events, bounce notifications, open/click tracking | `webhooks.md` |
| Using Resend-hosted templates with variable substitution | `templates.md` |
| Debugging send failures, 422 errors, rate limits, test-mode quirks | `gotchas.md` |
| DNS setup and domain verification | `../devops/cloudflare-resend-email-setup.md` |

## What is already in place

- `CodeMySpec.Mailer` — `lib/code_my_spec/mailer.ex`, three-line Swoosh mailer module
- `CodeMySpec.Users.UserNotifier` — magic link and confirmation emails
- `CodeMySpec.Invitations.InvitationNotifier` — invitation, reminder, cancellation, welcome emails
- `config/runtime.exs` — prod adapter: `Swoosh.Adapters.Resend`, key from `RESEND_API_KEY`
- `config/prod.exs` — `api_client: Swoosh.ApiClient.Req`, Req is already a project dep
- `config/test.exs` — `Swoosh.Adapters.Test`, `api_client: false`
- DNS/DKIM verified for `codemyspec.com`; `from` address must use that domain

## Stack

- **Swoosh 1.16** — Elixir mailer abstraction
- **Swoosh.Adapters.Resend** — built into Swoosh, no extra dep required
- **Swoosh.ApiClient.Req** — HTTP transport (Req is already in `mix.exs`)
- **Resend REST API** — `https://api.resend.com`
