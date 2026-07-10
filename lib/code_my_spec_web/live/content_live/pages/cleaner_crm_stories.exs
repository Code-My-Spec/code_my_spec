[
  %{
    story_id: 832,
    status: :completed,
    title: "Manage clients and properties with access details",
    description:
      "As a cleaning business owner, I want to manage clients and their properties — addresses, parking notes, entry method (key/lockbox/alarm codes), pets, and cleaning preferences — so that every job automatically carries authoritative entry and scope information and cleaners never get locked out or blindsided. (Research: key/entry management is a chronic owner burden; scattered access info is a top cleaner pain — docs/research/cleaner-pain-points.md §1.7, §2.2)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Add a property under an existing client", verified: true},
      %{description: "Reject a property with no client", verified: true},
      %{description: "Save a property with a valid service address", verified: true},
      %{description: "Reject a property with a blank address", verified: true},
      %{description: "Job brief inherits property access details", verified: true},
      %{description: "Updated code propagates to future jobs", verified: true},
      %{description: "Entry code change is logged", verified: true},
      %{description: "Deactivate a client with upcoming jobs", verified: true},
      %{description: "Block hard delete of a client with upcoming jobs", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "Every property must belong to exactly one client.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Add a property under an existing client",
              body: "Given a client \"Sarah Kim\" exists
When the owner adds a property \"123 Oak St\" and assigns it to Sarah Kim
Then the property is saved and listed under Sarah Kim
And the property shows Sarah Kim as its only owning client"
            },
            %{
              kind: "failure path",
              title: "Reject a property with no client",
              body: "Given the owner is creating a new property
When the owner submits the property without selecting a client
Then the property is not saved
And the owner sees an error that a client is required"
            }
          ]
        },
        %{
          statement: "A property cannot be saved without a service address.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Save a property with a valid service address",
              body: "Given the owner is adding a property for a client
When the owner enters the service address \"123 Oak St, Austin, TX\" and saves
Then the property is saved with that address"
            },
            %{
              kind: "failure path",
              title: "Reject a property with a blank address",
              body: "Given the owner is adding a property for a client
When the owner leaves the service address blank and tries to save
Then the property is not saved
And the owner sees an error that a service address is required"
            }
          ]
        },
        %{
          statement: "A property's access details (entry method, lockbox/alarm codes, parking notes, pet notes) are carried onto every job scheduled at that property.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Job brief inherits property access details",
              body: "Given a property with lockbox code \"4821\", parking note \"driveway only\", and pet note \"dog in yard\"
When a job is scheduled at that property
Then the job brief shows the lockbox code, parking note, and pet note from the property"
            },
            %{
              kind: "happy path",
              title: "Updated code propagates to future jobs",
              body: "Given a property with an upcoming job and lockbox code \"4821\"
When the owner changes the property's lockbox code to \"9077\"
Then the upcoming job's brief shows lockbox code \"9077\""
            }
          ]
        },
        %{
          statement: "Any change to a property's entry codes is recorded in an audit trail capturing who changed it and when.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Entry code change is logged",
              body: "Given a property with alarm code \"1234\"
When the owner changes the alarm code to \"5678\"
Then an audit entry records the owner's identity, the timestamp, and that the alarm code was changed"
            }
          ]
        },
        %{
          statement: "A client with upcoming scheduled jobs cannot be permanently deleted, only deactivated.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Deactivate a client with upcoming jobs",
              body: "Given a client with a job scheduled next week
When the owner deactivates the client
Then the client is marked inactive and hidden from active lists
And the client's history and properties are retained"
            },
            %{
              kind: "failure path",
              title: "Block hard delete of a client with upcoming jobs",
              body: "Given a client with a job scheduled next week
When the owner attempts to permanently delete the client
Then the deletion is blocked
And the owner is told to deactivate the client or first remove its upcoming jobs"
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
    story_id: 833,
    status: :completed,
    title: "Schedule recurring cleaning plans with series-wide conflict detection",
    description:
      "As a cleaning business owner, I want to create weekly/biweekly/monthly recurring cleaning plans that detect conflicts across the entire series (not just the first visit) and respect per-cleaner availability blocks, so that my calendar stays reliable without manually auditing future dates. (Research: ZenMaid detects conflicts only on first visit; owners want cleaner-unavailability blocking — pain-points §1.1, §4)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Weekly plan generates the full series", verified: true},
      %{description: "Conflict on a later occurrence is detected", verified: true},
      %{description: "Clean series saves without warnings", verified: true},
      %{description: "Assign a cleaner within their available hours", verified: true},
      %{description: "Block assignment during a time-off block", verified: true},
      %{description: "Block an overlapping double-booking", verified: true},
      %{description: "Owner reviews conflicting dates before saving", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "A recurring plan generates a job for every occurrence in its series (weekly, biweekly, or monthly), not just the first.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Weekly plan generates the full series",
              body: "Given the owner creates a weekly cleaning plan for a property running for 8 weeks
When the plan is saved
Then 8 jobs are created, one on each scheduled date"
            }
          ]
        },
        %{
          statement: "Conflict detection runs across every occurrence in the series, not only the first visit.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Conflict on a later occurrence is detected",
              body: "Given the assigned cleaner has a time-off block on the date of the 4th weekly visit
When the owner creates the 8-week weekly plan
Then the system flags the 4th visit as conflicting
And the first visit is not the only date checked"
            },
            %{
              kind: "happy path",
              title: "Clean series saves without warnings",
              body: "Given the assigned cleaner is available on every date in an 8-week weekly plan
When the owner creates the plan
Then no conflicts are reported
And all 8 jobs are scheduled"
            }
          ]
        },
        %{
          statement: "A job cannot be assigned to a cleaner during one of that cleaner's availability blocks.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Assign a cleaner within their available hours",
              body: "Given a cleaner is available Tuesday mornings
When the owner assigns that cleaner a Tuesday 9am job
Then the job is assigned without warning"
            },
            %{
              kind: "failure path",
              title: "Block assignment during a time-off block",
              body: "Given a cleaner has an all-day time-off block on Friday
When the owner tries to assign that cleaner a Friday job
Then the assignment is rejected as a conflict
And the owner is told the cleaner is unavailable that day"
            }
          ]
        },
        %{
          statement: "A cleaner cannot be booked for two jobs whose times overlap.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Block an overlapping double-booking",
              body: "Given a cleaner is booked for a job from 10am to 12pm
When the owner tries to assign that cleaner another job from 11am to 1pm the same day
Then the second assignment is rejected as an overlap conflict"
            }
          ]
        },
        %{
          statement: "When a series has conflicting occurrences, the owner is shown which dates conflict before the plan is saved.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner reviews conflicting dates before saving",
              body: "Given a proposed series has conflicts on the 4th and 7th visits
When the owner reviews the plan before saving
Then the owner sees a list naming the 4th and 7th visits as conflicting
And the owner can resolve or override them before the plan is saved"
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
    story_id: 834,
    status: :completed,
    title: "Dispatch from a single weekly schedule board",
    description:
      "As a cleaning business owner, I want a single-screen weekly board showing every cleaner's schedule where I can assign/reassign jobs, so that I can dispatch and rebalance the week at a glance instead of clicking through tabs. (Research: MaidCentral users explicitly wish for \"every employee's schedule for the entire week on a single screen\" — pain-points §1.1, §4)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "See the whole week at a glance", verified: true},
      %{description: "Reassign a job to another cleaner", verified: true},
      %{description: "Block reassigning onto a conflicting slot", verified: true},
      %{description: "Dispatch an unassigned job from the board", verified: true},
      %{description: "Reassignment reaches the cleaner's schedule", verified: true}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :fail, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "The weekly board shows every cleaner's jobs for the selected week on a single screen.",
          scenarios: [
            %{
              kind: "happy path",
              title: "See the whole week at a glance",
              body: "Given the company has 4 cleaners with jobs scheduled this week
When the owner opens the weekly board for that week
Then the board shows all 4 cleaners and their jobs across the seven days on one screen without switching tabs"
            }
          ]
        },
        %{
          statement: "Reassigning a job to another cleaner on the board updates that job's assignment immediately.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reassign a job to another cleaner",
              body: "Given a Wednesday job is assigned to cleaner Ana
When the owner moves the job to cleaner Ben on the board
Then the job's assigned cleaner becomes Ben
And the job no longer appears under Ana"
            }
          ]
        },
        %{
          statement: "The board blocks assigning a job to a cleaner who has an availability block or overlapping job at that time.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Block reassigning onto a conflicting slot",
              body: "Given cleaner Ben already has a job from 10am to 12pm Wednesday
When the owner tries to move a 11am Wednesday job onto Ben
Then the board rejects the move and keeps the job on its original cleaner
And the owner sees a conflict warning"
            }
          ]
        },
        %{
          statement: "Unassigned jobs for the week are visible on the board so the owner can dispatch them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Dispatch an unassigned job from the board",
              body: "Given a Thursday job has no cleaner assigned
When the owner opens the weekly board
Then the unassigned job is visible in an unassigned area
And the owner can assign it to an available cleaner from the board"
            }
          ]
        },
        %{
          statement: "A job reassigned on the board is reflected on the newly assigned cleaner's own schedule.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reassignment reaches the cleaner's schedule",
              body: "Given a job is reassigned from Ana to Ben on the board
When Ben views his own schedule for the week
Then the reassigned job appears on Ben's schedule
And it is gone from Ana's schedule"
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
    story_id: 835,
    status: :completed,
    title: "Build quotes with per-room, per-sqft, or hourly pricing",
    description:
      "As a cleaning business owner, I want to build quotes using per-room, per-square-foot, or hourly pricing models with my own rate card, so that I can quote new work quickly and profitably without an in-person walkthrough for every lead. (Research: no pricing model is clean and underpricing is the #1 owner mistake — pain-points §1.4)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Owner builds a per-room quote", verified: true},
      %{description: "Switching pricing model clears the other model's inputs", verified: true},
      %{description: "Per-square-foot total computes from the rate card", verified: true},
      %{description: "Owner quotes a phone lead without visiting the property", verified: true},
      %{description: "Missing rate on the chosen model blocks finalizing", verified: true},
      %{description: "Rate-card change does not alter an already-sent quote", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "A quote is priced using exactly one pricing model: per-room, per-square-foot, or hourly.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner builds a per-room quote",
              body: "Given the owner is creating a new quote for a lead
When the owner selects the per-room pricing model and adds 3 bedrooms and 2 bathrooms
Then the quote is priced per room and no square-footage or hourly inputs are requested"
            },
            %{
              kind: "failure path",
              title: "Switching pricing model clears the other model's inputs",
              body: "Given the owner has started a per-room quote with rooms entered
When the owner switches the pricing model to hourly
Then the per-room line items are cleared and the quote is priced only on hours, never a mix of both models"
            }
          ]
        },
        %{
          statement: "The quote total is computed by applying the owner's own saved rate card to the entered line items (rooms, square footage, or hours).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Per-square-foot total computes from the rate card",
              body: "Given the owner's rate card has a per-square-foot rate of $0.10
When the owner selects per-square-foot pricing and enters 2,000 square feet
Then the quote total is calculated as $200"
            }
          ]
        },
        %{
          statement: "A quote can be built and sent from client-supplied property details without an in-person walkthrough.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner quotes a phone lead without visiting the property",
              body: "Given a lead has given the owner their room count and square footage over the phone
When the owner builds a quote entering those details from their device
Then the owner can produce and send a complete priced quote without scheduling a site visit"
            }
          ]
        },
        %{
          statement: "A quote cannot be finalized until every line item in the chosen model has a rate, and the total is greater than zero.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Missing rate on the chosen model blocks finalizing",
              body: "Given the owner's rate card has no rate configured for the hourly model
When the owner builds an hourly quote and tries to finalize it
Then finalizing is blocked and the owner is prompted to set the missing rate before sending, preventing a zero-dollar quote"
            }
          ]
        },
        %{
          statement: "A sent quote captures the rates and amounts at the moment it was sent, so later rate-card edits do not change it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Rate-card change does not alter an already-sent quote",
              body: "Given the owner sent a quote totaling $200 using the current rate card
When the owner later raises the rate card rates
Then the previously sent quote still shows $200 and its line items are unchanged"
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
    story_id: 836,
    status: :completed,
    title: "Invoice completed jobs and collect payment",
    description:
      "As a cleaning business owner, I want jobs to generate invoices on completion and collect payment via card-on-file or payment link, so that I get paid without chasing clients and disputes are backed by proof-of-work evidence. (Research: payment failures and chargebacks are acute owner pains — pain-points §1.8)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Completing a job generates its invoice", verified: true},
      %{description: "Auto-charge the card on file", verified: true},
      %{description: "Client with no card on file pays via payment link", verified: true},
      %{description: "Invoice shows the job's proof-of-work", verified: true},
      %{description: "Card-on-file charge is declined", verified: true},
      %{description: "Invoice marked paid on provider confirmation", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:fail, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "Marking a job complete automatically generates an invoice for that job at its agreed price.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Completing a job generates its invoice",
              body: "Given a scheduled job has an agreed price of $150
When the cleaner marks the job complete
Then an invoice for $150 is generated for that job and appears in the owner's billing queue"
            }
          ]
        },
        %{
          statement: "An invoice can be collected by charging the client's card-on-file or by sending the client a payment link.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Auto-charge the card on file",
              body: "Given a client has a valid card on file
When the invoice is generated and the owner charges the card on file
Then the card is charged for the invoice amount and the client receives a receipt"
            },
            %{
              kind: "happy path",
              title: "Client with no card on file pays via payment link",
              body: "Given a client has no card on file
When the owner sends the invoice as a payment link and the client pays it online
Then the invoice is collected and the client's card can be saved for next time"
            }
          ]
        },
        %{
          statement: "Each invoice carries the completed job's proof-of-work — checklist and before/after photos — as evidence for billing disputes.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Invoice shows the job's proof-of-work",
              body: "Given a job was completed with a finished checklist and before/after photos
When the invoice for that job is opened
Then the completed checklist and photos are attached to the invoice as dispute evidence"
            }
          ]
        },
        %{
          statement: "A declined or failed card charge leaves the invoice unpaid and alerts the owner to retry or send a payment link.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Card-on-file charge is declined",
              body: "Given an invoice is set to auto-charge the card on file
When the payment provider declines the card
Then the invoice remains unpaid and the owner is alerted to retry the charge or send a payment link"
            }
          ]
        },
        %{
          statement: "An invoice is marked paid only after the payment provider confirms the charge succeeded.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Invoice marked paid on provider confirmation",
              body: "Given an invoice charge has been submitted to the payment provider
When the provider confirms the charge succeeded
Then the invoice is marked paid and the owner sees it settled in the billing queue"
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
    story_id: 837,
    status: :completed,
    title: "Send automated appointment reminders to clients",
    description:
      "As a cleaning business owner, I want automated, reliably-delivered appointment reminders (email/SMS) with confirm/reschedule actions, so that cancellations and lockouts drop and my route density holds. (Research: fragile reminder delivery is an unresolved incumbent complaint; missed appointments are the top client grievance — pain-points §1.1, §1.6)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Reminder fires at the configured lead time", verified: true},
      %{description: "Client who prefers SMS gets a text reminder", verified: true},
      %{description: "Reminder includes confirm and reschedule actions", verified: true},
      %{description: "Client confirms the appointment", verified: true},
      %{description: "Client requests a reschedule", verified: true},
      %{description: "SMS reminder is undeliverable and falls back to email", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "Each scheduled appointment automatically sends the client a reminder at the owner's configured lead time before the appointment.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reminder fires at the configured lead time",
              body: "Given the owner's reminder lead time is set to 24 hours and a client has an appointment tomorrow at 9am
When the clock reaches 9am today
Then an appointment reminder is automatically sent to the client"
            }
          ]
        },
        %{
          statement: "A reminder is delivered on the client's preferred channel — SMS or email.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client who prefers SMS gets a text reminder",
              body: "Given a client's preferred channel is SMS
When their appointment reminder is sent
Then the reminder is delivered as an SMS to the client's phone number"
            }
          ]
        },
        %{
          statement: "Every reminder gives the client one-tap confirm and reschedule actions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reminder includes confirm and reschedule actions",
              body: "Given a client receives an appointment reminder
When the client opens it
Then the reminder presents a confirm action and a reschedule action the client can tap"
            }
          ]
        },
        %{
          statement: "When a client confirms via the reminder, the appointment is marked confirmed and the owner sees the confirmation.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client confirms the appointment",
              body: "Given a client received a reminder for an unconfirmed appointment
When the client taps confirm
Then the appointment is marked confirmed and shows as confirmed on the owner's schedule"
            }
          ]
        },
        %{
          statement: "When a client requests reschedule via the reminder, the appointment is flagged for reschedule and the owner is notified to rebook.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client requests a reschedule",
              body: "Given a client received a reminder for an upcoming appointment
When the client taps reschedule
Then the appointment is flagged for reschedule and the owner is notified to rebook it, protecting route density"
            }
          ]
        },
        %{
          statement: "A reminder that fails to deliver on the primary channel falls back to the alternate channel and is flagged to the owner.",
          scenarios: [
            %{
              kind: "failure path",
              title: "SMS reminder is undeliverable and falls back to email",
              body: "Given a client prefers SMS but has blocked the reminder sender's number
When the SMS reminder fails to deliver
Then the reminder falls back to the client's email and the owner is flagged that the SMS did not reach the client"
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
    story_id: 838,
    status: :completed,
    title: "Track time and per-job pay in one system",
    description:
      "As a cleaning business owner, I want cleaner clock-in/out and per-job pay (hourly or piece-rate) tracked in the same system as scheduling, with a payroll-ready export, so that I stop running a parallel time-tracking system and pay disputes disappear. (Research: owners maintain separate clock-in systems; no payroll integration is a named ZenMaid gap — pain-points §1.3, §4)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Cleaner clocks in and out of an assigned job", verified: true},
      %{description: "Cleaner tries to clock in on a job not assigned to them", verified: true},
      %{description: "Hourly job pays rate times worked hours", verified: true},
      %{description: "Per-job piece rate pays a fixed amount regardless of time", verified: true},
      %{description: "Running pay-period total builds as jobs complete", verified: true},
      %{description: "Owner exports a completed pay period to CSV", verified: true},
      %{description: "Cleaner forgets to clock out", verified: true},
      %{description: "Export blocked while an unresolved time entry remains", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:fail, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "Worked time is recorded when a cleaner clocks in on arrival and clocks out on completion of a job assigned to them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner clocks in and out of an assigned job",
              body: "Given a job assigned to cleaner Maria scheduled for today
When Maria taps clock in on arrival at 9:00 and clock out at 11:30 on completion
Then a time entry of 2 hours 30 minutes is recorded against that job for Maria"
            },
            %{
              kind: "failure path",
              title: "Cleaner tries to clock in on a job not assigned to them",
              body: "Given a job that is not assigned to cleaner Maria
When Maria attempts to clock in on that job
Then the clock-in is rejected and no time entry is recorded"
            }
          ]
        },
        %{
          statement: "Each job's pay is calculated from its configured pay model: hourly pay equals the cleaner's rate times worked hours, and per-job pay is a fixed piece rate regardless of time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Hourly job pays rate times worked hours",
              body: "Given an hourly job with Maria's rate set to $25 per hour
When Maria records 2 hours 30 minutes of worked time on the job
Then the job's gross pay is calculated as $62.50"
            },
            %{
              kind: "happy path",
              title: "Per-job piece rate pays a fixed amount regardless of time",
              body: "Given a per-job job with a piece rate of $80
When Maria completes the job in 2 hours on one visit and another cleaner would take 3 hours
Then the job's gross pay is $80 regardless of the worked time recorded"
            }
          ]
        },
        %{
          statement: "A pay period accumulates each cleaner's gross earnings into a running total across all their jobs.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Running pay-period total builds as jobs complete",
              body: "Given a pay period in progress for Maria with an hourly job paying $62.50 already recorded
When Maria completes a second per-job job paying $80 in the same pay period
Then Maria's running pay-period total shows $142.50"
            }
          ]
        },
        %{
          statement: "The owner can export a pay period as a payroll-ready CSV listing each cleaner's hours, jobs, and gross pay.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner exports a completed pay period to CSV",
              body: "Given a closed pay period with all time entries resolved for three cleaners
When the owner exports the pay period
Then a CSV downloads with one row per cleaner showing worked hours, job count, and gross pay ready for the payroll provider"
            }
          ]
        },
        %{
          statement: "A time entry with no clock-out is flagged for owner review and excluded from pay totals and export until the owner resolves it.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Cleaner forgets to clock out",
              body: "Given Maria clocked in at 9:00 and left the job without clocking out
When the owner opens the pay period for review
Then the open time entry is flagged for review, is excluded from Maria's pay total, and the owner can set the missing clock-out time to resolve it"
            },
            %{
              kind: "failure path",
              title: "Export blocked while an unresolved time entry remains",
              body: "Given a pay period that still contains one flagged open time entry
When the owner attempts to export the pay period to CSV
Then the owner is warned that unresolved time entries exist and the export excludes or blocks until the entry is resolved"
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
    story_id: 839,
    status: :completed,
    title: "Review photo proof and quality scorecards per job",
    description:
      "As a cleaning business owner, I want completed jobs to show checklist completion, before/after photos, and a quality scorecard per cleaner over time, so that I can verify work I can't inspect in person, coach consistently, and defend against complaints and chargebacks. (Research: verification is standard in STR tools but absent in residential/janitorial — the #3 synthesis gap — pain-points §1.5, §5)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Cleaner completes a job with a fully checked checklist", verified: true},
      %{description: "Cleaner tries to complete with unchecked required tasks", verified: true},
      %{description: "Before and after photos attached with timestamps", verified: true},
      %{description: "Completed job gets a quality score", verified: true},
      %{description: "Owner reviews a cleaner's scorecard over time", verified: true},
      %{description: "Owner pulls up job proof to answer a chargeback", verified: true},
      %{description: "Photo taken offline uploads when signal returns", verified: true}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "A job cannot be marked complete until every required checklist task is checked off or explicitly marked skipped with a reason.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner completes a job with a fully checked checklist",
              body: "Given a job with a room-by-room checklist of ten required tasks
When the cleaner checks off all ten tasks and taps complete
Then the job is marked complete with checklist completion recorded"
            },
            %{
              kind: "failure path",
              title: "Cleaner tries to complete with unchecked required tasks",
              body: "Given a job checklist with two required tasks still unchecked
When the cleaner taps complete
Then completion is blocked and the cleaner is prompted to check off or mark the remaining tasks skipped with a reason before the job can close"
            }
          ]
        },
        %{
          statement: "Required before and after photos are captured per photo task and attached to the completed job with a timestamp.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Before and after photos attached with timestamps",
              body: "Given a checklist task that requires a before and an after photo of the kitchen
When the cleaner captures both photos during the job
Then both photos are attached to the completed job, each stamped with the time it was taken"
            }
          ]
        },
        %{
          statement: "Each completed job produces a quality score derived from checklist completion and any owner quality review of the job.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Completed job gets a quality score",
              body: "Given a completed job with full checklist completion and all required photos
When the owner reviews the job and rates it four out of five
Then the job records a quality score combining checklist completion and the owner's rating"
            }
          ]
        },
        %{
          statement: "A per-cleaner quality scorecard aggregates that cleaner's job scores over time so the owner can spot trends and coach.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner reviews a cleaner's scorecard over time",
              body: "Given a cleaner with twenty scored jobs over the last month
When the owner opens that cleaner's quality scorecard
Then the scorecard shows the average score and the trend across those jobs so the owner can coach on declining areas"
            }
          ]
        },
        %{
          statement: "Completed-job proof — checklist state, photos, and timestamps — is retained and retrievable so the owner can defend against a complaint or chargeback.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner pulls up job proof to answer a chargeback",
              body: "Given a client disputes a charge claiming the job was not done
When the owner opens the completed job from three weeks ago
Then the owner sees the completed checklist, before and after photos, and timestamps to present as proof the work was performed"
            }
          ]
        },
        %{
          statement: "Photos captured while the cleaner has no connection are queued on the device and uploaded automatically when connectivity returns.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Photo taken offline uploads when signal returns",
              body: "Given a cleaner in a basement with no cell signal captures the required after photos
When the photo upload cannot reach the server
Then the photos are queued on the device and upload automatically once the cleaner regains connectivity, without the cleaner having to retake them"
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
    story_id: 840,
    status: :completed,
    title: "See an audit trail of schedule and record changes",
    description:
      "As a cleaning business owner, I want an audit trail showing who changed what (jobs, assignments, client records, prices) and when, so that I can untangle scheduling mistakes and hold my office team accountable. (Research: direct MaidCentral user wish — \"an audit trail feature to track who makes changes\" — pain-points §4)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Office staff reschedules a job and it is logged", verified: true},
      %{description: "Price change records old and new value", verified: true},
      %{description: "Nobody can alter or delete an audit entry", verified: true},
      %{description: "Owner filters the trail to find who moved a job", verified: true},
      %{description: "Automated recurring job generation is attributed to the system", verified: true}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "Every create, update, or delete of an audited record — job, assignment, client record, or price — records who made the change, what changed, and when.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Office staff reschedules a job and it is logged",
              body: "Given office staffer Dana is signed in
When Dana moves a job from Tuesday 9:00 to Wednesday 1:00
Then an audit entry records that Dana rescheduled that job, the old and new times, and the timestamp of the change"
            }
          ]
        },
        %{
          statement: "Each audit entry captures the before and after values of the fields that changed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Price change records old and new value",
              body: "Given a client's recurring job is priced at $120
When Dana changes the price to $140
Then the audit entry shows the price field changed from $120 to $140 and leaves other unchanged fields out of the entry"
            }
          ]
        },
        %{
          statement: "The audit log is append-only per company — entries cannot be edited or deleted by anyone, including the owner.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Nobody can alter or delete an audit entry",
              body: "Given an audit entry recording a disputed schedule change
When the owner or any user attempts to edit or delete that entry
Then the system provides no way to modify or remove it and the entry remains intact"
            }
          ]
        },
        %{
          statement: "The owner can filter the audit trail by user, record type, specific record, and date range to untangle a change.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner filters the trail to find who moved a job",
              body: "Given a client complains their Friday job vanished from the schedule
When the owner filters the audit trail to that job over the past week
Then the owner sees the entry showing which user deleted or moved the job and when"
            }
          ]
        },
        %{
          statement: "A change made by an automated or system process is attributed to the system so that every audit entry has a named actor.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Automated recurring job generation is attributed to the system",
              body: "Given a recurring plan that automatically generates next week's jobs overnight
When the system creates those jobs with no human involved
Then each resulting audit entry names the system as the actor rather than showing a blank author"
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
    story_id: 841,
    status: :completed,
    title: "See today's jobs with everything needed to get in the door",
    description:
      "As a cleaner, I want a mobile day view listing my jobs in order with address, parking, entry method, codes, pet notes, and client preferences on each job card, so that I never dig through group texts or get locked out. (Research: scattered access info causes lockouts; group chats bury critical details — pain-points §2.2, §2.5)",
    tags: [%{name: "cleaner"}],
    criteria: [
      %{description: "Cleaner sees today's jobs in start-time order", verified: true},
      %{description: "Another cleaner's jobs are not shown", verified: true},
      %{description: "Access code appears on the day of the job", verified: true},
      %{description: "Access code stays hidden before the job date", verified: true},
      %{description: "Job card shows the full get-in-the-door brief", verified: true},
      %{description: "Missing optional detail shows a clear placeholder", verified: true},
      %{description: "Updated lockbox code propagates to future jobs", verified: true},
      %{description: "Day off shows an empty-day state", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaner", slug: "cleaner", type: "proto"},
      rules: [
        %{
          statement: "The day view lists only the signed-in cleaner's own jobs for the selected day, ordered by scheduled start time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner sees today's jobs in start-time order",
              body: "Given I am a cleaner signed in on my phone
And I have three jobs scheduled for today at 9:00, 12:30, and 15:00
When I open the day view
Then I see exactly those three job cards
And they are ordered 9:00, then 12:30, then 15:00"
            },
            %{
              kind: "failure path",
              title: "Another cleaner's jobs are not shown",
              body: "Given I am a cleaner signed in on my phone
And a coworker has a job scheduled for today that is not assigned to me
When I open the day view
Then the coworker's job does not appear on my list"
            }
          ]
        },
        %{
          statement: "Lockbox and alarm access codes are revealed on a job card only on the job's scheduled date, and are masked before then.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Access code appears on the day of the job",
              body: "Given I have a job scheduled for today with a lockbox code and an alarm code on file
When I open that job card
Then the lockbox code and alarm code are shown in full"
            },
            %{
              kind: "failure path",
              title: "Access code stays hidden before the job date",
              body: "Given I have a job scheduled for tomorrow with a lockbox code on file
When I view that upcoming job before its scheduled date
Then the lockbox code is masked
And the card indicates the code unlocks on the day of the job"
            }
          ]
        },
        %{
          statement: "Each job card displays address, parking notes, entry method, pet notes, and client preferences drawn from the property record.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Job card shows the full get-in-the-door brief",
              body: "Given my job's property has an address, parking notes, entry method, pet notes, and client preferences on file
When I open the job card
Then I see the address, parking notes, entry method, pet notes, and client preferences all on that card"
            },
            %{
              kind: "failure path",
              title: "Missing optional detail shows a clear placeholder",
              body: "Given my job's property has no parking notes recorded
When I open the job card
Then the parking section shows an explicit \"No parking notes\" placeholder
And the card does not error or leave the section blank"
            }
          ]
        },
        %{
          statement: "When a property's access details change, every future job for that property reflects the updated details with no manual re-entry per job.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Updated lockbox code propagates to future jobs",
              body: "Given a property with a lockbox code has jobs assigned to me today and on future dates
When the office updates that property's lockbox code
Then today's job reveals the new code on my day view
And no job — today or future — ever shows the old code
And future jobs keep the code masked until their own date (per criterion 7133), revealing the updated code when the day arrives, with no per-job re-entry
(Reconciled with criterion 7133: masking-before-day-of wins; propagation is observed via a day-of job showing the new code.)"
            }
          ]
        },
        %{
          statement: "A cleaner with no jobs scheduled for the selected day sees an explicit empty-day state rather than a blank screen.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Day off shows an empty-day state",
              body: "Given I have no jobs scheduled for today
When I open the day view
Then I see a message telling me I have no jobs today
And I am not shown a blank or broken screen"
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
    story_id: 842,
    status: :completed,
    title: "Work each job from a room-by-room checklist with photo proof",
    description:
      "As a cleaner, I want each job to present a room-by-room checklist defining exactly what's in scope, with the ability to check off tasks and attach before/after photos, so that scope is never ambiguous and I'm protected from \"missed spot\" blame for tasks that weren't agreed to. (Research: scope ambiguity is the top cleaner frustration; photo checklists proven by STR tools — pain-points §2.1, §3.3)",
    tags: [%{name: "cleaner"}],
    criteria: [
      %{description: "Checklist opens grouped by room", verified: true},
      %{description: "Out-of-scope task is not on the checklist", verified: true},
      %{description: "Checking tasks advances progress", verified: true},
      %{description: "Before and after photos attach to a task", verified: true},
      %{description: "Job completes when all required items are done", verified: true},
      %{description: "Completion blocked with a required task unchecked", verified: true},
      %{description: "Photo taken offline uploads when signal returns", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaner", slug: "cleaner", type: "proto"},
      rules: [
        %{
          statement: "Each job presents a room-by-room checklist generated from that property's checklist template.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Checklist opens grouped by room",
              body: "Given my job's property has a checklist template with tasks for Kitchen, Bathroom, and Bedroom
When I open the job's checklist
Then I see the tasks grouped under Kitchen, Bathroom, and Bedroom
And each task from the template appears under its room"
            }
          ]
        },
        %{
          statement: "The checklist is the authoritative scope for the job: only tasks on the checklist are in scope, and completed checklists are retained as proof of what was agreed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Out-of-scope task is not on the checklist",
              body: "Given my job's checklist does not include \"clean inside oven\"
When I complete every task on the checklist and finish the job
Then the completed checklist is retained showing no oven task
And it serves as proof that cleaning inside the oven was out of scope"
            }
          ]
        },
        %{
          statement: "A cleaner can check off individual checklist tasks, and the job shows progress as completed-of-total tasks.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Checking tasks advances progress",
              body: "Given my job's checklist has 10 tasks and none are checked
When I check off 4 tasks
Then the job shows progress as 4 of 10 tasks complete"
            }
          ]
        },
        %{
          statement: "A cleaner can attach before and after photos to a task or room, each stored with a timestamp.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Before and after photos attach to a task",
              body: "Given I am working the Kitchen task on my job
When I attach a before photo and an after photo to that task
Then both photos are shown on the task
And each photo is stored with the time it was captured"
            }
          ]
        },
        %{
          statement: "A job can be marked complete only when every required task is checked and every required photo is attached.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Job completes when all required items are done",
              body: "Given every required task on my job is checked
And every required photo is attached
When I mark the job complete
Then the job is accepted as complete"
            },
            %{
              kind: "failure path",
              title: "Completion blocked with a required task unchecked",
              body: "Given one required task on my job is still unchecked
When I try to mark the job complete
Then completion is blocked
And I am told which required task or photo is still missing"
            }
          ]
        },
        %{
          statement: "A photo upload that fails on poor connectivity is queued and retried, not silently dropped.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Photo taken offline uploads when signal returns",
              body: "Given I am in a home with no cell signal
When I attach a photo to a task
Then the photo is queued and marked as pending upload
And when signal returns the photo uploads automatically without me re-taking it"
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
    story_id: 843,
    status: :completed,
    title: "Get loud, acknowledged alerts when my schedule changes",
    description:
      "As a cleaner, I want schedule changes (added/moved/cancelled jobs) pushed to me as notifications that I explicitly acknowledge — with the office seeing unacknowledged changes — so that mid-day changes actually reach me and same-day cleanings aren't silently missed. (Research: undelivered assignment changes are the most common cause of missed same-day cleanings — pain-points §2.4)",
    tags: [%{name: "cleaner"}],
    criteria: [
      %{description: "Moved job notifies the cleaner", verified: true},
      %{description: "Cancelled job notifies the cleaner", verified: true},
      %{description: "Acknowledging clears the pending change", verified: true},
      %{description: "Unacknowledged change keeps prompting", verified: true},
      %{description: "Office sees who has not acknowledged", verified: true},
      %{description: "Never-acknowledged same-day change escalates", verified: true},
      %{description: "Push failure falls back to SMS", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaner", slug: "cleaner", type: "proto"},
      rules: [
        %{
          statement: "Every schedule change (added, moved, or cancelled job) affecting a cleaner's day sends that cleaner a notification.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Moved job notifies the cleaner",
              body: "Given I am a cleaner with a job scheduled today at 1:00 PM
When the office moves that job to 3:00 PM
Then I receive a notification describing the change from 1:00 PM to 3:00 PM"
            },
            %{
              kind: "happy path",
              title: "Cancelled job notifies the cleaner",
              body: "Given I have a job scheduled for later today
When the office cancels that job
Then I receive a notification that the job has been cancelled"
            }
          ]
        },
        %{
          statement: "A schedule-change notification stays pending and keeps prompting the cleaner until it is explicitly acknowledged.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Acknowledging clears the pending change",
              body: "Given I have a pending schedule-change notification
When I tap acknowledge on it
Then the change is marked acknowledged
And it stops prompting me"
            },
            %{
              kind: "failure path",
              title: "Unacknowledged change keeps prompting",
              body: "Given I have a schedule-change notification I have not acknowledged
When I dismiss it or close the app without acknowledging
Then the change remains pending
And I am prompted about it again when I next open the app"
            }
          ]
        },
        %{
          statement: "The office can see the acknowledgment status of each change and which cleaners still have unacknowledged changes.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Office sees who has not acknowledged",
              body: "Given the office pushed a schedule change to a cleaner
And the cleaner has not acknowledged it
When the office views the change
Then it shows as unacknowledged for that cleaner
And once the cleaner acknowledges, the office sees it flip to acknowledged"
            }
          ]
        },
        %{
          statement: "A same-day change left unacknowledged past the escalation window (default 10 minutes) is escalated: re-sent via fallback channel and flagged to the office.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Never-acknowledged same-day change escalates",
              body: "Given the office pushed a same-day schedule change to me 10 minutes ago
And I still have not acknowledged it
When the escalation window elapses
Then the notification is re-sent to me via the fallback channel
And the change is flagged to the office as unacknowledged and escalated"
            }
          ]
        },
        %{
          statement: "If the primary push channel fails to deliver, the notification falls back to SMS so the change still reaches the cleaner.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Push failure falls back to SMS",
              body: "Given a schedule change needs to reach me
And my push notification cannot be delivered
When the system sends the change
Then it falls back to sending me an SMS with the change details"
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
    story_id: 844,
    status: :completed,
    title: "Clock in/out per job and see my earnings build",
    description:
      "As a cleaner, I want to clock in/out on each job (or see its piece-rate) and watch my per-job and pay-period earnings accumulate transparently, so that I trust I'm being paid for all my work including drive time policies I can see. (Research: pay opacity and unpaid drive time breed distrust; pay transparency is the stickiest cleaner feature — pain-points §2.3)",
    tags: [%{name: "cleaner"}],
    criteria: [
      %{description: "Cleaner clocks in to their assigned job", verified: true},
      %{description: "Cleaner cannot clock in to a job assigned to someone else", verified: true},
      %{description: "Clocking in to a second job while already clocked in", verified: true},
      %{description: "Clock out then clock in to the next job", verified: true},
      %{description: "Hourly job earnings computed from clocked time", verified: true},
      %{description: "Piece-rate job shows its fixed rate up front", verified: true},
      %{description: "Running pay-period total grows as jobs complete", verified: true},
      %{description: "Cleaner sees the drive-time policy with their earnings", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaner", slug: "cleaner", type: "proto"},
      rules: [
        %{
          statement: "A cleaner can only clock in to a job that is assigned to them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner clocks in to their assigned job",
              body: "Given I am a cleaner assigned to today's 9:00 AM job at the Smith home
When I open that job and tap Clock In
Then I am clocked in and the job shows a running elapsed time starting now"
            },
            %{
              kind: "failure path",
              title: "Cleaner cannot clock in to a job assigned to someone else",
              body: "Given a job at the Jones home is assigned to another cleaner, not me
When I attempt to open that job
Then I am redirected away with an error explaining the job is not assigned to me
And I cannot start time on it
(Reconciled with story 838 criterion 7123: the job page exposes entry codes, so unassigned cleaners must not open it at all — \"cannot clock in\" follows from \"cannot open\".)"
            }
          ]
        },
        %{
          statement: "A cleaner can be clocked in to only one job at a time.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Clocking in to a second job while already clocked in",
              body: "Given I am already clocked in to the 9:00 AM Smith job
When I open my 11:00 AM job and tap Clock In
Then I am warned that I am still clocked in to the Smith job and must clock out there first before starting the new one"
            },
            %{
              kind: "happy path",
              title: "Clock out then clock in to the next job",
              body: "Given I am clocked in to the Smith job
When I tap Clock Out on the Smith job and then Clock In on my next job
Then the Smith job's time is closed and the next job begins accumulating time"
            }
          ]
        },
        %{
          statement: "Each job shows its pay basis — hourly clock time or fixed piece-rate — and its earnings are computed on that basis.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Hourly job earnings computed from clocked time",
              body: "Given the Smith job pays hourly at $25/hour
When I clock out after 2 hours of clocked time
Then the job shows earnings of $50 for that visit"
            },
            %{
              kind: "happy path",
              title: "Piece-rate job shows its fixed rate up front",
              body: "Given the Jones job pays a fixed piece-rate of $60
When I open the job before starting
Then it clearly shows I will earn $60 for this job regardless of how long it takes"
            }
          ]
        },
        %{
          statement: "Pay-period earnings accumulate as a running total the cleaner can see at any time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Running pay-period total grows as jobs complete",
              body: "Given I have completed two jobs this pay period earning $50 and $60
When I view my earnings summary
Then the current pay period shows a running total of $110"
            }
          ]
        },
        %{
          statement: "The company's drive-time pay policy is shown to the cleaner alongside their earnings.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner sees the drive-time policy with their earnings",
              body: "Given my company's policy is that drive time between jobs is unpaid
When I view my earnings summary
Then the drive-time policy is stated plainly so I understand what is and is not counted in my pay"
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
    story_id: 845,
    status: :completed,
    title: "Report damage, missing items, or unsafe conditions from the job",
    description:
      "As a cleaner, I want to file a timestamped photo report of damage, missing items, or unsafe conditions directly from the job screen, so that the office and client hear it from the record — not a text thread — and I'm protected from blame. (Research: damage/missing-item reporting is standard in STR tools and absent elsewhere; lone-worker safety is under-served — pain-points §2.7, §3.3)",
    tags: [%{name: "cleaner"}],
    criteria: [
      %{description: "Cleaner files a damage report from the job screen", verified: true},
      %{description: "Report carries the filing time and cleaner automatically", verified: true},
      %{description: "Submitted report cannot be altered", verified: true},
      %{description: "Damage report without a photo is blocked", verified: true},
      %{description: "Unsafe-condition report can be filed without a photo", verified: true},
      %{description: "Office is notified when a report is filed", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaner", slug: "cleaner", type: "proto"},
      rules: [
        %{
          statement: "An incident report is filed against a specific job and typed as damage, missing item, or unsafe condition.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleaner files a damage report from the job screen",
              body: "Given I am on the job screen for the Smith home and notice a cracked mirror
When I file a report, choose the Damage type, and describe the cracked mirror
Then a damage report is created and attached to the Smith job"
            }
          ]
        },
        %{
          statement: "Each incident report is automatically stamped with the time it was filed and the cleaner who filed it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Report carries the filing time and cleaner automatically",
              body: "Given I file an unsafe-condition report at 2:15 PM
When the report is created
Then it records that I filed it at 2:15 PM without my having to enter the time or my name"
            }
          ]
        },
        %{
          statement: "A submitted incident report cannot be edited or deleted — it is a permanent record.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Submitted report cannot be altered",
              body: "Given I submitted a damage report an hour ago
When I reopen that report
Then it is shown read-only with no option to edit or delete it, so the record stands as filed"
            }
          ]
        },
        %{
          statement: "A damage or missing-item report requires at least one photo before it can be submitted.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Damage report without a photo is blocked",
              body: "Given I am filing a damage report for the cracked mirror
When I try to submit without attaching a photo
Then submission is blocked and I am prompted to add at least one photo first"
            },
            %{
              kind: "happy path",
              title: "Unsafe-condition report can be filed without a photo",
              body: "Given I encounter an aggressive dog and need to leave the property immediately
When I file an unsafe-condition report without a photo
Then the report is accepted, because photo is required only for damage and missing-item types, not when my safety requires leaving"
            }
          ]
        },
        %{
          statement: "Filing an incident report notifies the office.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Office is notified when a report is filed",
              body: "Given I submit a missing-item report for a missing TV remote
When the report is filed
Then the office is notified of the report so they hear it from the record rather than a text thread"
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
    story_id: 846,
    status: :completed,
    title: "Keep the same cleaner on the same home",
    description:
      "As a cleaning business owner, I want recurring plans to prefer the client's assigned cleaner and warn me when I assign someone else, so that clients get the consistency they pay for and retention stays high. (Research: same-cleaner-to-same-home matching is a distinct residential pain — pain-points §3.1)",
    tags: [%{name: "owner"}],
    criteria: [
      %{description: "Owner sets a preferred cleaner on a recurring plan", verified: true},
      %{description: "New recurring visit is pre-assigned to the preferred cleaner", verified: true},
      %{description: "Owner is warned when reassigning away from the preferred cleaner", verified: true},
      %{description: "Substitute for one visit leaves the plan's preferred cleaner intact", verified: true},
      %{description: "No warning when the plan has no preferred cleaner", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Business Owner", slug: "cleaning-business-owner", type: "proto"},
      rules: [
        %{
          statement: "A client's recurring plan can name a preferred cleaner for that home.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner sets a preferred cleaner on a recurring plan",
              body: "Given the Smith home has a biweekly recurring plan
When I set Maria as the preferred cleaner on that plan
Then the plan records Maria as the client's preferred cleaner for the Smith home"
            }
          ]
        },
        %{
          statement: "Visits generated from a recurring plan default to the client's preferred cleaner.",
          scenarios: [
            %{
              kind: "happy path",
              title: "New recurring visit is pre-assigned to the preferred cleaner",
              body: "Given Maria is the preferred cleaner on the Smith home's biweekly plan
When the next visit is generated for the plan
Then that visit is assigned to Maria by default"
            }
          ]
        },
        %{
          statement: "Assigning a cleaner other than the client's preferred cleaner warns the owner before it is saved.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Owner is warned when reassigning away from the preferred cleaner",
              body: "Given Maria is the preferred cleaner for the Smith home's next visit
When I change that visit's assignment to David
Then I am warned that David is not the client's preferred cleaner before the change is saved"
            }
          ]
        },
        %{
          statement: "The owner can accept the warning and assign a substitute for a single visit without changing the plan's preferred cleaner.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Substitute for one visit leaves the plan's preferred cleaner intact",
              body: "Given Maria is out sick and I have been warned that David is not the preferred cleaner
When I confirm assigning David to this one visit
Then this visit is assigned to David and the Smith plan still lists Maria as the preferred cleaner for future visits"
            }
          ]
        },
        %{
          statement: "A recurring plan with no preferred cleaner produces no consistency warning on assignment.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No warning when the plan has no preferred cleaner",
              body: "Given the Jones home's recurring plan has no preferred cleaner set
When I assign David to the next visit
Then the assignment saves with no consistency warning"
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
    story_id: 848,
    status: :completed,
    title: "Get an instant quote from the public website",
    description:
      "As a cleaning client, I want a public instant-quote form (bedrooms, bathrooms, square footage, frequency, add-ons) that shows me a real price from the company's rate card before I hand over contact details, so that I can decide in one sitting instead of waiting for a callback I may never answer. (Research: instant-quote booking forms are the residential standard and convert where request-a-quote friction loses time-pressured jobs — customer-side.md §1, §3)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Building a quote with room counts shows a price with no contact info", verified: true},
      %{description: "Building a quote by square footage instead of room counts", verified: true},
      %{description: "Changing any input recomputes the total live", verified: true},
      %{description: "Selecting bi-weekly frequency applies the recurring discount", verified: true},
      %{description: "Selecting add-ons increases the running total", verified: true},
      %{description: "Unsupported input combination shows a message instead of a wrong price", verified: true},
      %{description: "Instant quote price matches the later acceptance total", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "The quote form computes a price from the business's active rate card (per-room, per-square-foot, or hourly) based on service type, size inputs, frequency, and selected add-ons — no contact information is required to see the price.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Building a quote with room counts shows a price with no contact info",
              body: "Given a business with a per-room rate card and a visitor on the public quote page
When the visitor selects a service type, bedroom count, and bathroom count without entering a name, email, or phone
Then a real price computed from the rate card is displayed immediately"
            },
            %{
              kind: "happy path",
              title: "Building a quote by square footage instead of room counts",
              body: "Given a business with a per-square-foot rate card
When the visitor enters the home's square footage and a service type
Then the displayed price is computed using the per-square-foot rate"
            }
          ]
        },
        %{
          statement: "The displayed price updates immediately as the customer changes any input (rooms, bathrooms, square footage, frequency, add-ons).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Changing any input recomputes the total live",
              body: "Given a quote is currently displayed for a 2-bedroom home
When the visitor changes the bedroom count to 3
Then the displayed price updates immediately to reflect the new bedroom count without a page reload"
            }
          ]
        },
        %{
          statement: "Selecting a recurring frequency applies the rate card's configured discount to the subtotal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Selecting bi-weekly frequency applies the recurring discount",
              body: "Given a one-time quote subtotal has been computed
When the visitor changes the frequency to bi-weekly
Then the displayed total is reduced by the rate card's configured bi-weekly discount"
            }
          ]
        },
        %{
          statement: "Each selected add-on adds its configured amount to the running total.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Selecting add-ons increases the running total",
              body: "Given a base quote is displayed with no add-ons selected
When the visitor selects \"inside fridge\" and \"interior windows\" add-ons
Then the running total increases by the sum of both add-ons' configured amounts"
            }
          ]
        },
        %{
          statement: "If the client's inputs fall outside what the business's rate card can price, the form shows a clear message and withholds a price rather than guessing or showing a wrong number.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Unsupported input combination shows a message instead of a wrong price",
              body: "Given a business's rate card has no configured price for a selected service type and size combination
When the visitor selects that unsupported combination
Then the form shows a clear \"can't price this yet, request a custom quote\" message instead of displaying $0 or a guessed price"
            }
          ]
        },
        %{
          statement: "The quoted price is the same number that carries through to acceptance and booking — no hidden fees are added afterward.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Instant quote price matches the later acceptance total",
              body: "Given a visitor sees an instant quote total of $195 in integer cents
When they proceed to the accept-and-book step without changing any selections
Then the total shown at acceptance is exactly $195 with no added fees"
            }
          ]
        }
      ],
      questions: [
        %{body: "Does the instant quote form need to support all three of Quoting's rate card types (per-room, per-sqft, hourly), or just one?", status: :resolved, resolution: nil},
        %{body: "Should bedroom/bathroom counts allow fractional values (e.g. 2.5 baths)?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 849,
    status: :completed,
    title: "Accept a quote and book online with card on file",
    description:
      "As a cleaning client, I want to accept my quote online — pick a slot, agree to the cancellation policy, and put a card on file — so that booking is done in minutes and the price I saw is the price I'm charged. (Research: Jobber captures cards at quote acceptance; capturing policy agreement at booking is best practice; bait-and-switch pricing is a top category complaint — customer-side.md §1, §2)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Client selects an open slot and proceeds to review", verified: true},
      %{description: "Selected slot becomes unavailable before confirmation", verified: true},
      %{description: "Client views and agrees to the cancellation policy before confirming", verified: true},
      %{description: "Booking is blocked without cancellation policy agreement", verified: true},
      %{description: "Client enters a valid card and the booking confirms", verified: true},
      %{description: "Payment gateway declines the card", verified: true},
      %{description: "Card is authorized for the exact quoted amount", verified: true},
      %{description: "Confirmed booking appears for client and business with portal access", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "Booking requires an available time slot to be selected before the client can confirm.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client selects an open slot and proceeds to review",
              body: "Given a client has an accepted instant quote and the business has open slots
When the client selects an available date and time
Then the booking flow proceeds to cancellation policy and payment"
            },
            %{
              kind: "failure path",
              title: "Selected slot becomes unavailable before confirmation",
              body: "Given a client has selected a time slot but another booking claims it first
When the client attempts to confirm the booking
Then the booking is blocked with a message to pick another slot and no charge is made"
            }
          ]
        },
        %{
          statement: "The client must explicitly agree to the cancellation policy — the 24-hour notice window and the fee — before the booking can be confirmed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client views and agrees to the cancellation policy before confirming",
              body: "Given the client has selected a slot and reached the confirmation step
When the cancellation policy (24-hour notice and fee) is displayed and the client checks agreement
Then the client is allowed to proceed to payment"
            },
            %{
              kind: "failure path",
              title: "Booking is blocked without cancellation policy agreement",
              body: "Given the client has selected a slot and reached the confirmation step
When the client tries to confirm without checking the cancellation policy agreement
Then the booking is not confirmed and the client is prompted to agree first"
            }
          ]
        },
        %{
          statement: "A valid payment card must be captured and stored on file via the payment gateway before the booking is confirmed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client enters a valid card and the booking confirms",
              body: "Given the client has agreed to the cancellation policy
When the client enters a valid card and the payment gateway accepts it
Then the card is stored on file and the booking is confirmed"
            },
            %{
              kind: "failure path",
              title: "Payment gateway declines the card",
              body: "Given the client has agreed to the cancellation policy and submitted a card
When the payment gateway declines the card
Then the booking is not confirmed and the client is prompted to retry with a different card"
            }
          ]
        },
        %{
          statement: "The amount authorized on the client's card at booking is exactly the quoted price the client saw, in integer cents — the same number later invoiced at job completion, with no adjustment.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Card is authorized for the exact quoted amount",
              body: "Given the client saw an instant quote total of $195 in integer cents
When the client completes booking with a valid card
Then the gateway authorizes exactly $195 with no added fee"
            }
          ]
        },
        %{
          statement: "Confirming the booking converts the accepted quote into a scheduled job visible to both the client and the business, and sends the client a confirmation with portal access.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Confirmed booking appears for client and business with portal access",
              body: "Given the booking has been confirmed with card on file
When the confirmation completes
Then the visit appears as scheduled for both the business and the client, and the client receives a confirmation containing a magic-link to their portal"
            }
          ]
        }
      ],
      questions: [
        %{body: "Does accepting the quote authorize/charge the card immediately at booking, or just tokenize it for later charge on job completion?", status: :resolved, resolution: nil},
        %{body: "Is a deposit required at booking, separate from the full invoice charged on job completion?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 850,
    status: :completed,
    title: "See my visits, cleaner, and proof-of-work in a client portal",
    description:
      "As a cleaning client, I want a portal showing my upcoming visits with the named, photo-identified cleaner assigned, plus my service history with checklist results and before/after photos, so that I know who is entering my home and can see exactly what I paid for. (Research: trust is the #1 gate — 73% of bad experiences trace to trust; Jobber's Client Hub shows assigned-team photos for this reason — customer-side.md §1, §2)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Client opens the portal via a valid magic link", verified: true},
      %{description: "Expired or invalid magic link denies access", verified: true},
      %{description: "Upcoming visit shows the assigned cleaner's name and photo", verified: true},
      %{description: "Reassigning the cleaner updates what the client sees", verified: true},
      %{description: "Unassigned upcoming visit shows a placeholder", verified: true},
      %{description: "Completed visit in history shows checklist and before/after photos", verified: true},
      %{description: "Portal proof-of-work matches the invoice's evidence", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "Portal access is granted via a unique magic-link token tied to the client — there is no username/password login.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client opens the portal via a valid magic link",
              body: "Given a client has been sent a magic-link token for their portal
When the client follows the link
Then the portal opens showing their upcoming visits and service history without requiring a password"
            },
            %{
              kind: "failure path",
              title: "Expired or invalid magic link denies access",
              body: "Given a client's magic-link token has expired or is invalid
When the client follows the link
Then access to the portal is denied and the client is offered a way to request a fresh link"
            }
          ]
        },
        %{
          statement: "Upcoming visits display the date/time and the named, photo-identified cleaner assigned to that visit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Upcoming visit shows the assigned cleaner's name and photo",
              body: "Given a client has an upcoming visit with a cleaner assigned
When the client views the portal
Then the visit shows the date/time along with the cleaner's name and photo"
            },
            %{
              kind: "happy path",
              title: "Reassigning the cleaner updates what the client sees",
              body: "Given a client's upcoming visit currently shows Cleaner A
When the business reassigns the visit to Cleaner B
Then the client's portal shows Cleaner B's name and photo the next time it is viewed"
            }
          ]
        },
        %{
          statement: "A visit with no cleaner assigned yet shows a clear \"not yet assigned\" state instead of a blank or broken cleaner card.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Unassigned upcoming visit shows a placeholder",
              body: "Given a client has an upcoming visit that has no cleaner assigned yet
When the client views the portal
Then the visit shows a \"cleaner not yet assigned\" placeholder instead of a blank or broken card"
            }
          ]
        },
        %{
          statement: "Completed visits show the finished checklist results and before/after photos as proof-of-work in the client's service history.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Completed visit in history shows checklist and before/after photos",
              body: "Given a client has a past visit that was completed with a finished checklist and before/after photos
When the client views that visit in their service history
Then the checklist results and before/after photos are displayed"
            }
          ]
        },
        %{
          statement: "The proof-of-work shown in the portal for a completed visit is the same evidence attached to that visit's invoice.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Portal proof-of-work matches the invoice's evidence",
              body: "Given a completed visit has an invoice with attached checklist and photos as dispute evidence
When the client views that same visit in the portal
Then the checklist and photos shown match exactly what is attached to the invoice"
            }
          ]
        }
      ],
      questions: [
        %{body: "How long does a magic-link token stay valid before it expires and needs reissuing?", status: :resolved, resolution: nil},
        %{body: "Does the portal show trust badges (bonded/insured/background-checked) alongside the assigned cleaner, or is that a separate story?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 851,
    status: :completed,
    title: "Reschedule or cancel a visit within the policy",
    description:
      "As a cleaning client, I want to reschedule or cancel an upcoming visit from the portal within the company's stated notice policy (with any late fee shown before I confirm), so that I stay in control without phone tag and the company isn't blindsided. (Research: self-service reschedule/cancel within a 24–48h policy is the expectation; captured policy agreement prevents disputes — customer-side.md §1)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Client reschedules a visit from the portal", verified: true},
      %{description: "Late cancellation shows fee before confirming", verified: true},
      %{description: "On-time cancellation has no fee", verified: true},
      %{description: "Reschedule notifies office and cleaner", verified: true},
      %{description: "Reschedule preserves price and scope", verified: true},
      %{description: "Cannot modify a completed visit", verified: true},
      %{description: "Same-day cancellation charges the maximum fee", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "A client can reschedule or cancel an upcoming visit from the portal via their magic-link session, without contacting the office.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client reschedules a visit from the portal",
              body: "Given a client has an upcoming visit scheduled 3 days from now
When they open the portal via their magic link and select a new date/time outside the notice window
Then the visit is rescheduled to the new date/time and no fee is shown"
            }
          ]
        },
        %{
          statement: "Cancelling or rescheduling inside the notice window displays the applicable late fee (percent or flat, as configured) and requires the client to confirm before the change is finalized.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Late cancellation shows fee before confirming",
              body: "Given a client's visit starts in 12 hours, inside the 24h notice window, and the company charges a 50% late fee
When the client attempts to cancel from the portal
Then the portal displays the late fee amount and requires the client to confirm before the cancellation is finalized"
            }
          ]
        },
        %{
          statement: "Cancelling or rescheduling at or beyond the notice window incurs no fee.",
          scenarios: [
            %{
              kind: "happy path",
              title: "On-time cancellation has no fee",
              body: "Given a client's visit is 3 days away, outside the 24h notice window
When the client cancels from the portal
Then the visit is cancelled immediately with no fee charged"
            }
          ]
        },
        %{
          statement: "A confirmed reschedule or cancellation notifies the office and the assigned cleaner through the schedule-change alert path.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reschedule notifies office and cleaner",
              body: "Given a client confirms a reschedule of their visit
When the change is saved
Then the office and the assigned cleaner receive a schedule-change alert reflecting the new date/time"
            }
          ]
        },
        %{
          statement: "Rescheduling changes only the date/time of the visit; the price and scope are unaffected.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reschedule preserves price and scope",
              body: "Given a client reschedules a visit
When the new time is confirmed
Then the job's price and scope remain unchanged and only the schedule is updated"
            }
          ]
        },
        %{
          statement: "A visit that has already started, completed, or been cancelled cannot be rescheduled or cancelled again from the portal.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Cannot modify a completed visit",
              body: "Given a visit has already been marked complete
When the client tries to reschedule or cancel it from the portal
Then the portal blocks the action and explains the visit can no longer be changed"
            }
          ]
        },
        %{
          statement: "Same-day cancellations or reschedules are charged the maximum configured fee tier, distinct from the standard late-fee tier.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same-day cancellation charges the maximum fee",
              body: "Given a client's visit is scheduled for later today and the company's policy charges 100% for same-day cancellation
When the client cancels from the portal
Then the portal displays the 100% fee and requires confirmation before the cancellation is finalized"
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
    story_id: 852,
    status: :completed,
    title: "Pay invoices and tip my cleaner from the portal",
    description:
      "As a cleaning client, I want to view and pay invoices in the portal, manage my card on file, and add a digital tip that reaches my cleaner, so that payment never needs a phone call and tipping doesn't need cash. (Research: over half of tips are digital and incumbents track tips poorly — an in-portal tip prompt is a customer convenience and a cleaner-retention lever — customer-side.md §1; owner-side payment pains pain-points §1.8)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Client views invoice list", verified: true},
      %{description: "Client pays an invoice with a new card", verified: true},
      %{description: "Invoice marked paid on webhook confirmation", verified: true},
      %{description: "Declined card leaves invoice unpaid", verified: true},
      %{description: "Client saves a card on file", verified: true},
      %{description: "Client adds a tip at payment", verified: true},
      %{description: "Client pays without tipping", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "A client can view their invoices, and each invoice's current status (unpaid, charge_pending, or paid), in the portal via their magic-link session.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client views invoice list",
              body: "Given a client has one unpaid invoice and one paid invoice
When they open the portal via their magic link
Then both invoices are listed with their current status"
            }
          ]
        },
        %{
          statement: "A client can pay an unpaid invoice online using a card, either one on file or one entered at checkout.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client pays an invoice with a new card",
              body: "Given a client has an unpaid invoice and no card on file
When they enter card details and submit payment
Then the invoice transitions to charge_pending while the payment processes"
            }
          ]
        },
        %{
          statement: "An invoice is marked paid only after the payment gateway's webhook confirms the charge succeeded.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Invoice marked paid on webhook confirmation",
              body: "Given an invoice is in charge_pending status after a client submits payment
When the Stripe webhook confirms the charge succeeded
Then the invoice is marked paid and the client sees the updated status in the portal"
            }
          ]
        },
        %{
          statement: "A declined charge leaves the invoice unpaid and lets the client retry payment or use a different card.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Declined card leaves invoice unpaid",
              body: "Given a client submits payment for an invoice
When the payment gateway declines the card
Then the invoice remains unpaid and the client is shown the decline reason with an option to retry"
            }
          ]
        },
        %{
          statement: "A client can save a card on file at payment so future invoices can be paid without re-entering card details.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client saves a card on file",
              body: "Given a client pays an invoice and opts to save the card
When the payment succeeds
Then the card is stored on file for use on future invoices"
            }
          ]
        },
        %{
          statement: "At payment, the client can add a digital tip via preset percentage options, and the tip is recorded for the assigned cleaner and reflected in that cleaner's earnings.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client adds a tip at payment",
              body: "Given a client is paying an invoice for a completed visit with an assigned cleaner
When they select a 20% tip preset and complete payment
Then the tip is recorded for that cleaner and appears in the cleaner's earnings"
            }
          ]
        },
        %{
          statement: "Tipping is optional; a client can pay an invoice in full without adding a tip.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Client pays without tipping",
              body: "Given a client is paying an invoice
When they decline to add a tip and complete payment
Then the invoice is paid successfully with no tip recorded"
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
    story_id: 853,
    status: :completed,
    title: "Leave a review when the job is done well",
    description:
      "As a cleaning client, I want a thank-you note after my cleaning with a low-friction review prompt (and a private complaint path if I'm unhappy), so that praising a great cleaner is effortless and problems reach the owner before they reach Google. (Research: Housecall Pro's auto thank-you + ~24h delayed review request is its single most-praised cleaning feature, yielding 2–3x review growth — customer-side.md §4)",
    tags: [%{name: "customer"}],
    criteria: [
      %{description: "Thank-you sent on job completion", verified: true},
      %{description: "Review request sent ~24h after completion", verified: true},
      %{description: "No duplicate review request", verified: true},
      %{description: "High rating routes to publish", verified: true},
      %{description: "Low rating routes to private complaint", verified: true},
      %{description: "Owner receives private complaint", verified: true},
      %{description: "No review prompt for incomplete visit", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Cleaning Client", slug: "cleaning-client", type: "proto"},
      rules: [
        %{
          statement: "Immediately after a job is marked complete, the client receives a thank-you message for that visit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Thank-you sent on job completion",
              body: "Given a cleaner marks a visit complete
When the completion is recorded
Then the client receives a thank-you notification for that visit"
            }
          ]
        },
        %{
          statement: "Approximately 24 hours after job completion, the client receives a low-friction review request if they haven't already responded.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Review request sent ~24h after completion",
              body: "Given a job was completed 24 hours ago and the client has not yet responded
When the scheduled review-request job runs
Then the client receives a review prompt for that visit"
            }
          ]
        },
        %{
          statement: "If the client has already left a review for a visit, no duplicate review request is sent for that visit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No duplicate review request",
              body: "Given a client already submitted a review for a completed visit
When the 24h review-request job runs for that visit
Then no additional review request is sent to the client"
            }
          ]
        },
        %{
          statement: "A review rating of 4 or 5 stars routes the client to publish the review publicly with the visit's details pre-filled.",
          scenarios: [
            %{
              kind: "happy path",
              title: "High rating routes to publish",
              body: "Given a client rates a visit 5 stars
When they submit the rating
Then the client is directed to publish the review publicly with the visit details pre-filled"
            }
          ]
        },
        %{
          statement: "A review rating of 3 stars or lower routes the client to a private complaint form addressed to the owner instead of a public review page, and no public review link is offered.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Low rating routes to private complaint",
              body: "Given a client rates a visit 2 stars
When they submit the rating
Then the client is shown a private complaint form with no public review link offered, and the owner is notified"
            }
          ]
        },
        %{
          statement: "A submitted private complaint is delivered to the owner along with the client's rating and the visit's details so the issue can be addressed before it becomes a public review.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner receives private complaint",
              body: "Given a client submits a private complaint with a 2-star rating
When the complaint is submitted
Then the owner receives the complaint along with the client's rating and the visit's details"
            }
          ]
        },
        %{
          statement: "A review or complaint can only be submitted for a visit that has been completed; visits not yet finished show no review prompt.",
          scenarios: [
            %{
              kind: "failure path",
              title: "No review prompt for incomplete visit",
              body: "Given a visit is still scheduled and not yet completed
When the client views the portal
Then no review or rating prompt is shown for that visit"
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
