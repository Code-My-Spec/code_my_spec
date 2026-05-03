# Code Generation Resources

Reference materials for AI-assisted Phoenix LiveView code generation.
Extracted from official documentation — each file lists source URLs at the top.

## When to read what

| Building...                        | Read                                      |
|------------------------------------|-------------------------------------------|
| A new LiveView module              | `liveview/patterns.md`                    |
| Function components / core_components | `liveview/core_components.md`          |
| A form (create, edit, settings)    | `liveview/forms.md`                       |
| LiveView or LiveComponent tests    | `liveview/testing.md`                     |
| Any HEEx template                  | `heex/syntax.md`                          |
| UI layout or styling               | `ui/tailwind.md` then `ui/daisyui.md`    |
| A table, modal, card, or list      | `ui/daisyui.md` + `liveview/patterns.md` |
| Context, schema, or test scaffold  | `conventions.md`                          |
| BDD specs (Given/When/Then)        | `bdd/spex.md`                             |
| Bounded context isolation, dep rules | `boundary.md`                             |
| Browser QA with `web` CLI           | `web-cli.md`                              |
| AWS S3 buckets, IAM users          | `devops/aws-s3-iam.md`                    |
| Cloudflare DNS, tunnels, SSL       | `devops/cloudflare-dns-tunnels.md`        |
| Hetzner server, Docker, Caddy      | `devops/hetzner-docker-deploy.md`         |
| Deployment scripts, secrets, envs  | `devops/hetzner-docker-deploy.md`         |
| Static images via S3 + Cloudflare CDN | `devops/s3-cloudflare-image-host.md`   |
| URL migrations / 301 redirects (Phoenix plug) | `devops/url-migration-redirects.md`  |
| HTTP client for an API integration | `req/clients.md`                          |
| Recording HTTP calls in tests      | `req/cassettes.md`                        |
| Env vars, secrets, .env files      | `dotenvy.md`                              |
| Persona research (PM intake + online mining) | `persona_research/README.md`    |

## Target stack

- Phoenix 1.8-rc
- Phoenix LiveView 1.1-rc
- DaisyUI 5
- Tailwind CSS 4

## File index

```
knowledge/
├── README.md                 ← you are here
├── boundary.md              # Boundary library, context isolation, dep/export rules
├── conventions.md            # Layered architecture, naming, scope, contexts, schemas, tests
├── dotenvy.md               # Dotenvy env vars, .env files, type casting, source!/1, env!/2
├── liveview/
│   ├── patterns.md           # mount, handle_event, handle_params, streams, assign_async, JS commands
│   ├── core_components.md    # attr/slot macros, function components, render_slot, :global
│   ├── forms.md              # to_form, phx-change/submit, validation, changesets
│   └── testing.md            # LiveViewTest: mount, events, forms, navigation, uploads, assertions
├── ui/
│   ├── daisyui.md            # Component classes, theme system, semantic colors
│   └── tailwind.md           # Layout, spacing, responsive breakpoints, flex/grid
├── heex/
│   └── syntax.md             # ~H sigil, :for/:if/:let, phx- bindings, change tracking
├── bdd/
│   └── spex.md               # SexySpex DSL, Given/When/Then, context flow, shared givens, mix spex
├── req/
│   ├── clients.md             # Minimal Req client modules, new/1 pattern, plug injection for tests
│   └── cassettes.md           # ReqCassette record/replay, with_cassette, filtering, CI modes
├── web-cli.md                # chrismccord/web CLI — shell browser for LLM agents, flags, LiveView support
├── persona_research/
│   ├── README.md             # Index: when to read what, agent workflow
│   ├── overview.md           # Definitions, persona types, critique, when to use what
│   ├── pm_intake.md          # Internal artifact checklist + 15 PM interview questions
│   ├── primary_research.md   # User interviews: sample size, screener, question discipline
│   ├── secondary_research.md # Online mining: Reddit, G2, HN, LinkedIn, VoC, operators
│   ├── jtbd.md               # Jobs-to-be-Done framework, Switch Interview, four forces, VPC
│   ├── templates.md          # Persona fields, one-page layout, deliverable set
│   ├── synthesis.md          # Raw data → personas: affinity, Cooper 7-step, validation
│   └── pitfalls.md           # Anti-patterns, bias countermeasures, ship checklist
└── devops/
    ├── aws-s3-iam.md          # S3 buckets, IAM users/policies, ExAws config, CLI commands
    ├── cloudflare-dns-tunnels.md # DNS records, tunnels, SSL/TLS, multi-env routing, Caddy integration
    ├── hetzner-docker-deploy.md # Hetzner provisioning, Docker Compose, Caddy, db backups, secrets, hardening
    ├── s3-cloudflare-image-host.md # Decoupled image CDN: S3 (bucket=host) + Cloudflare proxy + IMAGES_HOST env
    └── url-migration-redirects.md  # 301-redirect plug for URL migrations, query-string preservation, scaling
```
