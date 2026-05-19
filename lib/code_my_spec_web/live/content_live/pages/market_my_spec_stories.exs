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
  },
  %{
    story_id: 684,
    status: :completed,
    title: "Browse And Read Account Artifacts In A Files Explorer",
    description:
      "As a signed-in user I want a side-by-side files explorer that lists my account's artifacts in a nested tree on the left and renders the selected markdown file styled on the right, so that I can navigate strategy outputs without leaving the browser. Account switching re-scopes the tree; cross-account access is denied by the same Scope plumbing the MCP file tools use.",
    tags: [%{name: "files"}, %{name: "liveview"}, %{name: "markdown"}],
    criteria: [
      %{description: "Tree only contains the active account's artifacts", verified: true},
      %{description: "Direct access to a foreign-account artifact is denied", verified: true},
      %{description: "Nested paths render as a navigable tree", verified: true},
      %{description: "Selecting a markdown file renders it styled on the right", verified: true},
      %{
        description: "Switching accounts re-scopes the tree and clears stale selection",
        verified: true
      },
      %{description: "Empty account shows an empty-state placeholder", verified: true},
      %{description: "Selecting a non-markdown file is undefined behavior", verified: true},
      %{description: "MDEx renders CommonMark + GFM extensions for .md and .markdown files", verified: true},
      %{description: "Rendered output is wrapped in a Tailwind/daisyUI prose container", verified: true},
      %{description: "Non-markdown files fall back to a pre-wrap block, not a synthesized renderer", verified: true},
      %{description: "Unsafe HTML in source markdown is stripped via MDEx unsafe:false", verified: true},
      %{description: "Errors from Files.get/2 render a readable message, not a raw atom", verified: true},
      %{description: "Page title shows the artifact's account-relative key with a Back link", verified: true},
      %{description: "Rendering is server-side; no client-side markdown library is loaded", verified: true},
      %{description: "MDEx.to_html!/2 is the canonical entry point and a rename surfaces at compile time", verified: true}
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
    story_id: 696,
    status: :completed,
    title: "Invite Members To An Account",
    description:
      "As an account owner I want to invite collaborators by email with a role, so that they can join my account through a magic accept link. Pending invitations are listed; cancellable; expire after seven days; mismatched signed-in users are blocked from accepting an invite addressed to a different email.",
    tags: [%{name: "accounts"}, %{name: "invitations"}, %{name: "multi-tenant"}],
    criteria: [
      %{description: "Owner sends an invitation", verified: true},
      %{description: "Member-role user cannot invite", verified: true},
      %{description: "Invitee is already a member is rejected", verified: true},
      %{description: "Email already has a pending invitation is rejected", verified: true},
      %{description: "Invalid email rejected at submission", verified: true},
      %{description: "Owner sees pending invitations on the account", verified: true},
      %{description: "Non-member sees nothing on the invitations page", verified: true},
      %{description: "New user accepts an invitation", verified: true},
      %{description: "Existing user accepts an invitation", verified: true},
      %{description: "Invalid or unknown token rejected", verified: true},
      %{description: "Owner cancels a pending invitation", verified: true},
      %{description: "Cancelled invitation cannot be accepted", verified: true},
      %{description: "Expired invitation rejected", verified: true},
      %{description: "Signed-in matching user accepts", verified: true},
      %{description: "Signed-in mismatched user blocked from accepting", verified: true},
      %{description: "Invitation expires 7 days after creation", verified: true}
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
    story_id: 691,
    status: :completed,
    title: "Agency Branding Configuration",
    description:
      "As an agency owner I want a single LiveView form to claim a logo URL (HTTPS-only) and primary/secondary brand colors, so that visitors on my agency subdomain see white-labeled branding. Member-role users on the agency cannot save branding; apex visitors always see the default theme regardless of any agency's configuration.",
    tags: [%{name: "agency"}, %{name: "white-labeling"}, %{name: "branding"}],
    criteria: [
      %{description: "Owner saves all three branding fields", verified: true},
      %{description: "Member-role user is rejected from saving branding", verified: true},
      %{description: "Owner submits an HTTPS logo URL", verified: true},
      %{description: "Owner submits an HTTP-only logo URL is rejected", verified: true},
      %{description: "Owner submits a malformed logo URL is rejected", verified: true},
      %{description: "Owner submits valid hex colors", verified: true},
      %{description: "Owner submits a malformed color is rejected", verified: true},
      %{description: "Visitor on a configured agency subdomain sees branding", verified: true},
      %{description: "Visitor on an unconfigured agency subdomain sees default theme", verified: true},
      %{description: "Visitor on apex sees default theme regardless of agency configuration", verified: true},
      %{description: "Visitor on a different agency's subdomain sees that agency's branding only", verified: true},
      %{description: "Logo URL fails to load in the browser is handled gracefully", verified: true}
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
    story_id: 695,
    status: :completed,
    title: "Agency Subdomain Assignment And Host Routing",
    description:
      "As an agency owner I want to claim a globally unique subdomain on the apex domain, so that my clients connect through `<agency>.marketmyspec.com`. Reserved names are denied; individual accounts cannot claim subdomains; API endpoints (/oauth/*, /mcp, /.well-known/*) stay apex-only; unknown subdomains 302 to apex; previously-claimed subdomains 404 after a rename.",
    tags: [%{name: "agency"}, %{name: "subdomain"}, %{name: "host-routing"}],
    criteria: [
      %{description: "Owner claims an unused subdomain", verified: true},
      %{description: "Owner attempts to claim a subdomain already taken", verified: true},
      %{description: "Owner sets a well-formed subdomain", verified: true},
      %{description: "Owner submits a malformed subdomain is rejected", verified: true},
      %{description: "Owner attempts to claim a reserved subdomain is rejected", verified: true},
      %{description: "Individual account attempts to claim a subdomain is rejected", verified: true},
      %{description: "Admin changes the subdomain", verified: true},
      %{description: "Member-role user attempts to change the subdomain is rejected", verified: true},
      %{description: "Visitor hits an active agency subdomain and sees the agency context", verified: true},
      %{description: "API call hits the apex domain serves the API", verified: true},
      %{description: "API call hits an agency subdomain is rejected", verified: true},
      %{description: "Visitor lands on the apex domain sees the marketing site", verified: true},
      %{description: "Visitor hits a previously-claimed subdomain after rename is handled", verified: true},
      %{description: "Visitor hits a never-claimed subdomain is redirected to apex", verified: true},
      %{description: "Visitor hits an unrecognized subdomain is redirected to apex", verified: true},
      %{description: "Visitor hits a former subdomain after the agency renamed is handled", verified: true}
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
    story_id: 708,
    status: :completed,
    title: "Configure Venues Per Source For Engagement Search",
    description:
      "As an account owner I want a per-source venue admin (subreddits for Reddit, categories with optional tag filters for ElixirForum) under both a LiveView page and four MCP tools (add_venue, list_venues, update_venue, remove_venue), so that I can curate where the engagement-finder searches. Disabled venues are skipped; cross-account access is rejected; weight feeds the search ranking.",
    tags: [%{name: "engagements"}, %{name: "venues"}, %{name: "mcp"}],
    criteria: [
      %{description: "Venues persist source, identifier, weight, and enabled flag", verified: true},
      %{description: "Agent calls add_venue, list_venues, update_venue, remove_venue over MCP", verified: true},
      %{description: "Owner manages venues from a LiveView admin page", verified: true},
      %{description: "Adding a venue validates source-specific identifier rules", verified: true},
      %{description: "Search reads the enabled venue list per source and only queries those", verified: true},
      %{description: "Existing slash-command venue lists can be seeded on first run", verified: true},
      %{description: "Denylist warns when a venue conflicts with the MMS allocation", verified: true},
      %{description: "A new Reddit venue persists with all fields", verified: true},
      %{description: "An ElixirForum venue stores category and optional tag filter", verified: true},
      %{description: "Weight and enabled flag take sensible defaults", verified: true},
      %{description: "A valid Reddit subreddit name is accepted", verified: true},
      %{description: "An invalid Reddit subreddit name is rejected", verified: true},
      %{description: "An ElixirForum venue with an unknown category is rejected", verified: true},
      %{description: "Agent creates a venue via add_venue MCP tool", verified: true},
      %{description: "Agent lists venues, optionally filtered by source", verified: true},
      %{description: "Agent updates a venue's weight and enabled flag", verified: true},
      %{description: "Agent removes a venue via remove_venue MCP tool", verified: true},
      %{description: "Owner views the venue list in the admin LiveView", verified: true},
      %{description: "Owner adds a new venue from the admin UI", verified: true},
      %{description: "Owner toggles a venue's enabled flag from the list row", verified: true},
      %{description: "Owner removes a venue from the admin UI", verified: true},
      %{description: "Disabling a venue removes it from the next search", verified: true},
      %{description: "Re-enabling a venue restores it to the search target set", verified: true},
      %{description: "Each account sees only its own venues", verified: true},
      %{description: "Cross-account venue access is rejected", verified: true}
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
    story_id: 710,
    status: :completed,
    title: "Save And Run Named Keyword Searches Across Venues",
    description:
      "As a solo founder I want named multi-venue saved searches (Google-style query syntax, with optional source wildcards), so that I can re-run \"all ElixirForum testing threads\" or \"r/elixir + r/programming for credo\" by name from either the admin or the MCP agent. Recipes only — no run history persisted. Cross-account access returns not_found.",
    tags: [%{name: "engagements"}, %{name: "saved-searches"}, %{name: "mcp"}],
    criteria: [
      %{description: "Owner creates a search scoped to two specific Reddit subreddits", verified: true},
      %{description: "Owner creates a search scoped to all ElixirForum via wildcard", verified: true},
      %{description: "Creating a search with empty venue selection is rejected", verified: true},
      %{description: "Two accounts can each have a search with the same name", verified: true},
      %{description: "Renaming a search to a name already taken on the same account fails", verified: true},
      %{description: "run_search interprets OR alternates and quoted phrases", verified: true},
      %{description: "Member-role user can create and run a saved search", verified: true},
      %{description: "Cross-account run_search call returns not_found", verified: true},
      %{description: "run_search delegates to the shared orchestrator and persists nothing", verified: true},
      %{description: "Owner manages searches in the admin UI while the agent uses the same surface via MCP", verified: true}
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
    story_id: 705,
    status: :completed,
    title: "Discover Reddit Engagement Opportunities (Thread-Backed)",
    description:
      "As the agent I want a `search_engagements` MCP tool that runs a keyword query against the calling account's enabled Reddit venues and returns ranked Thread-backed candidates with engagement summaries, so that I can decide which threads are worth a touchpoint. The real adapter calls Reddit's search.json; this story originally shipped against a stub adapter and tautological spex (see Ugly), and was rebuilt against ReqCassette recordings on May 16.",
    tags: [%{name: "engagements"}, %{name: "search"}, %{name: "reddit"}],
    criteria: [
      %{description: "Tool call returns ranked candidate threads for a keyword query", verified: true},
      %{description: "Each candidate carries thread_id, title, source, URL, score, reply_count, recency, snippet", verified: true},
      %{description: "Search upserts a Thread row per candidate (no duplicate rows on re-run)", verified: true},
      %{description: "Thread fields populated on search; fetched_at left for get_thread", verified: true},
      %{description: "Each candidate carries an engagement summary (count, latest_state, latest_angle, latest_posted_at)", verified: true},
      %{description: "Engagement summary is nil/zero when the Thread has no Touchpoints", verified: true},
      %{description: "Results are deduplicated and ranking is deterministic given the same state", verified: true},
      %{description: "A failing source degrades gracefully and is reported in the response", verified: true},
      %{description: "Venue filter is available as an optional argument", verified: true},
      %{description: "Search returns only candidates from the calling account's venues", verified: true},
      %{description: "Disabled venues are not queried", verified: true},
      %{description: "Repeat calls with the same query and state return identical UUIDs", verified: true},
      %{description: "Higher-weight venue's candidate ranks above an equal-signal lower-weight candidate", verified: true},
      %{description: "Among same-weight venues, per-source signal determines order", verified: true},
      %{description: "Subsequent pages return the next batch via cursor", verified: true},
      %{description: "Recency reflects time of last activity, not thread creation", verified: true},
      %{description: "First page returns up to 25 candidates per source", verified: true}
    ],
    three_amigos: %{
      excerpted: true,
      persona: nil,
      rules: [],
      questions: [],
      note:
        "Persona linkage, rules, scenarios, and questions exist in the harness records for this story; not excerpted in this case study. Note: this story's first ship is the Ugly section's tautological-spex example."
    }
  },
  %{
    story_id: 706,
    status: :completed,
    title: "Refresh A Persisted Reddit Thread's Full Content For The LLM",
    description:
      "As the agent I want `get_thread(thread_id: UUID)` to refresh a Thread's full content (normalized comment tree, raw payload, last_activity_at, fetched_at) on demand, with a five-minute freshness window cache and graceful degradation on platform errors. Cross-account access returns not_found.",
    tags: [%{name: "engagements"}, %{name: "thread"}, %{name: "reddit"}],
    criteria: [
      %{description: "Agent calls get_thread with a UUID and receives the updated Thread", verified: true},
      %{description: "Comments are normalized into comment_tree preserving order and per-comment fields including depth", verified: true},
      %{description: "raw_payload is persisted alongside the normalized form on every successful fetch", verified: true},
      %{description: "last_activity_at is set to the newest comment's created_utc, or the post's created_utc when no comments", verified: true},
      %{description: "fetched_at updates to the call timestamp on every successful fetch", verified: true},
      %{description: "Within the freshness window, a repeat call returns the cached row with no HTTP call", verified: true},
      %{description: "Outside the freshness window, a refetch updates the same row in place (no new row)", verified: true},
      %{description: "Default page caps top-level comments at 25 with a comments_cursor for the next page", verified: true},
      %{description: "Platform errors surface as a usable error response; existing row data is preserved", verified: true},
      %{description: "Raw payload persists even when normalization partially fails", verified: true},
      %{description: "Cross-account access returns not_found and leaks no thread data", verified: true},
      %{description: "get_thread is idempotent within the freshness window", verified: true},
      %{description: "Outside-window refresh returning 429 serves stale cached data with a flag", verified: true}
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
    story_id: 714,
    status: :completed,
    title: "Add ElixirForum As A Second Engagement Source",
    description:
      "As the platform I want ElixirForum to join Reddit behind a common Source behaviour, so that adding a third source later is additive. Discourse latest.json normalizes to the canonical Thread shape; category slug auto-discovery happens via /categories.json (cached in :persistent_term). The orchestrator dispatches by venue.source; one source failing does not poison the other.",
    tags: [%{name: "engagements"}, %{name: "elixirforum"}, %{name: "discourse"}],
    criteria: [
      %{
        description: "Results are sourced from Reddit and ElixirForum behind a common Source behaviour",
        verified: true
      },
      %{description: "Reddit and ElixirForum candidates share the same shape", verified: true},
      %{description: "One source failing does not poison the other source's results", verified: true},
      %{description: "All sources failing returns an empty list with per-source failure entries", verified: true},
      %{description: "Cross-source ordering interleaves per-source ranked lists", verified: true},
      %{description: "Both adapter modules implement the Source behaviour; orchestrator dispatches by venue.source", verified: true},
      %{description: "validate_venue accepts category-slug and category-slug:tag; rejects malformed", verified: true},
      %{description: "Discourse latest.json normalizes to Thread rows with the canonical field set", verified: true},
      %{description: "Reddit and ElixirForum candidates in one response have identical key sets", verified: true},
      %{
        description: "Reddit 429 plus ElixirForum 200: response has the ElixirForum thread and a Reddit failure entry",
        verified: true
      },
      %{description: "Every venue across every source 5xx: empty candidates plus per-venue failures", verified: true},
      %{
        description: "High-weight ElixirForum candidate outranks low-weight Reddit candidate at same per-source signal",
        verified: true
      },
      %{description: "Failure entries carry source, venue_identifier, and a human-readable reason", verified: true}
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
    story_id: 707,
    status: :completed,
    title: "Polish Dictated Draft, Embed UTM-Tracked Link, Stage As A Touchpoint",
    description:
      "As the agent I want `stage_response(thread_id, polished_body, link_target)` to create a staged Touchpoint with a UTM-rewritten link embedded in the body, so that the operator can copy-paste a draft tagged for analytics. Per-source UTM scheme (utm_source=reddit|elixirforum, utm_medium=engagement); the original link_target is preserved on the Touchpoint for audit. v1 makes no platform API call.",
    tags: [%{name: "engagements"}, %{name: "touchpoint"}, %{name: "utm"}],
    criteria: [
      %{description: "Agent stages a draft and receives the new Touchpoint id", verified: true},
      %{description: "Optional angle is persisted when provided, nil when omitted", verified: true},
      %{description: "Created Touchpoint has state :staged", verified: true},
      %{
        description: "link_target is rewritten with a per-source UTM scheme before embedding",
        verified: true
      },
      %{description: "UTM-embedded link replaces the original link_target at the same position", verified: true},
      %{description: "Original (un-UTM'd) link_target is stored on the Touchpoint for audit", verified: true},
      %{description: "polished_body is plain text suitable for direct copy-paste", verified: true},
      %{description: "Cross-account access returns not_found; no Touchpoint is created", verified: true},
      %{description: "stage_response makes no platform API call (no Reddit submit, no Discourse post)", verified: true},
      %{
        description: "Optional :synopsis writes to the parent thread when nil; never overwrites a non-nil thread synopsis",
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
    story_id: 716,
    status: :completed,
    title: "Touchpoints Carry Their Own Angle And Explicit Lifecycle",
    description:
      "As the agent and operator I want Touchpoints to carry an explicit `:state` (`:staged | :posted | :abandoned`) and an optional `:angle` (the agent's reasoning for this specific comment), so that the lifecycle is unambiguous and back-transitions are allowed. The LiveView paste-URL flow and the `update_touchpoint` MCP tool share one context function. Engagement summaries on search candidates trust the state column, not inferred from posted_at.",
    tags: [%{name: "engagements"}, %{name: "touchpoint"}, %{name: "state-machine"}],
    criteria: [
      %{description: "Touchpoint schema gains a :state field with :staged default on create", verified: true},
      %{description: "Touchpoint schema gains an optional :angle text field", verified: true},
      %{
        description: "Existing touchpoints backfill: state = :posted where posted_at IS NOT NULL, else :staged",
        verified: true
      },
      %{description: "stage_response accepts an optional angle and persists it on the new touchpoint", verified: true},
      %{description: "Transition to :posted requires comment_url and posted_at; rejected otherwise", verified: true},
      %{description: "Transition to :abandoned preserves angle and polished_body (no destructive delete)", verified: true},
      %{
        description: "update_touchpoint(touchpoint_id, state, comment_url, posted_at) transitions state",
        verified: true
      },
      %{description: "list_touchpoints(thread_id) returns all touchpoints ordered by inserted_at desc", verified: true},
      %{
        description: "list_touchpoints payload includes id, state, angle, polished_body, comment_url, posted_at, inserted_at",
        verified: true
      },
      %{description: "Cross-account access via update_touchpoint or list_touchpoints returns not_found", verified: true},
      %{
        description: "LiveView paste-URL flow and update_touchpoint MCP tool share one context function",
        verified: true
      },
      %{description: "Engagement summary on search candidates is populated from explicit state", verified: true},
      %{description: "Touchpoint state moves freely through staged, posted, abandoned, and back", verified: true},
      %{description: "TouchpointLive.Show renders the parent thread's synopsis when present", verified: true},
      %{
        description: "TouchpointLive.Show renders polished_body in an editable textarea with explicit Save",
        verified: true
      },
      %{description: "TouchpointLive.Show renders angle in an editable textarea with the same Save flow", verified: true},
      %{
        description: "Saving with empty polished_body is rejected; previously persisted value preserved",
        verified: true
      },
      %{
        description: "TouchpointLive.Show renders the parent thread URL as a target=_blank anchor",
        verified: true
      },
      %{
        description: "update_touchpoint MCP tool accepts optional polished_body, angle, and state edits",
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
