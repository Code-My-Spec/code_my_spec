%{
  metadata: %{
    meta_title: "MetricFlow Case Study: Zero Human-Written Code, 40 Commits, 13 Days",
    meta_description:
      "How CodeMySpec built MetricFlow: a full-stack Phoenix analytics platform with OAuth integrations, AI insights, and multi-tenant accounts. Zero human-written code. This is an honest assessment of the process.",
    og_title: "MetricFlow Case Study - AI-Driven Development in Practice",
    og_description:
      "A full-stack Phoenix app built entirely by AI agents. 40 commits, 13 working days, zero human-written code. Here's the honest story.",
    og_image: nil,
    author: "John Davenport",
    tags: [
      "case-study",
      "metricflow",
      "analytics",
      "phoenix",
      "elixir",
      "ai-development",
      "bdd",
      "google-analytics",
      "quickbooks",
      "software-factory"
    ]
  },
  hero: %{
    title: "MetricFlow",
    tagline: "Zero Human-Written Code. One Honest Assessment.",
    description:
      "A Phoenix LiveView marketing analytics platform with OAuth integrations, multi-tenant accounts, correlation analysis, and AI insights. Built entirely by CodeMySpec agents. 100% of the code was generated. 90% of the orchestration was autonomous.",
    stats: [
      %{label: "Commits", value: "40"},
      %{label: "Working Days", value: "13"},
      %{label: "Human Code", value: "0 lines"},
      %{label: "Integrations", value: "5 platforms"}
    ]
  },
  overview: %{
    title: "What is MetricFlow?",
    description:
      "MetricFlow is a Phoenix LiveView marketing analytics platform that correlates advertising spend across Google Ads, Facebook Ads, and Google Analytics with revenue data from QuickBooks. It offers multi-tenant accounts with role-based access, OAuth integrations for five platforms, correlation analysis with AI-powered insights, interactive Vega-Lite dashboards, and an AI chat interface for data exploration.",
    integrations: [
      %{
        name: "Google Analytics",
        description: "Website traffic, user behavior, and conversion tracking",
        icon: "hero-chart-bar"
      },
      %{
        name: "Google Ads",
        description: "Advertising spend, campaign performance, and ROI tracking",
        icon: "hero-cursor-arrow-rays"
      },
      %{
        name: "Google Search Console",
        description: "Search performance, indexing status, and keyword rankings",
        icon: "hero-magnifying-glass"
      },
      %{
        name: "QuickBooks",
        description: "Revenue, expenses, daily credit/debit breakdowns",
        icon: "hero-currency-dollar"
      },
      %{
        name: "Facebook Ads",
        description: "Ad performance, reach, and campaign ROI",
        icon: "hero-megaphone"
      }
    ],
    key_features: [
      "Correlation analysis engine: raw and SmartAI modes with goal configuration",
      "Interactive Vega-Lite dashboards with date range controls and platform filters",
      "Multi-tenant accounts with agency white-labeling and client management",
      "Automated daily data sync with Oban job processing",
      "LLM-generated custom reports from natural language prompts",
      "AI chat interface for data exploration",
      "Full BDD specification framework with automated QA"
    ]
  },
  repository: %{
    title: "Open Source Repository",
    description:
      "MetricFlow is fully open source. Browse the code, check the commit history, and see the methodology in action.",
    url: "https://github.com/Code-My-Spec/metric_flow",
    stats: [
      %{label: "Language", value: "Elixir / Phoenix"},
      %{label: "Database", value: "PostgreSQL"},
      %{label: "Job Processing", value: "Oban"},
      %{label: "Auth", value: "OAuth2 + RBAC"}
    ]
  },
  dev_story: %{
    title: "The Dev Story",
    subtitle: "The Good, The Bad, and The Ugly",
    description:
      "An honest assessment of building a full-stack application with a software factory. The calendar span is January 30 to March 20, 2026, but the actual work happened across just 13 days.",
    sections: [
      %{
        id: "good",
        label: "The Good",
        icon: "hero-check-circle",
        color: "success",
        items: [
          %{
            title: "The Velocity Was Real",
            description:
              "The first commit landed on January 30: a Phoenix scaffold. Two days later, a 48-hour sprint laid down the entire foundation: Oban, Vault, PromEx, the BDD framework, and 25,000+ lines of specifications before a single line of business logic existed. By end of February, the core domain was complete: Accounts, Integrations, Metrics, DataSync with four providers, ~22,000 lines of unit tests, and 50+ BDD spex files."
          },
          %{
            title: "The Architecture Held Up",
            description:
              "Boundary-enforced module dependencies, context modules as the public API surface, %Scope{} threaded through every public function, repository pattern separating queries from business logic. The factory understood Phoenix conventions and produced idiomatic Elixir. The invitation system came with the full lifecycle (send, accept, cancel, role assignment, token invalidation) with appropriate authorization checks."
          },
          %{
            title: "The Dashboard Came Out Clean",
            description:
              "The dashboard redesign is a good example of what the factory can do when the spec is clear. It generated a multi-series Vega-Lite chart with date range controls, platform filters, data tables, and proper Phoenix hooks for CSP-safe rendering. The QueryBuilder that feeds it was clean, tested, and worked on the first deploy."
          },
          %{
            title: "QA Infrastructure Was the Best Output",
            description:
              "Over the final two weeks, automated Vibium browser agents ran QA scenarios against 25+ stories, producing hundreds of screenshots and structured pass/fail reports. The QA agents found real bugs (nil account guards, broken token invalidation, missing navigation links, role select defaults) and the coding agents fixed them in the same commit cycle."
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
            title: "Agency-to-Account Link Was Broken",
            description:
              "The white-label and agency features were structurally present but not wired together. The last two commits, written with heavy human guidance, finally connected agency accounts to client accounts and got auto-enrollment working. The factory had generated the Agencies context, the repository, and the WhiteLabelHook, but never connected them to the account settings UI."
          },
          %{
            title: "QuickBooks Data Sync Was Wrong",
            description:
              "The original QuickBooks provider fetched data in a format that didn't match how the correlation engine consumed it. An 8,000-line rewrite switched from aggregate fetches to daily credit/debit breakdowns. The factory's first attempt produced code that technically synced data but produced unusable correlation results. The cassette fixtures alone went from 352 to 7,708 lines."
          },
          %{
            title: "Visualizations Were Anemic",
            description:
              "The ReportGenerator generates Vega-Lite specs from natural language via LLM, but the generated reports are generic and not anchored to the user's actual data. You can't refine them by conversation. The saved visualizations had no useful index page; QA needed four failed attempts before the route even existed. The feature technically works but wouldn't survive contact with a real user."
          },
          %{
            title: "AI Chat Lacked Real Data Access",
            description:
              "The chat interface renders, accepts messages, saves history, and can call the LLM, but the context injection for metrics, correlations, and dashboards is stubbed. The QA agent marked it as passing because it could send and receive messages. The responses just aren't grounded in anything useful."
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
            title: "Integrations Were a Nightmare",
            description:
              "The integration code went through more QA iterations than every other feature combined. Connecting marketing platforms via OAuth had six failed QA runs before passing. Managing integrations had seven. Triggering data sync had twelve failed runs across two days. The problem was compounding failures: when the agent fights both broken integration code AND invalid OAuth tokens simultaneously, it papers over everything."
          },
          %{
            title: "Agents Built a Potemkin Village",
            description:
              "The coding agent would catch a FunctionClauseError, wrap it in try/catch, show a flash message saying \"connection successful,\" and move on. The QA agent would see the flash message and mark the scenario as passing. Both agents were collaborating to produce a Potemkin village of passing tests over broken functionality. The QA agent told me over and over that QA passed, and I'd go click through the integrations and find nothing actually worked."
          },
          %{
            title: "Google Provider Architecture Was Wrong",
            description:
              "The factory initially generated a single \"Google\" provider for Ads, Analytics, and Search Console through one OAuth flow. That's architecturally wrong; each Google product has different scopes, different account selection flows, and different API endpoints. A massive refactor to split them into separate providers had to be guided step by step. The factory couldn't reach this decision on its own because the spec said \"connect Google\" and it connected Google."
          },
          %{
            title: "Manual Debugging Was Unavoidable",
            description:
              "I eventually sat down for two days and QA'd the integrations with the agent by hand, pointing at each broken flow and walking it through the fix. That was the only way to get working integrations. These are all things a human would catch in five minutes of clicking around."
          }
        ]
      }
    ]
  },
  conclusion: %{
    title: "Lessons Learned",
    takeaways: [
      %{
        title: "QA Must Be Gate-Keeping, Not Advisory",
        description:
          "Failed QA initially produced reports but the pipeline continued. Even requiring passage wasn't enough; agents learned to make QA pass rather than make the code work. The fix: QA scenarios that test outcomes, not UI elements. \"Did the OAuth token exchange produce a valid access token?\" not \"Does the success flash message appear?\""
      },
      %{
        title: "Integrations Should Be Procedurally Generated",
        description:
          "Multi-tenancy and OAuth integrations are solved problems. They're the same everywhere. An LLM adds variance where you want consistency, and integrations are exactly the domain where variance kills you. Generators, not generation."
      },
      %{
        title: "Validate External Dependencies Before Code Gen",
        description:
          "When the factory generates a QuickBooks integration, it needs a working sandbox with valid credentials up front. When it discovers credential problems mid-generation, it papers over them. Let the machine generate code against a working foundation, not fight two problems at once."
      },
      %{
        title: "The Factory Produced a Working App (With Caveats)",
        description:
          "The bulk of MetricFlow works. Auth, account management, invitations, the dashboard, correlation analysis, data sync scheduling, the QA infrastructure: all functional. The output is best understood as a thorough first draft: architecturally sound, broadly functional, but with integration points that need human verification. 90% worked. The remaining 10% would never have shipped without a human clicking through it."
      }
    ],
    closing:
      "40 commits. 13 working days. Zero human-written code. The factory produced 100% of the code and did 90% of the orchestration without intervention. That's the headline number. The honest assessment: the structured approach (stories, specs, implementation, QA) turned a complex multi-provider platform into a manageable sequence of verified steps. But the last 10% required a human sitting down and clicking through it."
  }
}
