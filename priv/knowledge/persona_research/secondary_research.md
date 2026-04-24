# Secondary Research — Mining Public Sources

When interviews are blocked, budgets are thin, or the agent is entering a category cold, mine public sources to form evidence-grounded hypotheses about the persona. Every claim still needs triangulation: ≥3 independent sources before it ships in the persona.

## Sources
- Erika Hall, Mule Design — https://www.muledesign.com/blog/the-9-rules-of-design-research ; *Just Enough Research* — https://abookapart.com/products/just-enough-research
- NN/g, Triangulation — https://www.nngroup.com/articles/triangulation-better-research-results-using-multiple-ux-methods/
- NN/g, Confirmation Bias in UX — https://www.nngroup.com/articles/confirmation-bias-ux/
- Joanna Wiebe, Copyhackers review mining — https://copyhackers.com/2014/10/amazon-review-mining/ and https://copyhackers.com/how-to-do-rapid-fire-review-mining/
- Amy Hoy &amp; Alex Hillman, Sales Safari (30x500) — https://stackingthebricks.com/podcast/ep42-what-is-sales-safari-with-eteinne-garbugli/
- Ahrefs, Google search operators — https://ahrefs.com/blog/google-advanced-search-operators/
- Guest, Bunce &amp; Johnson (2006), saturation — https://journals.sagepub.com/doi/10.1177/1525822X05279903

---

## Triangulation rule

**No claim goes in the persona unless ≥3 independent sources support it.** One Reddit thread + one G2 review + one podcast guest quote beats three posts in the same subreddit. NN/g: triangulation combines methodological (different methods) and data-source (different people/places/times) forms.

For every hypothesis, also search **explicitly for disconfirming evidence** before locking it. This is the cheapest bias countermeasure.

## Logic of secondary research

| When it works                                         | When it fails                                          |
|-------------------------------------------------------|--------------------------------------------------------|
| Need a defensible hypothesis fast                     | You let survivorship bias drive conclusions            |
| Budget or access blocks interviews                    | Single-platform mining without cross-check             |
| Entering a category you don't yet understand          | Vocal-minority posts treated as median user voice      |
| Comparing public perception with internal assumptions | Confirmation bias — you find what you were looking for |
| Pre-interview orientation (know the vocabulary)       | AI-generated review pollution (10–30% on G2/Capterra)  |

Hall's principle: "good research is about asking more and better questions, and thinking critically about the answers." Desk research is not exempt from discipline — you can still cherry-pick. **Triangulate.**

---

## Platform playbook

For each platform: what you learn, how to search effectively, limitations.

### Reddit

**Signal:** unfiltered complaints, "I wish" feature requests, competitor comparisons, community vocabulary.

**Sort strategy:**
- **Top / All-time** — canonical gripes. Characterizes the persona's worldview.
- **New** — current mood; reaction to launches and price changes.
- **Controversial** — where the community splits (surfaces sub-personas).

**Discovery:** r/findareddit, Pushshift (https://search-tool.pushshift.io/), NicheProwler (https://www.nicheprowler.com/tools/reddit/subredditList). Follow active users across subs — their comment history reveals adjacent communities.

**Search** (use Google; Reddit's native search is weak):
- `site:reddit.com/r/[sub] "I wish" [category]`
- `site:reddit.com "switched from [competitor]" "to"`
- `site:reddit.com "alternative to [competitor]"`
- `site:reddit.com "is there a tool for"` — decided they need something, can't find it
- `site:reddit.com "does anyone else" [pain]`
- `site:reddit.com "why is there no"`

**Tools:** GummySearch (shutting down Nov 30, 2026), PainOnSocial, Reddinbox, TrendSeeker, BigIdeasDB — all surface pain-point posts, solution requests, "money talk."

**Limitations:** US/male/tech skew; vocal minority effect; karma-farming accounts. Save thread URL, date, upvotes, top 3 comments verbatim.

### Review sites (G2, Capterra, TrustRadius, Trustpilot, Gartner Peer Insights, Product Hunt, App/Play Store)

**Signal:** jobs-to-be-done ("we hired this to…"), the actual prior solution ("switched from X"), buyer role, company size, deal-breakers, dollar amounts.

**Key field: "Switched from."** Capterra explicitly prompts for it. "We used to use…" and "before switching, we tried…" reveal the real replacement competitor — rarely the one marketing names.

**Read negative reviews for JTBD signals:**
- **Trigger** — "When we grew past 50 people, X broke"
- **Alternatives considered** — fills competitive set
- **Switching-cost narrative** — stickiness levers
- **"Finally" / "At last"** — long-running pain
- **"Tired of" / "Fed up"** — pain intensity
- **Dollar amounts / headcount** — ICP firmographics

**Queries:**
- `site:g2.com [category] "switched from"`
- `site:capterra.com [product] "alternatives"`
- `site:trustradius.com [product] cons`
- `site:trustpilot.com "[product]" refund OR cancel` (high emotion)

**Tier profile:**
| Platform | Skew | Notes |
|---|---|---|
| G2 | Mid-market SaaS | Volume-driven; high fake-review rate |
| TrustRadius | Enterprise | Longer-form; 60% rejection rate on submissions |
| Capterra | SMB | Strong "switched from" data |
| Gartner Peer Insights | Enterprise | Vendor-gated but deep |
| Product Hunt | Launch-day | Comments = real-time feature-request firehose |
| App / Play Store | Consumer mobile | Export via Apify; localized pain signals |

**Limitations:** 10–30% estimated AI-generated reviews across G2/TrustRadius/Capterra. Weight specific, dated, numeric reviews over generic praise. Fake-review red flags: generic ROI claims, marketing phrasing, no use case specifics, clustered dates.

### Hacker News

**Signal:** how technical decision-makers frame a category. Competitor comparisons marketing would never write.

**Search:** Algolia full-text at https://hn.algolia.com/. Sort by points, date, or relevance. Filter by `created_at_i`.
- Search `[competitor]` — read every top-level comment in the top 20 threads.
- `Show HN: [category]` — alternatives and benchmarks.
- `Ask HN: [category]` — direct tooling requests.

Weight commenters by karma + tenure (years of activity). Dismiss new low-karma contrarians.

**Limitations:** SV skew, contrarian audience. Not a proxy for non-technical personas.

### YouTube

**Signal:** comment threads under competitor tutorials are raw VoC. "This doesn't work if you're trying to…" comments surface unmet jobs.

**Method:**
- Search `[competitor] tutorial`, views descending, top 10 videos, read comments sorted by "Top."
- Search `[competitor] vs [competitor]` — comments often contain actual buyer deliberation.
- Creators with multiple videos in the category = the persona's media environment. Sponsor reads reveal the buyer.

Save: video URL, creator, subscriber count, sentiment, verbatim quotes from top-ranked comments.

### LinkedIn

**Signal:** who the buyer is (titles), who the user is (titles), what tools they already use (job reqs), what they read/repost.

**Tactics:**
- **Job postings** as ICP intel. A company hiring "5 data engineers" is mid-buying-cycle for data tooling. Extract: title, "tools you've used," reporting line, team size.
- **Sales Navigator boolean** (operators UPPERCASE): `("Head of Marketing" OR "VP Marketing" OR CMO) NOT Assistant`. Stack firmographic (industry, headcount, geo) → role (title, seniority) → signal (funding, job changes, hiring growth).
- **Competitor job postings** — who they hire tells you who they serve.
- **People Also Viewed** on profiles → archetype clustering.
- **Posts from the ICP** — search `"as a [role]" "I need"` filtered to posts.

**Limitations:** performance layer. People post aspirational, not honest. Combine with anonymous sources (Reddit, Blind).

### Twitter/X

**Signal:** real-time reactions, competitor complaints, "I wish" requests.

**Operators:**
- `from:competitor` — their announcements
- `to:competitor (disappointed OR frustrated OR switching OR cancel)` — unhappy customers = prospect list
- `"[competitor]" (unhappy OR "bad experience" OR alternative) -from:yourbrand`
- `"I wish [category] did"`
- `"as a [role]" "need"`
- `"[category]" min_faves:50 min_replies:20` — posts that struck a nerve
- `filter:replies "to:[competitor]"` — thread patterns

**Limitations:** API gated/expensive post-2023; UI rate-limited. Use cautiously.

### Quora

**Signal:** long-tail beginner vocabulary; one-time decisions.

**Queries:**
- `site:quora.com "best [category] for [persona]"`
- `site:quora.com "how do I [job]"`

Weight by upvotes and answerer credentials. Many answers are SEO affiliate content.

### Facebook groups

**Signal:** SMB / consumer personas that don't live on LinkedIn. Parents, hobbyists, local operators.

**Method:** join 5–10 groups; observe silently 1–2 weeks before drawing conclusions. Cross-reference across groups. Meta's reduced discoverability: supplement with `site:facebook.com/groups [niche]`.

**Ethics:** don't quote identifying info publicly.

### Discord / Slack

**Signal:** power-user workflows, real-time support conversations, tool recommendations.

**Find them:** `[niche] discord server list`, disboard.org, top.gg, Indie Hackers, creator Linktrees.

**Ethics:** digital ethnography norms. Observe, don't exploit. Private/invite-only communities are off-limits without permission.

### Stack Overflow

**Signal:** technical personas' top pain — error messages, library quirks.

**Approach:**
- Tag page (e.g., https://stackoverflow.com/questions/tagged/elixir), sort by Frequent or Votes — top N = "what this persona is stuck on."
- Annual Developer Survey for macro trends: https://survey.stackoverflow.co/

**Queries:**
- `site:stackoverflow.com [competitor-sdk] error`
- `site:stackoverflow.com [category] best practice`

Pair with HN/Reddit for motivation ("why").

### Specialized forums / niche watering holes

IndieHackers, dev.to, WarriorForum, DesignerHangout, BiggerPockets, Chowhound, rideshare driver forums, trucking forums, Reef Central, BackYardChickens, etc. For any niche, `[niche] forum` and `[niche] community` + "where does [persona] hang out" Reddit cross-check surfaces the watering hole.

### GitHub

**Signal:** developer priorities — issue reactions, Discussions tab, stargazer profiles.

**Approach:**
- `repo:[competitor] is:issue` sorted by :+1: for most-wanted features.
- Discussions tab for longer-form problems.
- Stargazer list → firmographics via profiles.
- `"as a developer" "I want" in:issues org:[competitor]`

### Amazon / marketplace reviews

**Signal:** adjacent-category verbatim language. Wiebe's canonical review-mining ground.

**Method (Copyhackers):**
- 50–100 reviews, mix of 5-star and 1–3-star
- Extract verbatim into sheet: quote | rating | pain | dream | barrier | trigger | vocabulary
- Rapid-fire Google formula: `site:amazon.com inurl:"product-reviews" "tired of" [keyword]`
- Swap "tired of" for: `"finally"`, `"at last"`, `"I wish"`, `"was hoping"`, `"useless"`, `"waste of money"`

---

## Competitor analysis

Competitors have paid to learn who their customer is. Read the evidence they leaked.

**Signals to extract:**
- **Homepage H1 + subhead** — the job they think they sell.
- **Pricing page** — seats/volume/feature gating tells ICP firmographics.
- **Changelog / release notes** — which personas win attention.
- **Case studies** — logo + role + industry = paying ICP. Extract ROI metrics verbatim.
- **Customer logos** — marketing's version of the ICP.
- **"Switching from [X]" pages** — who they steal from.
- **Job postings** — who they hire signals who they sell to.
- **Ads libraries** — Meta Ads Library, LinkedIn Ads Library, SEMrush Advertising Research.

Build a competitor matrix: ICP firmographics, pricing model, claimed primary job, hero case-study quotes, recent changelog themes, job-post signals.

**Every "we switched from X because…" quote is a documented Force of Progress** — see `jtbd.md#four-forces`. Triangulation-grade evidence.

---

## Industry reports without paying

- **Vendor-hosted copies.** Gartner / Forrester reports are frequently hosted free by vendors self-promoting. `"Gartner Magic Quadrant" [category] filetype:pdf`.
- **Analyst blogs + press releases.** Forrester/IDC publish free blog summaries.
- **Webinars.** Free registration often yields the slide deck with charts.
- **Library databases.** University/public library card → IBISWorld, Statista, Mintel, Frost &amp; Sullivan.
- **Pew Research Center.** Fully free; raw data 6 months after publication. https://www.pewresearch.org/
- **Statista.** Many charts linked free from news articles.
- **Government data.** data.gov, FRED, Census, BLS.
- **Google Scholar** for analyst-cited white papers.
- **Trade associations.** NRF (retail), HIMSS (healthcare IT), IAB (digital advertising), etc.

---

## Trade publications, podcasts, newsletters

The media the ICP consumes is itself a persona artifact.

- **Guest lists on vertical podcasts** → archetype catalog. Each guest bio is a persona sketch.
- **Sponsor lists** → categories the ICP is being sold → budget-holder inference.
- **Advertorial placements** in trade pubs → budget-holding personas.
- **Editors/columnists** → follow on LinkedIn; read their vocabulary.

For each persona produce a **Media Diet**: 5 podcasts, 5 newsletters, 5 publications, 3 conferences, 3 thought leaders.

---

## Google search operators

Canonical reference: https://ahrefs.com/blog/google-advanced-search-operators/

| Operator             | Use                                                       |
|----------------------|-----------------------------------------------------------|
| `site:`              | Restrict domain                                           |
| `intitle:` / `allintitle:` | Title match                                          |
| `inurl:` / `allinurl:` | URL match (e.g., `inurl:reviews`, `inurl:forum`)        |
| `intext:`            | Body content                                              |
| `"exact phrase"`     | Verbatim match                                            |
| `-exclude`           | Subtract                                                  |
| `OR` (uppercase) / `\|` | Disjunction                                           |
| `AROUND(N)`          | Proximity                                                 |
| `filetype:pdf`       | Analyst reports, whitepapers                              |
| `before:YYYY-MM-DD` / `after:YYYY-MM-DD` | Date-filtered                      |

### Persona-discovery query templates
- `"as a [role]" "I need" site:reddit.com`
- `"as a [role]" "I'm struggling" OR "I can't"`
- `"switched from [X]" "to [Y]" site:g2.com OR site:capterra.com`
- `"alternative to [competitor]" intitle:best`
- `"[category]" "I wish" site:reddit.com after:2024-01-01`
- `[competitor] case study filetype:pdf`
- `"[persona role]" "job description" [tool]` — postings listing the tool = ICP firmographic
- `inurl:reviews "cancelled" [competitor]`
- `intitle:"[category] vs [category]"` — head-to-head buyer content

### Voice-of-customer mining
- `site:reddit.com "tired of [category]"`
- `site:amazon.com inurl:product-reviews "finally" [category]`
- `"I used to [old solution]" "now [new solution]"`

---

## AI citation &amp; SERP mining

SERPs and AI answer engines proxy the questions the persona is asking.

- **People Also Ask (PAA).** Top 4–8 nodes per query; click each to expand. For any head term, a PAA tree maps the persona's decision flow. Tools: AlsoAsked, AnswerThePublic.
- **AI Overviews (Google SGE).** Cited sources are the canonical category authorities — read them. Absences are whitespace.
- **ChatGPT Search / Perplexity.** Ask `best [category] for [persona]` and `why do people switch from [X] to [Y]` — note cited domains.
- **SERP features to capture.** Featured snippet text, PAA tree, AI Overview citations, related-searches footer, image pack, video carousel.

---

## Voice-of-customer (VoC) mining

Consolidate every public-source quote into a single structured grid. Keep it verbatim.

### The 5-bullet VoC grid

For each persona candidate:

| Cell          | Meaning                                         | Example                                                      |
|---------------|-------------------------------------------------|--------------------------------------------------------------|
| **Pain**      | Verbatim frustration                            | "I spend 3 hours every Monday reconciling spreadsheets"      |
| **Dream**     | Verbatim outcome wished for                     | "I just want to hit publish and go home"                     |
| **Barrier**   | What's in their way                             | "My CFO won't approve another SaaS seat"                     |
| **Trigger**   | Event that makes them shop                      | "We just got acquired / our lead left / we crossed 50 users" |
| **Vocabulary**| Exact words they use for the category           | "ops stack" not "business process tools"                     |

Each cell requires **≥3 verbatim citations** (URL + date + quote). Paraphrase destroys signal.

### Joanna Wiebe / Copyhackers method
- 50–100 reviews per competitor or adjacent product, mix of 5★ and 1–3★
- Spreadsheet with quote | rating | pain | dream | barrier | trigger | vocabulary
- Cluster. Most-repeated phrasing becomes the headline copy.

### Amy Hoy &amp; Alex Hillman — Sales Safari (30x500)
Online ethnography. Watering-hole-first, four-quadrant notes:
- **Pain** — problems, frustrations
- **Jargon** — persona's vocabulary (use exact words in copy/product)
- **Worldview** — unshakable beliefs ("enterprise software is bloated")
- **Recommendations** — what they tell each other to use/avoid

Time investment: 30–50 hours of observation per persona before drawing conclusions.

---

## Red flags and traps

See `pitfalls.md` for the full catalog. Secondary-research-specific:

- **Survivorship bias.** Churned users have left, deleted, or never posted. Actively search for "why I left [product]", "migrated away from X", `"cancelled [product]"`.
- **Vocal minority.** Active posters are extreme. Weight by **engagement breadth** (many unique users agreeing), not volume (same user posting repeatedly).
- **AI-generated reviews.** Estimated 10–30% on G2/Capterra/TrustRadius. Red flags: generic ROI, marketing phrasing, clustered dates, no use-case specifics.
- **Echo chamber / algorithm bubble.** Use incognito, rotate platforms, read dissenting sources deliberately.
- **Platform demographic skew.** Reddit ≠ your ICP automatically. Check whether your real persona actually lives on the platform you're mining.
- **Self-report vs behavior gap.** Weight observed behavior (migration posts, cancelled subs) over stated preferences.
- **Astroturfing.** Especially around launches. Check account age and history before weighting.

## Signal-weighting heuristic

| Confidence | Criteria                                                                     |
|------------|------------------------------------------------------------------------------|
| **High**   | Verbatim quote, identifiable firmographic context, ≥3 independent sources, last 18 months, user with history |
| **Medium** | Anonymous but specific, single platform / multiple threads, last 3 years     |
| **Low**    | Generic, no context, single post, new account, clustered with similar posts  |

Discount "low" confidence signals; don't ship them into the persona.

---

## Agent operating procedure (secondary-only path)

1. **Orient.** 30 min on SERPs, PAA trees, AI Overview citations — identify category authorities and question shape.
2. **Find watering holes.** Reddit subs, Discord servers, YouTube creators, newsletters, podcasts, forums. Log top 10 per persona candidate.
3. **Sales-Safari observe.** Spread 30–50 hours total across watering holes; capture pain / jargon / worldview / recommendations verbatim.
4. **Review-mine.** G2 / Capterra / TrustRadius / Amazon / App Store — 50–100 reviews per relevant product into a VoC grid.
5. **Competitor-read.** Pricing, case studies, switching pages, changelogs, job postings — extract ICP firmographics.
6. **LinkedIn + Twitter layer.** Pull the public version; compare against anonymous Reddit; note the gap.
7. **Triangulate.** Every final claim ≥3 independent sources with verbatim citations.
8. **Disconfirm.** For each claim, actively search counter-evidence before locking.
9. **Assemble.** Feed the VoC grid (pain / dream / barrier / trigger / vocabulary) populated with verbatim quotes (URL + date) into `synthesis.md`.
