# Persona Research — Overview

## Sources
- Nielsen Norman Group — https://www.nngroup.com/articles/persona/
- NN/g, 3 Persona Types — https://www.nngroup.com/articles/persona-types/
- NN/g, Personas vs Archetypes — https://www.nngroup.com/articles/personas-archetypes/
- Alan Cooper, *The Inmates Are Running the Asylum* (1999) / *About Face* (2007)
- Alan Cooper, "Defending Personas" — https://mralancooper.medium.com/defending-personas-2657fe26dd0f
- Kim Goodwin, *Designing for the Digital Age*, Ch. 11 — https://www.oreilly.com/library/view/designing-for-the/9780470229101/ch11.html
- Jeff Gothelf, *Lean UX* — https://jeffgothelf.com/blog/using-personas-for-executive-alignment/
- Steve Mulder &amp; Ziv Yaar, *The User Is Always Right*
- Jared Spool — https://articles.uie.com/persona_value_suck/
- Chapman &amp; Milham, "The Personas' New Clothes" (HFES 2006) — https://journals.sagepub.com/doi/10.1177/154193120605000503
- Lene Nielsen / Interaction Design Foundation — https://ixdf.org/literature/book/the-encyclopedia-of-human-computer-interaction-2nd-ed/personas

---

## What a persona is

> "A fictional, yet realistic, description of a typical or target user of the product... fictional representations and generalizations of a cluster of target users who exhibit similar attitudes, goals, and behaviors in relation to the product."
> — Nielsen Norman Group

> "A composite portrait of an idealized user... a single sheet of paper with name, picture, job description, goals, and often a quote."
> — Alan Cooper, paraphrasing *The Inmates Are Running the Asylum*

Operational rule (NN/g): **personas are made-up people, but should be based on information about real people.**

## Persona vs adjacent constructs

| Construct         | What it is                                                            | Relationship to persona                              |
|-------------------|-----------------------------------------------------------------------|------------------------------------------------------|
| **Archetype**     | Same behavioral cluster, no name/photo/bio                            | Presentational difference only; persona adds empathy |
| **User segment**  | Analytics-driven grouping by behavior/attributes                      | Segments → persona *candidates*; not personas alone  |
| **Audience**      | Marketing-side group you want to reach                                | Broader; persona is a design exemplar within it      |
| **ICP** (B2B)     | Ideal Customer Profile — the **company** (firmographics, tech stack)  | Distinct deliverable. Build ICP first, then personas per role |
| **JTBD**          | The progress a user is trying to make in a situation                  | Complement or replacement (see `jtbd.md`)            |

Key trap: **analytics segments are not personas.** Segments describe behavior; personas add attitude, goal, motivation, and context. A behavioral cohort ("users who opened the dashboard ≥3×/week") is a persona *candidate* pending qualitative validation.

## Types of personas

NN/g and Mulder/Yaar converge on three modes; pick the one whose effort matches the decision stakes.

| Type                         | Data                                                        | Cost          | When to use                                                        |
|------------------------------|-------------------------------------------------------------|---------------|--------------------------------------------------------------------|
| **Proto / Lightweight**      | Team's existing assumptions, no new research                | Hours         | Early-stage, align stakeholders, generate hypotheses to validate  |
| **Qualitative** (default)    | 5–30 user interviews, coded and clustered                   | Weeks         | Most real product work. NN/g's recommended default.                |
| **Statistical / Data-driven**| Large survey + cluster analysis (k-means etc.), enriched qual | Months      | Large user base, enterprise defensibility, investment justification |

**Cooper-school ("research-based") personas** are the classical qualitative mode, formalized with behavioral variables and persona roles. Taught in Goodwin's *Designing for the Digital Age*, Ch. 11. See `synthesis.md#cooper-7-step` for the full process.

**Proto-personas** are explicitly hypotheses. Gothelf: "our best guess as to who is using (or will use) our product, sketched on paper with the entire team contributing — to capture everyone's assumptions." Must be validated with real users before load-bearing decisions depend on them.

## Cooper's persona roles

| Role              | Definition                                                                          |
|-------------------|-------------------------------------------------------------------------------------|
| **Primary**       | The one the interface is designed for. One per interface. Design each interface for a *single* primary persona. |
| **Secondary**     | Additional needs that can be accommodated without harming the primary             |
| **Supplemental**  | Needs already satisfied by the primary design                                     |
| **Customer**      | The buyer, distinct from the user (B2B)                                           |
| **Served**        | Affected by the product but doesn't use it (e.g., the patient vs. the nurse)      |
| **Negative / Anti** | Explicit non-target — "we are *not* designing for this person"                  |

Cooper's axiom: **design each interface for a single, primary persona.** A product may have multiple interfaces with different primaries (email client vs. admin console).

## Goodwin's three goal types

Most persona goals should be **end goals**. The other two only when the product actually touches them.

- **Life goals** — long-term aspirations ("retire by 45"). Rarely useful.
- **Experience goals** — how the user wants to *feel* ("not feel stupid," "have fun").
- **End goals** — concrete outcomes from using the product ("close the sprint by Friday"). Primary persona fodder.

## Marketing vs UX vs Product personas

| Flavor       | Focus                                       | Drives                                  | Lifecycle          |
|--------------|---------------------------------------------|-----------------------------------------|--------------------|
| **Marketing / Buyer** | Who buys, why, objections, channels, media habits | Positioning, messaging, paid channels   | Usually annual     |
| **UX / Design**       | How the user works, task flow, context, behavior | Feature design, IA, usability             | Living, updated continuously |
| **Product** (hybrid)  | Jobs + behavior + business context               | Prioritization and feature design       | Quarterly-ish      |

Important: **don't substitute marketing personas for UX personas.** Marketing personas skew demographic/channel and rarely constrain design decisions. Behavior is what constrains design.

## When personas fail (critiques)

- **Jared Spool.** "Personas should only be built from scenarios. And scenarios should only be built by people who did the research." His study of "dozens of orgs claiming to use personas" found <5% did actual field research; the rest "made up the descriptions from internal guesswork." The failure mode isn't personas; it's fake personas. https://articles.uie.com/persona_value_suck/
- **Chapman &amp; Milham (HFES 2006).** Personas can't be falsified, representation is unknown (how many real users does this persona describe?), and they can harm research decisions politically. https://cnchapman.files.wordpress.com/2007/03/chapman-milham-personas-hfes2006-0139-0330.pdf
- **Indi Young.** Personas conflate *who someone is* with *how they think in a given context*. People occupy different thinking styles by context, not fixed personalities. https://indiyoung.com/method/
- **Alan Klement / Tony Ulwick.** JTBD camp: demographic attributes don't predict consumption; segment by desired outcomes or job context instead. See `jtbd.md`.
- **NN/g.** Typical failure modes: personas created but not used, no leadership buy-in, created in isolation, scope mismatch, team doesn't know how to apply them.

## When a persona is "good"

Criteria synthesized from Cooper, Goodwin, NN/g, Pichler, IxDF:

- **Evidence-backed** — every claim cites an interview, transcript, analytics segment, or survey.
- **Decision-useful** — removing the field would change a design decision. If not, cut it.
- **Falsifiable** — statements about behavior are testable. "Values community" is not; "checks Slack before email every morning" is.
- **Specific** — constrains decisions. If the persona fits any user, it's the *elastic user* (Cooper). Not a persona.
- **Distinct** — differs from other personas on *behavioral* variables, not demographics alone.
- **Memorable** — team refers to it unprompted. Distinct name, tagline, photo.
- **Scoped** — matches the product's domain. Irrelevant hobbies are decoration.
- **Current** — updated in last 6–12 months or after major product/market shift.

Goodwin's rule: **"If every aspect of the description can't be tied back to real data, it's not a persona — it's a creative writing project."**

## How many personas

Consensus across Cooper, NN/g, IxDF: **3–5 total**, of which **1 primary, 1–3 secondary, optional anti-persona**.

- One primary per interface.
- If you need more than 3 primaries, your scope is wrong — split the product.
- More than ~7 total: none are memorable, team won't use them.
- One single "general" persona: you have the elastic user. Not a persona.

## Persona lifecycle

NN/g data on refresh cadence: teams who didn't revise for 5+ years rated satisfaction 3.9/7; those who updated quarterly or more often rated 5.5/7. https://www.nngroup.com/articles/revising-personas/

Refresh triggers:
- Product pivot or major feature expansion
- Competitor category shift
- User-base demographic shift (new geo, new segment)
- Analytics diverging from persona assumptions
- Support ticket patterns changing

Prevent death-by-Confluence: store in a format that's **easy to update** (slide deck, Notion page) and bind personas to live scenarios, not posters. See `pitfalls.md#persona-theater`.
