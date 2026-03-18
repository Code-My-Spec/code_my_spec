%{
  metadata: %{
    meta_title: "Ship Working Software with AI, Not Just Generate Code",
    meta_description:
      "The full methodology for shipping production software with AI — from stories through BDD specs, implementation, and application QA.",
    og_title: "The CodeMySpec Method - Ship Working Software with AI",
    og_description:
      "Generating code is the easy part. The CodeMySpec method covers the full loop — stories, architecture, BDD specs, implementation, and QA — so what you ship actually works.",
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
      icon: "📝",
      color: "purple",
      creates: "User stories with testable acceptance criteria",
      manual: %{
        description: "Write stories yourself or interview with AI",
        steps: [
          "Write stories in 'As a... I want... So that...' format",
          "Add specific, testable acceptance criteria to each story",
          "Acceptance criteria become the source of truth for BDD specs and QA",
          "Group stories by feature or workflow"
        ],
        guide: %{
          title: "How to Manage User Stories",
          url: "/pages/managing-user-stories",
          status: :published
        }
      },
      automated: %{
        description: "Stories MCP Server handles interviews, generation, and lifecycle",
        steps: [
          "AI interviews you about requirements with structured PM persona",
          "AI creates stories with acceptance criteria and version history",
          "Stories link to bounded contexts and BDD specs automatically",
          "Track status throughout the development lifecycle"
        ],
        guide: %{
          title: "Stories - AI-Managed Requirements",
          url: "/pages/stories-feature",
          status: :published
        }
      },
      example: %{
        title: "Story with Acceptance Criteria",
        file: "lib/code_my_spec/stories/story.ex",
        description: "Ecto schema with acceptance criteria that drive BDD spec generation"
      }
    },
    %{
      number: 2,
      title: "Architecture",
      tagline: "Define bounded contexts and dependencies",
      icon: "🏗️",
      color: "orange",
      creates: "Context boundaries, dependency graph, component spec stubs",
      manual: %{
        description: "Map stories to bounded contexts, define dependencies",
        steps: [
          "Group stories by entity ownership into bounded contexts",
          "Map dependencies between contexts",
          "Identify components within each context",
          "Generate spec stubs for each component",
          "Architecture review validates the design before implementation begins"
        ],
        guide: %{
          title: "Context Mapping for AI Development",
          url: "/pages/managing-architecture",
          status: :published
        }
      },
      automated: %{
        description: "Architect MCP Server designs contexts and validates dependencies",
        steps: [
          "AI interviews you about architecture with structured architect persona",
          "AI creates bounded contexts with dependency validation",
          "Architecture review catches circular dependencies and orphaned contexts",
          "Component spec stubs generated for each context"
        ],
        guide: %{
          title: "Architect - AI-Guided Context Design",
          url: "/pages/architect-mcp-feature",
          status: :published
        }
      },
      example: %{
        title: "Requirements Context Design",
        file: ".code_my_spec/design/code_my_spec/requirements.md",
        description: "Bounded context with checkers, definitions, and dependency graph"
      }
    },
    %{
      number: 3,
      title: "BDD Specs",
      tagline: "Turn acceptance criteria into executable scenarios",
      icon: "🎯",
      color: "purple",
      creates: "Gherkin scenarios for each story's acceptance criteria",
      manual: %{
        description: "Write Gherkin scenarios from acceptance criteria",
        steps: [
          "Take each acceptance criterion from the story",
          "Write a Given/When/Then scenario for each criterion",
          "Scenarios test the feature from the user's perspective",
          "These run against the actual application after implementation",
          "BDD specs are the contract between stories and working software"
        ],
        guide: %{
          title: "BDD Specs for AI-Generated Code",
          url: "/pages/bdd-specs-for-ai-generated-code",
          status: :published
        }
      },
      automated: %{
        description: "BDD spec generation from story acceptance criteria",
        steps: [
          "AI generates one Gherkin scenario per acceptance criterion",
          "Scenarios validated against story structure",
          "Fixture generation for test data",
          "Specs execute against the running application after implementation"
        ],
        guide: %{
          title: "BDD Specification Lifecycle",
          url: "/content/bdd-specification-lifecycle",
          status: :planned
        }
      },
      example: %{
        title: "Story QA Spec",
        file: "test/code_my_spec/bdd_specs/",
        description: "Executable Gherkin scenarios generated from acceptance criteria"
      }
    },
    %{
      number: 4,
      title: "Implementation",
      tagline: "Specs → tests → code → green, per bounded context",
      icon: "⚡",
      color: "orange",
      creates: "Component specs, tests, and implementation that passes all tests",
      manual: %{
        description: "For each bounded context: generate specs, write tests, implement, iterate until green",
        steps: [
          "Generate component specs from the context design",
          "Write tests from specs — they should fail (no implementation yet)",
          "Generate implementation from specs + failing tests",
          "Run tests — iterate until all pass",
          "Static analysis validates code quality",
          "Repeat for each bounded context the story touches"
        ],
        guide: %{
          title: "How to Write Design Documents for AI",
          url: "/pages/writing-design-documents",
          status: :published
        }
      },
      automated: %{
        description: "Session orchestrators handle the full spec → test → code → green loop",
        steps: [
          "Component spec sessions generate validated specs from context design",
          "Test sessions generate tests from specs",
          "Coding sessions implement and iterate until green",
          "Static analysis pipeline validates the result",
          "All sessions tracked with full audit trail"
        ],
        guide: %{
          title: "Design Sessions - AI-Generated Specifications",
          url: "/pages/design-sessions-feature",
          status: :published
        }
      },
      example: %{
        title: "Requirements Context Implementation",
        file: "lib/code_my_spec/requirements/",
        description: "Spec → test → implementation chain with checkers and definitions"
      }
    },
    %{
      number: 5,
      title: "BDD Verification",
      tagline: "Run BDD specs against the app — does it actually work?",
      icon: "🧪",
      color: "purple",
      creates: "Verified features that pass acceptance criteria against the running app",
      manual: %{
        description: "Run BDD specs against the application, file issues for failures",
        steps: [
          "Run Gherkin scenarios against the running application",
          "Each scenario exercises the feature from the user's perspective",
          "Failures trace back to specific acceptance criteria",
          "Issues route to the right level: story problem, design problem, or code bug",
          "Iterate until all BDD specs pass"
        ],
        guide: %{
          title: "Verification Over Writing Code",
          url: "/blog/verification-pipeline",
          status: :published
        }
      },
      automated: %{
        description: "BDD execution engine runs specs and files structured issues",
        steps: [
          "Specs execute against the live application automatically",
          "Failures generate structured issues with reproduction steps",
          "Issues categorized by root cause: spec, design, or implementation",
          "Feedback loop routes issues back to the appropriate phase"
        ],
        guide: %{
          title: "BDD Verification Pipeline",
          url: "/content/bdd-verification-pipeline",
          status: :planned
        }
      },
      example: %{
        title: "BDD Spec Execution",
        file: "lib/code_my_spec/bdd_specs/",
        description: "Executable scenarios that verify features against the running app"
      }
    },
    %{
      number: 6,
      title: "Application QA",
      tagline: "Browser automation, screenshots, and end-to-end verification",
      icon: "✅",
      color: "orange",
      creates: "QA results with screenshots, filed issues, ship-ready features",
      manual: %{
        description: "QA the running application against each story",
        steps: [
          "Walk through each story's acceptance criteria in the running app",
          "Take screenshots of key states",
          "File structured issues for anything that doesn't match the story",
          "Issues feed back into the development loop",
          "Feature ships when QA passes"
        ],
        guide: %{
          title: "Agentic QA Testing",
          url: "/content/agentic-qa",
          status: :draft
        }
      },
      automated: %{
        description: "QA agent tests stories against the running application with browser automation",
        steps: [
          "Agent reads story and acceptance criteria",
          "Creates test brief and executes against the live app",
          "Browser automation clicks through flows, takes screenshots",
          "Structured issues filed automatically for failures",
          "Journey QA tests end-to-end flows spanning multiple features"
        ],
        guide: %{
          title: "Application QA - Automated Verification",
          url: "/content/application-qa",
          status: :planned
        }
      },
      example: %{
        title: "Story QA Session",
        file: ".code_my_spec/status/qa/",
        description: "QA results with screenshots, issues, and pass/fail per acceptance criterion"
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
      "Every feature traces from story → BDD spec → implementation → QA. The loop is the methodology.",
    repo_url: "https://github.com/yourusername/code_my_spec"
  },
  getting_started: %{
    title: "Getting Started",
    paths: [
      %{
        name: "Manual Process",
        description: "Learn the methodology, works with any framework",
        time: "2-4 hours to learn",
        best_for: [
          "Learning the method",
          "Non-Phoenix projects",
          "Small projects",
          "Prefer more control"
        ],
        steps: [
          "Write user stories with testable acceptance criteria",
          "Map stories to bounded contexts",
          "Write BDD scenarios from acceptance criteria",
          "Generate specs, tests, and code per context",
          "Run BDD specs against the running app",
          "QA each story before shipping"
        ],
        cta: %{
          text: "Start with Manual Process",
          url: "/pages/managing_user_stories"
        }
      },
      %{
        name: "Automated Workflow",
        description: "Full automation with CodeMySpec, Phoenix/Elixir only",
        time: "30 minutes setup",
        best_for: [
          "Phoenix/Elixir projects",
          "Want the full loop automated",
          "Medium/large projects",
          "Teams that need traceability"
        ],
        steps: [
          "Install CodeMySpec",
          "AI interviews you → generates stories",
          "Architect designs bounded contexts",
          "BDD specs generated from acceptance criteria",
          "Implementation sessions run the spec → test → code loop",
          "QA agent verifies features against the running app"
        ],
        cta: %{
          text: "Try CodeMySpec",
          url: "/users/register"
        }
      }
    ]
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
      question: "What about other frameworks?",
      answer: "The manual process works with any language or framework. The automated workflow is Phoenix/Elixir only (for now)."
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
  related_content: %{
    main_quest: [
      %{
        title: "Managing User Stories",
        url: "/content/managing-user-stories",
        status: :published
      },
      %{
        title: "Context Mapping for AI Development",
        url: "/content/managing-architecture",
        status: :published
      },
      %{
        title: "BDD Specs for AI-Generated Code",
        url: "/pages/bdd-specs-for-ai-generated-code",
        status: :published
      },
      %{
        title: "Writing Design Documents for AI",
        url: "/content/writing-design-documents",
        status: :published
      }
    ],
    side_quest: [
      %{
        title: "Stories - AI-Managed Requirements",
        url: "/content/product-manager-mcp-feature",
        status: :published
      },
      %{
        title: "Architect - AI-Guided Context Design",
        url: "/content/architect-mcp-feature",
        status: :published
      },
      %{
        title: "Design Sessions - AI-Generated Specifications",
        url: "/content/design-sessions-feature",
        status: :published
      },
      %{
        title: "Verification Over Writing Code",
        url: "/blog/verification-pipeline",
        status: :published
      },
      %{
        title: "Application QA - Automated Verification",
        url: "/content/application-qa",
        status: :planned
      }
    ]
  }
}
