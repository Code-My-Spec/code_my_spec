# Jobs-to-be-Done (JTBD)

The strongest complement (or, some practitioners argue, replacement) for personas. Where personas ask *who*, JTBD asks *what progress they're trying to make in this situation*. Use when the product lives in a switching-heavy market (new category entry, competitor replacement, episodic purchase).

## Sources
- Clayton Christensen, "Know Your Customers' Jobs to Be Done," HBR Sept 2016 — https://hbr.org/2016/09/know-your-customers-jobs-to-be-done
- HBS Working Knowledge, Christensen Milkshake — https://www.library.hbs.edu/working-knowledge/clay-christensens-milkshake-marketing
- Tony Ulwick / Strategyn — https://strategyn.com/jobs-to-be-done/ and https://anthonyulwick.com/outcome-driven-innovation/
- Wikipedia, Outcome-Driven Innovation — https://en.wikipedia.org/wiki/Outcome-Driven_Innovation
- Bob Moesta &amp; Chris Spiek — *The Jobs-to-be-Done Handbook*
- ReWired Group — https://therewiredgroup.com/learn/complete-guide-jobs-to-be-done/
- Jobs-to-be-Done Radio, Four Forces — https://jobstobedone.org/radio/unpacking-the-progress-making-forces-diagram/
- Intercom on Job Stories — https://www.intercom.com/blog/using-job-stories-design-features-ui-ux/ and https://www.intercom.com/blog/accidentally-invented-job-stories/
- Strategyzer Value Proposition Canvas — https://www.strategyzer.com/library/the-value-proposition-canvas
- Alan Klement — https://medium.com/down-the-rabbit-hole/replacing-personas-with-characters-aa72d3cf6c69

---

## Core idea

Christensen: **"People don't buy products — they hire products to do jobs."**

The canonical story: McDonald's tried to improve milkshake sales via demographic interviews. No impact. When researchers asked "when you didn't hire a milkshake, what did you hire?", they found two distinct jobs:
- Morning commuter wanted something filling, slow to consume, one-handed, for a boring drive — competitors were bagels, bananas, Snickers.
- Afternoon parent wanted to placate a child briefly — competitors were small toys, treats.

Different jobs → different competitive sets → different product improvements. Demographics missed all of it.

## Job statement formats

Four canonical formats. Pick one per project and stay consistent.

| Format                 | Author           | Structure                                                   |
|------------------------|------------------|-------------------------------------------------------------|
| **Job statement**      | Ulwick           | `When [situation], I want to [task]`                        |
| **Full job story**     | Intercom / Klement | `When [situation], I want to [motivation], so I can [outcome]` |
| **Outcome statement**  | Ulwick           | `[direction] the [metric] it takes to [object] [context]`   |
| **Colloquial job**     | Christensen      | "Hire [X] to do [Y] in [situation]"                         |

### Examples

**Christensen-style (milkshake):**
> "When I'm driving to work with a long, boring commute and one free hand, I want something I can consume slowly that fills me up, so I can stay occupied and not be hungry by mid-morning."

**Intercom-style job story (SaaS):**
> "When I'm reviewing a Slack thread with 80+ replies, I want to generate a one-paragraph summary, so I can decide whether I need to read the thread or can just respond to the gist."

**Ulwick outcome statement (automotive):**
> "Minimize the time it takes to determine when to change the oil in a car."

A single job can have 50+ associated desired outcomes (Ulwick). Outcomes give you a survey instrument to prioritize (importance × satisfaction).

## Four Forces of Progress

The core mental model from Moesta &amp; Spiek. A switch only happens when progress-forces overcome status-quo-forces:

```
  Push of old   →  [SWITCH]  ←   Habit of old
  Pull of new   →            ←   Anxiety of new
```

- **Push of the situation** — frustration with current state. "I keep losing the handoff."
- **Pull of the new solution** — attraction, desired outcome. "If I had this, my CFO would stop asking."
- **Anxiety of the new** — fears about switching. "What if the migration breaks production?"
- **Habit of the present** — inertia, sunk cost, familiarity. "We've always done it in Excel."

Rule: **Switch happens only when (Push + Pull) > (Anxiety + Habit).** If your product is being ignored, the problem is usually anxiety/habit, not pull.

## The Switch Interview (Moesta / Spiek)

When the question is "why do people switch?" — this is the interview method. See also `primary_research.md#interview-structure-options`.

**Target:** ~10 recent buyers of your product or a direct competitor.

**Walk them back** through the timeline from first thought to ongoing use:

| Stage              | What you're probing for                                |
|--------------------|--------------------------------------------------------|
| 1. First thought   | The inciting moment. What happened that day?           |
| 2. Passive looking | Casual noticing, vague discomfort, lurking in forums   |
| 3. Active looking  | Google, demos, peers, shortlist                        |
| 4. Deciding        | Objections, stakeholders, pricing conversation         |
| 5. Onboarding      | Anxiety peaks here. What almost made them bail?        |
| 6. Ongoing use     | What habit formed. Did the pull hold? New frustrations.|

Listen for the four forces in each stage. Capture verbatim.

## Value Proposition Canvas (Strategyzer)

Osterwalder's VPC operationalizes JTBD at the segment level. Two sides:

**Customer profile (right, circle):**
- **Jobs** — functional, social, emotional
- **Pains** — negatives, risks, obstacles, unwanted outcomes
- **Gains** — required / expected / desired / unexpected outcomes. Gains are **not** simply the opposite of pains.

**Value map (left, square):**
- **Products &amp; Services**
- **Pain Relievers**
- **Gain Creators**

Rule: **always start with the customer side.** The canvas is designed to expose misfit before you've invested in a solution.

### Functional / social / emotional jobs

- **Functional** — concrete tasks ("reconcile attribution data")
- **Social** — how they want to be perceived ("look competent in the QBR")
- **Emotional** — internal state ("stop dreading Monday mornings")

Functional jobs are most visible; **social and emotional jobs are often the differentiators** that explain why people don't switch on functional merits alone.

## How JTBD complements personas

Three camps. The agent should pick one intentionally.

| Camp              | Position                                                     | Who                         |
|-------------------|--------------------------------------------------------------|------------------------------|
| **Complement**    | Persona (who) + primary job (what progress) per persona      | Intercom, Pichler, most PMs |
| **JTBD-first**    | Start with jobs; personas optional and downstream            | Christensen Institute       |
| **Replace**       | Kill personas entirely; use "characters" or outcome segments | Klement, Ulwick             |

**Default recommendation:** complement. Build personas, then assign each a **primary job-to-be-done** and a brief **four-forces map** covering their switching context.

The pairing is load-bearing in the persona deliverable — see `templates.md#full-persona-layout`.

## When JTBD is stronger than personas alone

- **New category entry.** You're not sure who the user is yet, but the progress they're trying to make is clear.
- **Episodic / one-time purchases.** Wedding planning, refinancing, first-time hire. The "persona" varies less than the situation.
- **High-switch categories.** Productivity tools, payroll, CRM — the interesting question is "why did they leave the last one?"
- **Enterprise B2B with committee buying.** Multiple roles share a single job ("close the quarter cleanly").

## When personas are stronger than JTBD alone

- **Design and UX decisions.** You need a specific, named, behaviorally-consistent user to constrain decisions.
- **Content / voice / messaging.** Vocabulary, tone, media diet require a human, not just a job.
- **Onboarding, education, support.** Progression and capability depend on who the user is, not just what they're trying to do.
- **Team alignment / shared language.** Personas are memorable; raw jobs are not.

## Ulwick's critique (for calibration)

Ulwick explicitly attacks persona-based segmentation: "Demographic, psychographic, and behavioral attitudinal data will nearly always fail to explain why customers have different unmet needs." His prescription: segment by **desired outcomes**, not by who the customer is.

Useful even if you don't buy the replacement argument: build outcome statements anyway, and see whether the outcomes cluster by persona or cut across them. If outcomes cut across personas, your personas may be over-segmented.

## Klement's alternative ("Characters")

Klement proposes replacing personas with **Characters** — role-based representations tied to jobs/contexts, not demographic attributes. "Characters persist throughout a product's lifecycle as places where solutions fit into."

In practice, Characters look a lot like Cooper's persona *roles* stripped of biographical decoration. Useful lens when a persona feels like it's becoming a stereotype: strip the demographics and see if what remains (job, context, role) is still distinct.

## Operating procedure — adding JTBD to a persona project

1. **Pick the format** (Ulwick job statement, Intercom job story, Christensen colloquial). Stay consistent.
2. **Extract jobs from interview transcripts / reviews** — flag every verbatim "when I'm… I want to… so I can…" or "we hired this to…"
3. **Cluster jobs** independently of personas. You may find a job shared across personas (same problem, different people) or multiple jobs per persona (same person, multiple modes).
4. **Assign each persona a primary job.** Write it in the persona page with evidence.
5. **Build a four-forces map** for each primary job: Push / Pull / Anxiety / Habit, populated from Switch Interview content or secondary-research VoC.
6. **Add a Value Proposition Canvas** if the GTM team will use it — jobs / pains / gains on the customer side, products / pain relievers / gain creators on the value side.

Deliverable fits into the persona one-pager; see `templates.md`.
