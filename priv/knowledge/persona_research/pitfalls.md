# Pitfalls — Anti-Patterns and Quality Checks

Common ways persona projects go wrong. Read before shipping a draft; read again when a persona feels off.

## Sources
- Alan Cooper, "Defending Personas" — https://mralancooper.medium.com/defending-personas-2657fe26dd0f
- Jared Spool, "5 Ways to Suck Value Away from Your Persona Projects" — https://articles.uie.com/persona_value_suck/
- Chapman &amp; Milham, "The Personas' New Clothes" (HFES 2006) — https://cnchapman.files.wordpress.com/2007/03/chapman-milham-personas-hfes2006-0139-0330.pdf
- NN/g, Why Personas Fail — https://www.nngroup.com/articles/why-personas-fail/
- NN/g, Are Your Personas Outdated? — https://www.nngroup.com/articles/revising-personas/
- NN/g, Confirmation Bias in UX — https://www.nngroup.com/articles/confirmation-bias-ux/
- IxDF, 9 Persona Mistakes — https://ixdf.org/literature/article/9-persona-mistakes
- Indi Young — https://indiyoung.com/method/

---

## Anti-pattern catalog

### Elastic user {#elastic-user}
Cooper's original anti-pattern. When "the user" is a shape-shifting abstraction that every stakeholder redefines to justify their preferred decision. The persona becomes equally elastic: "Maria uses this and also does that and also needs something else" — she fits every feature, so she constrains no feature.

**Detection:** can you write a feature the persona would *reject*? If no, you have the elastic user.

**Fix:** add specificity. The persona should constrain decisions; if it doesn't, it's not doing its job. Pair with an anti-persona to sharpen the primary.

### Assumption-based personas
Created from team guesswork, never validated with real users. Spool: <5% of orgs in his study actually did field research; the rest "made up the descriptions from internal guesswork."

**Fix:** either do the research, or explicitly label proto-personas as hypotheses with a validation plan (`overview.md#types-of-personas`).

### Demographic-heavy, behavior-light
Persona is mostly age, gender, location, income. Demographics don't predict behavior. A user who "36-year-old, urban, $80k income" is indistinguishable from millions of other people with nothing in common.

**Fix:** replace demographic fields with behavioral variables from Cooper's categories (activities, attitudes, aptitudes, motivations, skills). If you can't articulate a behavioral claim, cut the demographic.

### Stereotype risk
Personas encode clichés: the single mother, the tech-savvy millennial, the overworked dad. Reinforces bias and produces fragile designs.

**Fix:** every persona attribute should be evidence-linked. If a field sounds like a stereotype and you can't cite 3 interviews that support it, remove it.

### Marketing persona contamination
Marketing/buyer personas (channels, objections, purchase intent) imported into UX work. These don't constrain design decisions because they don't describe workflow or behavior during use.

**Fix:** separate them. Marketing personas drive channels and messaging; UX personas drive feature and workflow design. Run both; don't substitute.

### Too many personas
10+ archetypes, none memorable. Team can't recall them. No prioritization.

**Fix:** prune to 3–5. If merging two personas wouldn't change a design decision, merge them. One primary; rest are secondary with clear reasoning.

### Too few / one-general persona
A single persona representing "our user." This is the elastic user (above) in disguise.

**Fix:** split. There are always distinctions; the question is which are decision-useful.

### Stale personas {#stale-personas}
Created once, never revised. NN/g data: teams that didn't update in 5+ years rated personas 3.9/7 for usefulness; teams updating quarterly or more rated 5.5/7.

**Fix:** refresh cadence. Quarterly check-in; full review annually or on major product/market shift. Store in an updatable format (Notion, slides), not locked PNG.

### Persona theater {#persona-theater}
Created, printed, framed on a wall, never referenced in a decision. Deliverable satisfies a checklist item; no downstream impact.

**Detection:** search the team's recent PRDs, sprint reviews, and design critiques for persona names. If zero mentions, it's theater.

**Fix:** bind personas to active decisions. Tag user stories with persona names. Recruit usability participants against persona definitions. Include personas in prioritization scoring.

### No scenarios
Spool: personas exist to support scenarios. A persona without scenarios can't inform feature decisions.

**Fix:** write at least one detailed scenario per primary persona. Scenarios are what actually drive decisions; the persona is how you remember whose scenario it is. See `templates.md#scenarios`.

### Research done by people who don't use the output
Spool: "If you didn't partake in the research, you don't get to play with the scenarios or the personas." Teams who outsource research to a consultant and then import the polished deck lose the tacit knowledge that makes personas useful.

**Fix:** researchers and designers overlap. If the agent is doing the research, the agent owns the synthesis. If a human owns downstream decisions, include them in the research.

### Manufactured quotes
Quote bubbles that sound like the persona but weren't actually said by any interviewee. Anti-signal — manufactured language lacks the specificity of real speech.

**Fix:** every quote cites an interview ID or review URL. If you want a quote and no real one fits, go back to the data; the persona may be over-specified.

### Merging research and synthesis
Writing the persona narrative while transcribing interviews. The narrative gets shaped by the most recent interview, not by patterns across interviews.

**Fix:** separate phases. Collect all data first, then cluster, then narrate. Use Cooper's 7-step method (`synthesis.md#cooper-7-step`) or Braun &amp; Clarke thematic analysis (`synthesis.md#thematic-analysis`).

---

## Research bias catalog

### Confirmation bias {#confirmation-bias}
Collecting evidence that supports a prior thesis; discounting evidence that contradicts it. The single biggest persona-research trap.

**Countermeasure:** for every hypothesis, actively search for counter-evidence before locking it. Run a query like "why [category] is fine as-is" or "people who love [status quo]." If you can't find any counter-evidence, you probably didn't look.

### Vocal minority
Active online posters are a small, attitudinally extreme subset. Treating Reddit top posts as median user voice produces personas shaped by the loudest 1%.

**Countermeasure:** weight by **engagement breadth** (many unique users agreeing) not volume (same user posting repeatedly). Cross-check against quiet sources (support tickets, NPS passives, analytics).

### Survivorship bias
Churned users have left, deleted accounts, or never posted. The visible corpus is current-customer-skewed.

**Countermeasure:** actively seek "why I left" content. Search `"cancelled [product]"`, `"migrated away from"`, `"don't use [category] anymore"`. Interview churned customers specifically (not just current ones).

### Echo chamber / algorithmic filter
Platforms serve you more of what you've engaged with. Your view of the persona is algorithmically curated.

**Countermeasure:** incognito sessions, rotate platforms, read dissenting-view sources deliberately. Cross-check any finding across 3+ independent platforms.

### Platform demographic skew
Reddit = young, male, tech-adjacent, Anglophone. LinkedIn = performative, professional. HN = SV. TikTok = Gen Z.

**Countermeasure:** check whether your ICP actually uses the platform you're mining. If the persona is a 55-year-old small-town insurance agent, HN will mislead you.

### Self-report vs behavior gap
"What people say they'd do and what people actually do are two entirely different things." Surveys and "would you pay?" questions overstate intent.

**Countermeasure:** weight observed behavior (cancelled subs, migration posts, feature adoption) over stated preferences. Never ask hypothetical purchase questions (The Mom Test rule).

### Availability / recency bias
The most recent thread or loudest post dominates the impression.

**Countermeasure:** for canonical signal, sort by all-time; layer recent for drift detection. Don't let a single viral thread overweight the view.

### AI-generated review pollution
Estimated 10–30% of G2/Capterra/TrustRadius reviews are likely AI-generated.

**Countermeasure:** weight reviews with specific, dated, numeric details higher than generic praise. Red flags: generic ROI claims, marketing phrasing, no named team size/industry, clustered posting dates.

### Astroturfing
Especially around product launches. Sudden cluster of new accounts praising or attacking one product.

**Countermeasure:** check account age and posting history before weighting. Brand-new account + polished take = discount heavily.

### Sample-size mistakes {#sample-size-mistakes}
Quoting "we interviewed 5 users" as evidence for a quantitative claim. 5 is enough for qualitative problem discovery; wrong for "most users do X."

**Countermeasure:** match claim to sample. Qualitative claims ("these users struggled with…") fit small samples. Quantitative claims ("67% of users…") need survey-grade sample sizes. See `primary_research.md#sample-size`.

### Leading / loaded questions
"Don't you think X is a problem?" / "This must be frustrating, right?" — plant the answer in the question.

**Countermeasure:** The Mom Test (`primary_research.md#question-discipline`). Ask about past specifics, not future hypotheticals or opinions. "Tell me about the last time…" not "Would you like…"

### Single-source evidence
A persona claim backed by one interview, one review, or one cohort.

**Countermeasure:** triangulation rule — ≥3 independent sources. If only one source supports a claim, flag it as a hypothesis, not a finding.

---

## Quality heuristics (ship checklist)

Before declaring a persona set done, run through these. Each is drawn from Cooper, Goodwin, NN/g, Pichler, IxDF:

- **Evidence-backed** — every claim cites ≥3 independent sources
- **Decision-useful** — every field would change a design decision if removed
- **Falsifiable** — behavioral claims are testable ("opens Slack before email every morning" not "values community")
- **Specific** — persona constrains decisions, doesn't fit everyone (elastic-user check)
- **Distinct** — differs from other personas on behavior, not demographics alone
- **Memorable** — team refers to it unprompted; distinct name + tagline
- **Scoped** — matches the product's domain; no decorative fields
- **Current** — updated in last 6–12 months, or since last major shift
- **Paired with scenarios** — at least one concrete scenario per primary persona
- **Anti-persona present** — explicit who the product is NOT for
- **Mixed-source clusters** — no persona is built from a single source type alone
- **Hypothesis-flagged** — claims that couldn't be triangulated are marked, not shipped as findings

Goodwin's test: "If every aspect of the description can't be tied back to real data, it's not a persona — it's a creative writing project."

---

## When to refresh or retire

**Refresh triggers** (NN/g):
- Product pivot or major feature expansion
- Competitor category shift
- User-base demographic shift (new geo, segment)
- Analytics diverging from persona assumptions
- Support ticket patterns shifting

**Retirement signal:** a persona that no longer maps to observable user behavior in the product, and hasn't in 6+ months, is dead. Retire it explicitly rather than letting it linger.

**Update cadence:** quarterly check-in (tweaks), annual full review (potential restructure).

---

## Quick sanity check before shipping

Three questions. If any answer is weak, iterate.

1. **"What decision does this persona help us make?"** If you can't name one, it's theater.
2. **"What would falsify this persona?"** If nothing, the persona is too vague — elastic user risk.
3. **"Who is explicitly NOT this persona?"** If everyone could be, the persona doesn't constrain. Add anti-persona specificity.
