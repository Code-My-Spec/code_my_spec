%{
  metadata: %{
    meta_title: "Market My Spec Case Study: 4 Days, 13 Stories, Zero Prompts From Me",
    meta_description:
      "How CodeMySpec built Market My Spec across one weekend (May 3-6). Configurable per-component workflow, Three Amigos as an agent task, BDD-spec boundary protection. Here's what worked and what didn't.",
    og_title: "Market My Spec Case Study — The Harness Built This Too",
    og_description:
      "A small MCP server built by CodeMySpec across four days. 17 commits, 13 stories, ~130 spex files. Zero prompts. Zero lines of code from me. The honest teardown of the experiments that made that possible.",
    og_image: nil,
    author: "John Davenport",
    tags: [
      "case-study",
      "market-my-spec",
      "marketing",
      "phoenix",
      "elixir",
      "ai-development",
      "bdd",
      "harness-engineering",
      "configurable-pipeline",
      "three-amigos",
      "boundary-protection"
    ]
  },
  hero: %{
    title: "Market My Spec",
    tagline: "Zero prompts. Zero lines of code. Four days. Same harness.",
    description:
      "A small MCP server built by CodeMySpec across one weekend (May 3 through May 6, 2026). Seventeen commits. Thirteen stories with criterion-level spex coverage. Zero prompts written by me, zero lines of code. The same harness that shipped MetricFlow shipped this one, this time without me typing into the chat. Three new experiments made that possible. Here's what they are, what worked, and what's still open.",
    stats: [
      %{label: "Build Days", value: "4"},
      %{label: "Stories", value: "13"},
      %{label: "Prompts by John", value: "0"},
      %{label: "Lines of Code by John", value: "0"}
    ]
  },
  overview: %{
    title: "What is Market My Spec?",
    description:
      "Market My Spec is a small MCP server that exposes a marketing-strategy skill to Claude Code. One install command connects a user's existing agent to the server, and the agent walks the user through an eight-step strategy flow covering ICP, positioning, channels, and content. The MVP ships the connection plumbing: magic-link auth, multi-tenant accounts with an agency tier, OAuth provider scaffolding, two MCP servers, and the skill-content surface the agent reads. The strategy intelligence runs in the user's own Claude Code subscription — no token markup, no inference resale.",
    integrations: [
      %{
        name: "Claude Code",
        description: "Primary client. Connects with one `claude mcp add` install command",
        icon: "hero-command-line"
      },
      %{
        name: "Magic-link Email",
        description: "Passwordless sign-up and sign-in via Resend",
        icon: "hero-envelope"
      },
      %{
        name: "OAuth (GitHub, Google)",
        description: "Provider scaffolding for connect-account flows",
        icon: "hero-key"
      }
    ],
    key_features: [
      "Marketing-strategy skill delivered to Claude Code over MCP",
      "Eight-step strategy walkthrough: ICP, positioning, channels, content",
      "Multi-tenant accounts with admin-provisioned agency tier",
      "Magic-link sign-up and sign-in (no passwords)",
      "OAuth provider scaffolding for GitHub and Google",
      "BYO-Claude — no token markup, no inference resale"
    ]
  },
  repository: %{
    title: "Source",
    description:
      "A snapshot of the Market My Spec build is available for inspection on GitHub. The harness's own source remains in the CodeMySpec repository. The MMS snapshot is offered for verification of the case study's claims; it will not stay open source forever.",
    url: "https://github.com/johns10/market_my_spec",
    stats: [
      %{label: "Language", value: "Elixir / Phoenix"},
      %{label: "Distribution", value: "Claude Code plugin"},
      %{label: "Strategy Storage", value: "MCP-backed records"},
      %{label: "Auth", value: "OAuth2 + magic link"}
    ]
  },
  dev_story: %{
    title: "The Dev Story",
    subtitle: "The Good, The Bad, and The Ugly",
    description:
      "An honest assessment of the second product the harness shipped. The MMS build itself is small: seventeen commits across four days (May 3-6). The harness changes that made the build possible were larger and longer — about 200 commits across the seventeen days between the prior r/elixir post and this one. Three named experiments landed in that window, every one of them with criterion-level Spex covering its evaluator rules.",
    sections: [
      %{
        id: "good",
        label: "The Good",
        icon: "hero-check-circle",
        color: "success",
        items: [
          %{
            title: "The Configurable Workflow Shipped Working",
            description:
              "Story 671 covers the requirement-graph projector with seventeen criterion-level specs. A ProjectConfiguration row carries require_specs, require_reviews, require_tests, spec_validation, and qa_validation per project. The knobs gate module specs, spec reviews, and unit tests — BDD specs are not configurable; they are the spine of the default loop. Toggle require_specs off and the module-spec nodes drop out of the graph cleanly. Toggle require_reviews off and implementation splices onto the spec-valid edge directly. Toggle them on and off and the graph round-trips. The configurable per-component workflow stopped being a slogan the moment seventeen tests landed against it."
          },
          %{
            title: "Three Amigos Caught Real Ambiguity",
            description:
              "Story 678 (multi-tenancy) is the cleanest example. The agent ran the Three Amigos protocol, surfaced four open questions about agency-vs-individual UX instead of guessing, and parked them on the story. I answered in plain English. The agent then added a new rule capturing the product decision I had just made (\"agency accounts are admin-provisioned only, no self-service\") plus a matching scenario, and only then closed out the readiness gate. Without the gate, that ambiguity would have flowed straight into BDD specs."
          },
          %{
            title: "Boundary Protection Installed Clean On First Run",
            description:
              "On May 1 the spex_boundary_ready task ran for the first time on Market My Spec. It installed two framework Credo checks (deny stdlib calls and direct send/2 from inside specs), generated a project-local Credo deny list by reading architecture/proposal.md and naming seven internal contexts (Repo, Mailer, Vault, Users, Integrations, McpAuth, Skills), scaffolded the curated fixtures bridge, and wrote the project BDD plan. Four artifacts in one task, zero hand-edits."
          },
          %{
            title: "Zero Prompts, Orchestration Only",
            description:
              "The headline number is honest with one footnote: I orchestrated. I picked which subagent ran when, called retries, and occasionally said \"do it yourself, no subagent on this one.\" The writing was the agent's, top to bottom. The 0/0 stat is the result. The orchestration framing is the truth that prevents the headline from reading as marketing."
          },
          %{
            title: "The Harness Started Specifying Itself",
            description:
              "Story 553 landed within nine hours of the prior r/elixir post going live. Seven criterion specs against the harness's own ProjectConfiguration pipeline. By May 5 the harness was running roughly two hundred criterion-level Spex against its own internal modules, with cassette-backed pipeline fixtures for the validation paths and a release CI that fails on warnings. The framework that builds Phoenix applications now has the framework's own BDD coverage as its backstop."
          }
        ]
      },
      %{
        id: "bad",
        label: "The Bad",
        icon: "hero-exclamation-triangle",
        color: "warning",
        items: [
          %{
            title: "Orchestration Was Still Required",
            description:
              "Interventions during the build clustered at orchestration boundaries. \"Use this subagent here, don't use one there. Retry that. Pause and let me check.\" The dominant intervention shape was switching the agent's execution mode rather than fixing its code. The 0/0 number is real, but the post is honest: I orchestrated, the agent built, and orchestration mostly meant routing."
          },
          %{
            title: "Story 561's Orphan Filter Took Three Passes",
            description:
              "May 3 was the longest day of the window. The orphan-context filter on next_actionable went in, was extended to the full subtree, was reverted when fixture damage outweighed the win, and then landed in narrower form. The harness can absorb a wrong-shaped change and a clean revert; the case for narrower scope on graph-projector changes was made out loud, in commits."
          },
          %{
            title: "The Configurable Workflow Has No Automated Signal",
            description:
              "Right now the operator decides when to flip a layer on. Module specs go on when you want to read the contract before code is written. Spec review goes on when agent drift is showing across components. Unit tests go on when you're about to refactor non-trivial internal logic. None of those triggers are machine-detectable today. That is the next experiment, not a closed problem."
          }
        ]
      },
      %{
        id: "ugly",
        label: "The Ugly",
        icon: "hero-fire",
        color: "error",
        items: [
          %{
            title: "The BDD Specs Got Sloppy On A Less-Careful Model",
            description:
              "Story 609 (magic-link sign-up) shipped on May 1 via the BDD-only path: Three Amigos, six BDD criterion specs, twelve implementation files, no module specs and no unit tests. The model writing the specs that day was not Opus. Two days later, when Opus was available again, I spun up a fresh session with the brief \"You are reviewing every BDD spec file in this project. The specs were written by a less-careful model and need a thorough audit.\" All six spec files needed the sweep. The cleanup wasn't gated by a config flip — BDD specs are not currently configurable in the workflow. The lever was the model itself: getting Opus back was what made the audit possible. The honest version of \"knob, not deletion\" is that the workflow knobs cover module specs and spec reviews and unit tests, not BDD specs, and model selection is a separate axis nobody has automated yet."
          },
          %{
            title: "Boundary Protection Has No Live-Catch Transcript Yet",
            description:
              "The four artifacts are in place. The framework Credo checks are active. The project-local check denies the right modules. The fixtures bridge is the only sanctioned door. The BDD plan is written. What's missing is a transcript moment where Credo fires live on a violation and the agent has to back up and try again. The artifacts work as designed. The live catch will get staged in the demo video; until then, the boundary-protection claim stands on installation evidence and design intent, not on a real-time catch."
          },
          %{
            title: "The Mixed-Session Corpus",
            description:
              "Forty-seven Claude Code sessions covered the build window. Twenty had build-side signal. All twenty were also marketing-operations sessions, because Market My Spec is the marketing tool we use to do CodeMySpec's marketing. There are no \"build-only\" sessions in the corpus. Transcript mining for this case study had to happen at the cwd-and-tool-call level inside each session. Privacy review on every excerpt. No customer data leaked, but the operational cost was real."
          },
          %{
            title: "The Three Amigos Gate Is Structural, Not Semantic",
            description:
              "The readiness check confirms records exist: at least one persona linked, at least one rule, every rule has at least one scenario, scenarios outnumber open questions. It does not confirm the rules are right. Quality lives in the agent's prompt and the human PM's review. Whether a one-PM Three Amigos session can substitute for a real workshop with a human dev and a human QA is an open question, not a closed one."
          }
        ]
      }
    ]
  },
  conclusion: %{
    title: "What We Changed After Market My Spec",
    takeaways: [
      %{
        title: "The Layers Are Knobs, Not Doctrine",
        description:
          "MetricFlow taught us that the six-phase pipeline ran most of its layers for ceremony rather than catching real problems. Market My Spec made the layers configurable instead of removing them. Module specs, spec reviews, and unit tests are still available; they're one config flip away. The default path is the shortest one that ships working software, and you opt into ceremony as the surface stabilizes. The harness rewires its own requirement graph when the toggles change."
      },
      %{
        title: "Example Mapping Belongs Inside The Harness",
        description:
          "The MetricFlow conclusion called Example Mapping the missing step. Market My Spec made it a real agent task with twelve criterion-level specs against the readiness rules, hosted in the harness, runnable from Claude Code through MCP. Persona, Rules, Scenarios, Questions, all persisted as records, not flat files. The records make the gate machine-checkable. The agent calls evaluate_task when it thinks the conditions are met. The PM holds product intent."
      },
      %{
        title: "Specs Should Drive The User's Surfaces, Not The Internals",
        description:
          "The MetricFlow Potemkin Village failure mode was the coding agent and the QA agent collaborating to ship broken functionality. The fix is structural: a sealed boundary that forces specs to drive the same LiveView, controller, and MCP surfaces a real user drives. Repo is denied. Direct send/2 is denied. System.cmd is denied. The fixtures bridge is the only door, and it is grep-able. The harness refuses to walk into boundary-shaped work until the gate is green."
      },
      %{
        title: "Orchestration Is The Next Bottleneck",
        description:
          "I didn't write prompts. I didn't write code. I did pick which subagent ran when, call retries, and occasionally route around a bad path. That is the work that's left, and it is the work the next experiment has to absorb. Auto-orchestration through the requirement graph is the obvious next step. We are not there yet."
      }
    ],
    closing:
      "Four days. Seventeen commits. Thirteen stories. Zero prompts. Zero lines of code from me. The harness shipped Market My Spec the same way it shipped MetricFlow, but this time without me typing into the chat. The fix wasn't more automation. It was knobs on the layers, a real gate before the specs, and a sealed boundary around them. Configurable workflow, Three Amigos, and boundary protection. Three changes, one MVP, one open question about orchestration. That's the loop that ships."
  }
}
