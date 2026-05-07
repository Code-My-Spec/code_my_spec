[
  %{
    story_id: 633,
    status: :completed,
    title: "Public Landing Page",
    description:
      "As a visitor I want a landing page that shows a real strategy artifact and a copy-paste install command without a sign-up wall, so that I can see and try the product before committing. Enforces the messaging guide: no enterprise framing, no banned phrases, BYO-Claude lives below the hero as a benefit line, and the agency CTA sits below the install path rather than at equal weight.",
    tags: [%{name: "marketing"}, %{name: "landing"}],
    criteria: [
      %{description: "Visitor sees a real strategy artifact in the hero", verified: true},
      %{description: "Hero with no artifact fails the proof-on-page bar", verified: true},
      %{description: "Visitor copies install command without an auth gate", verified: true},
      %{description: "Sign-up gate in front of install command is rejected", verified: true},
      %{description: "BYO-Claude lives below hero as a benefit line", verified: true},
      %{description: "Hero with BYO-Claude warning copy is rejected", verified: true},
      %{description: "Page passes the messaging-guide phrase audit", verified: true},
      %{description: "Draft with banned phrase or enterprise framing is rejected", verified: true},
      %{description: "Agency visitor finds the talk-to-john lane below install", verified: true},
      %{description: "Equal-weight agency CTA next to install is rejected", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 634,
    status: :completed,
    title: "MCP Setup Guide",
    description:
      "As a new user I want a guide that walks me top-to-bottom from install to first interview with explicit verification steps so that I can ship my first marketing-strategy interview without external help. Three required troubleshooting blocks are mandatory; pages without them fail the audit.",
    tags: [%{name: "onboarding"}, %{name: "documentation"}],
    criteria: [
      %{
        description: "New user follows guide top-to-bottom and ships first interview",
        verified: true
      },
      %{description: "Page lacking expected-result verification step is rejected", verified: true},
      %{
        description: "User hits port conflict and recovers via troubleshooting block",
        verified: true
      },
      %{
        description:
          "Page missing one of the three required troubleshooting blocks is rejected",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 609,
    status: :completed,
    title: "Sign Up And Sign In With Email Magic Link",
    description:
      "As a new visitor I want to sign up and sign in with a magic-link email so that I never have to choose or remember a password. Shipped on the BDD-only configurable-workflow path: Three Amigos session, six BDD criterion specs, twelve implementation files. No spec_review, no unit_test, no module_spec layers — workflow knobs were OFF for this surface.",
    tags: [
      %{name: "configurable-workflow"},
      %{name: "auth"},
      %{name: "bdd-only-path"}
    ],
    criteria: [
      %{description: "New visitor signs up via magic link end-to-end", verified: true},
      %{description: "Invalid email format is caught before submission", verified: true},
      %{description: "Returning user signs in with a fresh magic link", verified: true},
      %{
        description: "Expired or consumed magic link surfaces a recoverable error",
        verified: true
      },
      %{
        description: "Login page renders only the magic-link form (password form removed)",
        verified: true
      },
      %{description: "Direct POST to password endpoint is rejected", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 672,
    status: :completed,
    title: "Sign Up And Sign In With Google",
    description:
      "As a new visitor I want one-click Google sign-up and sign-in so that I can start without a password. Handles consent denial, email change, and missing sub claim cleanly.",
    tags: [%{name: "auth"}, %{name: "oauth"}],
    criteria: [
      %{description: "New visitor signs up via Google in one click", verified: true},
      %{description: "User denies Google consent and recovers cleanly", verified: true},
      %{
        description:
          "User changes Google email and still resolves to the same MMS account",
        verified: true
      },
      %{description: "Callback missing sub claim is rejected", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 673,
    status: :completed,
    title: "Sign Up And Sign In With GitHub",
    description:
      "As a developer I want one-click GitHub sign-up and sign-in so that I can start without a password. Handles cancellation, private email, and missing user_id cleanly.",
    tags: [%{name: "auth"}, %{name: "oauth"}],
    criteria: [
      %{description: "Developer signs up via GitHub in one click", verified: true},
      %{description: "User cancels GitHub authorization and recovers cleanly", verified: true},
      %{description: "User with private GitHub email still resolves consistently", verified: true},
      %{description: "Callback missing GitHub user_id is rejected", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 611,
    status: :completed,
    title: "View MCP Connection Instructions",
    description:
      "As a signed-in user I want a single page showing the install command and bearer token so that I can connect Claude Code to MMS in seconds. Anonymous visitors get bounced through sign-in first; the response body never leaks connection details to unauthenticated requests.",
    tags: [%{name: "mcp"}, %{name: "onboarding"}],
    criteria: [
      %{
        description: "Signed-in user lands on /mcp-setup with everything they need",
        verified: true
      },
      %{description: "Page missing server URL or install command is rejected", verified: true},
      %{
        description: "Anonymous visitor is bounced through sign-in to /mcp-setup",
        verified: true
      },
      %{
        description: "Anonymous request gets no connection details in the response body",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 612,
    status: :completed,
    title: "OAuth Authentication For MCP Connection",
    description:
      "As a Claude Code instance I need to complete OAuth, hold a bearer token, and have it validated on every MCP request so that the connection between agent and server is end-to-end authenticated. Covers RFC 9728 discovery, dynamic client registration, PKCE validation, expired-token re-auth, and token revocation.",
    tags: [%{name: "mcp"}, %{name: "auth"}, %{name: "oauth"}],
    criteria: [
      %{
        description: "Claude Code completes OAuth and receives a bearer token",
        verified: true
      },
      %{description: "Token request with bad PKCE verifier is rejected", verified: true},
      %{
        description: "MCP client auto-discovers endpoints via well-known metadata",
        verified: true
      },
      %{description: "Metadata document missing endpoints fails discovery", verified: true},
      %{description: "MCP request with valid bearer is authenticated", verified: true},
      %{description: "Expired bearer token returns 401 with re-auth pointer", verified: true},
      %{description: "Claude Code self-registers as an OAuth client", verified: true},
      %{description: "Registration request without redirect URIs is rejected", verified: true},
      %{description: "User revokes a token and the MCP endpoint rejects it", verified: true},
      %{description: "Revoke request with invalid token format is rejected", verified: true},
      %{description: "MCP client discovers auth server from MCP endpoint URL", verified: true},
      %{
        description: "Document missing authorization servers fails RFC 9728 validation",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 678,
    status: :completed,
    title: "Multi-Tenant Account Architecture",
    description:
      "As a user of Market My Spec I want my work scoped to an account so that I can keep marketing strategies separate, share an account with collaborators, and (for agencies) hold multiple client accounts under one operator. The clearest demonstration of the harness's new Three Amigos gate: the agent surfaced four open questions about agency-vs-individual UX, John resolved them in plain English, and the agent then added a new rule capturing the product decision before closing the readiness gate.",
    tags: [
      %{name: "three-amigos"},
      %{name: "multi-tenant"},
      %{name: "accounts"}
    ],
    criteria: [
      %{description: "New user gets a default individual account on sign-up", verified: true},
      %{
        description: "User with no account membership is redirected to account creation",
        verified: true
      },
      %{description: "Account creator is automatically the owner", verified: true},
      %{description: "Invited user receives exactly one role in the account", verified: true},
      %{description: "Adding an existing member a second time is rejected", verified: true},
      %{
        description: "Two members in the same account see the same MCP connection",
        verified: true
      },
      %{description: "Switching accounts changes the data context", verified: true},
      %{description: "Account name produces a URL-safe slug on creation", verified: true},
      %{description: "Duplicate slug is rejected at creation", verified: true},
      %{description: "Individual account does not show agency features", verified: true},
      %{description: "Agency account unlocks agency features", verified: true},
      %{
        description:
          "Self-service account creation always produces an individual account",
        verified: true
      },
      %{
        description: "Admin-provisioned agency account unlocks agency features",
        verified: true
      },
      %{
        description:
          "New user is sent to explicit account creation before reaching the dashboard",
        verified: true
      },
      %{
        description: "User switches accounts via a dedicated account picker page",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: %{
        name: "Agency Owner Alex",
        slug: "agency-owner",
        type: "proto"
      },
      rules: [
        %{
          statement:
            "A user must belong to at least one account before they can access any platform features",
          scenarios: []
        },
        %{
          statement: "The user who creates an account is automatically assigned the owner role",
          scenarios: [
            %{
              title: "Account creator is automatically the owner",
              kind: :happy_path,
              body: """
              Given an authenticated user
              When they create a new account named "Acme Agency"
              Then an account_members record is created for that user on the new account
              And the role on that record is "owner"
              """
            }
          ]
        },
        %{
          statement: "A user holds exactly one role within a given account (owner, admin, or member)",
          scenarios: []
        },
        %{
          statement:
            "All platform data — MCP connections, strategy artifacts, and settings — belongs to the account, not the individual user",
          scenarios: []
        },
        %{
          statement:
            "A user with multiple accounts operates within exactly one current account context at a time; all reads and writes are scoped to that context",
          scenarios: []
        },
        %{
          statement: "Account slugs are globally unique and URL-safe; once set they cannot be changed",
          scenarios: []
        },
        %{
          statement:
            "Account type (individual or agency) is fixed at creation and gates which features are available to that account",
          scenarios: []
        },
        %{
          statement:
            "Agency accounts are admin-provisioned only; the self-service account creation form produces individual accounts exclusively — users cannot self-select the agency type",
          scenarios: [
            %{
              title: "Self-service account creation always produces an individual account",
              kind: :happy_path,
              body: nil
            }
          ]
        }
      ],
      questions: [
        %{
          body:
            "On sign-up, does a default individual account auto-create silently, or does the user go through an explicit \"create your first account\" step?",
          status: :resolved,
          resolution:
            "Explicit step. The user goes through a create-your-first-account flow with an account type and name."
        },
        %{
          body:
            "Can an account owner change account type from individual to agency after creation? The rule says type is fixed at creation — but if an existing solo user wants to upgrade to agency, what's the path?",
          status: :resolved,
          resolution:
            "No self-service upgrade. Agency accounts are admin-provisioned only; existing solo users have to talk to John and make a deal."
        },
        %{
          body:
            "What is the UX for account switching when a user belongs to multiple accounts — a nav dropdown, a separate accounts landing page, or per-account URLs?",
          status: :resolved,
          resolution:
            "Separate page for the account picker. UI dropdowns for account switching have caused too many problems in past products."
        },
        %{
          body:
            "Existing users have no account record. When multi-tenancy lands, does a migration backfill a default individual account for every existing user, or is a manual onboarding step required?",
          status: :resolved,
          resolution:
            "No backfill needed. The whole application is net new; there are no existing users to migrate."
        }
      ],
      note:
        "Excerpted from the project records for this case study. Eight scenarios were authored across these rules; only the bodied scenario and the named scenario shown above are quoted here. The full set lives in the harness."
    }
  },
  %{
    story_id: 679,
    status: :completed,
    title: "Agency Account Type And Client Dashboard",
    description:
      "As an agency operator I want a client management dashboard so that I can grant or revoke agency access to client accounts, walk into a client account from the dashboard, and have agency team members navigate into client accounts with appropriate permissions. Originator access grants are immutable; either party can revoke a non-originator grant.",
    tags: [
      %{name: "three-amigos"},
      %{name: "multi-tenant"},
      %{name: "agency"}
    ],
    criteria: [
      %{description: "Agency user sees the client management dashboard", verified: true},
      %{
        description: "Individual account user cannot access the agency dashboard",
        verified: true
      },
      %{description: "Agency creates a client account and becomes the originator", verified: true},
      %{description: "Originator access grant cannot be revoked", verified: true},
      %{description: "Client account grants an agency invited access", verified: true},
      %{description: "Either party can revoke an invited access grant", verified: true},
      %{description: "Agency owner enters a client account from the dashboard", verified: true},
      %{
        description: "Read-only agency user cannot modify client account settings",
        verified: true
      },
      %{
        description:
          "Attempting to grant access for an already-granted agency-client pair is rejected",
        verified: true
      },
      %{description: "Dashboard rows show name and access level only", verified: true},
      %{description: "Agency team member navigates into a client account", verified: true},
      %{
        description:
          "Dashboard shows all client accounts with name and access level",
        verified: true
      },
      %{description: "Dashboard variant with a status column is rejected", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: %{
        name: "Agency Owner Alex",
        slug: "agency-owner",
        type: "proto"
      },
      rules: [],
      questions: [],
      note:
        "Six rules covering agency-management UX were authored; details are not included in this case study excerpt. The protocol completed roughly seven minutes after story 678's Three Amigos session, demonstrating the pattern's repeatability."
    }
  },
  %{
    story_id: 674,
    status: :completed,
    title: "Start A Marketing Strategy Interview",
    description:
      "As a user I want to invoke the marketing-strategy skill from my agent and have the agent load the playbook, skim my project context, ask one question at a time, and ground persona research in real evidence. The skill is industry-aware (a restaurant gets restaurant examples, not SaaS-by-default) and resilient — a user bailing after step 3 still finds three usable artifacts on disk.",
    tags: [%{name: "skill"}, %{name: "strategy"}],
    criteria: [
      %{
        description: "User runs marketing-strategy and the agent loads the playbook",
        verified: true
      },
      %{description: "Slash-command invocation without bearer fails clearly", verified: true},
      %{
        description: "Agent skims project context before asking the first question",
        verified: true
      },
      %{
        description: "Skipping orient and asking interview questions cold is rejected",
        verified: true
      },
      %{
        description:
          "Restaurant owner gets restaurant examples and one-question cadence",
        verified: true
      },
      %{
        description: "SaaS-default examples for a non-SaaS user are rejected",
        verified: true
      },
      %{
        description: "User bails after step 3 and finds three usable artifacts on disk",
        verified: true
      },
      %{description: "Batched end-of-run artifact writes are rejected", verified: true},
      %{
        description:
          "Step 3 dispatches research subagents and grounds personas in evidence",
        verified: true
      },
      %{
        description: "Persona file with no supporting research artifacts is rejected",
        verified: true
      },
      %{
        description:
          "User asks for a blog post and the agent deflects to downstream content",
        verified: true
      },
      %{
        description:
          "Agent silently producing a 40-slide deck or setting up analytics is rejected",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 675,
    status: :completed,
    title: "Skill Behavior Exposed Over MCP SSE",
    description:
      "As an MCP-enabled agent I need to initialize a session over SSE, list resources, invoke skills, read step files on demand, and have path-traversal attempts rejected before any filesystem read. The skill content mirrors the canonical plugin file tree.",
    tags: [%{name: "mcp"}, %{name: "skill"}],
    criteria: [
      %{description: "MCP session initializes over SSE and serves resources", verified: true},
      %{description: "Plain non-SSE client cannot read resource bodies", verified: true},
      %{description: "Agent invokes marketing-strategy and receives SKILL.md", verified: true},
      %{description: "Invoking an unknown skill returns a clear MCP error", verified: true},
      %{
        description: "Agent reads step 3 file on demand and only step 3 lands in context",
        verified: true
      },
      %{description: "Reading a non-existent step file returns a not-found error", verified: true},
      %{description: "Marketing-strategy skill mirrors the canonical plugin file tree", verified: true},
      %{
        description: "Skill missing SKILL.md or with synthesized-at-runtime content is rejected",
        verified: true
      },
      %{
        description: "Path-traversal attempts are rejected before any filesystem read",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 676,
    status: :completed,
    title: "Strategy Artifacts Saved To My Account",
    description:
      "As a user completing the strategy interview I want each step's artifact written to my account workspace under stable filenames so that I can find positioning, ICP, channels, and content without hunting. Re-running overwrites in place; a prompt-edit audit catches any drift toward local-filesystem language.",
    tags: [%{name: "skill"}, %{name: "strategy"}, %{name: "artifacts"}],
    criteria: [
      %{description: "Each step file passes the write-file-directive audit", verified: true},
      %{description: "Step file lacking write-file directive is rejected", verified: true},
      %{description: "Destination filenames match the canonical table", verified: true},
      %{description: "Drifted filename (e.g. timestamped variant) is rejected", verified: true},
      %{
        description: "Skill content sweep finds no local-filesystem language",
        verified: true
      },
      %{
        description: "Prompt edit introducing local-filesystem language is caught",
        verified: true
      },
      %{
        description:
          "User completes step 5 and finds positioning in account workspace",
        verified: true
      },
      %{description: "Re-running overwrites stable filenames", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  },
  %{
    story_id: 683,
    status: :completed,
    title: "Agent File Tools Over MCP",
    description:
      "As an agent I want a sandboxed file API (read, write, edit, delete, list) over MCP so that I can persist work scoped to my caller's account. All paths resolve server-side under the bearer token's account prefix; path traversal is rejected, cross-tenant access is impossible by construction, and edit/delete require a prior read of the same path.",
    tags: [%{name: "mcp"}, %{name: "files"}, %{name: "boundary"}],
    criteria: [
      %{
        description:
          "tools/list response includes read/write/edit/delete/list_files with the right shapes",
        verified: true
      },
      %{
        description: "read_file returns the file body for an existing key under the caller's account prefix",
        verified: true
      },
      %{
        description:
          "write_file with a fresh path creates the object under the caller's account prefix",
        verified: true
      },
      %{
        description:
          "write_file on an existing path requires the caller to have read_file'd that path earlier",
        verified: true
      },
      %{
        description:
          "edit_file performs an exact-string replacement of old_string with new_string in the named path",
        verified: true
      },
      %{
        description:
          "delete_file removes the object under the caller's account prefix and requires a prior read",
        verified: true
      },
      %{
        description:
          "list_files returns keys under the caller's account prefix, optionally filtered by a relative prefix",
        verified: true
      },
      %{
        description: "Every tool resolves the path under accounts/<account_id> server-side",
        verified: true
      },
      %{
        description: "Adjacent admin or debug tool fails the surface audit",
        verified: true
      },
      %{description: "Path traversal is rejected", verified: true},
      %{description: "Absolute path is rejected", verified: true},
      %{description: "Cross-account access is impossible by construction", verified: true},
      %{description: "edit_file with replace_all replaces every occurrence", verified: true},
      %{
        description: "edit_file with non-unique old_string and no replace_all is rejected",
        verified: true
      }
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study."
    }
  }
]
