[
  %{
    story_id: 678,
    status: :completed,
    title: "Multi-Tenant Account Architecture",
    description:
      "As a user of Market My Spec, I want my work scoped to an account so that I can keep individual marketing strategies separate, share an account with collaborators, and (for agencies) hold multiple client accounts under one operator. The account is the unit of ownership for MCP connections, strategy artifacts, and settings. The clearest demonstration of the harness's new Three Amigos gate: the agent surfaced four open questions about agency-vs-individual UX, John resolved them in plain English, and the agent then added a new rule capturing the product decision before closing the readiness gate.",
    tags: [
      %{name: "three-amigos"},
      %{name: "multi-tenant"},
      %{name: "accounts"}
    ],
    criteria: [
      %{
        description: "A user must belong to at least one account before accessing any platform feature",
        verified: true
      },
      %{
        description: "The user who creates an account is automatically assigned the owner role",
        verified: true
      },
      %{
        description: "A user holds exactly one role within a given account: owner, admin, or member",
        verified: true
      },
      %{
        description:
          "All platform data — MCP connections, strategy artifacts, settings — belongs to the account, not the individual user",
        verified: true
      },
      %{
        description:
          "A user with multiple accounts operates in exactly one current account context at a time; all reads and writes are scoped to that context",
        verified: true
      },
      %{
        description: "Account slugs are globally unique and URL-safe; once set they cannot be changed",
        verified: true
      },
      %{
        description:
          "Account type (individual or agency) is fixed at creation and gates which features are available",
        verified: true
      },
      %{
        description:
          "Agency accounts are admin-provisioned only; the self-service form produces individual accounts exclusively",
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
        "Excerpted from the project records for this case study. Eight scenarios were authored across these rules (one happy_path plus one failure_path on most rules); only the bodied scenario and the named scenario shown above are quoted here. The full set lives in the harness."
    }
  },
  %{
    story_id: 679,
    status: :completed,
    title: "Agency Multi-Tenancy",
    description:
      "Companion to story 678. As an agency operator I want to manage multiple client accounts from one login so that I can run strategy and execution across all of them without switching identities. Re-runs the Three Amigos protocol on the agency-management surface, producing six rules in the agency-management direction, all via MCP records. Same protocol shape as story 678; different surface.",
    tags: [
      %{name: "three-amigos"},
      %{name: "multi-tenant"},
      %{name: "agency"}
    ],
    criteria: [],
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
      %{
        description: "Login page renders only the magic-link form (password form removed)",
        verified: true
      },
      %{description: "Invalid email format is caught before submission", verified: true},
      %{
        description: "Expired or consumed magic link surfaces a recoverable error",
        verified: true
      },
      %{description: "Returning user signs in with a fresh magic link", verified: true},
      %{description: "New visitor signs up via magic link end-to-end", verified: true},
      %{description: "Direct POST to password endpoint is rejected", verified: true}
    ],
    three_amigos: nil
  },
  %{
    story_id: 603,
    status: :completed,
    title: "Onboarding Empty State",
    description:
      "As a freshly-signed-up user I want a clean empty state that asks for the first piece of context I need to provide (project name) so that I can move into the product without a wall of forms. Replaced an earlier, heavier onboarding wizard.",
    tags: [%{name: "auth"}, %{name: "onboarding"}],
    criteria: [],
    three_amigos: nil
  },
  %{
    story_id: 604,
    status: :completed,
    title: "Post-Signup Redirect",
    description:
      "As a user completing signup I want to land somewhere immediately useful so that the first thing I see is a working product, not a confirmation screen. Derives a project module_name from signup context and routes the user to /app.",
    tags: [%{name: "auth"}, %{name: "onboarding"}],
    criteria: [],
    three_amigos: nil
  }
]
