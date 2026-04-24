# Persona Research

Reference material for an agent doing persona research end-to-end. The agent's two primary modes are (a) interviewing a Product Manager to pull existing sources and data, and (b) doing its own desk / online research when primary data is thin or missing.

## When to read what

| Doing...                                                  | Read                                   |
|-----------------------------------------------------------|----------------------------------------|
| Orienting — what a persona is, which type to build        | `overview.md`                          |
| Preparing to interview the PM                             | `pm_intake.md`                         |
| Planning or summarizing fresh user interviews             | `primary_research.md`                  |
| Mining public sources: Reddit, G2, HN, LinkedIn, etc.     | `secondary_research.md`                |
| Framing around Jobs-to-Be-Done instead of / beside personas | `jtbd.md`                            |
| Deciding which fields the persona should contain          | `templates.md`                         |
| Turning raw data into a finished persona                  | `synthesis.md`                         |
| Sanity-checking for anti-patterns and bias                | `pitfalls.md` (read before shipping)   |

## Agent workflow (canonical order)

1. **Orient** — read `overview.md`, decide which persona *type* fits (proto, qualitative, statistical, JTBD-first).
2. **Intake** — use `pm_intake.md` to run the PM conversation. Get access to every existing artifact before doing new work.
3. **Mode branch:**
   - Qualitative data already exists or interviews are feasible → plan fresh research using `primary_research.md`.
   - Interviews are blocked / budget-limited → mine public sources using `secondary_research.md`.
   - In practice: usually some of both.
4. **Framework decision** — if the domain is switching-heavy (new category, competitor replacement, episodic purchase), add `jtbd.md` as the primary lens.
5. **Synthesize** — use `synthesis.md` to go from raw transcripts / quotes / analytics → clusters → draft personas.
6. **Format** — shape the output per `templates.md`. One primary, 1–3 secondary, optional anti-persona. Every claim cites evidence.
7. **Pressure-test** — walk the draft through `pitfalls.md`. If any anti-pattern fits, iterate.

## Guardrails (apply throughout)

- **Triangulate.** No claim goes in the persona unless ≥3 independent sources support it. One interview, one review, one analytics cohort beats three interviews from the same team.
- **Verbatim wins.** Save exact quotes with URL / date / speaker context. Paraphrase destroys signal.
- **Evidence footer.** Every persona has a footer listing which interviews, review URLs, and analytics cohorts back it.
- **Disconfirm.** For every hypothesis, actively search for counter-evidence before locking. See `pitfalls.md#confirmation-bias`.
- **Sample size realism.** 5–30 interviews is the sweet spot for qualitative personas. Fewer than 5 per segment = hypothesis, not persona. See `primary_research.md#sample-size`.
- **Personas ≠ segments.** Analytics produce segments; personas add attitude/goal/motivation. See `overview.md#persona-vs-adjacent-constructs`.
- **ICP ≠ persona.** In B2B, the Ideal Customer Profile describes the company; personas describe the humans in the buying committee. Build both.
- **Decision-useful or cut it.** If a persona field wouldn't change a product decision, remove it (NN/g rule).

## Source index

Every file lists its primary sources at the top. The load-bearing references across the set:

- Nielsen Norman Group — https://www.nngroup.com/articles/persona/ and the full persona article series
- Alan Cooper — *The Inmates Are Running the Asylum*, *About Face*, and https://mralancooper.medium.com/defending-personas-2657fe26dd0f
- Kim Goodwin — *Designing for the Digital Age*, Chapter 11
- Jeff Gothelf — *Lean UX*, proto-persona methodology, https://jeffgothelf.com/blog/using-personas-for-executive-alignment/
- Clayton Christensen — https://hbr.org/2016/09/know-your-customers-jobs-to-be-done
- Tony Ulwick / Strategyn — https://strategyn.com/jobs-to-be-done/
- Bob Moesta &amp; Chris Spiek — *The JTBD Handbook*, Switch Interview methodology
- Teresa Torres — *Continuous Discovery Habits*, https://www.producttalk.org/
- Steve Portigal — *Interviewing Users* (2nd ed.)
- Rob Fitzpatrick — *The Mom Test*, https://www.momtestbook.com
- Erika Hall — *Just Enough Research*
- Indi Young — *Mental Models*, *Practical Empathy*, *Time to Listen*
- Joanna Wiebe — https://copyhackers.com review-mining methodology
- Strategyzer — Value Proposition Canvas
- Jared Spool — https://articles.uie.com/persona_value_suck/
- Chapman &amp; Milham — "The Personas' New Clothes," HFES 2006
