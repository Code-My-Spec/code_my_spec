# The onboarding process

Taking somebody from "I want to build a thing" to a project they can work
in, with an agent doing the taking.

This is the sales process. Somebody arriving has not decided to buy
anything yet, and what convinces them is watching their idea turn into a
working project — not filling in a form about it. That framing decides
most of what follows: **the conversation is the product.** There is no
fallback questionnaire.

## Where the visitor is, at each point

```
home page  →  /build  →  (register)  →  /build/workspace
"what do      describe +     gate         convert, boot,
 you want     shape,                      then interview
 to build?"   then confirm
```

Nothing before the gate requires an account. They see the plan first.

## The questions, in order

There are three groups, and they are different kinds of thing. Do not
merge them.

### 1. The opening question — one, always the same

> **"What do you want to build?"**

Asked on the home page as a plain form and again as the first line of the
transcript, because a visitor who typed it on the home page should see it
already answered rather than be asked twice.

The example to give is concrete and small: *"A booking tool for hair
salons, so owners can see their week and clients can book themselves in."*

### 2. Shaping questions — at most two, generated, not fixed

These are asked by a model, from what they actually wrote, and they exist
to settle two specific things a generator needs to know:

- **Do people sign in to use it?**
- **Does each business get its own separate copy?**

If the description already answers both, **ask nothing.** That is not an
optimisation, it is the rule — the cap is two and the correct number is
often zero. An agent that asks its two questions because it has two
questions available is padding a sales conversation.

### 3. The plan, then five things to confirm

The agent produces a summary and a first build, and the visitor confirms:

| Field | Asked as |
|---|---|
| `account_name` | Account name |
| `project_name` | Project name |
| `needs_sign_in` | People sign in to use it |
| `separate_copies` | Each business gets its own separate copy |
| `location` | Where should it run — in the cloud, or on my machine |

This one *is* a form, and should be. It is a proposal to check, not a
conversation — the agent has already made the guesses and the visitor is
correcting them.

A question that was never asked is not a `false`. Unanswered and "no" are
different states and the form requires a real answer for the two generator
inputs rather than defaulting them.

## What has to exist before the agent can hand off

Conversion needs a signed-in user and a plan carrying the confirmed names.
It then creates, in order:

1. **An account**, if the scope has none. Created by a path that picks an
   available slug before inserting, so a name somebody else already uses is
   accepted rather than refused — a visitor should never be told their
   company name is taken.
2. **A project**, from the confirmed project name.
3. **A persona**, from what they said about who uses it. Recorded as a
   proto-persona and deliberately **best-effort**: if it fails, it logs and
   the conversion still succeeds. A missing persona is a gap to fill later;
   a failed signup is a lost customer.
4. **The plan row**, marked converted with the account and project on it,
   so a second visit adopts what exists instead of building a duplicate.

Then the workspace boots — except for `local`, where the visitor is given
the commands to run on their own machine instead, because there is nothing
for us to boot.

**The handoff is complete when there is a project with a working copy the
agent can act in.** Until then the agent has a conversation and nothing to
apply it to.

## After the handoff — the interview

Once they are in the workspace, a longer interview runs: **up to four
questions, one at a time**, with the progress shown (`question 2 of 4`).
Its output is a set of derived rules, shown back as *"the rules I
derived"*.

The scripted fallback set, which is also a good model for what these
questions are for:

1. Who does the very first thing in this application, and what are they
   trying to get done?
2. What should never be allowed to happen, even by accident?
3. When something goes wrong, who needs to find out, and how?
4. What would make you say this was worth building?

Those are product questions, not configuration questions. They feed
`process/product.md` — stories, personas, rules — rather than the
generator.

## Things to hold onto

- **The visitor sees the plan before signing up.** Moving the gate earlier
  converts fewer people, not more.
- **Both pages rebuild the same transcript from the same row**, because
  registering navigates between them and a conversation that forgets itself
  across a signup reads as a broken product at the exact moment trust
  matters most.
- **This costs real tokens on somebody who has not paid.** That is
  accepted deliberately — it is the sales process. What it buys is a
  visitor who has watched the thing work. What it does not license is
  asking questions that were already answered.
