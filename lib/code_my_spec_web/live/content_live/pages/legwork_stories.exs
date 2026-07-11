[
  %{
    story_id: 825,
    status: :completed,
    title: "Author an outbound pipeline",
    description:
      "As an outbound operator, I want to create a pipeline and write its runbook — naming the target type I'm going after and giving the model per-stage instructions for gather, qualify, resolve, enrich, and launch — so that I capture a repeatable outbound motion in one place instead of re-explaining it every time.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Pipelines are isolated per account", verified: true},
      %{description: "Create a pipeline with a name and target type", verified: true},
      %{description: "Cannot save a pipeline without a name", verified: true},
      %{description: "Runbook shows the five fixed stages", verified: true},
      %{description: "Save an incomplete runbook and finish later", verified: true},
      %{description: "Editing a runbook affects an in-flight run", verified: true},
      %{description: "Clone a pipeline as a starting point", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "A pipeline is owned by the account it's created in and is visible only to that account's operators.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Pipelines are isolated per account",
              body: "Given operator A has an active account
And operator B belongs to a different account
When operator A creates a pipeline \"Denver crane cos\"
Then operator B does not see \"Denver crane cos\" in their pipeline list"
            }
          ]
        },
        %{
          statement: "A pipeline requires a name and a free-text target type before it can be run.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Create a pipeline with a name and target type",
              body: "Given I am an operator with an active account
When I create a pipeline named \"Denver crane cos\" with target type \"company\"
Then the pipeline is saved and appears in my pipeline list"
            },
            %{
              kind: "failure path",
              title: "Cannot save a pipeline without a name",
              body: "Given I am creating a new pipeline
When I try to save it without a name
Then I see a validation error and the pipeline is not saved"
            }
          ]
        },
        %{
          statement: "A runbook has exactly the five stages — Gather, Qualify, Resolve, Enrich, Launch — each with free-form markdown instructions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Runbook shows the five fixed stages",
              body: "Given I am an operator with an active account
When I open a new pipeline's runbook
Then I see instruction sections for Gather, Qualify, Resolve, Enrich, and Launch"
            }
          ]
        },
        %{
          statement: "A pipeline can be saved and edited incrementally, without every stage's instructions filled in.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Save an incomplete runbook and finish later",
              body: "Given a new pipeline with only the Gather instructions filled in
When I save the pipeline
Then it is saved successfully
And I can reopen it later to fill in the remaining stages"
            }
          ]
        },
        %{
          statement: "A run always uses the pipeline's current runbook, so editing a runbook takes effect immediately for in-flight runs.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Editing a runbook affects an in-flight run",
              body: "Given a pipeline with a run currently in progress
When I edit the runbook's Qualify instructions
Then the in-flight run uses the updated Qualify instructions when it reaches that stage"
            }
          ]
        },
        %{
          statement: "An operator can clone an existing pipeline as the starting point for a new one.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Clone a pipeline as a starting point",
              body: "Given an existing pipeline \"Denver crane cos\"
When I clone it
Then a new pipeline is created pre-filled with the source pipeline's target type and runbook
And I can edit the clone without changing the original"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 826,
    status: :completed,
    title: "Drive a model through the pipeline",
    description:
      "As an outbound operator, I want the system to give the model the full runbook and the tools up front and let it work the pipeline stages in as few passes as it can — recording findings as it discovers them — so that the legwork gets done without me running each step by hand.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Gather produces the targets", verified: true},
      %{description: "Record a target via tool or API", verified: true},
      %{description: "Model receives the whole runbook at start", verified: true},
      %{description: "Person and contact recorded in one pass", verified: true},
      %{description: "Model works hands-free over MCP", verified: true},
      %{description: "Concurrent runs stay separate by ID", verified: true},
      %{description: "A key scoped to one run cannot write to another", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "The Gather stage is where the model produces the targets (e.g. via web search or a Places API call); the operator does not supply them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Gather produces the targets",
              body: "Given a run starts on a pipeline targeting companies
When the model works the Gather stage
Then it produces target companies (e.g. via web search) and records them to the run"
            }
          ]
        },
        %{
          statement: "The model records targets, people, and contacts through MCP tools and a run-scoped API endpoint it can call from code.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Record a target via tool or API",
              body: "Given an active run
When the model calls the create-target MCP tool or POSTs a target to the run's API endpoint
Then the target is recorded on that run"
            }
          ]
        },
        %{
          statement: "When a run starts, the model is given the full runbook (all five stages' instructions) up front, not one stage at a time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Model receives the whole runbook at start",
              body: "Given I start a run on a pipeline
When the model begins
Then it receives all five stages' instructions at once, not just Gather's"
            }
          ]
        },
        %{
          statement: "When one action yields data for several stages (e.g. a scrape that finds a person and their contact together), the model records all of it in that pass rather than waiting for a later stage.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Person and contact recorded in one pass",
              body: "Given the model finds a person and their contact info in the same web pass
When it records what it found
Then both the person and the contact are saved without waiting for a later stage"
            }
          ]
        },
        %{
          statement: "Once a run is started the model does the work hands-free over the MCP session; the operator does not run each step and there is no pause/resume.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Model works hands-free over MCP",
              body: "Given I have started a run and said nothing further
When the model works over the MCP session
Then it completes the stages on its own with no pause or manual step from me"
            }
          ]
        },
        %{
          statement: "Multiple runs can execute concurrently, each addressed by its run ID via MCP tools or a run-scoped API endpoint/key.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Concurrent runs stay separate by ID",
              body: "Given runs A and B are both in progress
When the model records a target addressed to run B's ID
Then the target appears only on run B"
            },
            %{
              kind: "failure path",
              title: "A key scoped to one run cannot write to another",
              body: "Given the model holds run A's API key
When it attempts to write a target to run B
Then the write is rejected"
            }
          ]
        }
      ],
      questions: [
        %{body: "Given the model works the runbook opportunistically (not strictly stage-by-stage), what marks a stage \"done\", and does the gate apply per target (e.g. does this target have a contact yet?) rather than as a hard sequential barrier for the whole run? Resolve in stories 828 (gate) and 831 (agent).", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 827,
    status: :completed,
    title: "Record the model's findings as targets",
    description:
      "As an outbound operator, I want the model's findings saved as targets I can see and query — created and annotated via an API endpoint or MCP tools as it works each stage — so that I have a durable, reviewable record of who was gathered, qualified, resolved, and enriched rather than just chat output.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Findings persist after the session ends", verified: true},
      %{description: "Target nests its people and contacts", verified: true},
      %{description: "Annotations are visible on the record", verified: true},
      %{description: "Filter a run's targets", verified: true},
      %{description: "Records are isolated per account", verified: true},
      %{description: "Operator corrects a wrong contact", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "Every finding the model records is saved as a structured database record and survives after the model's session ends — not left as chat output.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Findings persist after the session ends",
              body: "Given the model recorded 40 targets during a run
When the model's session has ended
Then all 40 targets are still there for the operator to review"
            }
          ]
        },
        %{
          statement: "A run's data is targets, each with the people found for it, and each person's contacts (target → person → contact).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Target nests its people and contacts",
              body: "Given a target with a resolved person who has a verified email
When I open the target
Then I see the person nested under the target and the contact nested under the person"
            }
          ]
        },
        %{
          statement: "Each record carries its annotations — a target its qualify verdict and reason, a person its role/identity, a contact its verified email/phone.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Annotations are visible on the record",
              body: "Given a target the model qualified
When I open the target
Then I see its qualify verdict and the reason the model gave"
            }
          ]
        },
        %{
          statement: "The operator can list and filter a run's targets and open any target to see its people and contacts.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Filter a run's targets",
              body: "Given a run with a mix of qualified and disqualified targets
When I filter to \"qualified\"
Then only the qualified targets are listed"
            }
          ]
        },
        %{
          statement: "A run's records belong to that run and account; an operator only sees their own account's data.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Records are isolated per account",
              body: "Given a target recorded in account A
When an operator in account B lists or queries targets
Then they cannot see the account A target"
            }
          ]
        },
        %{
          statement: "The operator can edit or correct any recorded finding; edits overwrite the current value in place, with no change history kept.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Operator corrects a wrong contact",
              body: "Given a contact with a wrong email
When the operator edits it to the correct email
Then the corrected email is shown and the old value is not retained"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 828,
    status: :completed,
    title: "Gate advancement between stages",
    description:
      "As an outbound operator, I want the system to confirm a stage actually produced valid results before it advances to the next stage, so that an empty or broken stage doesn't silently poison the rest of the run and waste effort downstream.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Cannot attach a contact without a person", verified: true},
      %{description: "Empty Gather holds the run", verified: true},
      %{description: "Blocked target shows why", verified: true},
      %{description: "A target becomes launch-eligible automatically once its data is complete", verified: true},
      %{description: "Resume a held run", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "A target can only receive a later stage's data if it has the prior stage's — no person on an ungathered target, no contact on an unresolved person, no launch without a verified contact.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Cannot attach a contact without a person",
              body: "Given a target with no resolved person
When the agent tries to attach a contact
Then the write is rejected because there is no person to attach it to"
            }
          ]
        },
        %{
          statement: "If a stage yields zero valid output for the run — zero targets from Gather, zero people from Resolve, or no contact info from Enrich — the run is held and the operator is alerted rather than proceeding.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Empty Gather holds the run",
              body: "Given a run whose Gather produced zero targets
When the run would otherwise proceed
Then it is held and the operator is alerted that Gather found nothing"
            }
          ]
        },
        %{
          statement: "A target that cannot advance shows as blocked at its stage, with the reason (e.g. no contact was found).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Blocked target shows why",
              body: "Given a target that was resolved but never enriched
When I view the run
Then that target shows as blocked at Enrich because it has no contact"
            }
          ]
        },
        %{
          statement: "Advancement is gated by whether the required data exists, not by a manual approval; the only human gate is the launch review.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A target becomes launch-eligible automatically once its data is complete",
              body: "Given a qualified target with a person
When the agent adds a verified contact
Then the target becomes launch-eligible with no operator approval step before the launch review"
            }
          ]
        },
        %{
          statement: "A held or blocked run just sits; the operator can point the agent at that run again to work it further.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Resume a held run",
              body: "Given a run that is held with several blocked targets
When the operator points the agent at that run again
Then the agent continues working the blocked targets from where they left off"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 829,
    status: :completed,
    title: "Do the human parts at launch",
    description:
      "As an outbound operator, I want to review the agent's launch drafts and supply the human parts — record the video, approve or edit the copy — before anything goes out, so that the machine does the grunt work while I keep the outreach personal and control what actually gets sent.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Agent can't create the outreach before approval", verified: true},
      %{description: "Approve with a recorded video", verified: true},
      %{description: "Approve without a video", verified: true},
      %{description: "Edit the copy before approving", verified: true},
      %{description: "Agent creates the Gmail draft after approval", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "Nothing proceeds to actual outreach until the operator has done their part and approved the draft — the launch review is the one human gate.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Agent can't create the outreach before approval",
              body: "Given a launch draft the operator has not approved
When the agent attempts to create the Gmail draft for it
Then it is not allowed until the operator approves"
            }
          ]
        },
        %{
          statement: "The operator reviews the agent's launch draft and supplies the human parts (e.g. records a video, approves or edits the copy); the video is optional, not required.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Approve with a recorded video",
              body: "Given a launch draft
When the operator records a video and approves the copy
Then the draft is marked approved with the human parts attached"
            },
            %{
              kind: "happy path",
              title: "Approve without a video",
              body: "Given a launch draft
When the operator approves the copy without recording a video
Then the draft is still marked approved"
            }
          ]
        },
        %{
          statement: "The operator can approve, edit, or reject a draft.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Edit the copy before approving",
              body: "Given a launch draft whose copy the operator wants to change
When the operator edits the copy and approves
Then the approved draft carries the edited copy"
            }
          ]
        },
        %{
          statement: "After the operator approves, the agent assembles and creates the actual outreach (e.g. the Gmail draft) via its own tools; Legwork records the human parts and approval but does not create the Gmail draft or handle the outbound channel.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent creates the Gmail draft after approval",
              body: "Given the operator has approved a draft with their human parts
When the agent picks it up
Then the agent creates the Gmail draft via its own tools, and Legwork only records that it was approved"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 830,
    status: :completed,
    title: "See run progress across the pipeline",
    description:
      "As an outbound operator, I want to see where a run and each of its targets sit in the pipeline — done, stuck, or dropped at each stage — so that I know what needs my attention and can trust the motion is moving.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Each target shows its state", verified: true},
      %{description: "Run summary shows status and per-stage counts", verified: true},
      %{description: "Stuck and dropped are distinguishable", verified: true},
      %{description: "See what's already been covered", verified: true},
      %{description: "Delete an unwanted run", verified: true},
      %{description: "Progress updates live", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Outbound Operator", slug: "outbound-operator", type: "proto"},
      rules: [
        %{
          statement: "For a run, the operator sees each target's current stage and status — done, stuck, or dropped.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Each target shows its state",
              body: "Given a run with targets in various states
When I view the run
Then each target shows as done, stuck, or dropped"
            }
          ]
        },
        %{
          statement: "The operator sees the run's overall status (in progress, held, or done) with how many targets sit at each stage.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Run summary shows status and per-stage counts",
              body: "Given a run in progress
When I view it
Then I see its overall status and how many targets sit at each stage"
            }
          ]
        },
        %{
          statement: "A stuck target is shown with the stage it is blocked at and why; a dropped (disqualified) target is shown distinctly.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Stuck and dropped are distinguishable",
              body: "Given one target blocked at Enrich with no contact and one target disqualified in Qualify
When I view the run
Then the first shows as stuck at Enrich with the reason and the second shows as dropped"
            }
          ]
        },
        %{
          statement: "Each run carries an explicit free-text scope the agent records (e.g. \"heavy equipment dealers in Houston\"), and the operator can see it across their runs so they don't repeat covered ground.",
          scenarios: [
            %{
              kind: "happy path",
              title: "See what's already been covered",
              body: "Given a prior run scoped \"heavy equipment dealers in Houston\"
When I look at my runs
Then I can see that scope was already covered so I don't repeat it"
            }
          ]
        },
        %{
          statement: "The operator can cancel or delete a run they no longer need.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Delete an unwanted run",
              body: "Given a run I no longer need
When I delete it
Then it is removed from my run list"
            }
          ]
        },
        %{
          statement: "Progress updates live as the agent works, without the operator refreshing.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Progress updates live",
              body: "Given I am viewing a run while the agent works
When the agent records new targets and contacts
Then the progress updates on screen without me refreshing"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 831,
    status: :completed,
    title: "Execute a pipeline stage as the agent",
    description:
      "As an agent, I want to execute each stage of a pipeline run — using the tools to gather, qualify, resolve, enrich, and launch — so that I can help the outbound operator do their outreach.",
    tags: [%{name: "agent"}],
    criteria: [
      %{description: "Run secret authorizes writes", verified: true},
      %{description: "Writes without the secret are rejected", verified: true},
      %{description: "Create-target tool persists what the agent found", verified: true},
      %{description: "Agent sets the qualify verdict from its own judgment", verified: true},
      %{description: "Disqualified targets are skipped downstream", verified: true},
      %{description: "Record person and contact together", verified: true},
      %{description: "Gate-eligible target accepts a draft", verified: true},
      %{description: "Draft rejected when the gate isn't met", verified: true},
      %{description: "Agent-composed draft is stored, nothing sent", verified: true},
      %{description: "Re-recording the same target creates no duplicate", verified: true},
      %{description: "Run reads as done from the data", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "The Pipeline Agent", slug: "pipeline-agent", type: "proto"},
      rules: [
        %{
          statement: "Starting a run mints a run ID and a secret; every tool/API write must present that secret and applies only to that run, so the endpoints can't be spammed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Run secret authorizes writes",
              body: "Given a run started with run ID R and secret S
When the agent writes a target presenting secret S for run R
Then the write is accepted and applied to run R"
            },
            %{
              kind: "failure path",
              title: "Writes without the secret are rejected",
              body: "Given a run R
When someone writes to run R with a missing or wrong secret
Then the write is rejected"
            }
          ]
        },
        %{
          statement: "The stage tools are plain CRUD — create a target, set a qualify verdict, attach a person, attach a contact, store a launch draft — that just persist what the agent produces; the agent does the heavy lifting.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Create-target tool persists what the agent found",
              body: "Given the agent has found a target company
When it calls the create-target tool with that company's fields
Then the target is persisted on the run exactly as supplied"
            }
          ]
        },
        %{
          statement: "Whether a target is qualified is the agent's judgment from the runbook's Qualify instructions (it may script the decision, e.g. checking whether the target is already AI-recommended); the system enforces no qualification rules of its own.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent sets the qualify verdict from its own judgment",
              body: "Given the runbook's Qualify instructions say to exclude targets already recommended by AI
When the agent determines a target is not AI-recommended
Then it sets qualified = true with its reason, and the system stores that verdict without overriding it"
            }
          ]
        },
        %{
          statement: "A target the agent marks qualified = false is excluded from Resolve, Enrich, and Launch.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Disqualified targets are skipped downstream",
              body: "Given a target marked qualified = false
When the agent works Resolve, Enrich, and Launch
Then that target is skipped in all three"
            }
          ]
        },
        %{
          statement: "The agent may record data for any stage as it discovers it; it needn't finish one stage before recording another.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Record person and contact together",
              body: "Given the agent finds a person and their contact in the same pass
When it records both
Then both are saved on the target without needing a separate later stage"
            }
          ]
        },
        %{
          statement: "A target is Launch-eligible only when it is qualified and has a person with a verified contact; the launch endpoint rejects a draft for a target that hasn't met the gate.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Gate-eligible target accepts a draft",
              body: "Given a qualified target with a person and a verified contact
When the agent submits a launch draft for it
Then the draft is accepted"
            },
            %{
              kind: "failure path",
              title: "Draft rejected when the gate isn't met",
              body: "Given a target with no verified contact
When the agent submits a launch draft for it
Then the launch endpoint rejects it as not gate-eligible"
            }
          ]
        },
        %{
          statement: "The agent composes the launch draft (copy and video ask) and passes it to the tool/API to store as-is; the system does not generate the draft and nothing is sent — the operator reviews it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent-composed draft is stored, nothing sent",
              body: "Given the agent has composed the copy and the video ask
When it passes the draft to the launch endpoint
Then the draft is stored as-is for operator review and no outreach is sent"
            }
          ]
        },
        %{
          statement: "Tool writes are idempotent — re-recording the same finding or retrying a write does not create duplicates.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Re-recording the same target creates no duplicate",
              body: "Given a target already recorded on the run
When the agent records the same target again
Then no duplicate target is created"
            }
          ]
        },
        %{
          statement: "A target's stage is derived from the data it has; the run is done when every qualified target has been taken as far as it can, with no manual per-stage done signal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Run reads as done from the data",
              body: "Given a run where every qualified target has a launch draft
When the agent has no more work to do
Then the run shows as done without any manual done signal"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  }
]
