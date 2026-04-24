# Primary Research — Fresh User Interviews

How to plan, run, and capture interviews when the agent needs new data (either the PM has none, or existing data has gaps from intake). Interview content feeds `synthesis.md`.

## Sources
- NN/g, Personas article — https://www.nngroup.com/articles/persona/
- NN/g, Why You Only Need to Test with 5 Users — https://www.nngroup.com/articles/why-you-only-need-to-test-with-5-users/
- NN/g, How Many Test Users — https://www.nngroup.com/articles/how-many-test-users/
- NN/g, Screening Questions — https://www.nngroup.com/articles/screening-questions-select-research-participants/
- Teresa Torres, Product Talk — https://www.producttalk.org/ and *Continuous Discovery Habits*
- Teresa Torres, Opportunity Solution Trees — https://www.producttalk.org/opportunity-solution-trees/
- Steve Portigal, *Interviewing Users* (2nd ed.) — https://rosenfeldmedia.com/books/interviewing-users-second-edition/
- Rob Fitzpatrick, *The Mom Test* — https://www.momtestbook.com
- Erika Hall, *Just Enough Research*
- Indi Young — https://indiyoung.com/method/
- Adele Revella, 5 Rings of Buying Insight — https://buyerpersona.com/leadership
- GV Design Sprint Research — https://library.gv.com/the-gv-research-sprint-interview-participants-and-summarize-findings-day-4-3d34792baa3f
- Guest, Bunce &amp; Johnson (2006), saturation research — https://journals.sagepub.com/doi/10.1177/1525822X05279903
- Bob Moesta &amp; Chris Spiek, Switch Interview — see `jtbd.md`

---

## Sample size

One of the most-misquoted rules in UX. Be precise:

| Study type                           | Target sample                                          | Source                               |
|--------------------------------------|--------------------------------------------------------|--------------------------------------|
| Qualitative usability (find problems) | **5 per user group**; catches ~85% at p=0.31            | NN/g, Why You Only Need 5            |
| Multiple distinct user groups        | **3 per group** across 3–5 segments → 9–15 total       | NN/g, How Many Test Users            |
| Persona discovery (qualitative)      | **5–30 interviews**, rolling sample of 5 until saturation | NN/g, Personas article             |
| Code saturation (themes emerge)      | **9–17 interviews**                                    | Guest &amp; Bunce 2006, PLOS One      |
| Meaning saturation (deep understanding) | **16–24 interviews**                                 | Guest &amp; Bunce 2006                |
| Griffin &amp; Hauser benchmark         | **20–30 interviews** uncover 90–95% of customer needs | Marketing research canon             |
| Continuous discovery                 | **Weekly / bi-weekly** ongoing, no bounded study        | Teresa Torres                        |

**Practical defaults:**
- Small effort, directional: **5 per persona candidate**, so 15–20 total across 3–4 candidates.
- Standard rigor: **15–20 total** with rolling review, stopping at saturation.
- High-stakes: **25+**, add survey validation (see `pitfalls.md#sample-size-mistakes`).
- Fewer than 5 per segment = hypothesis, not persona.

**Quant vs qual**: 5 is fine for qualitative discovery, **wrong for quantitative claims**. Don't say "most users" after 5 interviews.

## Screener design

The screener exists to get **the right person in the room** — not to collect data. Never reuse screener answers as interview data; respondents give "ideal" answers there.

NN/g rules:
- Focus on **behaviors, contexts, motivations, and attitudes** of the target user — not just demographics.
- Keep it short. Long screeners → dropoff.
- Screen for **recent actual behavior**, not hypothetical intent ("In the last 30 days, have you…").
- Disqualify known-bad profiles explicitly (competitors, friends-of-team, professional respondents).

Teresa Torres' rule: *only interview people who have actually done the target behavior recently, not hypothetically*. See https://www.producttalk.org/2016/02/why-you-are-probably-interviewing-the-wrong-people-and-how-to-fix-it/

Checklist:
- [ ] 1 behavioral qualifier (did X in last Y days)
- [ ] 1 role / context qualifier
- [ ] 1 disqualifier (not a competitor, not in research-for-hire pool)
- [ ] Demographic info last, minimal

## Interview structure options

Different methods fit different goals. Pick one explicitly; don't mix.

### Portigal's structured interview (discovery)
Steve Portigal, *Interviewing Users* (2nd ed.). Default structure:
1. Friendly welcome + permission to record.
2. Warm-up: broad, low-stakes context questions.
3. Body: progressively deeper, moving from broad to specific.
4. Tools in the body: **comparisons, specific examples, projections, childhood influences, exceptions**.
5. Wrap: anything we missed, what should I have asked.

Portigal's rule: **let silences happen**. People keep talking when you don't rush in.

### GV 5-Act Interview (design sprint)
Michael Margolis, GV Library. Used inside design sprints.
1. Friendly welcome + recording consent.
2. Context questions (life, role, domain).
3. Introduce prototype / concept.
4. Detailed task walkthrough.
5. Debrief.

Team watches via remote feed and takes structured notes so the interviewer can focus. Debrief all 5 interviews same-day to lock patterns while fresh.

### Teresa Torres — story-based interviews
Torres, *Continuous Discovery Habits*. Key moves:
- **Ask for specific past stories**, never generalizations. "Tell me about the last time you…"
- Use **Interview Snapshots** to capture each interview in a standard template.
- Feed snapshots into an **Opportunity Solution Tree** — opportunities (customer needs/pains/desires) map up to a desired outcome and down to solutions.
- Cadence: **weekly or bi-weekly**, not bounded studies. "The biggest barrier to interviewing every week is recruiting." Automate it.

### Indi Young — listening sessions
https://indiyoung.com/method/. Distinct from standard interviews.
- **One germinal question** ("what went through your mind as you were doing X?"). No question list.
- Remote audio-only to build trust.
- Output: transcripts combed for **atomic tasks, inner reasoning, and thinking styles**.
- Skips "opinion, preference, generalizations, explanations" in favor of inner voice.

Use when the product lives in an ambiguous or novel problem space where standard interviews would prematurely collapse to surface answers.

### JTBD Switch Interview (Moesta &amp; Spiek)
When the question is "why do people switch?" — see `jtbd.md` for full detail. Six-stage timeline walkback around a specific purchase decision.

### Adele Revella — 5 Rings of Buying Insight (B2B)
For B2B buyer personas. Every interview pins down:
1. **Priority Initiative** — the trigger moment ("take me back to the moment you said, we've got to spend money to solve this").
2. **Success Factors** — what results they expect.
3. **Perceived Barriers** — what worries them about your solution.
4. **Decision Criteria** — what attributes of each option they evaluate.
5. **Buyer's Journey** — steps, stakeholders, information sources.

---

## Question discipline

### The Mom Test (Rob Fitzpatrick)
Three rules. Follow them always.
1. **Talk about their life**, not your idea.
2. **Ask about specifics in the past**, not opinions about the future.
3. **Talk less, listen more.**

Anti-questions (don't ask):
- "Would you buy this?" / "Would you use this?"
- "Do you think this is a good idea?"
- "What features would you want?"

Replacements:
- "How do you solve this today?"
- "How much did you pay last time you tried to solve this?"
- "Walk me through the last time you had this problem."

### Question shape guide

| Goal                     | Use                                   | Avoid                              |
|--------------------------|---------------------------------------|------------------------------------|
| Understand behavior      | Past-tense specifics                   | Future/hypothetical                |
| Understand motivation    | "Why" after a concrete story           | "Why" on an abstraction            |
| Understand context       | "Walk me through…"                     | "Tell me about your workflow"      |
| Understand pain          | "What did you do when that happened?"  | "How frustrating was that?"        |
| Understand trigger       | "When did you start looking for a new X?" | "What made you pick us?"         |

Erika Hall: direct questions get guarded answers. Use open-ended + active listening.

### Leading-question traps
- "Don't you think X is a problem?" (loaded)
- "Most people do X — do you?" (social proof anchor)
- "This must be really frustrating, right?" (affirmation bait)
- "Would it be better if…" (solution-space)

Neutralizers: "What happened next?" · "Tell me more." · silence.

---

## Capture for synthesis

Record everything (with consent): Grain, Otter, Rev, Fathom, Gong.

Produce for each interview:
- **Recording + transcript** (verbatim)
- **One-page interview snapshot** (Torres-style): who, context, 3–5 most-surprising quotes, behavioral variables observed, candidate opportunities
- **Quote bank** with timestamps, tagged by theme

Synthesis mechanics live in `synthesis.md`. Briefly: quotes → sticky-note affinity map → clusters → behavioral variable map → personas.

## Recruiting

Cheapest-to-most-expensive:
1. **Existing users** via in-product intercepts (Hotjar, Sprig, Pendo) or support ticket followups.
2. **Lapsed / churned users** via CS list export — often the highest-signal conversations.
3. **Waitlist / lead list** for pre-launch.
4. **User Interviews, Respondent.io, Ethnio** — paid panels, fast, but screener hygiene matters.
5. **LinkedIn outreach / Sales Navigator** for B2B.
6. **Clearbit / Apollo / ZoomInfo** lookups + cold outreach for specific roles.

Torres on the recruiting bottleneck: **automate it**. Continuous interviewing lives or dies by how cheap it is to get the next person in the chair.

## Ethics and consent

- Record only with explicit consent. Pay respondents for their time (standard: $50–$150 for 30–60 minutes in B2B; lower for consumer).
- Don't deceive about the purpose of the conversation.
- Anonymize quotes in the persona deliverable (role + company size, not name + company).
- If interviewing in regulated industries (health, finance, children), apply the domain's additional rules.

## When NOT to interview

- The decision is low-stakes or reversible and time cost exceeds decision value.
- Existing qualitative data is already sufficient (intake already answered the question).
- Fundamental questions are market-sizing, not behavioral — use analytics / secondary research instead.
- The product is so novel that no one has relevant past behavior. Shift to listening sessions or observational methods.
