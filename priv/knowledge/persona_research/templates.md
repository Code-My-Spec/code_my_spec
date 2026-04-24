# Persona Templates and Output Format

Which fields belong in a persona, which are decoration, and what the final deliverable looks like on one page.

## Sources
- NN/g, Personas Make Users Memorable — https://www.nngroup.com/articles/persona/
- Alan Cooper, *About Face 3* — reconstructed via https://www.cs.cmu.edu/~jhm/Readings/cooper_personas.pdf
- Kim Goodwin, *Designing for the Digital Age*, Ch. 11 — https://articles.centercentre.com/research_to_personas/
- Jeff Gothelf, Lean UX proto-persona — https://jeffgothelf.com/blog/using-personas-for-executive-alignment/
- Roman Pichler — https://www.romanpichler.com/blog/persona-template-for-agile-product-management/
- HubSpot buyer persona — https://blog.hubspot.com/marketing/buyer-persona-research
- IxDF, 9 Persona Mistakes — https://ixdf.org/literature/article/9-persona-mistakes
- UX Tools, Fixing User Personas — https://www.uxtools.co/blog/fixing-user-personas

---

## The NN/g rule

> "Each piece of information should have a purpose... if it would not affect the final design or help make any decision easier, remove it."

Apply this to every field below. If removing it wouldn't change a design decision, cut it.

## Template comparison

| Template                     | Primary focus              | Core fields                                          | Fluff risk |
|------------------------------|----------------------------|------------------------------------------------------|------------|
| **Cooper / About Face**      | Design, goal-directed       | Name, photo, narrative, **goals**, behaviors, environment, frustrations, persona type | Low |
| **NN/g**                     | UX design                   | Name, image-with-context, tagline, product-interaction context, goals, concerns | Low |
| **Goodwin (Cooper-school)**  | Design                      | Cooper + life/experience/end goal split + behavioral-variable evidence | Low |
| **Gothelf proto-persona**    | Hypothesis / alignment      | Sketch + name, behaviors &amp; beliefs, demographics, needs/goals; 5-spectrum slider | Medium (sliders decorative) |
| **Pichler (agile PM)**       | Product prioritization      | Identity, details, **one goal** (the problem solved) | Low |
| **HubSpot buyer persona**    | Marketing / sales           | Demographics, job, goals, pain, info sources, channels | High (demographic heavy) |
| **Xtensio / Miro / FigJam**  | Workshop-friendly           | Kitchen sink: demographics, bio, goals, JTBD, pains, gains, tech, channels | High |

## Critical vs decorative fields

### Earn-their-place-almost-always (keep)

- **Name** — memorability aid; team refers to it unprompted.
- **Photo with contextual background** — not a stock headshot. NN/g recommendation: background carries signal (office, kitchen, laptop on lap).
- **Tagline** — "X who needs to do Y." One-sentence anchor.
- **Persona type** — primary / secondary / anti. Explicit.
- **Goals** — end, experience, life (Goodwin). Most persona goals are **end goals**.
- **Behaviors** — observable actions, key workflow steps relevant to the product.
- **Context of use** — environment, device, frequency, by choice vs forced.
- **Frustrations / pain points** — what blocks them; workarounds they use.
- **Primary job-to-be-done** — see `jtbd.md`. Pairs with the persona; one sentence.
- **Evidence footer** — which interviews / reviews / analytics cohorts back this.

### Decorative / often cut

- **Favorite brands, hobbies, personality sliders** — unless they demonstrably affect a design decision.
- **Quote bubbles not traceable to a real interview** — manufactured quotes are anti-signal.
- **Exhaustive demographics** beyond what affects the product.
- **Decorative stock photography** — if the photo is a headshot with no context, it's failing its job.
- **"Tech savviness 8/10" style sliders** — imported from Gothelf proto-personas; rarely constrain downstream decisions unless rigorously sourced.

## Anti-patterns to avoid in templates

- **Demographic-heavy, behavior-light.** Demographics don't predict behavior. A persona full of age/income/location and no workflow is a segment, not a persona.
- **Marketing persona masquerading as UX persona.** Marketing personas drive channels and messaging; they don't constrain design. Don't substitute. See `overview.md#marketing-vs-ux-vs-product-personas`.
- **Personality sliders without rigor.** If you can't cite which interviews placed the slider at 7, drop it.
- **Static stock-photo posters.** Format-locked deliverables don't get updated. Use Notion / slides / FigJam, not Photoshop.
- **Manufactured quote bubbles.** If the quote isn't from a real transcript (with interview ID in evidence footer), cut it.

## Full persona layout (one-page)

```
┌──────────────────────────────────────────────────────────┐
│ NAME + PHOTO (contextual background, not studio)         │
│ Tagline: "[Role] who needs to [core job]"                │
│ Persona type: Primary / Secondary / Anti                 │
├──────────────────────────────────────────────────────────┤
│ CONTEXT                    │ GOALS                       │
│ Role, company size, env,   │ End goals (concrete outcomes)│
│ device, frequency,         │ Experience goals (how they  │
│ by-choice / forced,        │   want to feel)             │
│ tech stack                 │ Life goals (rare; only if    │
│                            │   product touches them)     │
├──────────────────────────────────────────────────────────┤
│ BEHAVIORS                  │ FRUSTRATIONS / PAINS         │
│ Observable actions, key    │ What blocks them             │
│ workflow steps, what they  │ Workarounds they use         │
│ use today                  │ Trigger moments              │
├──────────────────────────────────────────────────────────┤
│ PRIMARY JOB-TO-BE-DONE                                   │
│ "When ___, I want to ___, so I can ___"                  │
├──────────────────────────────────────────────────────────┤
│ FOUR FORCES (optional; see jtbd.md)                      │
│ Push: ...   Pull: ...   Anxiety: ...   Habit: ...        │
├──────────────────────────────────────────────────────────┤
│ REPRESENTATIVE QUOTE                                     │
│ (verbatim from interview, with interview ID)             │
├──────────────────────────────────────────────────────────┤
│ EVIDENCE FOOTER                                          │
│ Based on: P03, P07, P11, P14                             │
│ Cohort: "weekly-dashboard-rebuilders" (n=47, Sept 2025)  │
│ Reviews: [G2-url], [capterra-url]                        │
│ Anti-persona callout: "We are NOT designing for ..."     │
└──────────────────────────────────────────────────────────┘
```

## Worked example (composite, B2B SaaS)

**Maria Chen** · Senior Digital Marketing Manager at a 200-person B2B SaaS company · **Primary**

> "Reconciles campaign attribution across 3 tools every Monday to defend her budget."

- **Context:** Marketo + HubSpot + LinkedIn Ads daily. Reports up to CMO. Reviewed quarterly on pipeline sourced.
- **End goal:** Defensible campaign attribution by channel before the QBR.
- **Experience goal:** Walk into Monday standup without dread.
- **Behavior:** Every Monday, 8–10am, exports CSVs from three tools and stitches in Google Sheets. Has tried 2 attribution vendors; both required engineering time she didn't get.
- **Frustration:** "Every tool claims to integrate but the data never reconciles, so I rebuild the spreadsheet."
- **Primary JTBD:** "When I'm preparing for a QBR and the CFO asks which channel drove pipeline, I want a reconciled attribution view across paid, organic, and events, so I can defend my budget without manually stitching CSVs the night before."
- **Four Forces:** Push (3hr Monday rebuild) · Pull (CFO-ready dashboard) · Anxiety (previous vendor required 2 weeks of eng time) · Habit (Sheet template works, "it's ugly but it's mine")
- **Representative quote:** *"I've stopped trusting the dashboards. I just rebuild it myself."* (Interview P07, 2025-11-14)
- **Evidence:** Interviews P02, P05, P09, P14 · HubSpot cohort `weekly-dashboard-rebuilders` (n=47) · G2 reviews on [Tool X] tagged "integration pain"
- **We are explicitly NOT designing for:** Enterprise CMOs who delegate attribution to a dedicated analytics team. See anti-persona `ops-director-delegates`.

## Deliverable set

For a typical persona project:

- **1 primary persona** (detailed, one page)
- **1–3 secondary personas** (same template, equal depth)
- **0–1 anti-persona** (explicitly who the product is NOT for, with reasoning)
- **Anti-persona callouts** embedded in each primary page
- **Evidence registry** — master index of all interviews, review URLs, analytics queries cited

Never ship one single "general" persona — that's the elastic user (`pitfalls.md#elastic-user`).

## Where to store personas

| Tool                 | Fit                                                        |
|----------------------|------------------------------------------------------------|
| **Confluence**       | Atlassian teams; lives alongside PRDs and sprint plans     |
| **Notion**           | Flexible DB; embed interview audio/transcripts, Figma links |
| **Figma / FigJam**   | Design-led teams; personas sit beside wireframes           |
| **Slides**           | NN/g recommended for ease of update                        |
| **Xtensio**          | Polished stakeholder-facing versions (clients, leadership)  |

Non-negotiable: **one canonical source**, linked from everywhere (PRDs, user stories, Jira epics). If the persona lives in three places, two are stale.

**Avoid:** locked-PNG posters, Photoshop files, anything the team can't edit. Update-friendliness is a quality criterion (`overview.md#persona-lifecycle`).

## Scenarios — the load-bearing companion

Spool's position: **personas exist to support scenarios.** A persona without scenarios is theater.

For each persona, produce at least one detailed scenario:

```
Scenario: Maria ships the Q3 pipeline attribution report
1. Monday 8am — opens laptop, loads dashboard, sees the familiar mismatch.
2. Exports CSVs from HubSpot, Marketo, LinkedIn Ads.
3. Pastes into her template, runs pivot tables, joins on campaign UTM.
4. Notices LinkedIn Ads data is off by 11% vs last week. Slack to RevOps.
5. Waits 45 min for response. Works on deck while waiting.
6. Gets confirmation tracking URL was wrong in one campaign. Fixes. Re-pulls.
7. Exports final table as image, drops into QBR deck. Closes laptop, 10:45am.
```

Scenarios are what actually drive feature decisions; the persona is how you remember whose scenario it is.
