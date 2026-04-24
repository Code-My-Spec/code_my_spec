# Synthesis — Raw Data → Personas

Turning transcripts, VoC quotes, and analytics cohorts into a finished persona set. This is where most persona projects fail: people collect data, skip synthesis rigor, and ship demographically-colored fiction.

## Sources
- Alan Cooper &amp; Kim Goodwin, Goal-Directed Design — https://articles.centercentre.com/research_to_personas/ and https://www.cooper.com/journal/2002/11/getting_from_research_to_perso
- Kim Goodwin, *Designing for the Digital Age*, Ch. 11
- CMU-hosted Cooper chapter — https://www.cs.cmu.edu/~jhm/Readings/cooper_personas.pdf
- Jiro Kawakita, KJ Method (affinity diagrams) — https://asq.org/quality-resources/affinity
- Interaction Design Foundation, Affinity Diagrams — https://ixdf.org/literature/topics/affinity-diagrams
- Braun &amp; Clarke (2006), thematic analysis — https://link.springer.com/article/10.1007/s11135-021-01182-y
- NN/g, 3 Persona Types — https://www.nngroup.com/articles/persona-types/
- Pipedrive Engineering, cluster analysis personas — https://medium.com/pipedrive-engineering/identifying-behavioral-personas-with-cluster-analysis-86b724ad0365
- MixBright, persona validation methods — https://mixbright.com/buyer-persona-validation-methods/

---

## Overview of the synthesis pipeline

```
Raw inputs                Intermediate artifacts           Output
─────────                 ──────────────────────           ──────
interviews       ┐
reviews          ├─► affinity-mapped quotes  ─┐
analytics cohort │                             ├─► behavioral   ─┐
support tickets  │   thematic codes           │    variable map  ├─► personas
NPS open-text    │                             │                  │
CRM closed-lost  ┘    coded quotes            ┘                  ┘
```

Three parallel streams come together at the **behavioral variable map**. That's the Cooper move: behaviors cluster across multiple variables, and those clusters become personas.

---

## 1. Affinity mapping (KJ method)

Jiro Kawakita, 1960s. The standard synthesis technique for qualitative data.

**Process:**
1. One observation / quote / issue per sticky note. Keep it atomic.
2. Silently cluster notes by natural affinity. (Silent clustering reduces groupthink and speed-of-articulator bias.)
3. Label clusters with theme names.
4. Iterate: merge, split, add second-order groupings.
5. Derive insights, user needs, and behavior patterns from themes.

Co-located: physical wall. Remote: Miro, FigJam, Mural.

**Sources of sticky notes:**
- Interview quotes (one sticky per quote, not per interview)
- Review-mining verbatim (from `secondary_research.md#voc-mining`)
- Support ticket snippets
- NPS "why" open-text
- Analytics observations ("users in Cohort A return weekly, Cohort B bi-weekly")

**Tip:** color-code by source. If a cluster is all from one source type, that cluster is shaped by the source's bias, not by user reality. Look for clusters with **mixed sources** — those are durable.

## 2. Thematic analysis (Braun &amp; Clarke) — when rigor matters

For high-stakes work, upgrade affinity mapping to formal thematic analysis. Six phases:

1. **Familiarization** — repeated reading of all transcripts.
2. **Generating initial codes** — tag every interesting snippet.
3. **Searching for themes** — cluster codes.
4. **Reviewing themes** — check clusters hold across the full dataset.
5. **Defining and naming themes** — articulate what each theme *is*.
6. **Writing the report** — narrate.

Recursive; move back and forth between phases. Two coders independently coding and comparing is the rigor upgrade (inter-rater reliability).

## 3. Cooper 7-step persona method

The canonical structured method (Cooper / Goodwin). Use this as the backbone when you have qualitative interview data.

### Step 1 — Group interview subjects by role
In B2C: by rough archetype (newbie, power user, occasional user). In B2B: by job role (marketer, ops, finance).

### Step 2 — Identify behavioral variables
For each role, list dimensions along which interviewees differ. Cooper's five categories:

| Category       | Examples                                                    |
|----------------|-------------------------------------------------------------|
| **Activities** | Frequency, volume, intensity (e.g., campaigns per month)    |
| **Attitudes**  | Stance toward the domain ("data-driven" vs "gut feel")      |
| **Aptitudes**  | Education, learning capability, tech comfort                |
| **Motivations**| Why they do it — intrinsic vs extrinsic                     |
| **Skills**     | Domain and technology proficiency                           |

Typical count: ~20 variables per role. Err toward more; prune later.

### Step 3 — Map interviewees to variables
For each interviewee, place a dot on each variable's spectrum. Precision of position is less important than **relative** placement across interviewees.

Example for "campaign volume":
```
  low ─────────●───●●───────●────────●●●── high
               P02 P05      P07      P03 P09 P11
```

### Step 4 — Identify significant behavior patterns
Look for **clusters of ~6+ subjects co-located across multiple variables**. One-variable co-location is a demographic, not a persona. The cluster "P03, P09, P11 are high-volume, data-driven, tech-comfortable, externally-motivated" is a persona candidate.

### Step 5 — Synthesize characteristics and define goals
For each cluster, pull frustrations, environment, workflow details. Distill goals into Goodwin's three types:

- **End goals** — primary (most persona goals are here).
- **Experience goals** — how they want to feel.
- **Life goals** — only if the product actually touches them.

### Step 6 — Check for completeness and redundancy
Merge overlapping personas; fill gaps (is there a user type not represented?). Sanity-check against the ICP (B2B) — you should be able to map each persona to real accounts.

### Step 7 — Designate persona types and narrate
Primary / secondary / supplemental / customer / served / negative (anti). Expand the cluster into narrative and the template fields in `templates.md`.

**Goodwin's rule:** "If every aspect of the description can't be tied back to real data, it's not a persona — it's a creative writing project."

## 4. Behavioral cohort validation

Independent of Cooper's qualitative method, run cluster analysis on product analytics (Amplitude's Personas chart; k-means on Mixpanel event data). Do the behavioral clusters match your qualitative personas?

**Scenarios:**
- **Clusters match personas** — high confidence. Both lenses converge.
- **Clusters don't match** — investigate. Either personas are wrong, clusters are wrong, or personas describe attitudes that don't surface in observed behavior.
- **Analytics has more clusters than personas** — you've under-segmented.
- **Analytics has fewer clusters than personas** — your personas may differ on attitude/goal but not behavior; ask whether that distinction is decision-useful.

See Pipedrive Engineering's worked example: https://medium.com/pipedrive-engineering/identifying-behavioral-personas-with-cluster-analysis-86b724ad0365

## 5. Statistical personas (when justified)

For very large user bases or when enterprise defensibility is required.

**Pipeline:**
1. Qualitative research (interviews) → hypothesized persona candidates.
2. Survey instrument built from qualitative themes.
3. Large-sample survey (hundreds to thousands).
4. Cluster analysis: k-means, hierarchical, or DBSCAN on survey responses + behavioral traits.
5. Label each cluster with narrative (named persona).
6. Validate: do the clusters reproduce on a held-out sample?

This is expensive. Reserve for projects where the persona deliverable has to defend major investment decisions.

## 6. Validation

Before shipping a draft, run it through these checks.

### Stakeholder review
Walk personas through product, engineering, support, sales. They have tacit knowledge about edge cases and archetypes the research missed. Listen for "that's not our customer" — dissent often correlates with missing segments.

### Validation interviews
Recruit **new** participants (not the ones who sourced the persona). Test: "does this person fit Persona A, B, C, or none?" If a material fraction don't fit any persona, the set is incomplete or wrong.

### A/B messaging tests
Variant-per-persona in ads, landing pages, onboarding emails. Measure CTR / conversion by variant. The 35–50% resonance-lift numbers quoted by some vendors are directional; the *method* is what matters.

### Behavioral cohort validation
See above. Do the personas cluster in the product analytics?

### Continuous validation
Track persona-tagged behavior (feature adoption, support interactions, expansion/churn) against expectations. Update or retire when behavior diverges.

## 7. How many personas to end up with

Consensus across Cooper, NN/g, IxDF: **3–5 total**, of which **1 primary, 1–3 secondary, optional anti-persona**.

- **One primary per interface.** If you need more than 3 primaries across a product, scope is wrong — split the product.
- **Seven is usually too many.** None will be memorable. The team won't use them.
- **One "general" persona is the elastic user.** Not a persona.

Decision rule: if merging two personas wouldn't change a single design decision, merge them. If splitting one would, split it.

## 8. Synthesis discipline — heuristics

- **Verbatim wins.** Paraphrased quotes lose signal. Keep the original wording with source ID.
- **Evidence footer from day one.** Every persona claim cites an interview ID, review URL, or analytics cohort. If a claim has no source, it's either a hypothesis flagged explicitly or deleted.
- **Decision-useful or cut.** Before shipping a field, ask: would removing this change a decision? If not, cut it (NN/g rule).
- **Triangulate cross-source.** A theme grounded in interviews + reviews + analytics is strong. A theme grounded in one source is a hypothesis.
- **Distinct on behavior, not demographics.** If two personas differ only on age / gender / location, merge them. If they differ on workflow, behavior, or attitude, keep them apart.
- **Name the anti-persona.** Explicit non-targets sharpen the primary. "We are not designing for X" is often more useful than "we are designing for Y."
- **Write the scenario alongside.** Spool: personas without scenarios are theater. For each primary persona, produce at least one concrete scenario — see `templates.md#scenarios`.

## 9. Anti-patterns to watch during synthesis

Covered in `pitfalls.md`. Most-common synthesis-stage failures:

- Clustering on demographics (age, income, location) instead of behavior.
- Accepting a cluster with fewer than ~3–5 supporting interviewees.
- Writing narrative first, then back-filling "evidence." Evidence first, narrative last.
- Merging the synthesis and validation step — treating the draft as final.
- Importing assumptions from the PM intake into the persona without marking them as hypotheses.
- Skipping the anti-persona step.
- Letting the visual polish stage (pretty layout) drive decisions about field inclusion. Fields are decided by utility, not by layout fit.

## 10. End-of-synthesis checklist

Before sending draft for validation:

- [ ] 3–5 personas (1 primary, 1–3 secondary, 0–1 anti-persona)
- [ ] Each persona has a tagline, goals, behaviors, frustrations, primary JTBD
- [ ] Each persona has an evidence footer with ≥3 independent sources per claim
- [ ] Each persona has at least one verbatim quote with source ID
- [ ] Personas differ on **behavior**, not only demographics
- [ ] At least one scenario is written per primary persona
- [ ] Anti-persona is named with reasoning
- [ ] Every field would change a design decision if removed
- [ ] No field relies on a single source
- [ ] PM intake assumptions marked: which were validated, which invalidated, which still open
