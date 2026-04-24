# PM Intake — What to Ask For and What to Ask

The agent's first move. Before planning new research, exhaustively pull existing artifacts and data. Everything below has usually already been partially done at the company; the PM just doesn't know to hand it over until asked by name.

## Sources
- NN/g — https://www.nngroup.com/articles/persona-types/
- NN/g, Personas vs Analytics Segments — https://www.nngroup.com/videos/personas-vs-analytics-segments/
- Gartner, Define Your ICP — https://www.gartner.com/en/digital-markets/insights/b2b-ideal-customer-profile
- Adele Revella, Buyer Persona Institute (5 Rings of Buying Insight) — https://buyerpersona.com/leadership
- Klue, Win-Loss Interviews — https://klue.com/blog/win-loss-interviews and https://klue.com/blog/31-best-win-loss-questions
- Amplitude, Behavioral Cohorts — https://amplitude.com/docs/analytics/behavioral-cohorts
- Mixpanel, Cohorts — https://docs.mixpanel.com/docs/users/cohorts
- Segment CDP — https://segment.com/customer-data-platform/
- Thematic, analyzing support tickets — https://getthematic.com/insights/zendesk-ticket-analytics-intercom-chat-analytics
- Teresa Torres, Product Talk — https://www.producttalk.org/

---

## Framing before intake

Set two things with the PM before pulling data:

1. **Mode.** Proto, qualitative, or statistical? (See `overview.md#types-of-personas`.) This controls cost and timeline.
2. **Decision being supported.** Personas that don't tie to a live decision become wall art (`pitfalls.md#persona-theater`). Ask: "What decision will these personas inform? Feature prioritization? GTM positioning? Onboarding redesign?"

Also: in B2B, split the intake into **account-level (ICP, firmographic)** vs **person-level (role, job)**. They come from different systems and different owners.

## Intake checklist

For each item: *what it is · why it matters · how to ask*.

### Qualitative research

| Artifact                             | Why it matters for personas                                              | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **User interview recordings / transcripts** | Highest-signal input. Transcripts get coded and clustered directly into personas. | "Any interview recordings / transcripts from the last 12 months — discovery, usability, win/loss, churn? Where (Dovetail, Notion, Grain, Gong, Drive)? Can I get read access or exports?" |
| **Existing research reports / insight summaries** | Cheaper than re-running the study. Look for thematic codes and verbatim quotes. | "What user/market research has been synthesized? Can you share raw themes and tags, not just the slide conclusions?" |
| **Listening-session / mental-model data** | Non-directed interviews produce thinking-style data that maps cleanly to archetypes. | "Have you done any non-leading, deep-listening interviews focused on a purpose (not the product)?" |

### Sales / revenue

| Artifact                             | Why                                                                      | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Sales call recordings (Gong / Chorus / Clari)** | Transcribed, AI-tagged buyer conversations. Voice of the buyer, resonant value props by segment. | "Do we use Gong, Chorus, Clari, or any conversation intelligence tool? Can I pull transcripts tagged by deal stage?" |
| **Win/loss interview notes**         | Reveal buyer role, buying process, trigger event, evaluation criteria, objections. | "Do we run win/loss? Who does it (internal vs Klue / Primary Intelligence)? Raw notes, not just the win-rate dashboard." |
| **CRM pipeline — Salesforce / HubSpot** | Deal stage history + Closed-Lost-Reason + contact roles surface systemic objections by segment. | "12 months of closed-won and closed-lost deals with: firmographics, deal size, closed-lost reason, primary contact title, # of stakeholders. Is closed-lost-reason mandatory on stage change?" |
| **Enriched firmographic / contact data (Clearbit / Apollo / ZoomInfo)** | Establishes ICP at company level; lets you slice all other data by firmographic cohort. | "Which enrichment vendor? Dump enriched traits on all accounts that converted in the last year, plus trial-only and closed-lost." |

### Customer success / support

| Artifact                             | Why                                                                      | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Support tickets (Zendesk / Intercom / Help Scout)** | Best record of customer pain. Segmenting tickets by persona/plan uncovers trends invisible in aggregate. | "Export 6 months of tickets with: account ID, plan/segment, tags, ticket body (redacted if needed). Raw text, not just category counts." |
| **CS notes / health scores / QBR decks** | CSMs know why customers stay; hear usage patterns, expansion triggers. | "Last two quarters of QBR decks for top-20 accounts, and a CSM's informal archetype of their book — they always have one." |
| **Churn reasons**                    | Not all customers leave for the same reasons; churn analysis differs by persona. | "Structured (dropdown) or unstructured (CSM note)? Both, tied to firmographics and usage at time of churn." |

### Quantitative product / marketing

| Artifact                             | Why                                                                      | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Product analytics (Amplitude / Mixpanel / Heap / PostHog)** | Behavioral cohorts surface power-user vs churning clusters → persona *candidates*. | "Which tool? Who can give read access? Any saved cohorts for power users, activated users, at-risk users?" |
| **Funnel / onboarding dropoff**      | Dropoff patterns diverge sharply by persona.                              | "Current onboarding funnel segmented by signup source, plan tier, role (from signup form). Where does each segment drop?" |
| **CDP / Segment traits**             | Unified user profiles with computed traits — ready-made clustering inputs. | "Do we have a CDP? Identity resolution model (userId vs email)? Export the trait schema." |
| **NPS / CSAT (raw, not just score)** | Open-text "why" is a cheap VoC gold mine. Segmenting by role/plan/industry exposes persona differences. | "Raw open-text NPS/CSAT for the last year, joinable to user ID. Not the averaged score." |
| **Surveys (general)**                | Validation (not discovery). Test whether a hypothesized role/need holds at scale. | "List every survey run in the last 18 months, the tool, and whether raw responses are still accessible." |

### Marketing / growth

| Artifact                             | Why                                                                      | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Signup form data**                 | Cheapest self-reported role/firmographic; join to behavior.               | "Signup form schema + 12-month export of answers joined to conversion outcome." |
| **Pricing-page analytics + ICP doc** | Plan distribution is a segmentation proxy; ICP doc is the starting hypothesis. | "Do we have an ICP document? Who owns it? When last updated, and on what data?" |
| **Competitor win/loss analysis**     | Reveals alternative solutions personas compare against → positioning inputs. | "Top-5 competitor list and where we track competitive win rates by competitor." |

### Existing persona artifacts

| Artifact                             | Why                                                                      | Ask                                                                 |
|--------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Any existing persona docs**        | Even bad ones are starting hypotheses. Multi-team inconsistency is itself a finding worth surfacing. | "Send me every persona doc that exists — product's, marketing's, sales enablement's, success's. I expect inconsistency." |
| **Feature adoption by segment**      | Features used by Persona A but ignored by B are the strongest evidence the personas are actually distinct. | "Adoption rates for top-10 features segmented by industry, company size, role." |

---

## 15 questions to put to the PM

Organized by theme. Designed to surface **what the PM actually knows vs. what they're assuming.**

### A. ICP &amp; segment boundaries
1. "Walk me through your current ICP in one sentence. When was it last revised, and what data drove that revision?"
2. "If I pulled your closed-won accounts from the last year and compared their firmographics to your stated ICP, what % would fit?"
3. "Which customer segments make the most money, and which consume the most support/CS effort? Are they the same?"

### B. Existing research &amp; artifacts
4. "What user, win/loss, or churn interviews have been done in the last 12 months? Where are the recordings?"
5. "Do personas exist today? Send me every version — product's, marketing's, sales enablement's. I expect them to disagree."
6. "What's the single most-cited customer insight inside the company — the thing everyone repeats? Where did that claim originate, and was it ever validated?"

### C. Data access
7. "Which of these do we have, and who owns access: Gong/Chorus, Zendesk/Intercom, Amplitude/Mixpanel/GA4, Segment/CDP, Clearbit/ZoomInfo/Apollo, Salesforce/HubSpot pipeline, NPS history?"
8. "Is there an event schema doc for our product analytics, and is user identity wired through signup → paid → churn?"
9. "Is closed-lost-reason a mandatory dropdown in the CRM, or free text? Same question for churn reason in CS tooling."

### D. Business context
10. "What's the current top-line outcome metric the team is driving toward? (Personas should ladder up to a desired outcome — per Teresa Torres.)"
11. "Which competitors do we most frequently lose to, and why — stated reason vs. your gut read?"
12. "Where are we acquiring customers right now — and is that channel mix driving a different persona than our 'target' persona?"

### E. Known unknowns &amp; conviction
13. "What do you believe about our users that you **can't** point to direct evidence for?" (Surfaces proto-persona assumptions to validate.)
14. "Which of the personas or segments we've discussed do you have the **least** confidence in, and what would change your mind?"
15. "If you could put one question in front of 100 current customers this week, what would it be?" (Reveals the highest-priority open question and seeds screener design.)

---

## Access and permissions — what to actually request

- **Read-only database exports** to CSV/Parquet — not BI dashboards, which filter.
- **Full transcript access** to conversation-intelligence tools (Gong/Chorus), not just clip highlights.
- **Raw survey responses** with respondent ID, not aggregated score.
- **Event-level analytics export** — you need to re-cluster, not just view saved cohorts.
- **CRM field schema** + closed-lost reasons + custom fields.
- **Support ticket dumps** in full text, with metadata, for last 6 months minimum.

## Common PM failure modes to expect

- **"We don't really have personas."** They have 3 conflicting sets across product, marketing, and sales. Ask each team separately.
- **"All our customers are basically the same."** Almost never true. Push with "which accounts are churning and which are expanding?"
- **"Sales can tell you."** Sales know buyers, not users. You need both sources.
- **"The data is a mess."** Often true. Ask for raw exports anyway — messy data beats no data.
- **"We're too early for personas."** Not a reason to skip; this is when proto-personas are exactly right. See `overview.md#types-of-personas`.

## Output of intake

Leave the PM meeting with:

- [ ] A **list of every artifact** the company owns, with an owner name for each.
- [ ] **Access granted or requested** for each, with target dates.
- [ ] A **decision stake statement** — what these personas will inform.
- [ ] An **initial mode pick** — proto / qualitative / statistical, with rationale.
- [ ] A **known-unknown list** — everything the PM couldn't answer. These become research questions.
- [ ] An **assumption list** — things the PM believes without evidence. These become hypotheses to validate.

Downstream: with qualitative data already in hand, go to `synthesis.md`. With gaps to fill, branch to `primary_research.md` (fresh interviews) and/or `secondary_research.md` (public-source mining).
