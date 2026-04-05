%{
  metadata: %{
    meta_title: "Ship Working Software with AI, Not Just Generate Code",
    meta_description:
      "The full methodology for shipping production software with AI — from stories through BDD specs, implementation, and application QA.",
    og_title: "The CodeMySpec Method - Ship Working Software with AI",
    og_description:
      "Generating code is the easy part. The CodeMySpec method covers the full loop — stories, architecture, BDD specs, implementation, and QA — so what you ship actually works.",
    canonical_url: "https://codemyspec.com/methodology",
    og_image: nil,
    author: "John Davenport",
    tags: [
      "methodology",
      "bdd",
      "verification",
      "ai-code-generation",
      "phoenix",
      "elixir",
      "qa",
      "acceptance-testing",
      "bounded-contexts",
      "claude-code",
      "mcp",
      "user-stories",
      "architecture"
    ]
  },
  hero: %{
    title: "The CodeMySpec Method",
    tagline: "Generating Code Is the Easy Part.",
    description:
      "AI can write code. But shipping working software? That takes stories, architecture, BDD specs, verified implementations, and QA. Here's the full loop."
  },
  problem: %{
    title: "The Problem: Code Generation Isn't Software",
    description:
      "Most AI coding tools stop at code generation. You get output that looks right, passes a vibe check, and falls apart in production.",
    points: [
      %{
        title: "No Verification",
        description:
          "Generated code compiles and maybe passes a few tests. But does it actually do what the user asked for? Nobody checks."
      },
      %{
        title: "No Traceability",
        description:
          "Requirements live in a chat thread. Architecture lives in the AI's head. When something breaks, there's no trail back to intent."
      },
      %{
        title: "No Feedback Loop",
        description:
          "When QA finds a bug, where does it go? Back into the same chat? A new prompt? There's no structured path from 'this is broken' to 'this is fixed.'"
      }
    ],
    conclusion:
      "AI code generation without verification is just sophisticated autocomplete. You need the full loop."
  },
  solution: %{
    title: "The Solution: The Full Loop",
    description:
      "Code generation is one step in a six-step process. Every step produces artifacts that the next step verifies against. Nothing ships without passing through the full loop.",
    approach: [
      "Stories define what 'done' looks like — with testable acceptance criteria",
      "BDD specs turn acceptance criteria into executable Gherkin scenarios",
      "Component specs and tests verify the implementation per bounded context",
      "Application QA verifies features work end-to-end in the running app",
      "Problems at any gate route back to the right level — story, design, or code"
    ],
    tagline: "Stories → Architecture → BDD Specs → Implementation → QA → Ship."
  },
  phases: [
    %{
      number: 1,
      title: "Stories",
      tagline: "Define what 'done' looks like",
      icon: "hero-clipboard-document-list",
      color: "purple",
      creates: "User stories with testable acceptance criteria",
      description:
        "The Stories MCP Server interviews you about requirements, generates stories with acceptance criteria, and tracks them through the development lifecycle. Stories link to bounded contexts and BDD specs automatically.",
      highlights: [
        "AI interviews you with a structured PM persona",
        "Generates stories with testable acceptance criteria",
        "Stories link to contexts and BDD specs automatically",
        "Track status throughout the development lifecycle"
      ],
      guide: %{
        title: "Managing User Stories",
        url: "/pages/managing-user-stories",
        status: :published
      }
    },
    %{
      number: 2,
      title: "Architecture",
      tagline: "Define bounded contexts and dependencies",
      icon: "hero-cube-transparent",
      color: "orange",
      creates: "Context boundaries, dependency graph, component spec stubs",
      description:
        "The Architect MCP Server designs bounded contexts, validates dependencies, and catches circular references before implementation begins. Component spec stubs are generated for each context.",
      highlights: [
        "AI designs bounded contexts with dependency validation",
        "Architecture review catches circular dependencies",
        "Component spec stubs generated per context",
        "Full dependency graph visualization"
      ],
      guide: %{
        title: "Managing Architecture",
        url: "/pages/managing-architecture",
        status: :published
      }
    },
    %{
      number: 3,
      title: "BDD Specs",
      tagline: "Turn acceptance criteria into executable scenarios",
      icon: "hero-beaker",
      color: "purple",
      creates: "Gherkin scenarios for each story's acceptance criteria",
      description:
        "AI generates one Gherkin scenario per acceptance criterion. These scenarios run against the actual application after implementation — they're the contract between stories and working software.",
      highlights: [
        "One Gherkin scenario per acceptance criterion",
        "Scenarios validated against story structure",
        "Execute against the running application",
        "BDD specs are the contract between stories and software"
      ],
      guide: %{
        title: "BDD Specs for AI-Generated Code",
        url: "/pages/bdd-specs-for-ai-generated-code",
        status: :published
      }
    },
    %{
      number: 4,
      title: "Implementation",
      tagline: "Specs → tests → code → green, per bounded context",
      icon: "hero-bolt",
      color: "orange",
      creates: "Component specs, tests, and implementation that passes all tests",
      description:
        "Session orchestrators handle the full spec → test → code → green loop. Component specs are generated from the context design, tests are written from specs, and implementation iterates until all tests pass.",
      highlights: [
        "Component specs generated from context design",
        "Tests written from specs — they fail first (TDD)",
        "AI implements and iterates until green",
        "Static analysis validates code quality"
      ],
      guide: %{
        title: "Writing Design Documents for AI",
        url: "/pages/writing-design-documents",
        status: :published
      }
    },
    %{
      number: 5,
      title: "BDD Verification",
      tagline: "Run BDD specs against the app — does it actually work?",
      icon: "hero-shield-check",
      color: "purple",
      creates: "Verified features that pass acceptance criteria against the running app",
      description:
        "BDD specs execute against the live application. Failures generate structured issues with reproduction steps, categorized by root cause: spec problem, design problem, or implementation bug. The feedback loop routes issues back to the right phase.",
      highlights: [
        "Specs execute against the live application",
        "Failures generate structured issues automatically",
        "Issues categorized by root cause",
        "Feedback loop routes to the right phase"
      ],
      guide: %{
        title: "Verification Over Writing Code",
        url: "/blog/verification-pipeline",
        status: :published
      }
    },
    %{
      number: 6,
      title: "Application QA",
      tagline: "Browser automation, screenshots, and end-to-end verification",
      icon: "hero-check-badge",
      color: "orange",
      creates: "QA results with screenshots, filed issues, ship-ready features",
      description:
        "The QA agent tests each story against the running application using browser automation. It clicks through flows, takes screenshots, and files structured issues for failures. Features ship when QA passes.",
      highlights: [
        "Browser automation tests each story",
        "Screenshots captured at key states",
        "Structured issues filed for failures",
        "Features ship when QA passes"
      ],
      guide: %{
        title: "Agentic QA Verification",
        url: "/blog/agentic-qa-verification",
        status: :published
      }
    }
  ],
  proof: %{
    title: "The Proof",
    description: "I built CodeMySpec using this method. Every feature went through the full loop.",
    evidence: [
      "Stories with acceptance criteria drive every feature",
      "Architecture review catches design problems before implementation",
      "BDD specs verify features do what users asked for",
      "Unit tests verify implementations match their specs",
      "Application QA catches what automated tests miss",
      "The feedback loop routes problems to the right level"
    ],
    tagline:
      "Every feature traces from story → BDD spec → implementation → QA. The loop is the methodology."
  },
  getting_started: %{
    title: "Get Started",
    description: "CodeMySpec works with Phoenix/Elixir projects. Set up takes about 30 minutes.",
    steps: [
      "Install CodeMySpec CLI",
      "AI interviews you and generates user stories",
      "Architect designs bounded contexts",
      "BDD specs generated from acceptance criteria",
      "Implementation sessions run the spec → test → code loop",
      "QA agent verifies features against the running app"
    ],
    cta: %{
      text: "Try CodeMySpec",
      url: "/users/register"
    }
  },
  faq: [
    %{
      question: "How is this different from just using Cursor/Copilot/Claude?",
      answer:
        "Those tools generate code. This is a methodology for shipping working software. Code generation is step 4 of 6. The verification steps — BDD specs and application QA — are what catch the problems that code generation introduces."
    },
    %{
      question: "Why BDD specs AND unit tests?",
      answer:
        "They catch different things. Unit tests verify the implementation matches its spec. BDD specs verify the feature does what the user asked for. You need both — unit tests passing doesn't mean the feature works."
    },
    %{
      question: "What if requirements change?",
      answer:
        "Update the story → BDD specs update → implementation changes flow through the same loop. Every change goes through verification. The traceability means you can see exactly what's affected."
    },
    %{
      question: "Isn't this a lot of overhead?",
      answer:
        "Less than you'd think. Most of the artifacts are generated. And it's far less overhead than debugging AI-generated code that passed a vibe check but doesn't actually work. The verification steps save more time than they cost."
    },
    %{
      question: "What happens when BDD specs or QA finds a problem?",
      answer:
        "Problems get filed as structured issues and routed to the right level. A code bug goes back to implementation. A spec mismatch goes back to design. A requirements gap goes back to the story. The feedback loop is the point."
    }
  ],
  related_content: [
    %{
      title: "Managing User Stories",
      url: "/pages/managing-user-stories",
      status: :published
    },
    %{
      title: "Managing Architecture",
      url: "/pages/managing-architecture",
      status: :published
    },
    %{
      title: "BDD Specs for AI-Generated Code",
      url: "/pages/bdd-specs-for-ai-generated-code",
      status: :published
    },
    %{
      title: "Writing Design Documents for AI",
      url: "/pages/writing-design-documents",
      status: :published
    },
    %{
      title: "Verification Over Writing Code",
      url: "/blog/verification-pipeline",
      status: :published
    },
    %{
      title: "MetricFlow Case Study",
      url: "/case-studies/metric-flow",
      status: :published
    }
  ]
}
