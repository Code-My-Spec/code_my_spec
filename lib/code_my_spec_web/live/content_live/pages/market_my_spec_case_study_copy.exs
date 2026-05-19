%{
  metadata: %{
    meta_title: "Market My Spec Case Study: Ten Working Days, Zero Prompts From Me",
    meta_description:
      "How CodeMySpec built Market My Spec across ten working days of build activity between April 19 and May 17. Configurable per-component workflow, Three Amigos as an agent task, BDD-spec boundary protection, and a full engagement-finder loop. Here's what worked and what didn't.",
    og_title: "Market My Spec Case Study — The Harness Built This Too",
    og_description:
      "A Phoenix MCP server built by CodeMySpec across ten working days. About 200 commits, 24 shipped stories, 315-plus criterion-level BDD spex. Zero prompts. Zero lines of code from me. The honest teardown of the experiments that made that possible.",
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
    tagline: "Zero prompts. Zero lines of code. Ten working days. Same harness.",
    description:
      "A Phoenix MCP server built by CodeMySpec across ten working days of build activity between April 19 and May 17, 2026. About two hundred commits. Twenty-four shipped stories with criterion-level BDD spex coverage. Zero prompts written by me, zero lines of code. The same harness that shipped MetricFlow shipped this one, this time without me typing into the chat. Three named experiments made the change of mode possible. The engagement-finder loop, the agency white-labeling, and the analytics-admin MCP server are what the harness produced on top.",
    stats: [
      %{label: "Working Days", value: "10"},
      %{label: "Stories Shipped", value: "24"},
      %{label: "BDD Spex", value: "315+"},
      %{label: "Prompts by John", value: "0"}
    ]
  },
  overview: %{
    title: "What is Market My Spec?",
    description:
      "Market My Spec is a Phoenix MCP server that exposes marketing operations to Claude Code. An eight-step strategy interview, an engagement-finder loop that searches subreddits and ElixirForum categories from per-account venues (ElixirForum live in prod, Reddit search pending API approval), staged touchpoint drafts with UTM-tracked link rewriting, a per-account file workspace, agency white-labeling on a custom subdomain, and a Google Analytics admin surface for custom dimensions, metrics, and key events. Magic-link auth and OAuth (GitHub, Google) live on the apex. The strategy intelligence runs in the user's own Claude Code subscription, no token markup, no inference resale.",
    integrations: [
      %{
        name: "Claude Code",
        description: "Primary client. Connects with one `claude mcp add` install command",
        icon: "hero-command-line"
      },
      %{
        name: "Reddit",
        description: "Per-account subreddit venues; live search pending Reddit API approval",
        icon: "hero-chat-bubble-left-right"
      },
      %{
        name: "ElixirForum",
        description: "Discourse-backed category venues with auto-discovered category ids (live)",
        icon: "hero-chat-bubble-left-ellipsis"
      },
      %{
        name: "Google Analytics Admin",
        description: "Custom dimensions, custom metrics, key events over MCP",
        icon: "hero-chart-bar"
      },
      %{
        name: "OAuth (GitHub, Google)",
        description: "One-click sign-up resolved by provider identity, not just email",
        icon: "hero-key"
      },
      %{
        name: "Magic-link Email",
        description: "Passwordless sign-up and sign-in via Resend",
        icon: "hero-envelope"
      }
    ],
    key_features: [
      "Marketing-strategy skill delivered to Claude Code over MCP",
      "Eight-step strategy walkthrough: ICP, positioning, channels, content",
      "Per-account venues for Reddit and ElixirForum, with weight and enabled flags",
      "Saved searches: named multi-venue query recipes, runnable from LiveView or MCP",
      "Parallel search orchestrator: weighted ranking, per-source failure isolation, pagination cursor",
      "Touchpoints: staged comment drafts with UTM-rewritten link target, state machine through staged / posted / abandoned",
      "Per-account S3 file workspace with read-before-overwrite gate, surfaced over MCP and a side-by-side LiveView browser",
      "Agency white-labeling: globally unique subdomain claim, logo plus brand colors, per-host routing",
      "Google Analytics Admin tools over a second MCP server",
      "BYO-Claude: the user pays the inference bill, MMS keeps no token margin"
    ]
  },
  repository: %{
    title: "Open Source Repository",
    description:
      "Market My Spec is open source under Apache 2.0. The harness's own source remains in the CodeMySpec repository, but the product the harness shipped is fully open for inspection, contribution, and self-hosting. Issues and PRs welcome.",
    url: "https://github.com/Code-My-Spec/market_my_spec",
    stats: [
      %{label: "Language", value: "Elixir / Phoenix"},
      %{label: "License", value: "Apache 2.0"},
      %{label: "MCP Servers", value: "3 mounted"},
      %{label: "Auth", value: "OAuth2 + magic link"}
    ]
  },
  dev_story: %{
    title: "The Dev Story",
    subtitle: "The Good, The Bad, and The Ugly",
    description:
      "An honest assessment of the second product the harness shipped. Ten working days of build activity between the prior r/elixir post on April 19 and this writing on May 17. About two hundred commits. Three named harness experiments landed and held: configurable per-component workflow, Three Amigos as an agent task, BDD-spec boundary protection. On top of those landed an engagement-finder loop (search, thread fetch, touchpoint staging, UTM rewriting), agency white-labeling on a per-host subdomain, a per-account file workspace surfaced over MCP, and an analytics-admin MCP server ported from CodeMySpec. None of it shipped on faith. Every shipped story carried criterion-level BDD spex against the surfaces the agent built.",
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
              "Story 671 covers the requirement-graph projector with seventeen criterion-level specs. A ProjectConfiguration row carries require_specs, require_reviews, require_tests, spec_validation, and qa_validation per project. The knobs gate module specs, spec reviews, and unit tests. BDD specs are not configurable; they are the spine of the default loop. Toggle require_specs off and the module-spec nodes drop out of the graph cleanly. Toggle require_reviews off and implementation splices onto the spec-valid edge directly. Toggle them on and off and the graph round-trips. The configurable per-component workflow stopped being a slogan the moment seventeen tests landed against it."
          },
          %{
            title: "Three Amigos Caught Real Ambiguity",
            description:
              "Story 678 (multi-tenancy) is the cleanest example. The agent ran the Three Amigos protocol, surfaced four open questions about agency-vs-individual UX instead of guessing, and parked them on the story. I answered in plain English. The agent then added a new rule capturing the product decision I had just made (agency accounts are admin-provisioned only, no self-service) plus a matching scenario, and only then closed out the readiness gate. Story 679 (the agency client dashboard) ran the same protocol roughly seven minutes after 678 wrapped. The pattern repeats."
          },
          %{
            title: "Boundary Protection Installed Clean On First Run",
            description:
              "On May 1 the spex_boundary_ready task ran for the first time on Market My Spec. It installed two framework Credo checks (deny stdlib calls and direct send/2 from inside specs), generated a project-local Credo deny list by reading architecture/proposal.md and naming the internal contexts (Repo, Mailer, Vault, Users, Integrations, McpAuth, Skills), scaffolded the curated fixtures bridge, and wrote the project BDD plan. Four artifacts in one task, zero hand-edits. The deny list grew naturally as Engagements, Agencies, and the analytics-admin server landed; every new context was named explicitly, every fixture passed through the bridge."
          },
          %{
            title: "The Engagement Loop Shipped End-To-End Against Cassettes",
            description:
              "Stories 705 through 716 wired the full agent loop: per-account venues (subreddits and ElixirForum categories) under VenueLive.Index and an add_venue / list_venues / update_venue / remove_venue MCP surface; saved searches as named multi-venue recipes runnable from either LiveView or MCP; a parallel Search orchestrator that fans out across enabled venues with weighted ranking and per-source failure isolation; ingested Thread rows with a normalized comment tree; staged Touchpoint drafts with UTM rewriting and a staged / posted / abandoned state machine; and ElixirForum joining Reddit behind a single Source behaviour with auto-discovered category ids. Three MCP servers now mount: marketing strategy, engagements, analytics admin. The MCP surface served seventeen tools by May 15. ElixirForum runs live against the public Discourse APIs. Reddit search is fully implemented and proven against ReqCassette recordings of real Reddit responses; it's gated on API access approval in prod (see Bad)."
          },
          %{
            title: "Agency White-Labeling Shipped Without Touching Apex",
            description:
              "Story 691 plus 695 added globally unique subdomain claims, logo URL plus primary and secondary colors, and a per-host AgencyHost plug between Plug.Session and the router. The apex stays clean; unknown subdomains 302 to apex; API endpoints (/oauth/*, /mcp, /.well-known/*) are apex-only. Agency owners configure branding from a single LiveView form. The harness wrote the per-host plug, the migration with a partial unique index on subdomain WHERE NOT NULL, and the spec coverage in one story pass."
          },
          %{
            title: "Zero Prompts, Orchestration Only",
            description:
              "The headline number is honest with one footnote: I orchestrated. I picked which subagent ran when, called retries, and occasionally said do it yourself, no subagent on this one. The writing was the agent's, top to bottom. The 0/0 stat is the result. The orchestration framing is the truth that prevents the headline from reading as marketing."
          },
          %{
            title: "The Harness Started Specifying Itself",
            description:
              "Story 553 landed within nine hours of the prior r/elixir post going live. Seven criterion specs against the harness's own ProjectConfiguration pipeline. By May 5 the harness was running roughly two hundred criterion-level Spex against its own internal modules. By May 17 the count is larger; the framework that builds Phoenix applications now has its own BDD coverage as its backstop, with cassette-backed pipeline fixtures for the validation paths and a release CI that fails on warnings."
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
              "Interventions during the build clustered at orchestration boundaries. Use this subagent here, don't use one there. Retry that. Pause and let me check. The dominant intervention shape was switching the agent's execution mode rather than fixing its code. The 0/0 number is real, but the post is honest: I orchestrated, the agent built, and orchestration mostly meant routing."
          },
          %{
            title: "Story 561's Orphan Filter Took Three Passes",
            description:
              "May 3 was the longest day of the early window. The orphan-context filter on next_actionable went in, was extended to the full subtree, was reverted when fixture damage outweighed the win, and then landed in narrower form. The harness can absorb a wrong-shaped change and a clean revert; the case for narrower scope on graph-projector changes was made out loud, in commits."
          },
          %{
            title: "The Configurable Workflow Has No Automated Signal",
            description:
              "Right now the operator decides when to flip a layer on. Module specs go on when you want to read the contract before code is written. Spec review goes on when agent drift is showing across components. Unit tests go on when you're about to refactor non-trivial internal logic. None of those triggers are machine-detectable today. That is the next experiment, not a closed problem."
          },
          %{
            title: "Saved-Searches Schema Drifted Between Dev And CI",
            description:
              "Story 710's migration (20260514100000_create_saved_searches) was rewritten in place during a design rollback. Environments that had already recorded the original version skipped the rewrite, so the dev DB and the CI DB held different column sets behind the same migration timestamp. The corrective migration (20260514110000_align_saved_searches_schema) was a forward-only IF EXISTS / IF NOT EXISTS sweep to reconcile both. Cost: half a day of confused QA before the drift was named. The lesson, in code: edits to a migration after it ships to any environment have to ship as a follow-up migration, not a hot patch in place."
          },
          %{
            title: "Reddit API Access Is Pending, So Live Reddit Search Is Not Yet Wired In Prod",
            description:
              "The Reddit adapter is real. It calls `GET /r/<sub>/search.json` with a descriptive User-Agent, normalizes Reddit's Listing JSON into the canonical candidate shape, and is covered by thirteen criterion-level spex against ReqCassette recordings of real Reddit responses. What's missing is the production credential: the Reddit script-app OAuth registration is pending Reddit's approval. Until that lands, the prod deployment can serve venue admin and saved-search admin and the LLM-facing MCP surface, but live searches against Reddit return an HTTP error rather than ranked candidates. ElixirForum runs live in prod because it sits behind anonymous public Discourse APIs. The cleanest way to read this: the harness shipped the loop end-to-end against fixtures and one of two sources live; the second source is one credential away."
          },
          %{
            title: "The MCP Surface Drifted Behind Its Own LiveView Admin",
            description:
              "Stories 708 and 710 shipped the LiveView venue + saved-search admin with their acceptance criteria calling out matching MCP tools, but the MCP tool modules weren't built. Smoke test on May 15 confirmed it: tools/list returned eight tools, none of them venue or search related. The QA roll-forward had greened the MCP criterion spex anyway because the spex were pattern-matching `{:scaffold, :not_yet_implemented}` as PASS via try/rescue. One follow-up commit on May 15 closed the gap with nine new MCP tool modules and a beefed-up rewrite of the nine anemic spex. Lesson: tautological spex around a known-stubbed surface will green without protest; the spex bar has to enforce a real reply envelope, not a pass-on-NotImplemented escape hatch."
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
            title: "Story 705 Shipped To Prod With A Stub Adapter And A Tautology For Coverage",
            description:
              "Story 705 (Discover engagement opportunities) shipped with `Reddit.search/2` returning `{:ok, []}` and eighteen spex that greened against the empty list using `Enum.each([], fn _ -> assert ... end)`. The MCP tool worked. The schema was right. The candidate list was always empty. The bug stayed in until a real search call from the agent surfaced it. The fix on May 16 rebuilt the adapter to call `GET /r/<sub>/search.json` with a descriptive User-Agent, normalized Reddit's Listing JSON into the canonical candidate shape, and rewrote thirteen spex against ReqCassette recordings of real Reddit responses. The split story 714 carried the ElixirForum criteria forward behind the same Source behaviour. Memory written: don't ship an MCP tool wired to a scaffold adapter, and reject `Enum.each([], ...)` as a passing test."
          },
          %{
            title: "UAT Was DOA On First Deploy Because :apex_host Was Read At Compile Time",
            description:
              "HostResolver read `Application.compile_env(:market_my_spec, :apex_host, \"marketmyspec.com\")` at module load. The BEAM built in CI hardcoded marketmyspec.com. Booting that image on UAT (uat.marketmyspec.com) treated uat as an agency subdomain, failed to resolve an agency named uat, and 302 redirected every request back to apex. UAT was down on its first deploy. Fix: read `Application.get_env/3` at call time inside apex_host/0, and set the value from runtime.exs after PHX_HOST is resolved. Three lines moved; whole environment came back. Compile-time reads of operator-supplied config are a category of bug the harness now has to flag in review."
          },
          %{
            title: "Migrate-Before-Swap Wasn't Wired, And A Column Wasn't There Yet",
            description:
              "Story 691 added a subdomain column to accounts. The May 14 UAT deploy swapped the new image in before the migration ran. The serving container started answering with `column a0.subdomain does not exist` 500-storms. The cause was a deploy script that ran the swap and the migration in the wrong order; the gap had been latent until a schema-changing migration finally exposed it. Fix: scripts/deploy and scripts/deploy-uat now run `kamal app exec --version=<sha> /app/bin/migrate` BEFORE `kamal deploy`. The new container holds, the old container serves against the now-migrated schema, the swap happens last. Caveat documented in the script: destructive migrations that drop a column the old code still reads break the old container during the pre-swap window; for those, the two-deploy split is required. Operationally costly. Mechanically a one-line ordering change."
          },
          %{
            title: "Boundary Protection Has No Live-Catch Transcript Yet",
            description:
              "The four artifacts are in place. The framework Credo checks are active. The project-local check denies the right modules. The fixtures bridge is the only sanctioned door. The BDD plan is written. What's missing is a transcript moment where Credo fires live on a violation and the agent has to back up and try again. The artifacts work as designed. Until a live-fire moment is captured, the boundary-protection claim stands on installation evidence and design intent, not on a real-time catch."
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
        title: "An MCP Tool Wired To A Stub Adapter Will Green Through Tautological Specs",
        description:
          "Story 705 shipped to prod with the search adapter returning an empty list and eighteen spex iterating over the empty list to claim coverage. The spex bar has to enforce a real reply envelope, not a pass-on-NotImplemented escape hatch. New review rule: any spex whose assertions live inside `Enum.each(empty_collection, ...)` is rejected at review; any MCP tool whose adapter returns the empty case unconditionally needs a fixture-backed real-world call before merge. The cleanup on May 16 rebuilt the adapter behind ReqCassette recordings against real Reddit responses and split the cross-source criteria into story 714."
      },
      %{
        title: "Operator-Supplied Config Has To Be Read At Runtime",
        description:
          "HostResolver's compile-time read of :apex_host took UAT down on its first deploy. Migrations that drop or rename columns are bookended by deploy ordering. Both are categories the harness can flag in review: any `Application.compile_env/2` call against a key set by runtime.exs is suspect, and any migration that touches a column the running code reads warrants a two-deploy split. Operationally these are one-line fixes; the value is in spotting the shape before it ships."
      },
      %{
        title: "Orchestration Is The Next Bottleneck",
        description:
          "I didn't write prompts. I didn't write code. I did pick which subagent ran when, call retries, and occasionally route around a bad path. That is the work that's left, and it is the work the next experiment has to absorb. Auto-orchestration through the requirement graph is the obvious next step. We are not there yet."
      }
    ],
    closing:
      "Ten working days. About two hundred commits. Twenty-four shipped stories. Zero prompts. Zero lines of code from me. The harness shipped Market My Spec the same way it shipped MetricFlow, but this time without me typing into the chat. The fix wasn't more automation. It was knobs on the layers, a real gate before the specs, and a sealed boundary around them. Configurable workflow, Three Amigos, and boundary protection. Three harness changes, one MCP server with three mounted servers on top, an engagement-finder loop wired against cassettes and live against ElixirForum (Reddit live search is one credential approval away), and one open question about orchestration. That's the loop that ships."
  }
}
