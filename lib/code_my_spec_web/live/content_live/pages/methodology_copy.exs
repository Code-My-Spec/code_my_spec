%{
  # Metadata from codemyspec_method.yaml
  metadata: %{
    meta_title: "Stop Fighting AI Drift, Control Context",
    meta_description:
      "Methodology for controlling AI code generation - from user stories, architecture, production code.",
    og_title: "The CodeMySpec Method - Design-Driven AI Development",
    og_description:
      "Stop fighting AI drift. The proven 5-phase methodology for building production apps with AI - stories, context mapping, design docs, tests, code.",
    og_image: nil,
    author: "John Davenport",
    tags: [
      "methodology",
      "design-driven-development",
      "ai-code-generation",
      "phoenix",
      "elixir",
      "context-mapping",
      "design-documents",
      "test-first",
      "vertical-slice",
      "claude-code",
      "mcp",
      "user-stories",
      "architecture"
    ]
  },
  hero: %{
    title: "The CodeMySpec Method",
    tagline: "Stop Fighting AI Drift. Control What Goes Into Context.",
    description:
      "The 5-phase methodology I use to build CodeMySpec with AI - from stories to production code."
  },
  problem: %{
    title: "The Problem: Compounding Drift",
    description:
      "AI drift compounds through reasoning layers. The farther the LLM's reasoning gets from your actual prompt, the more the output drifts from your intent.",
    points: [
      %{
        title: "Reasoning Drift",
        description:
          "LLM's reasoning slightly off from your intent → code generation is more off. Each inference step compounds the error."
      },
      %{
        title: "Documentation Drift",
        description:
          "Generate PRD → generate code from PRD → two layers of drift between your intent and the output."
      },
      %{
        title: "Process Drift",
        description:
          "Ask LLM to prescribe AND follow process → compounding error. Every time you ask the LLM to figure out the process, you add drift."
      }
    ],
    conclusion:
      "Every intermediate step adds drift. Every time you ask the LLM to figure out the process, you add drift."
  },
  solution: %{
    title: "The Solution: Control Context",
    description:
      "Remove drift by controlling exactly what goes into the LLM's context. No intermediate reasoning about requirements. No inventing process.",
    approach: [
      "Design documents define the specifications",
      "Tests define the validation",
      "LLM only generates code to match both"
    ],
    tagline: "Here's the spec, here are the tests, make them pass."
  },
  phases: [
    %{
      number: 1,
      title: "User Stories",
      tagline: "Define requirements in plain English",
      icon: "📝",
      color: "purple",
      creates: "`user_stories.md` with acceptance criteria",
      manual: %{
        description: "Write stories yourself or interview with AI",
        steps: [
          "Create user_stories.md in your repo",
          "Interview yourself about requirements",
          "Write stories in 'As a... I want... So that...' format",
          "Add specific, testable acceptance criteria"
        ],
        guide: %{
          title: "How to Manage User Stories",
          url: "/pages/managing-user-stories",
          status: :published
        }
      },
      automated: %{
        description: "Stories MCP Server handles interviews and generation",
        steps: [
          "AI interviews you about requirements with structured PM persona",
          "AI creates stories in database with full version history",
          "AI reviews stories for quality and completeness on demand",
          "Link stories to components automatically during design",
          "Track status (in_progress, completed, dirty) throughout lifecycle"
        ],
        guide: %{
          title: "Stories - AI-Managed Requirements",
          url: "/pages/stories-feature",
          status: :published
        }
      },
      example: %{
        title: "Story Schema Implementation",
        file: "lib/code_my_spec/stories/story.ex",
        description: "Ecto schema with versioning, locking, and component association"
      }
    },
    %{
      number: 2,
      title: "Context Mapping",
      tagline: "Map stories to Phoenix contexts",
      icon: "🗺️",
      color: "orange",
      creates: "Context boundaries, entity ownership, dependency graph",
      manual: %{
        description: "Map stories to Phoenix contexts using vertical slice architecture",
        steps: [
          "Group stories by entity ownership",
          "Apply business capability grouping within entity boundaries",
          "Keep contexts flat (no nested contexts)",
          "Identify components within each context",
          "Map dependencies between contexts"
        ],
        guide: %{
          title: "Context Mapping for AI Development",
          url: "/pages/managing-architecture",
          status: :published
        }
      },
      automated: %{
        description: "Architect MCP Server guides context design and validates dependencies",
        steps: [
          "AI interviews you about architecture with structured architect persona",
          "AI creates domain and coordination contexts in database",
          "AI validates dependencies and detects circular references",
          "Link stories to contexts automatically during design",
          "Track architectural health (orphaned contexts, dependency depth)",
          "Review architecture quality on demand with best practices validation"
        ],
        guide: %{
          title: "Architect - AI-Guided Context Design",
          url: "/pages/architect-mcp-feature",
          status: :published
        }
      },
      example: %{
        title: "Stories Context Design",
        file: ".code_my_spec/design/code_my_spec/stories.md",
        description: "Entity ownership, access patterns, public API, dependencies"
      }
    },
    %{
      number: 3,
      title: "Design Documents",
      tagline: "Write specifications that control AI context",
      icon: "📐",
      color: "purple",
      creates: "Structured markdown specs (purpose, entities, API, components, dependencies)",
      manual: %{
        description: "Write design docs following template structure",
        steps: [
          "Create docs/design/{app_name}/{context_name}.md",
          "Follow template structure (purpose, entities, access patterns, etc.)",
          "Be specific about behavior, edge cases, error handling",
          "Include acceptance criteria from relevant user stories",
          "List every component (file) that needs to be implemented",
          "Paste design document into AI context before asking for code"
        ],
        guide: %{
          title: "How to Write Design Documents for AI",
          url: "/pages/writing-design-documents",
          status: :published
        }
      },
      automated: %{
        description: "Design Sessions orchestrator generates validated designs from architecture",
        steps: [
          "AI generates context design from architecture and user stories",
          "System validates design against schema (required sections, dependencies)",
          "AI revises if validation fails, loops until design passes",
          "System spawns parallel component design sessions",
          "All designs committed to git with clear audit trail"
        ],
        guide: %{
          title: "Design Sessions - AI-Generated Specifications",
          url: "/pages/design-sessions-feature",
          status: :published
        }
      },
      example: %{
        title: "ContextDesign Schema",
        file: "lib/code_my_spec/documents/context_design.ex",
        description: "Embedded schema for parsing and storing design documents"
      }
    },
    %{
      number: 4,
      title: "Test Generation",
      tagline: "Generate tests from design documents",
      icon: "🧪",
      color: "orange",
      creates: "Test files, fixtures, integration tests",
      manual: %{
        description: "Write tests from design docs before implementation",
        steps: [
          "Read design document",
          "Write tests for each component's public API",
          "Include edge cases and error scenarios from acceptance criteria",
          "Create fixtures for test data",
          "Run tests (they should fail - no implementation yet)",
          "Paste design doc + failing tests into AI context for implementation"
        ],
        guide: %{
          title: "Test-First AI Code Generation",
          url: "/content/test_first_ai_generation",
          status: :planned
        }
      },
      automated: %{
        description: "Component Test Sessions orchestrator generates and validates tests",
        guide: %{
          title: "Component Test Sessions - Automated Test Generation",
          url: "/content/component_test_sessions",
          status: :planned
        }
      },
      example: %{
        title: "Stories Context Tests",
        file: "test/code_my_spec/stories_test.exs",
        description: "Comprehensive tests for public API, edge cases, error handling"
      }
    },
    %{
      number: 5,
      title: "Code Generation",
      tagline: "Generate code that makes tests pass",
      icon: "⚡",
      color: "purple",
      creates: "Implementation that passes tests",
      manual: %{
        description: "Paste design + tests into LLM, iterate until green",
        steps: [
          "Paste design document into AI context",
          "Paste failing tests into AI context",
          "Ask AI to implement each component following the design",
          "Run tests",
          "If tests fail, paste errors back to AI and ask for fixes",
          "Iterate until all tests pass",
          "Commit with clear message referencing design doc and tests"
        ],
        guide: %{
          title: "Design-Driven Code Generation with AI",
          url: "/content/design_driven_code_generation",
          status: :draft
        }
      },
      automated: %{
        description: "Component Coding Sessions orchestrator implements and iterates until green",
        guide: %{
          title: "Component Coding Sessions - Full Automation",
          url: "/content/component_coding_sessions",
          status: :planned
        }
      },
      example: %{
        title: "Stories Context Implementation",
        file: "lib/code_my_spec/stories.ex",
        description: "Public API generated from design doc, validated by tests"
      }
    }
  ],
  proof: %{
    title: "The Proof",
    description: "I built CodeMySpec using this method. The codebase is the proof.",
    evidence: [
      "Stories context: Generated from design docs",
      "Components context: Generated from design docs",
      "Sessions orchestration: Generated from design docs",
      "MCP servers: Generated from design docs",
      "This entire application: Built with the product"
    ],
    tagline:
      "Every module links back to a design document. Every design document links back to user stories.",
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
          "Read \"Managing User Stories\" guide",
          "Create user_stories.md",
          "Map contexts",
          "Write one design doc",
          "Write tests",
          "Generate code with design + tests"
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
          "Want maximum speed",
          "Trust the automated workflow",
          "Medium/large projects"
        ],
        steps: [
          "Install CodeMySpec",
          "Run setup session",
          "Interview generates stories",
          "Review generated designs",
          "Approve and generate code"
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
      question: "What if requirements change?",
      answer:
        "Update stories → regenerate designs → update tests → regenerate code. Version control shows impact. The process supports change."
    },
    %{
      question: "What about other frameworks?",
      answer: "Manual process works anywhere. Automation is Phoenix/Elixir only (for now)."
    },
    %{
      question: "Do I need MCP servers?",
      answer: "No. Manual process is copy-paste. MCP removes tedium."
    },
    %{
      question: "How is this different from Cursor/Windsurf/etc?",
      answer: "They optimize prompts. This controls context. Different approach."
    },
    %{
      question: "What if AI still generates wrong code?",
      answer:
        "Tests catch it. Iterate until green. If repeatedly failing, refine design. Tests are the validation gate."
    },
    %{
      question: "Isn't this a lot of overhead?",
      answer:
        "Less overhead than refactoring AI-generated technical debt. Manual process takes time; automation removes overhead."
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
        title: "Writing Design Documents for AI",
        url: "/content/writing-design-documents",
        status: :published
      },
      %{
        title: "Complete Workflow Walkthrough",
        url: "/content/workflow_walkthrough",
        status: :planned
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
        title: "Building a Components MCP Server",
        url: "/content/components_mcp_server",
        status: :draft
      },
      %{
        title: "Session Orchestration in Phoenix",
        url: "/content/session_orchestration",
        status: :planned
      },
      %{
        title: "CodeMySpec Product Introduction",
        url: "/content/codemyspec_introduction",
        status: :planned
      }
    ]
  }
}
