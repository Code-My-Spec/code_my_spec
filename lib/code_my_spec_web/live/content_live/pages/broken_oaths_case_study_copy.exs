%{
  metadata: %{
    meta_title: "Broken Oaths Case Study: A Playable 4X in a 12-Day Sprint",
    meta_description:
      "How CodeMySpec built a persistent hex-globe 4X game in 12 days. 108,734 lines of Elixir, 52 stories, 279 BDD spex, live in production. John typed 0.25%.",
    og_title: "Broken Oaths Case Study: The Hardest Thing the Harness Has Built",
    og_description:
      "A persistent hex-globe 4X MMO built in a 12-day sprint: 275 commits, 108,734 lines of Elixir, 279 executable BDD spex, seven production releases, real playtesters. Also the build where 20 of 52 stories carry no QA record at all. The honest teardown.",
    og_image: nil,
    author: "John Davenport",
    tags: [
      "case-study",
      "broken-oaths",
      "phoenix",
      "elixir",
      "liveview",
      "ai-development",
      "bdd",
      "harness-engineering",
      "game-development",
      "genserver",
      "playtesting"
    ]
  },
  hero: %{
    title: "Broken Oaths",
    tagline: "A persistent hex-globe 4X. Twelve days. The one I actually wanted.",
    description:
      "A massively multiplayer 4X strategy game on a hex globe that keeps turning while you sleep. Lose a war and you do not die: your conqueror makes you a vassal, and you pay tribute, fight their wars, bank gold, and plot rebellion. Built in a 12-day sprint in July 2026 on a Goldberg polyhedron mesh, a per-world GenServer, and 279 executable BDD specs. 108,734 lines of Elixir. Seven production releases in eight days. I typed 0.25 percent of the characters. This is the most complicated thing the harness has produced, and it is also a game I had been planning for years, which is why my fingerprints are all over it.",
    stats: [
      %{label: "Sprint Days", value: "12"},
      %{label: "Lines of Elixir", value: "108,734"},
      %{label: "BDD Spex", value: "279"},
      %{label: "Characters Typed by John", value: "0.25%"}
    ]
  },
  overview: %{
    title: "What is Broken Oaths?",
    description:
      "A browser-based persistent 4X built in Phoenix LiveView. The world is a Goldberg polyhedron generated from seeded 3D Perlin noise, so the hex grid closes cleanly around a sphere with pentagons at the poles. Each world runs as its own GenServer and keeps ticking whether or not you are logged in: movement resolves every tick, the economy every tenth. The mechanic the game is named after is what happens after you lose. Conquest makes you a vassal rather than a corpse, and vassalage comes with Oath Strain, Protection Pacts, tribute, a gold bank, stewardship, and the Pact of Broken Oaths that lets vassals coordinate a revolt. Three personas scoped it, all of them variations on a casual browser-strategy player.",
    integrations: [
      %{
        name: "Phoenix LiveView",
        description:
          "Server-authoritative rendering; the globe ships as a canvas impostor with a vector near mode and zero DOM tiles",
        icon: "hero-window"
      },
      %{
        name: "GenServer per world",
        description:
          "Each world is a supervised process holding live simulation state, rehydratable from Postgres",
        icon: "hero-cpu-chip"
      },
      %{
        name: "Spex",
        description:
          "279 executable BDD spec files driving the same LiveView surfaces a player drives",
        icon: "hero-check-badge"
      },
      %{
        name: "Kamal + Hetzner",
        description: "Fleet deploy to UAT and production, boot-time migrations, TLS via kamal-proxy",
        icon: "hero-server"
      },
      %{
        name: "Google OAuth + Resend",
        description: "Sign-in and transactional mail, both scaffolded by the harness in one evening",
        icon: "hero-key"
      },
      %{
        name: "Aseprite + Nano Banana",
        description: "709 game art PNGs from 13 Aseprite sources and a generated-texture CLI",
        icon: "hero-paint-brush"
      }
    ],
    key_features: [
      "Seamless hex globe: Goldberg polyhedron mesh, 3D Perlin terrain, orthographic projection, drag-rotate and wheel zoom",
      "Persistent simulation: movement every tick, economy every tenth tick, running whether you are online or not",
      "Feudal vassalage: tribute, gold bank, stewardship, levies, garrisons, Honor consequences for refusal",
      "Rebellion: Oath Strain, Protection Pacts, Declare Independence, heir reconciliation, coordinated multi-vassal revolt",
      "Combat with melee and ranged strength split, sieges, city defense, fortify stances, and a naval Galley",
      "Cities with production queues, growth, worked tiles, yields, wonders, and buildings",
      "Research tree from Stone Age through Bronze, gated strategic resources, worker chop and road orders",
      "Barbarian camps with a hunting AI, spawn cadence, and placement rules that keep them off claimed tiles",
      "Per-world chat with blocking and profanity filtering, alliances, cooperative combat with bounty split by damage dealt",
      "Fog of war and per-player exploration, with the camera keyed to the explored set"
    ]
  },
  repository: %{
    title: "Open Source Repository",
    description:
      "The repo is public. The architecture decision records, the 279 spec files, the QA briefs with their screenshot evidence, and the design documents that preceded the feudal system are all in there, including the commits that got rolled back.",
    url: "https://github.com/Code-My-Spec/broken-oaths",
    stats: [
      %{label: "Language", value: "Elixir / Phoenix"},
      %{label: "Commits", value: "275"},
      %{label: "Components", value: "171"},
      %{label: "Subagents Dispatched", value: "227"}
    ]
  },
  dev_story: %{
    title: "The Dev Story",
    subtitle: "The Good, The Bad, and The Ugly",
    description:
      "The first commit is dated March 19 and the last is still landing, but citing a four-month span would be dishonest. 253 of the 275 commits landed in July, across 12 distinct days. This is a 12-day sprint with a four-month exploratory prologue. It is also the first build in this series where I was a heavy participant on purpose, because I wanted to play the result. That shows up in the numbers, and the numbers are better read as a measure of how much I cared than as a measure of what the harness needed.",
    sections: [
      %{
        id: "good",
        label: "The Good",
        icon: "hero-check-circle",
        color: "success",
        items: [
          %{
            title: "A Playable Persistent 4X in Twelve Days",
            description:
              "108,734 lines of Elixir across 184 modules, 1,630 tracked files, 709 pieces of game art, and seven tagged releases from v0.2.0 to v0.3.1, all inside a 12-day window with two days off in the middle. July 13 alone carried 44 commits. July 14 produced roughly 13,000 lines of Elixir and ran the entire harness lifecycle twice, morning and evening: architecture, then red specs, then implementation, then a UI panel, then around again."
          },
          %{
            title: "Risk-First Sequencing Was the Right Call",
            description:
              "The unproven part got the whole day and the well-understood part got an evening. July 13 was spent entirely on the renderer, which is the thing that could have killed the project. Accounts, invitations, integrations, authorization, Google OAuth, a Kamal fleet deploy kit for two environments, and Resend mail all landed that same evening, with commit c728292 carrying 3,503 insertions of generated platform in one go. Both environments were verified live by the end of it."
          },
          %{
            title: "Specs Genuinely Came First, Repeatedly",
            description:
              "Commit 9bcc11e is the clearest instance: 5,624 insertions across 69 files, of which 46 were executable BDD specs and exactly two were implementation. Sieges, vassalization, tribute, banking, and stewardship were fully specified before a line of siege logic existed. The same shape repeats on July 14 (37 red spec files in the ten minutes between 11:17 and 11:27, green by 12:53) and on July 16 (roughly 7,900 lines of red specs for combat and garrisons before any combat code)."
          },
          %{
            title: "The Decomposition Was Clean and Nearly Free",
            description:
              "All the rebellion logic went into world_server.ex, and that was the problem. Starting at 18:37 on July 19, eight slices pulled it apart: feudal and rebellion logic first, then combat, cities, unit orders, social and vision, stewardship, turn.ex split into domain-owned tick phases, and the 1,161-line game.ex facade split into per-domain sub-facades. Then ten bounded contexts were promoted out of Game entirely, roughly 200 lines touched per commit with zero net change. The LiveViews followed at 04:10, with play.ex shedding 2,028 lines into components and a view-model."
          },
          %{
            title: "Cross-Story QA Caught What Per-Story QA Could Not",
            description:
              "Batch 5 shipped 147 files at 04:49 on July 18 with story-level QA already green. Four end-to-end journeys, run as a real player rather than as a test, immediately found three bugs the per-story passes had missed. The screenshot filenames are the receipt: j2_05_BUG_city_unreachable.png and j3_09_BUG_over_cap_worked_tiles.png. Fixed, rerun 4/4 clean, then frozen into permanent regression tests. That pattern is now the strongest QA idea in the harness."
          },
          %{
            title: "Real Playtesters Were in Production by Day Six",
            description:
              "On July 20 I stopped building long enough to recruit people: go play my game, use the feedback widget in the lower right, report anything you find. Roughly twenty commits exist because of what came back. Four user-reported bugs forced v0.2.1 out at 12:49 on July 18. Playtest triage then split three ways in seventy minutes across backend, frontend, and mobile rendering, and a single prod patch recorded nine playtest fixes. Individual reports carry ids in the harness; playtest issue 2a9df843 became the player display-name feature."
          },
          %{
            title: "The Sprint Held Its Shape Under Load",
            description:
              "227 subagents were dispatched across the build. 52 stories, 387 acceptance criteria, 285 BDD rules, 145 Three Amigos questions, and 171 architecture components went through the harness. The densest stretch, July 19 to 20, carried 59 commits in 46 hours and included both the largest feature commit of the project and a full architectural teardown, without the test suite going red for long enough to matter."
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
            title: "The Renderer Lost the Same Fight Four Times",
            description:
              "An experimental CSS-3D mode hit 60fps using nothing but HTML divs, which was exciting and did not scale. The next eight hours were a retreat conducted in good order: level-of-detail swapping at the disc edge, coarser far zoom with no hit-testing while dragging, windowing the fine layer around the view center, and finally a baked-texture canvas impostor with the coarse hexes deleted outright. Four rounds to reach impostor-first with zero DOM tiles. The commit message on the last fix reads phones stop drowning in hex divs."
          },
          %{
            title: "Specs Anchored to Turn Counts, and the Lesson Did Not Stick",
            description:
              "Nine city-loop specs were re-anchored from fixed turn counts to events on July 16. The same lesson had to be relearned three more times in separate commits over the following two days. A spec asserting after turn 6 is fragile the moment cadence changes. A spec asserting when the camp is struck is not. Nothing in the harness flags the fragile shape at review time, so it kept getting written."
          },
          %{
            title: "A Placeholder Cost a 39-File Rewrite of Same-Day Specs",
            description:
              "Tribute and banking were built against placeholder income. Wiring them to real city gold yields meant touching 39 files and rewriting nineteen spec files that had been authored that same morning. The specs held their shape and the stub underneath them did not, which is the correct failure mode but an expensive one. Building a whole economic subsystem against a fake number is a decision the harness should have surfaced as a risk."
          },
          %{
            title: "Several Fixes Took Three Passes",
            description:
              "Barbarian camp placement had to stop stealing claimed tiles, then obey an 8 to 15 hex band, then hold its spawn counter at cap so kills bought a three-turn grace. Board panning oscillated across three commits: degrade detail while panning, walk that back for capable machines, then finally scope the degradation to touch pans only. Copper was fixed twice, once live in production at 1am and again to make access mine-based and player-wide. Emergent systems do not converge on the first correction."
          },
          %{
            title: "QA Rules Were Written After They Cost an Afternoon",
            description:
              "Two one-line rules landed on July 16: no mix invocations at all during QA sessions, and kill the dev server by port and never by process pattern. Both exist because their absence burned real time first. They are good rules. They should have been in the harness before this build rather than discovered during it."
          },
          %{
            title: "Only 58 Percent of QA Attempts Passed First Look",
            description:
              "55 QA attempts across the build: 32 pass, 19 partial, 4 fail. Every story that was actually tested did end green, so the pass rate per story is 100 percent. The attempt-level number is the more honest one, and it says the first QA pass on a story is closer to a coin flip than a formality."
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
            title: "Twenty of Fifty-Two Stories Have No QA Record at All",
            description:
              "32 stories have a final QA attempt of pass. The other 20 have no QA attempt on record, and 0 of the 387 acceptance criteria are marked verified in the database. This build shipped to production seven times with 38 percent of its stories carrying no formal QA record and not one criterion formally checked off. The honest qualifier, which is not an excuse: those stories were not untested, they were tested by people. The game was live with playtesters filing issues from July 18, and roughly twenty commits exist because of what they found. What is missing is the record, not the testing. The harness cannot tell the difference between nobody checked this and twelve people played it for a week, and on this build that distinction is the whole story."
          },
          %{
            title: "The Case-Study Tooling Fabricated Its Own Evidence",
            description:
              "The script that exports harness records onto these pages did not derive three of its fields. It hard-coded status completed on every story, verified true on every acceptance criterion, and a passing final QA verdict on every story. Run unmodified against Broken Oaths it would have published 52 completed stories, 387 verified criteria, and a clean QA sweep. All three claims are false here, and the third is false for the 20 stories that were never formally tested. The script now reads all three from the database, and this page renders what it actually says. The uncomfortable part: a harness whose entire pitch is verified intent built the page that reports on itself, and the reporting layer was the least honest part of the stack."
          },
          %{
            title: "A Passing QA Sweep Blessed a Feature Deleted Fourteen Minutes Later",
            description:
              "QA briefs for three stories were filed at 16:15 on July 14 with screenshot evidence and a clean sweep. Fourteen minutes later the entire turn model was torn out: orders now execute immediately and the turn boundary only recharges movement, replacing the lockstep simultaneous resolution built that morning. Four spec files were rewritten, and their filenames still read boundary_then_everything_moves_at_once. QA confirmed the thing was built correctly. Playing it in a browser was what revealed it was the wrong thing to build."
          },
          %{
            title: "Weather Shipped and Was Pulled in Five Minutes",
            description:
              "A drifting cloud layer landed at 20:31 on July 13 and grew storm cells and lightning by 21:00. It was committed with the subject line about to be rolled back, kept for history, and 249 lines were removed at 21:05. Weather came back at 23:36 as an airspace layer of cloud hexes on the same mesh, one shell up, which is the design the rollback paid for. Cheap in absolute terms, and a reminder that nothing in the loop asked whether a cosmetic layer belonged on the critical path that day."
          },
          %{
            title: "The Harness Could Not File Its Own Bugs",
            description:
              "create_issue was broken by a deploy key, so nine framework issues were banked in a plain markdown file instead at 23:10 on July 13. The next morning two more complaints were filed against the architecture design run that had just generated the component specs being used. Nine issues sitting in a text file is a tooling gap, not a workaround, and it means the harness's own defect intake failed during the largest build it has ever run."
          },
          %{
            title: "The Feedback Widget Took Three Acts and Crashed the Game",
            description:
              "It was first mounted somewhere LiveView never rendered it, then simplified onto a deploy key with 287 deletions, then deleted outright and replaced with a generated support widget, which left dead references crashing the entire /play route until 14:45. The irony is load-bearing: that widget is the pipe every playtest report arrived through two days later. The most valuable QA channel in the build was the component that took three attempts to mount."
          }
        ]
      }
    ]
  },
  conclusion: %{
    title: "What Broken Oaths Changed About the Harness",
    takeaways: [
      %{
        title: "Testing and the Record of Testing Are Not the Same Thing",
        description:
          "Twenty stories carry no QA attempt and zero criteria are marked verified, yet the game was live in production with real players filing real bugs. Both facts are true. The harness has no way to represent human playtesting as evidence, so a build that was heavily tested reads as untested in its own database. The next experiment is an intake that treats a triaged player report as a first-class verification record against the story it touches, not as a support ticket that happens to produce a commit."
      },
      %{
        title: "Nothing Closes the Loop",
        description:
          "All 52 stories still sit at in_progress. So do Cleaner CRM's 21. No step in the workflow marks a story done when its QA passes and its code ships to production, which means the harness cannot answer what is finished from its own records. It also never noticed that 20 stories went untested, because it never asked. A completion gate that runs on deploy is the smallest useful fix here."
      },
      %{
        title: "Story-Level Green Is Not Build-Level Green",
        description:
          "Per-story QA is the harness's default unit of verification, and it went green on a 147-file batch with three reachable bugs in it. The fix was to run four end-to-end journeys as a player and then freeze them as permanent regression tests, and it worked immediately. The harness did not ask for that. Cross-story journey QA should be a required gate before a batch ships, not something the operator thinks to do."
      },
      %{
        title: "The Reporting Layer Needs the Same Bar as the Code",
        description:
          "The fixture exporter asserted completion, verification, and passing QA without reading any of them from the database, and it generated the three case studies already published on this site. Those pages need an audit. More generally, any tool that produces public claims about a build has to derive them or refuse to emit them, and that rule now applies to the harness's own marketing surface."
      },
      %{
        title: "Specs Should Be Anchored to Events, and Review Should Enforce It",
        description:
          "The turn-count fragility was found and fixed four separate times across two days. That is a mechanical pattern a review check can catch: a scenario asserting on an absolute tick or turn index is almost always the wrong shape when the cadence is still being tuned. Cheap to detect, and it would have saved four rounds on this build alone."
      },
      %{
        title: "High Human Input Is Not Automatically a Harness Failure",
        description:
          "I typed roughly three times the share here that I did on Cleaner CRM, and the reason is that this is a game I had been planning for years and intended to play myself. The characters went into taste and product judgment: whether the globe felt buttery, whether a world felt like resources everywhere, which of two defensible mechanics this game wanted. Measuring human involvement is useful. Treating a lower number as automatically better is not, and this build is the counterexample."
      }
    ],
    closing:
      "Twelve sprint days. 275 commits. 108,734 lines of Elixir, 52 stories, 387 acceptance criteria, 285 BDD rules, 279 executable spex, 227 subagents, seven production releases in eight days. I typed 58,535 characters against 23.3 million, which is 0.25 percent. Twenty of the fifty-two stories carry no QA record, zero criteria are marked verified, and the game has been live with real playtesters since day six. It is not finished. The immediate ask is players on the vassalization mechanic, the part the game is named after and the part that most needs other people's hands on it. Past that it keeps moving for a structural reason: Broken Oaths is the most complicated thing this harness has produced, which makes it the test bed for every revision to the harness itself. The case study does not close because the project does not close."
  }
}
