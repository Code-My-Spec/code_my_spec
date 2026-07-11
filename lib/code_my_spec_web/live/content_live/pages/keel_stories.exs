[
  %{
    story_id: 761,
    status: :in_progress,
    title: "Database-enforced balanced-or-rollback invariant",
    description:
      "As John, I want the database itself to reject any transaction whose entries don't sum to zero per currency, so that no agent, import, or code path can ever post unbalanced data — correctness is structural, not behavioral. Enforced by a Postgres deferred-constraint trigger checked at commit. (Covers: INV1, AD3, FR-LED-02, G4)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Balanced single-currency transaction posts", verified: true},
      %{description: "Unbalanced transaction is rejected and nothing persists", verified: true},
      %{description: "Cross-currency transaction balanced in every currency posts", verified: true},
      %{description: "Transaction balanced in one currency but not another is rejected", verified: true},
      %{description: "Multi-leg transaction assembled across inserts commits when it nets to zero", verified: true},
      %{description: "Empty transaction is rejected", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Every transaction's entries must net to zero in each currency.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Balanced single-currency transaction posts",
              body: "Given a transaction with a -100.00 CAD entry and a +100.00 CAD entry
When the transaction is committed
Then it is persisted successfully"
            },
            %{
              kind: "failure path",
              title: "Unbalanced transaction is rejected and nothing persists",
              body: "Given a transaction with a -100.00 CAD entry and a +90.00 CAD entry
When the transaction is committed
Then the commit is rejected and no entries or transaction are persisted"
            }
          ]
        },
        %{
          statement: "Each currency within a transaction is balanced independently.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cross-currency transaction balanced in every currency posts",
              body: "Given a transaction whose CAD entries net to zero and whose USD entries net to zero
When the transaction is committed
Then it is persisted successfully"
            },
            %{
              kind: "failure path",
              title: "Transaction balanced in one currency but not another is rejected",
              body: "Given a transaction whose CAD entries net to zero but whose USD entries net to +5.00
When the transaction is committed
Then the commit is rejected because USD does not net to zero"
            }
          ]
        },
        %{
          statement: "The balance check is deferred to commit, so legs may be inserted in any order within one database transaction.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Multi-leg transaction assembled across inserts commits when it nets to zero",
              body: "Given a database transaction that inserts four entries one at a time, momentarily unbalanced after each of the first three
When all four entries leave every currency netting to zero and the database transaction commits
Then the transaction is persisted successfully without tripping the check mid-insert"
            }
          ]
        },
        %{
          statement: "A transaction with no entries is rejected.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Empty transaction is rejected",
              body: "Given a transaction with no entries
When it is committed
Then it is rejected — a transaction must carry entries that net to zero"
            }
          ]
        }
      ],
      questions: [
        %{body: "Should a transaction with no entries (degenerate zero-sum) be allowed, or rejected as invalid?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 762,
    status: :completed,
    title: "Aggregate account balances, never chained",
    description:
      "As John, I want each account balance computed as SUM(entries.amount_cents) rather than a per-row running balance, so that backdated entries \"just work\" with no linear recompute or snapshot scaffolding. (Covers: AD2, NFR-3)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Balance equals the sum of all entries", verified: true},
      %{description: "Backdated entry updates the balance with no recompute of other rows", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "An account's balance is the sum of its entries, computed on demand — never stored as a per-row running balance.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Balance equals the sum of all entries",
              body: "Given an account with entries of +100.00, +30.00, and -20.00 CAD
When the account balance is read
Then it returns 110.00 CAD computed from the sum of entries"
            }
          ]
        },
        %{
          statement: "A backdated or out-of-order entry is reflected in the balance immediately, without recomputing any other rows.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Backdated entry updates the balance with no recompute of other rows",
              body: "Given an account whose latest entry is dated today with a balance of 110.00 CAD
When an entry of +50.00 CAD dated last month is posted
Then the balance immediately reads 160.00 CAD and no existing entry rows are modified"
            }
          ]
        }
      ],
      questions: [
        %{body: "At what entry volume (if ever) do we introduce materialized balance rollups as a speed optimization, per NFR-3?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 763,
    status: :in_progress,
    title: "Money stored as integer cents",
    description:
      "As John, I want all monetary amounts stored as signed bigint cents and never as floats, so that arithmetic is exact and rounding errors can't accumulate in the ledger. (Covers: AD4)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Summing fractional amounts has no floating-point drift", verified: true},
      %{description: "Amount round-trips through storage unchanged", verified: true},
      %{description: "Same numeric amount in different currencies is distinct", verified: true},
      %{description: "Adding two different currencies is not allowed implicitly", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Monetary amounts are stored and computed as exact values, never as floating point.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Summing fractional amounts has no floating-point drift",
              body: "Given amounts of 0.10 CAD and 0.20 CAD
When they are added
Then the result is exactly 0.30 CAD with no rounding drift"
            },
            %{
              kind: "happy path",
              title: "Amount round-trips through storage unchanged",
              body: "Given an entry amount of 1234.56 CAD
When it is persisted and read back
Then it returns exactly 1234.56 CAD"
            }
          ]
        },
        %{
          statement: "Every monetary amount carries its currency.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same numeric amount in different currencies is distinct",
              body: "Given an amount of 100.00 CAD and an amount of 100.00 USD
When they are compared
Then they are treated as distinct amounts because their currencies differ"
            },
            %{
              kind: "failure path",
              title: "Adding two different currencies is not allowed implicitly",
              body: "Given an amount of 100.00 CAD and an amount of 50.00 USD
When an attempt is made to add them directly
Then the operation is refused — cross-currency arithmetic requires an explicit FX conversion"
            }
          ]
        }
      ],
      questions: [
        %{body: "Are any non-2-decimal currencies in scope (e.g. zero-decimal or 3-decimal), or can we assume CAD/USD 2-decimal minor units for v1?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 764,
    status: :in_progress,
    title: "Append-only ledger with reversing-entry corrections",
    description:
      "As John, I want posted entries to be immutable — never edited or deleted — with corrections made only by posting reversing entries, so that the ledger is auditable and every posted figure traces back to its source import row and file. (Covers: AD5, FR-LED-03, NFR-2)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Attempt to edit or delete a posted entry is refused", verified: true},
      %{description: "A mistaken transaction is corrected with a reversing transaction", verified: true},
      %{description: "A posted entry links to its originating import row and file", verified: true},
      %{description: "Manual transaction posts with manual provenance", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Posted entries are never edited or deleted.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Attempt to edit or delete a posted entry is refused",
              body: "Given a posted entry of +100.00 CAD
When an attempt is made to update its amount or delete the row
Then the operation is refused and the entry is unchanged"
            }
          ]
        },
        %{
          statement: "A correction is made by posting a reversing entry, not by changing the original.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A mistaken transaction is corrected with a reversing transaction",
              body: "Given a posted transaction that was categorized incorrectly
When a reversing transaction is posted that negates its entries and a corrected transaction is posted
Then the original, the reversal, and the correction all remain visible and the net effect is correct"
            }
          ]
        },
        %{
          statement: "Every posted figure traces back to its source import row and file.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A posted entry links to its originating import row and file",
              body: "Given an entry posted from an imported bank transaction
When its provenance is inspected
Then it references the import row and the source file it came from"
            }
          ]
        },
        %{
          statement: "A transaction may be created manually without a source import row, recorded with manual provenance.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Manual transaction posts with manual provenance",
              body: "Given the operator creates a balanced transaction by hand, not from an import
When it is posted
Then it persists with a manual provenance marker (no import row) and is fully traceable in history"
            }
          ]
        }
      ],
      questions: [
        %{body: "For manually created transactions (no source import row), how is the traceability rule satisfied — a \"manual\" provenance marker, or is an import row always required?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 765,
    status: :in_progress,
    title: "Entity dimension on every account (day-0 seam)",
    description:
      "As John, I want every account to belong to exactly one entity from day one, with a transaction's entries confined to a single entity, so that multi-entity (e.g. a future DFC migration) is a later decision rather than a migration, and entities never commingle. (Covers: AD9, FR-ENT-01, INV4)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A new account is scoped to an entity", verified: true},
      %{description: "Same-entity transaction posts", verified: true},
      %{description: "Cross-entity transaction is rejected", verified: true},
      %{description: "A second entity can be introduced later with isolated books", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Every account belongs to exactly one entity.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A new account is scoped to an entity",
              body: "Given the person entity exists
When a new account is created under it
Then the account belongs to that entity and to no other"
            }
          ]
        },
        %{
          statement: "A transaction's entries all reference accounts of the same entity.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same-entity transaction posts",
              body: "Given two accounts that both belong to the person entity
When a transaction moves money between them
Then it posts successfully"
            },
            %{
              kind: "failure path",
              title: "Cross-entity transaction is rejected",
              body: "Given one account belonging to the person entity and one belonging to a second entity
When a single transaction tries to reference both accounts
Then it is rejected — entities never commingle within one transaction"
            }
          ]
        },
        %{
          statement: "The entity dimension exists from day one even though v1 runs a single entity.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A second entity can be introduced later with isolated books",
              body: "Given v1 running with a single person entity and its accounts
When a second entity is later added
Then its accounts and transactions are isolated from the person entity with no restructuring of existing data"
            }
          ]
        }
      ],
      questions: [
        %{body: "Should the single v1 person entity be auto-seeded during setup, or created explicitly by the operator on first run?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 766,
    status: :in_progress,
    title: "Backfill the ledger from the Quicken Mac SQLite database",
    description:
      "As John, I want to import directly from Quicken Mac's SQLite database (the `data` store inside the .quicken document package) so the ledger gets the full fidelity the QIF/CSV exports throw away: real per-account currency and type (no name-guessing), all accounts including closed ones (e.g. the TD accounts), each transaction's raw bank statement description (ZFITRANSACTION.ZSTATEMENTPAYEENAME — the un-renamed text), Quicken's own account-to-account transfer links (ZCASHFLOWTRANSACTIONENTRY.ZTRANSFER) imported as already-linked transfers, and investment holdings (units + security quotes) for real market value. Everything lands as balanced double-entry, idempotently, with transfers Quicken already paired arriving paired — leaving only the genuinely-unlinked remainder for Keel.Reconciliation.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Account currency and type come from the database", verified: true},
      %{description: "A closed TD account still imports", verified: true},
      %{description: "A renamed payee imports with its raw bank description", verified: true},
      %{description: "A Quicken-linked transfer arrives already paired", verified: true},
      %{description: "An investment holding imports with units and market value", verified: true},
      %{description: "Re-importing the same database is a no-op", verified: true},
      %{description: "A 401(k) imports as an investment-type account", verified: true},
      %{description: "A holding is marked to market, the gap booking as unrealized gain/loss", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A QFX/OFX file is parsed into one staging row per bank transaction.",
          scenarios: [
          ]
        },
        %{
          statement: "Each staging row carries the bank-assigned FITID and the currency from the file's CURDEF.",
          scenarios: [
          ]
        },
        %{
          statement: "Imported rows are single-sided (the bank leg only); the contra leg is assigned downstream.",
          scenarios: [
          ]
        },
        %{
          statement: "Each account imports with the currency and type recorded in the Quicken database — never inferred from the account name.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Account currency and type come from the database",
              body: "Given a Quicken database with \"RBC USA Checking (John)\" recorded as USD/CHECKING and \"RBC Avion Visa Infinite\" as CAD/CREDITCARD
When the database is imported
Then \"RBC USA Checking (John)\" is a USD asset account and \"RBC Avion Visa Infinite\" is a CAD liability account
And no currency was guessed from the account name"
            },
            %{
              kind: "happy path",
              title: "A 401(k) imports as an investment-type account",
              body: "Given a Quicken account \"OPENFORCE 401(K)\" of type DEFERREDCOMPRETIREMENT401K
When the database is imported
Then it is a Keel account of type :investment
And a CREDITCARD account imports as :liability"
            }
          ]
        },
        %{
          statement: "Closed accounts are imported with their full history, marked closed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A closed TD account still imports",
              body: "Given a Quicken database with a closed \"TD UNLIMITED CHEQUING ACCOUNT\" that carries transactions
When the database is imported
Then the account exists and is marked closed
And its transactions are posted"
            }
          ]
        },
        %{
          statement: "A transaction imports the raw bank statement description from the database when one exists, not just the renamed payee.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A renamed payee imports with its raw bank description",
              body: "Given a transaction whose Quicken payee is \"Tin\" but whose bank statement description is \"WWW PMT TIN0-02418\"
When the database is imported
Then the posted transaction carries the raw description \"WWW PMT TIN0-02418\""
            }
          ]
        },
        %{
          statement: "A transfer Quicken already linked imports as one already-linked transfer between the two accounts, not as unmatched legs in the review queue.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A Quicken-linked transfer arrives already paired",
              body: "Given a Quicken database with a transfer Quicken linked between \"RBC Day to Day Banking (John)\" and a loan account
When the database is imported
Then it posts as one linked transfer touching both accounts
And neither side appears in the unmatched transfer queue"
            }
          ]
        },
        %{
          statement: "An investment transaction imports its share units and the security's quoted market value.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An investment holding imports with units and market value",
              body: "Given a Quicken database with a brokerage purchase of a security that has a price quote
When the database is imported
Then the position records its share units
And the security's quoted market value is available for the account"
            },
            %{
              kind: "happy path",
              title: "A holding is marked to market, the gap booking as unrealized gain/loss",
              body: "Given an investment account whose holdings cost a total of X and whose units at the security's latest quote are worth Y
When the database is imported
Then the investment account's balance reflects the market value Y
And the difference Y minus X is booked as unrealized gain/loss"
            }
          ]
        },
        %{
          statement: "Re-importing the same database posts nothing new — import is idempotent on Quicken's stable transaction id.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Re-importing the same database is a no-op",
              body: "Given a Quicken database that has already been imported once
When the same database is imported again
Then no new transactions are posted
And the ledger totals are unchanged"
            }
          ]
        }
      ],
      questions: [
        %{body: "Which OFX variants must we handle for your QuickBooks/bank exports — OFX 1.x SGML with Intuit extensions (INTU.BID), OFX 2.x XML, or both? (Determines parser robustness needed.)", status: :open, resolution: nil},
        %{body: "Quicken account-type mapping to Keel types: CHECKING/SAVINGS -> asset, CREDITCARD -> liability, BROKERAGENORMAL/DEFERREDCOMPRETIREMENT401K -> asset (investment). Is there a loan/liability account type to handle, and should retirement/brokerage be a distinct :investment type or just :asset?", status: :resolved, resolution: nil},
        %{body: "Investment market value: represent it as a dated valuation/holding (units x latest security quote) separate from the cost-basis transactions, or per-lot? And use the latest quote or the quote as of a chosen date? This drives whether net worth reflects market value vs cost basis.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 767,
    status: :in_progress,
    title: "Map import account to ledger account; flag unmapped",
    description:
      "As John, I want the file's ACCTID mapped to a ledger account via accounts.external_id, with unmapped accounts rejected/flagged rather than silently imported, so that transactions always land in the right account. (Covers: FR-IMP-03)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Rows land in the account whose external_id matches the file's ACCTID", verified: true},
      %{description: "Unmapped ACCTID is flagged rather than silently imported", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The file's ACCTID maps to a ledger account via accounts.external_id.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Rows land in the account whose external_id matches the file's ACCTID",
              body: "Given an account whose external_id equals the file's ACCTID
When the file is imported
Then the staging rows are associated with that account"
            }
          ]
        },
        %{
          statement: "Transactions whose ACCTID has no mapped account are flagged, not silently imported.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Unmapped ACCTID is flagged rather than silently imported",
              body: "Given a file whose ACCTID matches no account's external_id
When the file is imported
Then its rows are flagged as unmapped (quarantined) rather than landing in an arbitrary account"
            }
          ]
        }
      ],
      questions: [
        %{body: "How does the operator create the ACCTID→account mapping — set external_id when creating the account, or a prompt on first import of an unknown ACCTID?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 768,
    status: :in_progress,
    title: "Idempotent re-import over overlapping ranges",
    description:
      "As John, I want re-importing a file whose (account_id, fitid) rows already exist to mark them as duplicate rather than erroring, so that re-running imports over overlapping date ranges never creates duplicates. (Covers: FR-IMP-05, INV2, NFR-1)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Re-importing the same file marks every row duplicate", verified: true},
      %{description: "Overlapping range adds only the genuinely new transactions", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A staging row whose (account, FITID) already exists is marked duplicate rather than re-imported.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Re-importing the same file marks every row duplicate",
              body: "Given a file that has already been imported once
When the same file is imported again
Then no new staging rows are created and the repeated transactions are marked duplicate"
            }
          ]
        },
        %{
          statement: "Re-importing an overlapping date range creates no new rows for transactions already seen.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Overlapping range adds only the genuinely new transactions",
              body: "Given a prior import covering Jan 1–15 and a new file covering Jan 10–20
When the new file is imported
Then only the Jan 16–20 transactions are added and the Jan 10–15 overlap is marked duplicate"
            }
          ]
        }
      ],
      questions: [
        %{body: "If a transaction has no FITID in the file, what identity do we use for dedup — a hash of (date, amount, descriptor)?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 769,
    status: :in_progress,
    title: "Quarantine bad rows without aborting the batch",
    description:
      "As John, I want unparseable rows (e.g. invalid dates) moved to quarantine status while the rest of the import proceeds, so that a single malformed row never crashes or aborts the whole import. (Covers: FR-IMP-06, NFR-4)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A row with an invalid date is quarantined", verified: true},
      %{description: "Good rows import while the bad row is quarantined", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A row that cannot be parsed is moved to quarantine status.",
          scenarios: [
            %{
              kind: "failure path",
              title: "A row with an invalid date is quarantined",
              body: "Given a file containing a transaction with an unparseable date
When the file is imported
Then that row is given quarantine status rather than crashing the import"
            }
          ]
        },
        %{
          statement: "A single bad row does not abort the rest of the import.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Good rows import while the bad row is quarantined",
              body: "Given a file with nine valid transactions and one malformed row
When the file is imported
Then the nine valid rows are staged and only the malformed row is quarantined"
            }
          ]
        }
      ],
      questions: [
        %{body: "How does the operator resolve a quarantined row — fix and re-import, or edit it in the review surface?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 770,
    status: :in_progress,
    title: "CSV fallback import path",
    description:
      "As John, I want a CSV import path (via NimbleCSV) for institutions that don't export QFX, normalizing into the same import_rows shape, so that every institution can feed the same downstream pipeline. (Covers: FR-IMP-08)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A CSV import produces the same staging shape as QFX", verified: true},
      %{description: "Institution-specific columns map to the normalized fields", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A CSV file is parsed into the same import_rows shape as a QFX file.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A CSV import produces the same staging shape as QFX",
              body: "Given a CSV export from an institution that offers no QFX
When the CSV is imported
Then it produces staging rows in the same shape (account, date, amount, currency, descriptor, fitid) as a QFX import"
            }
          ]
        },
        %{
          statement: "A per-institution column mapping normalizes CSV columns into the staging shape.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Institution-specific columns map to the normalized fields",
              body: "Given a CSV whose columns are \"Transaction Date\", \"Debit\", \"Credit\", and \"Description\"
When it is imported with that institution's mapping
Then the date, signed amount, and descriptor are normalized into the staging row correctly"
            }
          ]
        }
      ],
      questions: [
        %{body: "Which of your institutions (RBC/TD/Tangerine/Redstone) lack QFX and need CSV, and can you provide a sample CSV header for each?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 771,
    status: :in_progress,
    title: "One import pipeline for migration and weekly imports",
    description:
      "As John, I want the same import pipeline to serve both bulk historical migration (years of Quicken data) and recurring weekly imports, so that migrating my history requires zero manual re-keying and ongoing use is the same path. (Covers: FR-IMP-09, G2)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A large historical file and a weekly file go through the same pipeline", verified: true},
      %{description: "Years of Quicken history import without manual data entry", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The same import pipeline serves both bulk historical migration and recurring weekly imports.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A large historical file and a weekly file go through the same pipeline",
              body: "Given a multi-year historical export and a single-week export
When each is imported
Then both are processed by the same pipeline with the same staging, dedup, and quarantine behavior"
            }
          ]
        },
        %{
          statement: "Migrating years of history requires no manual re-keying.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Years of Quicken history import without manual data entry",
              body: "Given years of exported transactions
When they are imported
Then every transaction is staged automatically with no manual re-keying required"
            }
          ]
        }
      ],
      questions: [
        %{body: "For very large historical files, do we stream/chunk the parse, and is there a file-size or row-count ceiling to plan for?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 772,
    status: :in_progress,
    title: "Run import and categorization as background jobs",
    description:
      "As John, I want import and categorization to run as background jobs (Oban), so that large historical imports and LLM categorization don't block the interface. (Covers: NFR-5)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A large import is processed in the background", verified: true},
      %{description: "A retried import job does not create duplicate rows", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Imports run as background jobs so the interface is not blocked.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A large import is processed in the background",
              body: "Given the operator uploads a large historical file
When the import is started
Then it is enqueued and processed by a background worker while the interface stays responsive"
            }
          ]
        },
        %{
          statement: "A background job retries on transient failure without duplicating already-staged rows.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A retried import job does not create duplicate rows",
              body: "Given an import job that fails partway and is retried
When it runs again
Then rows already staged are recognized as duplicates and not re-created"
            }
          ]
        }
      ],
      questions: [
        %{body: "For a single-user local app, is Oban warranted in v1, or is a synchronous/Task-based import enough until import volume justifies it?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 773,
    status: :in_progress,
    title: "Deterministic rules engine: match a row, apply a categorize or transfer action",
    description:
      "As the system, I want a deterministic rules engine that matches a transaction row by regex (and optional account scope) and applies a categorize action, so rows are classified to income/expense accounts; transfers are handled separately by two-sided transfer rules.",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 774,
    status: :in_progress,
    title: "Rule-matched rows advance without LLM involvement",
    description:
      "As John, I want rows matched by rules to transition to approved (or proposed, configurable) without any LLM call, so that the deterministic majority of transactions are categorized cheaply and predictably. (Covers: FR-CAT-02)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 775,
    status: :in_progress,
    title: "LLM categorizes only the unmatched tail",
    description:
      "As John, I want only rows unmatched by rules sent to the LLM, which proposes a contra account and sets status proposed, so that model spend is confined to the genuine unknown tail. (Covers: FR-CAT-03, AD7)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 776,
    status: :in_progress,
    title: "Editable, extensible rules set",
    description:
      "As John, I want to edit and extend the categorization rules over time, so that the unknown tail sent to the LLM shrinks as I encode more known merchants. (Covers: FR-CAT-05)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 783,
    status: :in_progress,
    title: "Desert First distribution category in the personal chart",
    description:
      "As John, I want a \"Desert First distribution\" category present in the personal chart of accounts, so that irregular owner draws — which carry cross-border tax weight — are never left uncategorized. (Covers: FR-ENT-03)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Desert First distribution category exists in the personal chart", verified: true},
      %{description: "An owner draw is categorized as Desert First distribution", verified: true},
      %{description: "Desert First distribution appears as income in personal reports", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The personal chart of accounts includes a \"Desert First distribution\" category.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Desert First distribution category exists in the personal chart",
              body: "Given the personal entity's chart of accounts
When it is inspected
Then a \"Desert First distribution\" category is present"
            }
          ]
        },
        %{
          statement: "Owner draws from Desert First are categorized to that account, never left uncategorized.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An owner draw is categorized as Desert First distribution",
              body: "Given an irregular deposit into a personal account that represents an owner draw from Desert First
When it is categorized
Then the \"Desert First distribution\" category is available and applied so the draw is never left uncategorized"
            }
          ]
        },
        %{
          statement: "On the personal books, \"Desert First distribution\" is an income account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Desert First distribution appears as income in personal reports",
              body: "Given an owner draw categorized as \"Desert First distribution\"
When the personal Profit & Loss is produced
Then the draw appears on the income side with the correct sign"
            }
          ]
        }
      ],
      questions: [
        %{body: "Is \"Desert First distribution\" classified as an equity/draw account or an income account in the personal books? (Affects cross-border tax treatment of the draw.)", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 784,
    status: :completed,
    title: "Per-currency account balances",
    description:
      "As John, I want each account to be single-currency and balances computed per currency, so that CAD and USD are never implicitly mixed within an account. (Covers: FR-FX-01)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Account accepts only entries in its own currency", verified: true},
      %{description: "Entry in a foreign currency to an account is rejected", verified: true},
      %{description: "CAD and USD totals are reported separately", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Each account holds exactly one currency, fixed once set.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Account accepts only entries in its own currency",
              body: "Given a CAD account
When a CAD entry is posted to it
Then it is accepted"
            },
            %{
              kind: "failure path",
              title: "Entry in a foreign currency to an account is rejected",
              body: "Given a CAD account
When a USD entry is posted to it
Then it is rejected — the entry currency must match the account currency"
            }
          ]
        },
        %{
          statement: "Balances are computed and reported per currency.",
          scenarios: [
            %{
              kind: "happy path",
              title: "CAD and USD totals are reported separately",
              body: "Given CAD accounts and USD accounts with balances
When balances are reported
Then CAD totals and USD totals are presented separately, never summed into one number"
            }
          ]
        }
      ],
      questions: [
        %{body: "Do we ever present a single combined net-worth figure across currencies, and if so at what exchange rate (and does that conversion belong only in reporting, not the ledger)?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 785,
    status: :in_progress,
    title: "Cross-currency movement as a 4-leg FX transaction",
    description:
      "As John, I want a cross-currency movement recorded as a multi-leg transaction that balances each currency independently, with the rate difference flowing into a dedicated FX gain/loss account and no implicit base-currency conversion, so that CAD/USD conversions are explicit and correct. (Covers: FR-FX-02, FR-FX-03)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "CAD-to-USD transfer records as a balanced multi-leg transaction", verified: true},
      %{description: "Rate difference lands in the FX gain/loss account", verified: true},
      %{description: "A two-leg implicit cross-currency entry is not allowed", verified: true},
      %{description: "Conversion realizes gain against the average-cost basis", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A cross-currency movement is a single transaction whose legs balance each currency independently.",
          scenarios: [
            %{
              kind: "happy path",
              title: "CAD-to-USD transfer records as a balanced multi-leg transaction",
              body: "Given 1000.00 CAD leaving a CAD account and 730.00 USD arriving in a USD account
When the transfer is recorded
Then the transaction has legs that net to zero in CAD and net to zero in USD independently"
            }
          ]
        },
        %{
          statement: "The exchange-rate difference is posted to a dedicated FX gain/loss account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Rate difference lands in the FX gain/loss account",
              body: "Given a conversion where the realized rate differs from the cost basis of the currency given up
When the transfer is posted
Then the gain or loss is posted to the dedicated FX gain/loss account so each currency still balances"
            }
          ]
        },
        %{
          statement: "There is no implicit base-currency conversion; every conversion is explicit legs.",
          scenarios: [
            %{
              kind: "failure path",
              title: "A two-leg implicit cross-currency entry is not allowed",
              body: "Given an attempt to record a CAD outflow and a USD inflow as a single two-leg entry that \"just converts\"
When it is submitted
Then it is rejected — the conversion must be modeled with explicit legs that balance each currency"
            }
          ]
        },
        %{
          statement: "FX gain/loss uses a per-currency average-cost basis and is realized on CAD↔USD conversions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Conversion realizes gain against the average-cost basis",
              body: "Given a CAD pool with an average USD cost basis of 0.72 USD per CAD
When 1000.00 CAD is converted at an actual rate of 0.73 USD per CAD
Then a 10.00 USD FX gain is posted to the FX gain/loss account and the CAD pool is reduced by 1000.00 CAD"
            }
          ]
        }
      ],
      questions: [
        %{body: "What rate/cost-basis method do we use to compute FX gain/loss — the bank's posted rate from the file, an IRS yearly-average rate, or a cost-basis lot method? (Affects §988 reporting.)", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 786,
    status: :in_progress,
    title: "FX gain/loss reportable as its own line",
    description:
      "As John, I want FX gain/loss reportable as its own line, so that my cross-border USD filing can surface currency gains/losses explicitly. (Covers: FR-FX-04, G3)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 787,
    status: :in_progress,
    title: "Reconcile staged, posted, and statement balances",
    description:
      "As John, I want to match staged ↔ posted ↔ statement balances per account and surface unmatched/unreconciled items for review, so that I can trust each account ties out to its statement. (Covers: FR-REC-01, FR-REC-03)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 789,
    status: :in_progress,
    title: "Cross-entity movement as two mirror transactions",
    description:
      "As John, I want cross-entity money movement (e.g. a DFC owner draw) modeled as two mirror transactions — one per entity — linked by a shared reference rather than a single transaction spanning entities, so that entities never commingle while the movement stays traceable across both books. (Covers: FR-ENT-02)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Owner draw creates one transaction in each entity", verified: true},
      %{description: "Both sides of the draw are findable via the shared reference", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Cross-entity movement is modeled as two mirror transactions, one per entity.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner draw creates one transaction in each entity",
              body: "Given a draw moving money from Desert First (c_corp) to the person
When the movement is recorded
Then one balanced transaction is posted in the Desert First entity and a separate balanced transaction is posted in the person entity"
            }
          ]
        },
        %{
          statement: "The two mirror transactions are linked by a shared reference.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Both sides of the draw are findable via the shared reference",
              body: "Given the two mirror transactions of an owner draw
When one side is looked up by its reference
Then the other side is found through the same shared reference"
            }
          ]
        }
      ],
      questions: [
        %{body: "Must both mirror sides be created atomically (both or neither), and what happens if only one side appears at import time (the other entity's data arrives later)?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 790,
    status: :in_progress,
    title: "Trial balance integrity check",
    description:
      "As John, I want a trial balance where the sum across all entries equals zero, so that I have a one-glance integrity check on the whole ledger. (Covers: FR-RPT-01)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 791,
    status: :in_progress,
    title: "Profit and loss report with correct sign conventions",
    description:
      "As John, I want a Profit & Loss report with correct sign conventions per account type, so that income and expense net out correctly for the period. (Covers: FR-RPT-02)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 792,
    status: :in_progress,
    title: "Balance sheet report",
    description:
      "As John, I want a balance sheet of assets, liabilities, and equity, so that I get a real net-worth view as a byproduct of double-entry books. (Covers: FR-RPT-03)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 793,
    status: :in_progress,
    title: "Vendor/descriptor spend report",
    description:
      "As John, I want a spend report grouped by descriptor, so that I can see vendor/category spend without maintaining vendor accounts (vendors are a normalized descriptor field, not ledger accounts). (Covers: FR-RPT-04, §7)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 794,
    status: :in_progress,
    title: "Entity-scoped reports",
    description:
      "As John, I want all reports scoped to a single entity, so that personal and any future corporate books are reported separately and never mixed. (Covers: FR-RPT-05)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 795,
    status: :in_progress,
    title: "Cash flow and net-worth-over-time reports",
    description:
      "As John, I want cash flow and net-worth-over-time reports, so that I can see trends over time. (Nice-to-have.) (Covers: FR-RPT-06)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 796,
    status: :in_progress,
    title: "Expose intent-level operations as MCP tools",
    description:
      "As John, I want the agent to drive the ledger through intent-level MCP tools — stage_import, propose_categorization, post_transaction, reconcile, balance, trial_balance, pnl/report — that each enforce invariants server-side within a single entity context, so that the agent (the primary interface) operates the system safely. (Covers: FR-MCP-01 through FR-MCP-07)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 797,
    status: :in_progress,
    title: "Expose no CRUD-level MCP tools",
    description:
      "As John, I want the MCP surface to expose no raw row-manipulation tools (no create_entry, etc.), so that the agent can never bypass the invariants by manipulating rows directly. (Covers: FR-MCP-08, AD8)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 798,
    status: :completed,
    title: "Browse and filter posted transactions",
    description:
      "As John, I want to browse posted transactions and filter by account, date range, and descriptor, so that I can review and confirm the books by hand alongside the agent — not a full bookkeeping UI, just enough to inspect and trust what was posted. Read-only over the append-only ledger. (Supports G1; complements FR-RPT-04, FR-LED-03)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Transaction list shows posted transactions", verified: true},
      %{description: "Filtering by account narrows the list", verified: true},
      %{description: "Filtering by date range and descriptor", verified: true},
      %{description: "No edit or delete controls in the transaction view", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The operator can browse posted transactions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transaction list shows posted transactions",
              body: "Given several posted transactions exist
When the operator opens the transactions view
Then the posted transactions are listed"
            }
          ]
        },
        %{
          statement: "Transactions can be filtered by account, date range, and descriptor.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Filtering by account narrows the list",
              body: "Given transactions across an RBC account and a TD account
When the operator filters by the RBC account
Then only transactions touching the RBC account are shown"
            },
            %{
              kind: "happy path",
              title: "Filtering by date range and descriptor",
              body: "Given transactions spanning multiple months and descriptors
When the operator filters by a date range and the descriptor \"HETZNER\"
Then only HETZNER transactions within that range are shown"
            }
          ]
        },
        %{
          statement: "The transaction views are read-only over the append-only ledger.",
          scenarios: [
            %{
              kind: "failure path",
              title: "No edit or delete controls in the transaction view",
              body: "Given the transactions view is open
When the operator inspects a listed transaction
Then there is no control to edit or delete it from this view"
            }
          ]
        }
      ],
      questions: [
        %{body: "What is the default view when no filter is applied — current tax year, last 90 days, or all time?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 799,
    status: :completed,
    title: "Account register view with per-currency balance",
    description:
      "As John, I want an account-scoped register showing that account's entries in date order with its running per-currency balance, so that I can verify a single account ties out to its statement while doing manual review. Read-only. (Supports FR-FX-01, FR-REC-01; complements story 762, 784)",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Register lists the account's entries in date order", verified: true},
      %{description: "Register shows the current per-currency balance", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "An account register lists that account's entries in date order.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Register lists the account's entries in date order",
              body: "Given an account with several posted entries
When the operator opens the account register
Then the account's entries are listed in date order"
            }
          ]
        },
        %{
          statement: "The register shows the account's per-currency balance.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Register shows the current per-currency balance",
              body: "Given a single-currency CAD account with entries summing to 1,250.00 CAD
When the operator opens its register
Then the register shows a 1,250.00 CAD balance derived from the entries"
            }
          ]
        }
      ],
      questions: [
        %{body: "Should the register show a running balance per row (computed for display), or only the current total — given running balances are never stored (story 762)?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 800,
    status: :in_progress,
    title: "Manually categorize and reclassify alongside the LLM",
    description:
      "As John, I want to manually set or override a transaction's category (contra account) in the UI — working alongside the agent's proposals rather than only through it — so that I can do hands-on cleanup of the categorization tail. Operates on staging rows before posting; corrections to posted entries flow through reversing entries. (Complements FR-CAT-03, FR-REV-04, AD5)",
    tags: [%{name: "operator"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 802,
    status: :in_progress,
    title: "Auto-link exact same-currency transfer legs",
    description:
      "As John, I want the system to automatically link two transfer legs that are an exact same-currency mirror — equal amount, opposite sign, on the same or near date, on two different accounts — into a confirmed transfer, so I never have to hand-confirm the obvious ones and Transfer Clearing nets toward zero on its own. The link is a reversible record, not a destructive merge.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Equal, opposite, same-day legs are an exact match", verified: true},
      %{description: "Exact match links without review", verified: true},
      %{description: "An auto-link can be undone", verified: true},
      %{description: "Ambiguous ties are not auto-linked", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Two unmatched same-currency transfer legs on different accounts with equal absolute amount, opposite sign, and dates within the matching window form an exact match.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Equal, opposite, same-day legs are an exact match",
              body: "Given an unmatched CAD leg of -1,200.00 on RBC Staff Banking dated 2024-03-10
And an unmatched CAD leg of +1,200.00 on RBC Avion Visa dated 2024-03-10
When the matcher runs
Then the two legs are identified as an exact match"
            }
          ]
        },
        %{
          statement: "An exact same-currency match is linked automatically, with no human review.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Exact match links without review",
              body: "Given an exact same-currency match between two legs
When the matcher runs
Then a confirmed link is created automatically
And both legs leave the unmatched queue
And the Transfer Clearing balance for that pair nets to zero"
            }
          ]
        },
        %{
          statement: "An automatic link is stored as a reversible match record, never a destructive merge.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An auto-link can be undone",
              body: "Given two legs that were auto-linked
When the link is removed
Then both original leg transactions still exist unchanged
And both return to the unmatched queue"
            }
          ]
        },
        %{
          statement: "A leg auto-links only when it has exactly one exact-match candidate; ties go to review instead.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Ambiguous ties are not auto-linked",
              body: "Given an unmatched CAD leg of -500.00 dated 2024-06-01
And two unmatched CAD legs of +500.00 on different accounts both dated 2024-06-01
When the matcher runs
Then none of the legs are auto-linked
And all three are sent to the review queue as candidates"
            }
          ]
        }
      ],
      questions: [
        %{body: "Same-currency matching window: how many days apart can two legs be and still match (±1? ±3? ±5?)? And does an \"exact\" match require strictly equal amounts, or equal within a small cent tolerance?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 806,
    status: :in_progress,
    title: "Map Quicken categories to per-category ledger accounts",
    description:
      "As John, I want each Quicken transaction's category — the ZTAG its cash-flow entry references (ZCATEGORYTAG), with its parent hierarchy and income/expense type — mapped to the matching contra account, including one contra leg per split entry, so my Quicken-imported P&L breaks down by real category (Restaurants, Groceries, Paycheck, Dividend Income…) instead of collapsing into a couple of Uncategorized buckets. Quicken stores categories in ZTAG: ZTYPE 2 = income, ZTYPE 1 = expense, ZTYPE 0 = investment/special actions, null = user tags (not categories). Full category name follows ZPARENTCATEGORY (e.g. Food & Dining:Restaurants).

This mapping is OPTIONAL, controlled by an `import_categories` flag (default on). When turned off — for a source whose categories are unreliable or mismanaged — Quicken's category tags are ignored and every non-transfer contra lands in Uncategorized, so classification is rebuilt entirely from Keel's explicit rules. Accounts, amounts, dates, payees, transfer links, and Keel rule matches are unaffected by the flag either way.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A subcategory resolves to its full parent:child path", verified: true},
      %{description: "Paycheck posts as income, Parking as expense", verified: true},
      %{description: "A split transaction posts a contra leg per split", verified: true},
      %{description: "An uncategorized entry falls back to Uncategorized", verified: true},
      %{description: "The P&L breaks down by category", verified: true},
      %{description: "A ZTYPE 0 category lands in Uncategorized, not a guessed transfer", verified: true},
      %{description: "Importing with categories off sends tagged rows to Uncategorized", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A cash-flow entry's contra is the category (ZTAG) it references, resolved to the category's full parent:child name.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A subcategory resolves to its full parent:child path",
              body: "Given a transaction whose entry references the \"Restaurants\" category, child of \"Food & Dining\"
When the database is imported
Then the contra account is \"Food & Dining:Restaurants\""
            }
          ]
        },
        %{
          statement: "A ZTYPE 2 category posts to an income contra account; a ZTYPE 1 category posts to an expense contra account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Paycheck posts as income, Parking as expense",
              body: "Given a transaction categorized \"Paycheck\" (ZTYPE 2) and another categorized \"Parking\" (ZTYPE 1)
When the database is imported
Then \"Paycheck\" is an income account and \"Parking\" is an expense account"
            }
          ]
        },
        %{
          statement: "A split transaction posts one contra leg per split entry, each to its own category.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A split transaction posts a contra leg per split",
              body: "Given a transaction with two split entries categorized \"Groceries\" and \"Household\"
When the database is imported
Then the transaction has a Groceries contra leg and a Household contra leg, each for its split amount
And the transaction still balances per currency"
            }
          ]
        },
        %{
          statement: "An entry with no category — or one referencing a user tag rather than a category — posts to Uncategorized.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An uncategorized entry falls back to Uncategorized",
              body: "Given a transaction whose entry references no category
When the database is imported
Then its contra account is \"Uncategorized\""
            }
          ]
        },
        %{
          statement: "After import the P&L lists each category separately, not collapsed into one Uncategorized bucket.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The P&L breaks down by category",
              body: "Given an imported database with transactions in Restaurants, Groceries, and Paycheck
When the P&L is requested
Then Restaurants, Groceries, and Paycheck each appear as their own line
And none of those amounts are lumped under Uncategorized"
            }
          ]
        },
        %{
          statement: "A ZTYPE 0 (investment/special) category on a cash-flow entry posts to Uncategorized — it is never implicitly reclassified as a transfer or equity. Only unambiguous income/expense categories and Quicken's explicit transfer links are auto-classified; everything else is a work-queue item.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A ZTYPE 0 category lands in Uncategorized, not a guessed transfer",
              body: "Given a cash-flow entry categorized \"Credit Card Payment\" (ZTYPE 0) that is NOT one of Quicken's explicit transfer links
When the database is imported
Then its contra account is \"Uncategorized\"
And it is not silently turned into a transfer or an equity adjustment"
            }
          ]
        },
        %{
          statement: "Quicken category import is optional: when disabled, Quicken's ZTAG category tags are ignored and each non-transfer contra lands in Uncategorized, while Keel rule matches and transfer links still apply.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Importing with categories off sends tagged rows to Uncategorized",
              body: "Given the Quicken sample database whose paycheck row carries an income category and whose parking row carries an expense category
When it is imported with import_categories set to false
Then neither category account is credited/debited — both contras land in Uncategorized instead"
            }
          ]
        }
      ],
      questions: [
        %{body: "ZTYPE 0 categories (investment/special actions like Buy Bonds, Add Shares, Stock Dividend, plus Credit Card Payment and Adjustment) — investment actions are handled by the investment path, Credit Card Payment is really a transfer, and Adjustment maps to Opening Balance Equity. When a ZTYPE 0 category lands on an ordinary cash-flow entry, how should its contra be treated — transfer (Credit Card Payment), equity (Adjustment), or a catch-all?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 807,
    status: :in_progress,
    title: "Transfer rule type: classify a row as a transfer by regex",
    description:
      "As John, I want a transfer rule to match BOTH sides of a movement (each side = an account filter + a descriptor regex) and pair them into one linked transfer when both fire — exactly when the two share a reference key, or as a reviewable amount/FX/date proposal when they don't — so recurring transfers Quicken didn't link reconcile without me hand-matching.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "A transfer rule names both sides", verified: true},
      %{description: "Two matched sides become one linked transfer", verified: true},
      %{description: "Shared reference key pairs exactly", verified: true},
      %{description: "Keyless sides pair by amount/FX/date as a proposal", verified: true},
      %{description: "Keyless legs that don't reconcile are not proposed", verified: true},
      %{description: "One side without a counterpart waits in clearing, then links", verified: true},
      %{description: "FX cost computed from implied vs Bank of Canada rate", verified: true},
      %{description: "No rule, no transfer guess", verified: true},
      %{description: "Agent proposes a transfer rule; apply to the queue is explicit", verified: true},
      %{description: "Masked and unmasked refs pair on the shared suffix", verified: true},
      %{description: "Tolerances govern a keyless match", verified: true},
      %{description: "A candidate outside the date window is not proposed", verified: true},
      %{description: "Rate band gates a keyless cross-currency match", verified: true},
      %{description: "Editing the rate band recomputes the preview", verified: true},
      %{description: "Approving a mortgage pair books interest as the remainder", verified: true},
      %{description: "Same-currency remainder is the plain difference", verified: true},
      %{description: "A mortgage payment pairs with its principal leg", verified: true},
      %{description: "Preview shows the interest remainder", verified: true},
      %{description: "Window 0 pairs same-day legs only", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A transfer rule defines two sides; each side is an optional account filter plus a descriptor/payee regex.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A transfer rule names both sides",
              body: "Given a transfer rule whose side A is account \"RBC U.S. High Interest eSavings\" + regex \"(?i)online banking foreign exchange\"
And whose side B is account \"RBC Staff Banking\" + regex \"(?i)online banking foreign exchange\"
When the engine evaluates a USD leg on RBC U.S. High Interest eSavings and a CAD leg on RBC Staff Banking, both with that descriptor
Then the USD leg matches side A and the CAD leg matches side B"
            }
          ]
        },
        %{
          statement: "When one leg matches side A and another leg matches side B, the engine pairs them into a single linked transfer, off the P&L.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two matched sides become one linked transfer",
              body: "Given a leg matching side A for -10000 USD and a leg matching side B for +13710 CAD
When the transfer rule is applied
Then the two legs are linked as a single transfer
And neither leg appears as income or expense on the P&L"
            }
          ]
        },
        %{
          statement: "When both sides' regexes capture a shared reference key, the pair is matched exactly and auto-confirmed — no amount or date heuristic needed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Shared reference key pairs exactly",
              body: "Given a USD leg \"Ref 3WWXXXXXXXX8470 Online Banking foreign exchange\" and a CAD leg \"Ref 3WWXXXXXXXX8470 Online Banking foreign exchange\"
And both sides' regexes capture the key \"8470\"
When the engine pairs them
Then they are matched on the shared key alone and auto-confirmed
And no amount or date heuristic is used"
            },
            %{
              kind: "happy path",
              title: "Masked and unmasked refs pair on the shared suffix",
              body: "Given a USD leg \"...Ref 3WW742041628540...\" (full) and a CAD leg \"...Ref 3WWXXXXXXXX8540...\" (masked)
And each side's regex captures the trailing suffix \"8540\" as the key
When the engine pairs them
Then they match on the shared suffix \"8540\" despite the differing full ref strings
And the pair is auto-confirmed"
            }
          ]
        },
        %{
          statement: "When there is no shared key, the two sides pair by amount-via-daily-FX-rate and date within tolerance, surfaced as a proposal for review — never auto-applied.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Keyless sides pair by amount/FX/date as a proposal",
              body: "Given side-A and side-B legs that capture no shared key: -2279.29 USD and +3097.66 CAD within a few days
When the engine evaluates them
Then it proposes the pair using the daily FX rate and date proximity
And the proposal is surfaced for review, not auto-confirmed"
            },
            %{
              kind: "failure path",
              title: "Keyless legs that don't reconcile are not proposed",
              body: "Given keyless side-A and side-B legs whose amounts do not reconcile at the daily FX rate within tolerance
When the engine evaluates them
Then no pair is proposed
And both legs remain unpaired"
            }
          ]
        },
        %{
          statement: "A leg matching only one side, with no counterpart yet, parks in Transfer Clearing pending its pair; Transfer Clearing is internal and the user sees the linked transfer, not the clearing account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "One side without a counterpart waits in clearing, then links",
              body: "Given only the side-A leg has been imported and its side-B counterpart has not arrived yet
When the transfer rule is applied
Then the side-A leg parks in Transfer Clearing pending its pair
And when the side-B leg is later imported, the two link into one transfer that the user sees as a single movement (not a Transfer Clearing entry)"
            }
          ]
        },
        %{
          statement: "On pairing, the FX cost is computed from the implied rate (the two legs' amounts) against the Bank of Canada daily rate for the transfer date.",
          scenarios: [
            %{
              kind: "happy path",
              title: "FX cost computed from implied vs Bank of Canada rate",
              body: "Given a pair of -10000 USD and +13710 CAD legs dated 2026-05-20 (implied rate 1.371)
When they are linked
Then the implied rate 1.371 is recorded on the transfer
And the difference against the Bank of Canada rate for 2026-05-20 is booked as the transfer's FX cost"
            }
          ]
        },
        %{
          statement: "Transfer rules run in the one deterministic engine before any LLM, and a row matching no rule stays Uncategorized — never an implicit transfer guess.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No rule, no transfer guess",
              body: "Given a row whose description matches no transfer rule
When the deterministic engine evaluates it (no LLM call)
Then it stays Uncategorized
And it is never implicitly treated as a transfer"
            }
          ]
        },
        %{
          statement: "Transfer rules are agent-proposable via MCP and applied at import; re-applying them to rows already in the queue is an explicit, user- or agent-triggered action.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent proposes a transfer rule; apply to the queue is explicit",
              body: "Given an agent adds a two-sided transfer rule via MCP
When a later import contains rows matching both sides
Then those rows are paired per the rule at import
And existing Uncategorized rows are reclassified only when \"apply rules\" is explicitly triggered"
            }
          ]
        },
        %{
          statement: "A transfer rule provisions its matching tolerances — a date window (± days) and an amount tolerance applied after FX conversion — which govern the keyless pairing path.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tolerances govern a keyless match",
              body: "Given a transfer rule with a date window of ±5 days and an amount tolerance of 2%
And keyless side-A (-2279.29 USD) and side-B (+3097.66 CAD) legs 3 days apart that reconcile within 2% at the daily FX rate
When the engine evaluates them
Then the pair is proposed (inside both the date window and the amount tolerance)"
            },
            %{
              kind: "failure path",
              title: "A candidate outside the date window is not proposed",
              body: "Given a transfer rule with a date window of ±5 days
And keyless legs whose amounts reconcile at the FX rate but are 30 days apart
When the engine evaluates them
Then no pair is proposed (the date window is exceeded)"
            }
          ]
        },
        %{
          statement: "A transfer rule has a rate band (min_rate/max_rate); a keyless cross-currency pair matches only when its implied CAD/USD rate falls within the band, replacing the fixed 1.15–1.55 plausibility band.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Rate band gates a keyless cross-currency match",
              body: "Given a keyless transfer rule with rate band 1.30–1.50 and date window 5 days
And a USD leg of -1000 and a CAD leg of +1370 three days apart (implied 1.37)
And a second CAD leg of +9000 the same day (implied 9.0)
When the rule is applied
Then the 1.37 pair is matched
And the 9.0 candidate is not paired (outside the band)"
            }
          ]
        },
        %{
          statement: "John can edit the rate band on a transfer-rule proposal and the previewed pairs recompute against it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Editing the rate band recomputes the preview",
              body: "Given a proposed keyless transfer rule previewing a pair that implies 1.37
When John tightens the rate band to 1.40–1.50
Then the 1.37 pair drops from the preview"
            }
          ]
        },
        %{
          statement: "A transfer rule can name a remainder account; on approve, the difference between the two matched legs is posted to it so the two legs plus the remainder form one balanced transaction.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Approving a mortgage pair books interest as the remainder",
              body: "Given a proposed match of a bank payment -3527.01 (RBC Staff Banking) and a mortgage principal +1320.66 (Mortgage), with remainder account \"Home:Mortgage Interest\"
When John approves it
Then one balanced transaction results: RBC Staff Banking -3527.01, Mortgage +1320.66, Home:Mortgage Interest +2206.35"
            }
          ]
        },
        %{
          statement: "The remainder is currency-aware: a same-currency pair posts |A| − |B| to the remainder account, a cross-currency pair posts the FX cost, and no remainder leg is posted when the difference is zero.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same-currency remainder is the plain difference",
              body: "Given a same-currency pair of -1000 CAD and +900 CAD with a remainder account
When the rule is applied
Then 100 CAD is posted to the remainder account (not treated as an FX cost)
And an exact same-currency pair (-500 CAD, +500 CAD) posts no remainder leg"
            }
          ]
        },
        %{
          statement: "A same-currency two-sided rule pairs its legs by date window (rate band applied to the amount ratio), surfaced as a reviewable proposal — so a recurring payment pairs with its principal leg.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A mortgage payment pairs with its principal leg",
              body: "Given a bank \"Meridian Credit\" payment and a Mortgage \"Transfer in From Interest Payment\" leg on the same date
When the rule is previewed
Then the two legs are paired as a proposal (matched by date, not equal amounts)"
            }
          ]
        },
        %{
          statement: "The proposal preview shows the remainder line (its destination account and amount) alongside the two matched legs before approval.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Preview shows the interest remainder",
              body: "Given a proposed mortgage pair with remainder account \"Home:Mortgage Interest\"
When John views the proposal
Then it shows the two matched legs and a remainder line: Home:Mortgage Interest 2206.35"
            }
          ]
        },
        %{
          statement: "A date window of 0 matches only same-day legs — two legs on the same date pair, but a candidate one day apart is not paired.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Window 0 pairs same-day legs only",
              body: "Given a same-currency out-leg and an equal in-leg on the same date, plus another in-leg one day later
When a transfer rule with date_window_days 0 is applied
Then the same-day pair is linked and the one-day-apart leg is left unmatched"
            }
          ]
        }
      ],
      questions: [
        %{body: "Rule precedence: when more than one rule matches a row (e.g. a category rule and a transfer rule, or two transfer rules), which wins — first by explicit priority/order, most-specific (account-scoped beats unscoped), or is an ambiguous multi-match itself an Uncategorized work-queue item?", status: :resolved, resolution: nil},
        %{body: "Do rules apply only at import time, or also retroactively — re-running the rule set over already-imported Uncategorized/unmatched rows to reclassify them (so adding a new rule clears matching items already in the work queue)?", status: :resolved, resolution: nil},
        %{body: "How is the reference key specified — a named capture group in each side's regex (e.g. the captured substring IS the key), so two legs pair when their captures are equal? Lean: yes, a capture group defines the key; no capture → keyless (fuzzy) path.", status: :resolved, resolution: nil},
        %{body: "Masking: one leg can show the full ref (3WW742041628540) while its partner is masked (3WWXXXXXXXX8540) — the full strings differ but the trailing suffix (8540) is shared. Do we key on the stable trailing suffix rather than the whole token? Lean: yes, key on the suffix so masked/unmasked partners still pair.", status: :resolved, resolution: nil},
        %{body: "On approve, the two legs currently carry placeholder/wrong contras (bank leg → Uncategorized; mortgage principal → \"Interest Earned\" income). To end up with one clean balanced transaction (bank / principal / interest), approve must undo those. Given the append-only ledger (corrections = reversing entries), the mechanism is: reverse the two junk contras and post the corrected transfer+remainder transaction. Confirm that's the approach?", status: :resolved, resolution: nil},
        %{body: "Does a remainder account apply to ANY matched pair (keyed-by-ref or keyless), or only keyless? Lean: any matched pair can carry a remainder account; the mortgage happens to be keyless (date-matched, unequal amounts).", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 808,
    status: :completed,
    title: "Uncategorized work queue for human-AI review",
    description:
      "As John, I want a queue of every still-uncategorized transaction — the ones no rule could classify — presented as a shared work board, so that the agent and I can review the tail together and decide what becomes a rule versus what is a genuine one-off.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Only uncategorized rows appear", verified: true},
      %{description: "CAD and USD uncategorized rows share one list", verified: true},
      %{description: "A row carries enough to decide", verified: true},
      %{description: "Biggest dollars first regardless of sign", verified: true},
      %{description: "Resolving a row removes it from the queue", verified: true},
      %{description: "Queue shows total and per-currency counts", verified: true},
      %{description: "Empty queue when nothing is uncategorized", verified: true},
      %{description: "Agent reads the same queue as John", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:pass, :pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The queue contains exactly the transactions whose contra leg is the Uncategorized account; rows a rule already classified never appear.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Only uncategorized rows appear",
              body: "Given a transaction posted with its contra leg in the \"Uncategorized\" account
And another transaction a rule classified to \"Groceries\"
When John opens the uncategorized queue
Then the Uncategorized transaction appears in the queue
And the Groceries transaction does not appear"
            }
          ]
        },
        %{
          statement: "The queue is entity-wide: it aggregates uncategorized rows across every account and both currencies into one shared list.",
          scenarios: [
            %{
              kind: "happy path",
              title: "CAD and USD uncategorized rows share one list",
              body: "Given an uncategorized transaction in a CAD chequing account
And an uncategorized transaction in a USD credit card account
When John opens the uncategorized queue
Then both the CAD and the USD transactions appear in the same list"
            }
          ]
        },
        %{
          statement: "Each queue row shows date, description/descriptor, amount, currency, and source account — enough to decide a rule or a one-off without opening the transaction.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A row carries enough to decide",
              body: "Given an uncategorized transaction \"WWW PMT TIN0-02418\" for -420.00 CAD dated 2026-03-01 from \"RBC Chequing\"
When John views it in the uncategorized queue
Then the row shows the date 2026-03-01
And the description \"WWW PMT TIN0-02418\"
And the amount -420.00 with currency CAD
And the source account \"RBC Chequing\""
            }
          ]
        },
        %{
          statement: "Rows are ordered by absolute amount descending, so the highest-dollar unclassified work surfaces first.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Biggest dollars first regardless of sign",
              body: "Given uncategorized transactions of -5,000.00, +50.00, and -1,200.00
When John opens the uncategorized queue
Then they are listed in the order 5,000.00 then 1,200.00 then 50.00"
            }
          ]
        },
        %{
          statement: "A transaction leaves the queue once its contra is no longer Uncategorized — whether a new rule matched it or it was categorized manually.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Resolving a row removes it from the queue",
              body: "Given an uncategorized transaction \"ACME LOAN PMT\" in the queue
When a rule is added that matches \"loan pmt\" and rules are applied
Then \"ACME LOAN PMT\" no longer appears in the uncategorized queue"
            }
          ]
        },
        %{
          statement: "The queue displays its total count and per-currency totals so progress is visible as the tail shrinks.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Queue shows total and per-currency counts",
              body: "Given 7 uncategorized transactions, 4 in CAD and 3 in USD
When John opens the uncategorized queue
Then it shows a total count of 7
And a per-currency split of 4 CAD and 3 USD"
            },
            %{
              kind: "failure path",
              title: "Empty queue when nothing is uncategorized",
              body: "Given no transaction has its contra leg in the \"Uncategorized\" account
When John opens the uncategorized queue
Then it shows an empty state
And a total count of 0"
            }
          ]
        },
        %{
          statement: "The agent can retrieve the same queue programmatically via MCP, so John and the agent work from one shared list.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent reads the same queue as John",
              body: "Given uncategorized transactions exist
When the agent requests the uncategorized queue via MCP
Then it receives the same rows John sees in the UI, with description, amount, currency, date, and source account"
            }
          ]
        }
      ],
      questions: [
        %{body: "~7,500 rows are uncategorized on the real data today. Does the flat queue paginate/page through results, or is a single virtualized LiveView stream acceptable for v1?", status: :resolved, resolution: nil},
        %{body: "Default order is absolute-amount descending. Once clustering (next story) lands, should the queue group by cluster and order by cluster dollar-impact instead of a flat amount sort — or keep the flat list and put clusters on a separate view?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 809,
    status: :completed,
    title: "Cluster uncategorized transactions into rule candidates",
    description:
      "As the categorization agent, I want uncategorized transactions grouped into clusters of similar rows by a normalized form of their description, so I can propose a single rule that clears a whole cluster instead of John reviewing thousands of rows one at a time.",
    tags: [%{name: "agent"}],
    criteria: [
      %{description: "Same input, same clusters", verified: true},
      %{description: "Descriptions differing only by a number cluster together", verified: true},
      %{description: "Classified rows are excluded from clustering", verified: true},
      %{description: "A cluster carries everything needed to draft a rule", verified: true},
      %{description: "Biggest-dollar clusters first", verified: true},
      %{description: "A unique row forms a size-one cluster", verified: true},
      %{description: "Agent pulls clusters over MCP", verified: true},
      %{description: "Singletons are one-offs, multi-row clusters are rule candidates", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Keel Categorization Agent", slug: "categorization-agent", type: "proto"},
      rules: [
        %{
          statement: "Clustering is deterministic — the same uncategorized rows always produce the same clusters, with no LLM or randomness.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same input, same clusters",
              body: "Given a fixed set of uncategorized transactions
When the agent runs clustering twice
Then both runs produce the identical set of clusters in the identical order"
            }
          ]
        },
        %{
          statement: "Rows are grouped by a normalized descriptor: lowercase, strip digit/reference/date runs, collapse whitespace — so descriptions differing only by an embedded number land in one cluster.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Descriptions differing only by a number cluster together",
              body: "Given uncategorized rows \"WWW PMT TIN0-02418\" and \"WWW PMT TIN0-00870\"
When the agent runs clustering
Then both rows fall into one cluster whose normalized pattern is \"www pmt tin\""
            }
          ]
        },
        %{
          statement: "Clustering operates only over uncategorized rows, never transactions a rule already classified.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Classified rows are excluded from clustering",
              body: "Given an uncategorized row \"MISC PAYMENT 123\"
And a row already classified to \"Groceries\"
When the agent runs clustering
Then only the uncategorized row appears in a cluster
And the Groceries row appears in no cluster"
            }
          ]
        },
        %{
          statement: "Each cluster reports its normalized pattern, a sample description, member count, and per-currency dollar total.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A cluster carries everything needed to draft a rule",
              body: "Given 41 uncategorized rows that normalize to \"www pmt tin\" totaling -12,000.00 CAD
When the agent reads that cluster
Then it sees the pattern \"www pmt tin\", a sample description, a member count of 41, and a total of -12,000.00 CAD"
            }
          ]
        },
        %{
          statement: "Clusters are ordered by total absolute dollar impact descending, so the biggest rule opportunities surface first.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Biggest-dollar clusters first",
              body: "Given a cluster totaling -12,000.00 and a cluster totaling +300.00
When the agent lists clusters
Then the -12,000.00 cluster is listed before the +300.00 cluster"
            }
          ]
        },
        %{
          statement: "Every uncategorized row belongs to exactly one cluster; a unique description forms a cluster of size one, so nothing is hidden.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A unique row forms a size-one cluster",
              body: "Given an uncategorized row with a description that matches no other row
When the agent runs clustering
Then that row appears as a cluster of size 1, not omitted"
            }
          ]
        },
        %{
          statement: "The agent retrieves clusters via MCP so it can draft one rule per cluster.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Agent pulls clusters over MCP",
              body: "Given uncategorized transactions exist
When the agent requests clusters via MCP
Then it receives the clusters, each with its pattern, sample, count, and per-currency total"
            }
          ]
        },
        %{
          statement: "A size-one cluster is surfaced as a one-off for manual categorization, not flagged as a rule candidate — rules are only for repeating patterns.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Singletons are one-offs, multi-row clusters are rule candidates",
              body: "Given a cluster of size 1 and a cluster of size 12
When the agent reviews clusters for rule candidates
Then only the size-12 cluster is flagged as a rule candidate
And the size-1 cluster is marked a one-off for manual categorization"
            }
          ]
        }
      ],
      questions: [
        %{body: "How aggressive should normalization be — strip all digit-runs + punctuation, or use a curated noise-token list? Over-stripping risks merging genuinely distinct payees (e.g. two different \"PAYPAL *MERCHANT\" rows collapsing into one). Lean: strip digit/ref/date runs only, keep alpha tokens.", status: :resolved, resolution: nil},
        %{body: "Is there a minimum cluster size to flag as a rule *candidate* (e.g. 3+ rows), or does the agent see all clusters including singletons and decide for itself? Lean: surface all, sorted by dollar impact, and let the agent judge.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 810,
    status: :completed,
    title: "Agent drafts, previews, and applies a rule on John's approval",
    description:
      "As the categorization agent, I want to draft a rule from a cluster, preview exactly which uncategorized transactions it would classify before anything changes, and apply it once John approves, so clusters get cleared safely without miscategorizing his transactions.",
    tags: [%{name: "agent"}],
    criteria: [
      %{description: "Preview lists matches and changes nothing", verified: true},
      %{description: "Preview reports count and a sample", verified: true},
      %{description: "Drafting without approval persists nothing", verified: true},
      %{description: "Rejecting a draft leaves rows uncategorized", verified: true},
      %{description: "Already-classified rows are never overridden", verified: true},
      %{description: "Approval persists the rule and reclassifies matches", verified: true},
      %{description: "Apply matches the preview exactly", verified: true},
      %{description: "Proposals appear live as the agent posts them", verified: true},
      %{description: "Editing a proposal re-computes the preview", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Keel Categorization Agent", slug: "categorization-agent", type: "proto"},
      rules: [
        %{
          statement: "A dry-run preview returns exactly which currently-uncategorized transactions the rule would classify and how (categorize to a target, or transfer), without persisting the rule or changing the ledger.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Preview lists matches and changes nothing",
              body: "Given uncategorized rows \"LOAN PMT 1\" and \"LOAN PMT 2\"
When the agent previews a transfer rule matching \"loan pmt\"
Then the preview lists both rows as classified to the transfer target
And the ledger is unchanged
And the rule is not saved"
            }
          ]
        },
        %{
          statement: "The preview reports the affected count and a sample of matched rows so John can judge impact before approving.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Preview reports count and a sample",
              body: "Given 41 uncategorized rows that a drafted rule would match
When the agent previews the rule
Then the preview reports an affected count of 41
And includes a sample of the matched rows"
            }
          ]
        },
        %{
          statement: "Nothing is persisted or applied without John's explicit approval; a rejected draft leaves the rule unsaved and the rows uncategorized.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Drafting without approval persists nothing",
              body: "Given the agent has drafted and previewed a rule
When John has not approved it
Then the rule is not saved
And no transaction is reclassified"
            },
            %{
              kind: "failure path",
              title: "Rejecting a draft leaves rows uncategorized",
              body: "Given a previewed rule matching 41 uncategorized rows
When John rejects the draft
Then the rule is not saved
And all 41 rows remain uncategorized"
            }
          ]
        },
        %{
          statement: "Preview and apply consider only still-uncategorized rows — neither overrides a transaction an existing rule already classified.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Already-classified rows are never overridden",
              body: "Given a transaction already classified to \"Groceries\" by an existing rule
And a newly drafted rule whose regex would also match that description
When the agent previews and then applies the new rule
Then the transaction stays classified to \"Groceries\"
And only still-uncategorized matches are affected"
            }
          ]
        },
        %{
          statement: "On approval, applying persists the rule and reclassifies the matched uncategorized rows in one operation, then re-runs transfer auto-linking.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Approval persists the rule and reclassifies matches",
              body: "Given John approves a previewed transfer rule matching \"loan pmt\"
When the rule is applied
Then the rule is saved
And the matching uncategorized rows are reclassified to the transfer target
And transfer auto-linking is re-run"
            }
          ]
        },
        %{
          statement: "The applied outcome matches the preview — the rows shown in the preview are exactly the rows reclassified, no more and no fewer.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Apply matches the preview exactly",
              body: "Given a preview that listed exactly 41 rows as matched
When John approves and the rule is applied
Then exactly those 41 rows are reclassified, no more and no fewer"
            }
          ]
        },
        %{
          statement: "Proposed rules appear on a durable UI surface that updates live as the agent posts proposals, where John approves, edits, or rejects each.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Proposals appear live as the agent posts them",
              body: "Given John is viewing the proposed-rules surface
When the agent posts a new rule proposal
Then the proposal appears on the surface live, without a manual refresh
And offers approve, edit, and reject actions"
            }
          ]
        },
        %{
          statement: "John can edit a proposed rule's regex, target, and priority before approving; the preview re-computes against the edited rule so he sees the new impact before committing.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Editing a proposal re-computes the preview",
              body: "Given a proposed rule with regex \"payment\" that previews 200 matched rows
When John edits the regex to \"loan payment\"
Then the preview re-computes to show only the loan-payment rows
And John can approve the edited rule, applying exactly the re-previewed rows"
            }
          ]
        }
      ],
      questions: [
        %{body: "Where does approval happen — a \"proposed rules\" surface in the queue UI (approve/reject per draft), or conversationally (the agent proposes in chat and John says \"apply\")? Lean: a durable UI surface so proposals are visible and auditable, with chat as a shortcut.", status: :resolved, resolution: nil},
        %{body: "Can John edit the agent's drafted regex/target/priority before approving, or only approve/reject as-is? Lean: edit-then-approve, since John will often tighten a too-broad regex.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 813,
    status: :completed,
    title: "Agent proposes a transfer rule on John's approval",
    description:
      "As the categorization agent, I want to propose a two-sided transfer rule from a cluster of transfer legs and preview the exact pairs it would link (key/implied-rate/FX-cost) on the workbench, so John reviews and approves it before any legs are linked.",
    tags: [%{name: "agent"}],
    criteria: [
      %{description: "A proposed transfer rule appears on the board", verified: true},
      %{description: "The proposal previews the pairs it would link", verified: true},
      %{description: "Previewing changes nothing", verified: true},
      %{description: "Keyed and keyless proposals preview differently", verified: true},
      %{description: "Approval links keyed pairs and queues keyless ones", verified: true},
      %{description: "Editing the proposed rule re-computes the pair preview", verified: true},
      %{description: "Rejecting leaves the legs untouched", verified: true},
      %{description: "Transfer-rule and categorization proposals are distinguishable", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Keel Categorization Agent", slug: "categorization-agent", type: "proto"},
      rules: [
        %{
          statement: "The agent proposes a two-sided transfer rule (each side: account filter + descriptor regex) and it appears on the workbench proposals board.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A proposed transfer rule appears on the board",
              body: "Given John is viewing the workbench proposals board
When the agent proposes a transfer rule (side A: RBC U.S. High Interest eSavings / \"foreign exchange ref …\", side B: RBC Staff Banking / same)
Then a transfer-rule proposal appears on the board live, naming both sides"
            }
          ]
        },
        %{
          statement: "The proposal shows a dry-run preview of the exact pairs it would link — each pair's side-A leg, side-B leg, key (or \"fuzzy\"), implied rate, and FX cost — without linking anything.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The proposal previews the pairs it would link",
              body: "Given a proposed keyed transfer rule over the FX-family legs
When John views the proposal
Then it shows each pair: the side-A (USD) leg, the side-B (CAD) leg, the shared key, the implied rate, and the FX cost
And no transfer has been linked yet"
            }
          ]
        },
        %{
          statement: "Proposing and previewing persists no links and reclassifies no legs; nothing changes until John approves.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Previewing changes nothing",
              body: "Given the agent has proposed a transfer rule and John has not approved it
When the preview is shown
Then no legs are linked
And no legs have been reclassified out of the uncategorized queue"
            }
          ]
        },
        %{
          statement: "Keyed proposals preview exact key-matched pairs; keyless proposals preview amount/FX/date candidate pairs, flagged as fuzzy for review.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Keyed and keyless proposals preview differently",
              body: "Given a keyed proposal (regexes capture a shared ref suffix) and a keyless proposal (no key capture)
When John views each
Then the keyed proposal's pairs each show the shared key
And the keyless proposal's pairs are flagged fuzzy, showing the amount/FX/date match basis"
            }
          ]
        },
        %{
          statement: "On approval the rule is applied and the outcome matches the preview: keyed pairs are auto-confirmed (linked); keyless pairs land in the /transfers review queue.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Approval links keyed pairs and queues keyless ones",
              body: "Given a previewed transfer-rule proposal with keyed pairs and keyless candidates
When John approves it
Then exactly the previewed keyed pairs are linked as confirmed transfers
And the keyless candidates appear in the /transfers review queue
And the previewed legs leave the uncategorized queue"
            }
          ]
        },
        %{
          statement: "John can edit the proposed rule (regex, account filters, tolerances) before approving, and the pair preview re-computes against the edit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Editing the proposed rule re-computes the pair preview",
              body: "Given a proposed transfer rule previewing 12 pairs
When John tightens side A's account filter so only one account qualifies
Then the pair preview re-computes to the smaller set of pairs that still match"
            }
          ]
        },
        %{
          statement: "Rejecting a proposed transfer rule discards it; no legs are linked and they remain as they were.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Rejecting leaves the legs untouched",
              body: "Given a proposed transfer rule previewing several pairs
When John rejects it
Then the proposal is removed from the board
And no legs are linked and they remain uncategorized"
            }
          ]
        },
        %{
          statement: "The board distinguishes transfer-rule proposals (two sides, pair preview) from single-transaction categorization-rule proposals.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transfer-rule and categorization proposals are distinguishable",
              body: "Given both a categorization-rule proposal and a transfer-rule proposal are on the board
When John views the board
Then the transfer-rule proposal is shown as two-sided with a pair preview
And the categorization-rule proposal is shown as single-sided with its matched-rows preview"
            }
          ]
        }
      ],
      questions: [
        %{body: "How does the agent pick the candidate cluster of transfer legs to propose a rule from — reuse the deterministic clusterer (story 809) over transfer-ish uncategorized legs (e.g. legs whose normalized descriptor is \"online banking foreign exchange ref\")? Lean: yes, propose from a cluster.", status: :resolved, resolution: nil},
        %{body: "Granularity of approval: John approves the RULE once (having seen the full pair preview) and the keyed pairs then auto-confirm as a batch — vs. confirming each pair individually? Lean: approve the rule once; keyed pairs auto-confirm, keyless go to /transfers for per-pair confirmation.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 817,
    status: :completed,
    title: "Show the actual linked transfers on the transfers screen",
    description:
      "As John, I want the transfers screen to list the transfers that are actually linked — each pair's date, both accounts, both amounts/currencies, implied rate and FX cost, and how it was matched — so I can see what's really in and unlink any that are wrong.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Linked transfers are listed newest-first", verified: true},
      %{description: "A cross-currency transfer row shows full detail", verified: true},
      %{description: "A row shows its match source", verified: true},
      %{description: "Unlinking returns both legs to unmatched", verified: true},
      %{description: "No proposals or queue on the screen", verified: true},
      %{description: "Empty state when nothing is linked", verified: true},
      %{description: "A same-currency transfer appears with rate 1.00", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The transfers screen lists linked transfers, one row per pair, newest first, paginated with a total count.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Linked transfers are listed newest-first",
              body: "Given two confirmed transfers, one dated 2026-05-20 and one dated 2024-07-29
When John opens the transfers screen
Then both transfers appear as rows
And the 2026-05-20 transfer is listed above the 2024-07-29 one"
            }
          ]
        },
        %{
          statement: "Each transfer row shows the date, both legs' accounts, both amounts with currencies, the implied rate, and the FX cost.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A cross-currency transfer row shows full detail",
              body: "Given a confirmed cross-currency transfer of -10000 USD ↔ 13710 CAD on 2026-05-20
When John views the transfers screen
Then the row shows the date, both accounts, -10000 USD and 13710 CAD, the implied rate (~1.371), and the FX cost"
            },
            %{
              kind: "happy path",
              title: "A same-currency transfer appears with rate 1.00",
              body: "Given a confirmed same-currency transfer of -500 CAD ↔ 500 CAD
When John views the transfers screen
Then the row appears in the same roster with implied rate 1.00 and FX cost 0"
            }
          ]
        },
        %{
          statement: "Each row labels how the transfer was matched (shared-ref rule, rate-band rule, manual link, Quicken-linked, or exact auto-link).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A row shows its match source",
              body: "Given a transfer that was linked by a shared-ref transfer rule
When John views its row
Then the row labels the match source as the shared-ref rule (distinct from manual or Quicken-linked)"
            }
          ]
        },
        %{
          statement: "John can unlink a transfer from the screen; both legs return to unmatched and the row leaves the roster (reversible, not destructive).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Unlinking returns both legs to unmatched",
              body: "Given a confirmed transfer on the screen
When John unlinks it
Then the row leaves the roster
And both legs are unmatched again (the underlying transactions still exist)"
            }
          ]
        },
        %{
          statement: "The screen shows only linked transfers — no match proposals and no review queue.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No proposals or queue on the screen",
              body: "Given there are both confirmed transfers and unmatched legs in the system
When John opens the transfers screen
Then only the confirmed transfers are shown
And there is no proposal list or match-review queue"
            }
          ]
        },
        %{
          statement: "When there are no linked transfers, the screen shows an empty state.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Empty state when nothing is linked",
              body: "Given no confirmed transfers exist
When John opens the transfers screen
Then an empty state is shown instead of a table"
            }
          ]
        }
      ],
      questions: [
        %{body: "Volume: there can be hundreds of linked transfers (Quicken pre-linked ~279 + rule-linked + exact). Show all, or paginate / show top-N with a total count? Lean: paginate (or top-N with total), newest first.", status: :resolved, resolution: nil},
        %{body: "Same-currency transfers (exact mirrors): show them in the same roster with implied rate 1.00 / FX cost 0, or only show cross-currency transfers here? Lean: one roster for all linked transfers regardless of currency.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 820,
    status: :in_progress,
    title: "Administer categorization rules",
    description:
      "As John, I want an admin page that lists my categorization rules — match, action, target, priority, and enabled state — so I can review, edit, enable/disable, and delete them in one place.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Rules listed in priority order", verified: true},
      %{description: "A rule row shows its full detail", verified: true},
      %{description: "Disabling a rule keeps it but marks it disabled", verified: true},
      %{description: "Editing a rule's target updates it", verified: true},
      %{description: "Deleting a rule removes it from the list", verified: true},
      %{description: "Empty state when no rules", verified: true},
      %{description: "Transfer rules listed with both sides and band", verified: true},
      %{description: "Adding a categorization rule lists it", verified: true},
      %{description: "Adding a transfer rule lists it", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The rules admin page lists all categorization rules in priority order (the order they are evaluated).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Rules listed in priority order",
              body: "Given two rules exist, one with priority 10 and one with priority 50
When John opens the rules admin page
Then both rules are listed
And the priority-10 rule appears above the priority-50 rule"
            }
          ]
        },
        %{
          statement: "Each rule row shows its match regex, action (categorize or transfer), target, account scope, priority, and enabled state.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A rule row shows its full detail",
              body: "Given a categorize rule matching \"(?i)hetzner\" → \"Discussit:Hosting\", priority 100, enabled
When John views the page
Then the row shows the regex, the categorize action, the target Discussit:Hosting, the priority, and that it is enabled"
            }
          ]
        },
        %{
          statement: "John can enable or disable any rule (categorization or transfer) from the page without deleting it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Disabling a rule keeps it but marks it disabled",
              body: "Given an enabled rule on the page
When John disables it
Then the rule remains listed
And it is shown as disabled (and would no longer apply on the next run)"
            }
          ]
        },
        %{
          statement: "John can edit a rule's fields (match regex, target, priority) from the page.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Editing a rule's target updates it",
              body: "Given a rule targeting \"Discussit:Hosting\"
When John edits its target to \"Discussit:Infrastructure\" and saves
Then the listed rule shows the new target"
            }
          ]
        },
        %{
          statement: "John can delete a rule from the page.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Deleting a rule removes it from the list",
              body: "Given a rule on the page
When John deletes it
Then the rule is no longer listed"
            }
          ]
        },
        %{
          statement: "When there are no rules, the page shows an empty state.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Empty state when no rules",
              body: "Given no categorization rules exist
When John opens the rules admin page
Then an empty state is shown instead of a table"
            }
          ]
        },
        %{
          statement: "The page also lists the two-sided transfer rules, each showing both sides (account + regex), the rate band, date window, priority, and enabled state.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transfer rules listed with both sides and band",
              body: "Given a two-sided transfer rule (RBC eSavings ↔ RBC Staff Banking, rate band 1.30–1.50, ±5 days)
When John opens the rules admin page
Then the transfer rule is listed showing both sides, the rate band, the date window, priority, and enabled state"
            }
          ]
        },
        %{
          statement: "John can add a new categorization rule from the page (regex, action, target, priority).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Adding a categorization rule lists it",
              body: "Given John is on the rules admin page
When he adds a categorize rule matching \"(?i)aws\" → \"Discussit:Hosting\"
Then the new rule appears in the list"
            }
          ]
        },
        %{
          statement: "John can add a new two-sided transfer rule from the page (both sides, rate band, date window).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Adding a transfer rule lists it",
              body: "Given John is on the rules admin page
When he adds a transfer rule (side A account + regex, side B account + regex, rate band, date window)
Then the new transfer rule appears in the transfer-rules section"
            }
          ]
        }
      ],
      questions: [
        %{body: "Scope: does this page cover ONLY the single-row categorize/transfer rules (the Rule table), or also the two-sided transfer rules (TransferRule)? Lean: single-row Rule table for this story; two-sided transfer rules get their own admin later.", status: :resolved, resolution: nil},
        %{body: "Can John ADD a brand-new rule from this page, or is creation still only via the workbench proposal flow / MCP and this page is manage-existing-only? Lean: manage-existing only for now (review/edit/toggle/delete); creation stays in the proposal flow.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 821,
    status: :in_progress,
    title: "Per-account totals sidebar",
    description:
      "As John, I want a persistent right-hand sidebar that lists each account with its current balance (in its own currency), grouped by account type with subtotals, so I can see where my money is at a glance from any page.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Sidebar lists accounts with balances, not categories", verified: true},
      %{description: "Accounts grouped by type", verified: true},
      %{description: "Balances shown in each account's currency", verified: true},
      %{description: "Group shows per-currency subtotal", verified: true},
      %{description: "Sidebar present across main pages", verified: true},
      %{description: "Clicking an account opens its register", verified: true},
      %{description: "Closed account shown with a closed marker", verified: true},
      %{description: "Per-currency net worth at the bottom", verified: true},
      %{description: "Closed accounts grouped at the bottom", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The right sidebar lists each balance-sheet account (asset, liability, investment, equity) with its current balance; income/expense category accounts are excluded.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Sidebar lists accounts with balances, not categories",
              body: "Given an asset account \"RBC Chequing\" and an expense category \"Discussit:Hosting\"
When John views any main page
Then the right sidebar lists RBC Chequing with its balance
And the expense category does not appear in the sidebar"
            }
          ]
        },
        %{
          statement: "Accounts are grouped by type, each group labeled (e.g. Assets, Liabilities, Investments).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Accounts grouped by type",
              body: "Given an asset account and a liability account (credit card)
When John views the sidebar
Then the asset is under an \"Assets\" group and the liability under a \"Liabilities\" group"
            }
          ]
        },
        %{
          statement: "Each account's balance is shown in its own currency (CAD or USD), never summed across currencies.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Balances shown in each account's currency",
              body: "Given a CAD account and a USD account
When John views the sidebar
Then the CAD account shows its balance in CAD and the USD account in USD"
            }
          ]
        },
        %{
          statement: "Each group shows a per-currency subtotal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Group shows per-currency subtotal",
              body: "Given two CAD asset accounts of 100 and 250
When John views the Assets group
Then the group shows a CAD subtotal of 350"
            }
          ]
        },
        %{
          statement: "The sidebar is present on the main app pages (workbench, transactions, transfers, rules).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Sidebar present across main pages",
              body: "Given accounts exist
When John opens the transactions page and the transfers page
Then the per-account sidebar is shown on both"
            }
          ]
        },
        %{
          statement: "Clicking an account in the sidebar opens its register (/accounts/:name).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Clicking an account opens its register",
              body: "Given the sidebar lists \"RBC Chequing\"
When John clicks it
Then he is taken to that account's register at /accounts/RBC Chequing"
            }
          ]
        },
        %{
          statement: "All accounts are shown including zero-balance ones; closed accounts are still listed but explicitly marked as closed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Closed account shown with a closed marker",
              body: "Given a closed account and a zero-balance open account
When John views the sidebar
Then both are listed
And the closed account is marked as closed"
            }
          ]
        },
        %{
          statement: "A per-currency net worth (total assets − total liabilities) is shown at the bottom of the sidebar.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Per-currency net worth at the bottom",
              body: "Given CAD assets totaling 1000 and a CAD liability of 300
When John views the sidebar
Then the bottom shows a CAD net worth of 700"
            }
          ]
        },
        %{
          statement: "Closed accounts appear in a single separate \"Closed\" group at the bottom of the sidebar, not within their type group.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Closed accounts grouped at the bottom",
              body: "Given an open asset account \"RBC Chequing\" and a closed asset account \"Old Savings\"
When John views the sidebar
Then \"Old Savings\" appears under a \"Closed\" group
And the open \"RBC Chequing\" appears under the \"Assets\" group above it"
            }
          ]
        }
      ],
      questions: [
        %{body: "Closed and zero-balance accounts: hide them from the sidebar, or show all? Lean: hide closed; show zero-balance open accounts.", status: :resolved, resolution: nil},
        %{body: "Bottom-line total: show a per-currency net worth (assets − liabilities) at the bottom, or just per-group subtotals? Cross-currency can't be summed without an FX conversion. Lean: per-currency net worth line, no cross-currency conversion for now.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 822,
    status: :in_progress,
    title: "Manage accounts",
    description:
      "As John, I want to list my accounts and create, rename, retype, and close/reopen them, so my chart of accounts stays correct (right types, no stale accounts) without editing the database.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Accounts listed with detail", verified: true},
      %{description: "Creating an account lists it", verified: true},
      %{description: "Renaming and retyping an account", verified: true},
      %{description: "Closing then reopening an account", verified: true},
      %{description: "Account with transactions cannot be deleted", verified: true},
      %{description: "Currency is not editable after creation", verified: true},
      %{description: "Creating with an opening balance starts the account there", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The accounts admin page lists every account with its name, type, currency, current balance, and open/closed status.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Accounts listed with detail",
              body: "Given a CAD asset account \"RBC Chequing\" with a balance
When John opens the accounts admin page
Then the row shows its name, type (asset), currency (CAD), balance, and open status"
            }
          ]
        },
        %{
          statement: "John can create a new account with a name, type, and currency.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Creating an account lists it",
              body: "Given John is on the accounts admin page
When he creates a liability account \"RBC Visa\" in CAD
Then the new account appears in the list as a CAD liability"
            }
          ]
        },
        %{
          statement: "John can rename an account and change its type.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Renaming and retyping an account",
              body: "Given an account typed asset
When John changes its type to liability and saves
Then the listed account shows type liability"
            }
          ]
        },
        %{
          statement: "John can close an account and reopen a closed one.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Closing then reopening an account",
              body: "Given an open account
When John closes it
Then it is shown as closed
And when John reopens it, it is shown as open again"
            }
          ]
        },
        %{
          statement: "An account that has transactions cannot be deleted; it can only be closed. An account with no entries may be deleted.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Account with transactions cannot be deleted",
              body: "Given an account that has posted transactions
When John attempts to delete it
Then the delete is refused (with a hint to close it instead)
And the account remains"
            }
          ]
        },
        %{
          statement: "An account's currency is set at creation and cannot be changed afterward.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Currency is not editable after creation",
              body: "Given an existing CAD account
When John opens its edit form
Then the currency is fixed (not editable) and stays CAD after saving other changes"
            }
          ]
        },
        %{
          statement: "On create, John may optionally enter an opening balance, which is posted as an opening transaction (contra to Opening Balance Equity) so the account starts at that balance.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Creating with an opening balance starts the account there",
              body: "Given John is creating a new CAD asset account
When he sets an opening balance of 500
Then the account is created with a balance of 500 CAD (an opening transaction is posted against Opening Balance Equity)"
            }
          ]
        }
      ],
      questions: [
        %{body: "Where does this live: a new /accounts index page (lists + manages all accounts), with the per-account register staying at /accounts/:name? Lean: yes — /accounts is the admin list, /accounts/:name stays the register.", status: :resolved, resolution: nil},
        %{body: "On create, do we set an opening balance, or just create the account shell (balance comes from transactions/import)? Lean: shell only; opening balances are a separate concern (posted as a transaction / from import).", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 824,
    status: :in_progress,
    title: "Flag structural accounts as system and keep them out of money views",
    description:
      "As John, I want the structural accounts (Transfer Clearing, Opening Balance Equity, Uncategorized) flagged as system, excluded from the sidebar and net worth, and shown in a protected \"System\" section of the accounts admin, so my account views show only real accounts.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "System accounts absent from the sidebar", verified: true},
      %{description: "Net worth ignores system accounts", verified: true},
      %{description: "System accounts in their own admin section", verified: true},
      %{description: "System account has no mutate controls", verified: true}
    ],
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "The accounts sidebar excludes system accounts (Transfer Clearing, Opening Balance Equity, Uncategorized) — they appear in no group.",
          scenarios: [
            %{
              kind: "happy path",
              title: "System accounts absent from the sidebar",
              body: "Given a real asset \"RBC Chequing\" and a system account \"Transfer Clearing\", both funded
When John views the sidebar
Then \"RBC Chequing\" is listed
And \"Transfer Clearing\" does not appear anywhere in the sidebar"
            }
          ]
        },
        %{
          statement: "System accounts do not count toward the sidebar's per-currency net worth.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Net worth ignores system accounts",
              body: "Given a real CAD asset of 1000 and a system CAD account holding 400
When John views the sidebar
Then the CAD net worth is 1000 (the system account's 400 is excluded)"
            }
          ]
        },
        %{
          statement: "The accounts admin lists system accounts in a separate \"System\" section, distinct from the regular (user) accounts.",
          scenarios: [
            %{
              kind: "happy path",
              title: "System accounts in their own admin section",
              body: "Given a regular account and a system account \"Transfer Clearing\"
When John opens the accounts admin
Then \"Transfer Clearing\" appears under a \"System\" section, not among the regular accounts"
            }
          ]
        },
        %{
          statement: "System accounts are protected in the admin: they offer no edit, close, retype, or delete controls.",
          scenarios: [
            %{
              kind: "happy path",
              title: "System account has no mutate controls",
              body: "Given a system account \"Transfer Clearing\" in the admin
When John views its row
Then it has no edit, close, or delete buttons"
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
    story_id: 847,
    status: :completed,
    title: "Crypto holdings modeled as asset-as-currency",
    description:
      "As the owner, I want my crypto activity modeled with real per-asset unit holdings, cost basis, and realized gains — so crypto stops being an unclassified cluster of Quicken \"check\" placeholder stubs and my net worth and gain/loss are actually correct.

## Problem
The Coinbase account currently holds only Quicken investment placeholder rows (\"check\"/balance-adjustment stubs) — Quicken can't model crypto lots, so the real activity is lost. Crypto activity spans buys (USD→crypto), converts (crypto→crypto, taxable disposals), sells, staking/reward income, and withdrawals (e.g. a $61,772 cash-out). Assets seen: ETH, LTC, ADA, ZRX, DAI, XRP, USDC.

## Feature: model crypto as currency (reuse the multi-currency core)
Treat each crypto asset as a CURRENCY in the existing multi-currency double-entry ledger — do NOT build a separate lots subsystem:
- `Coinbase:ETH`, `Coinbase:USDC`, etc. hold UNITS of each asset (Decimal, high precision).
- **Buy** = `USD → asset` at the buy price — structurally identical to a CAD→USD FX transaction.
- **Convert** = `asset A → asset B` — a disposal of A that realizes gain/loss (reuse the FX gain/loss residual mechanism) + acquisition of B.
- **Sell** = `asset → USD`, realizes gain.
- **Reward/staking income** = asset in + income at fair market value.
- **Withdrawal** = transfer of USD/asset out (to bank/wallet).
This story is the LEDGER CAPABILITY: the account/currency model, the transaction semantics above, cost-basis + realized-gain computation, and market value. It is source-agnostic — ongoing crypto data arrives via the holistic import path; historical backfill is a one-off `mix` task reading the Coinbase CSV (NOT a first-class importer).

## Resolved decisions (Three Amigos, 2026-07-09)
1. **Cost-basis method = AVERAGE COST (ACB).** One blended cost per asset, recomputed on each buy; matches Canadian reporting, no lot queue. Rule keeps the method pluggable, ACB is the default built.
2. **ex_money custom-currency is viable.** `Cldr.Currency.new/2` registers custom currencies with arbitrary `:digits` (high precision), stored in an ETS table. Implementation must (a) add `Cldr.Currency` to the supervision tree and register each crypto asset at boot; (b) handle the 4–11 char custom-code rule — `USDC` works directly, `XBT`/`XRP` are already CLDR-known, but 3-letter unknown codes (`ETH/LTC/ADA/DAI/ZRX`) need a 4-char alias (e.g. `XETH`).
3. **Price/market value derived from the Coinbase CSV** — the \"Price at Transaction\" column gives the last-known per-asset price for the units × price valuation (until a live feed exists).
4. **Realized gain/loss books to a dedicated Crypto Gains account** (not the existing FX gain/loss account).
5. Reconcile the ~$61,772 withdrawal cash-out to its bank landing.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Holding is denominated in asset units", verified: true},
      %{description: "Buy sets cost basis including fees", verified: true},
      %{description: "Convert realizes gain and acquires the target", verified: true},
      %{description: "Sell to fiat realizes gain against cost basis", verified: true},
      %{description: "Reward income booked at fair market value", verified: true},
      %{description: "Withdrawal is a transfer, not income", verified: true},
      %{description: "Average-cost (ACB) basis applied to every disposal", verified: true},
      %{description: "Unrealized gain shows in net worth but is not booked", verified: true}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "Each crypto asset is held as units in its own asset-denominated account, not as a USD dollar value.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Holding is denominated in asset units",
              body: "Given John buys 5 ETH on Coinbase
When the transaction posts to the ledger
Then his Coinbase ETH holding shows a balance of 5 ETH in units
And it is not stored as a USD dollar amount"
            }
          ]
        },
        %{
          statement: "A buy increases the asset's units and sets that acquisition's cost basis to the price paid including fees.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Buy sets cost basis including fees",
              body: "Given John buys 5 ETH with a subtotal of $540.89 and a $0.73 fee
When the transaction posts
Then his ETH units increase by 5
And the acquisition's cost basis is recorded as $541.62"
            }
          ]
        },
        %{
          statement: "A convert disposes the source asset (realizing gain or loss) and acquires the target asset at its fair value.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Convert realizes gain and acquires the target",
              body: "Given John holds 7.69 ETH with a cost basis of $15,001
When he converts that 7.69 ETH into 29,080 USDC worth $29,819
Then the ETH is disposed with a realized gain of about $14,818
And 29,080 USDC is acquired with a cost basis of $29,819"
            }
          ]
        },
        %{
          statement: "A sell to fiat disposes units and realizes gain or loss against their cost basis.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Sell to fiat realizes gain against cost basis",
              body: "Given John holds 61,722 USDC with a known cost basis
When he sells it for $61,722 USD
Then the USDC units are disposed
And the realized gain or loss equals proceeds minus the disposed units' cost basis"
            }
          ]
        },
        %{
          statement: "Reward or staking income is booked as income at the asset's fair market value on receipt, which becomes its cost basis.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reward income booked at fair market value",
              body: "Given Coinbase pays John 0.042246 USDC in rewards worth $0.04
When the reward posts
Then $0.04 of reward income is booked
And USDC increases by 0.042246 with a cost basis of $0.04"
            }
          ]
        },
        %{
          statement: "Moving value off the platform (withdrawal) is a transfer, never income or expense.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Withdrawal is a transfer, not income",
              body: "Given John withdraws $61,772 from Coinbase to his bank
When the transaction posts
Then it leaves the crypto account as a transfer off the P&L
And it reconciles to the bank deposit rather than counting as income"
            }
          ]
        },
        %{
          statement: "All disposals use one configured cost-basis method applied consistently.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Average-cost (ACB) basis applied to every disposal",
              body: "Given John bought 5 ETH at $108 and later 5 ETH at $400, an average cost of $254 per ETH
And average cost (ACB) is the configured cost-basis method
When he disposes 3 ETH
Then the cost basis of the disposed units is 3 x $254 = $762
And the same average-cost method is applied to every other disposal"
            }
          ]
        },
        %{
          statement: "A holding's value equals its units times the latest known price; unrealized change is not booked until disposal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Unrealized gain shows in net worth but is not booked",
              body: "Given John holds 5 ETH bought at about $108 each
When ETH's latest known price is $2,000
Then his holding is valued at $10,000
And the roughly $9,460 unrealized gain is reflected in net worth but not booked as income until he disposes"
            }
          ]
        }
      ],
      questions: [
        %{body: "Technical feasibility (main risk): can ex_money register custom high-precision crypto \"currencies\" (8+ decimals, e.g. ETH/USDC/BTC) — or do we need a parallel units representation alongside Money? Determines whether asset-as-currency is viable as designed.", status: :resolved, resolution: nil},
        %{body: "What is the price/market-value source for holdings — the CSV's last-known transaction price, or a live price feed (and refresh cadence)? Affects the \"units × latest price\" market-value rule.", status: :resolved, resolution: nil},
        %{body: "Does realized crypto gain/loss book to a dedicated Crypto Gains account, or reuse the existing FX gain/loss account?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 854,
    status: :completed,
    title: "Tag transactions and report by tag",
    description:
      "As a user, I want to apply tags to transactions so I can organize them and pull reports grouped by tag.

## Use case
Categorize all the expenses for a big trip — flights, hotels, meals, rentals — under one tag (e.g. `trip:italy-2025`) and see total spend for that trip across accounts and currencies, independent of the income/expense categories those transactions already carry.

## Shape
- Tags are MANY-TO-MANY with transactions (a transaction can carry several tags; a tag spans many transactions).
- Tags are ORTHOGONAL to categories — a tagged transaction keeps its category; tags are a second, cross-cutting axis for organizing and reporting.
- Actions: add/remove tags on a transaction; list transactions by tag; a totals-by-tag report (per currency, no cross-currency consolidation).
- Persist across re-import, keyed to transactions by a stable id (source + external_id), since reset_and_import wipes and re-creates transactions.

## Resolved decisions (Three Amigos, 2026-07-09)
1. **Namespaced tags** — `prefix:value` (e.g. `trip:italy-2025`). A report can total one tag OR roll up every tag sharing a prefix (`trip:` → per-trip totals + an all-trips total). Flat labels are the degenerate case (no `:`).
2. **Manual tagging only for v1** — tags are applied by hand (by John or the agent, one at a time) via MCP + UI. Rule-driven / auto-tagging is explicitly OUT of scope here; programmatic tagging is what story 855 (trace → auto-tag) adds on top.
3. **Both report surfaces** — a dedicated per-tag report (MCP tool + workbench page showing per-currency spend total + transaction list) AND a tag filter on existing transaction/P&L views.
4. **Transfers between the owner's own accounts are excluded from a tag's spend total** (money moved is not money spent).

Prerequisite for story 855 (\"trace a transaction and auto-tag downstream withdrawals\"), which reuses this tagging surface.

## Open for Developer/implementation
- Whether \"spend total\" reuses the existing P&L/expense aggregation or a new tag aggregation.
- Tag persistence table + join keyed on source+external_id.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Multiple tags on one transaction; one tag across many", verified: true},
      %{description: "Tagging leaves category and entries untouched", verified: true},
      %{description: "Trip report totals per currency", verified: true},
      %{description: "Internal transfer excluded from trip spend", verified: true},
      %{description: "Tag survives a Quicken re-import", verified: true},
      %{description: "Roll up all trips under a namespace prefix", verified: true},
      %{description: "Tags index lists every tag with per-currency totals", verified: true},
      %{description: "Tag detail page shows totals and transactions", verified: true},
      %{description: "Filter transactions by tag and see tag badges", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:pass, :pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A transaction can carry many tags and a tag can apply to many transactions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Multiple tags on one transaction; one tag across many",
              body: "Given a flight charge and a hotel charge
When John tags the flight with both \"Trip: Italy 2025\" and \"Business\"
Then the flight shows both tags
And the \"Trip: Italy 2025\" tag lists both the flight and the hotel once he tags the hotel too"
            }
          ]
        },
        %{
          statement: "Adding or removing a tag never changes the transaction's category or its ledger entries.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tagging leaves category and entries untouched",
              body: "Given a $500 hotel charge categorized as \"Travel:Lodging\"
When John tags it \"Trip: Italy 2025\"
Then its category is still \"Travel:Lodging\"
And its ledger entries and balances are unchanged — only the tag was added"
            }
          ]
        },
        %{
          statement: "A tag's report totals its transactions per currency, never blending currencies into one number.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Trip report totals per currency",
              body: "Given Italy-trip transactions in both USD and CAD tagged \"Trip: Italy 2025\"
When John pulls the \"Trip: Italy 2025\" report
Then it shows a USD total and a CAD total separately
And it does not blend them into a single converted number"
            }
          ]
        },
        %{
          statement: "Transfers between the owner's own accounts are excluded from a tag's spend total.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Internal transfer excluded from trip spend",
              body: "Given John tagged both a $2,000 hotel expense and a $2,000 transfer between his own accounts with \"Trip: Italy 2025\"
When he pulls the trip spend total
Then only the $2,000 hotel counts as spend
And the internal transfer is excluded from the total"
            }
          ]
        },
        %{
          statement: "A tag stays attached to the same real-world transaction across a re-import.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tag survives a Quicken re-import",
              body: "Given John tagged a flight charge \"Trip: Italy 2025\"
When he re-imports from Quicken (which wipes and re-creates transactions)
Then the same flight, matched by source and external id, still carries the \"Trip: Italy 2025\" tag"
            }
          ]
        },
        %{
          statement: "A report can total a single tag or roll up every tag sharing a namespace prefix.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Roll up all trips under a namespace prefix",
              body: "Given transactions tagged \"trip:italy-2025\" and others tagged \"trip:japan-2024\"
When John pulls the \"trip:\" rollup report
Then he sees the per-currency spend total for each trip
And a combined all-trips total per currency across the \"trip:\" namespace"
            }
          ]
        },
        %{
          statement: "All tags are browsable in the web UI, grouped by namespace prefix, with per-currency spend totals.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tags index lists every tag with per-currency totals",
              body: "Given transactions tagged \"trip:italy-2025\" and \"trip:japan-2024\" in USD and CAD
When John opens the Tags page in the app
Then he sees each tag grouped under the \"trip:\" namespace
And each tag shows its per-currency spend total and transaction count"
            }
          ]
        },
        %{
          statement: "A tag's own web page shows its per-currency spend totals and lists every transaction carrying it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tag detail page shows totals and transactions",
              body: "Given several transactions tagged \"trip:italy-2025\" in both USD and CAD
When John opens the \"trip:italy-2025\" tag page
Then he sees the USD total and CAD total separately
And a list of every transaction carrying that tag with date, description, accounts and amounts"
            }
          ]
        },
        %{
          statement: "The transactions view can be filtered to a single tag and shows each transaction's tags inline.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Filter transactions by tag and see tag badges",
              body: "Given transactions tagged \"trip:italy-2025\" among many untagged transactions
When John filters the transactions view by \"trip:italy-2025\"
Then only transactions carrying that tag are listed
And each listed transaction shows its tags as badges"
            }
          ]
        }
      ],
      questions: [
        %{body: "Flat tags vs namespaced/hierarchical tags (e.g. `trip:italy-2025`, `trip:japan-2024` grouped under `trip`)? Affects the report grouping and whether a \"all trips\" rollup is possible.", status: :resolved, resolution: nil},
        %{body: "Should tags be agent-proposable/rule-driven (like categorize rules — e.g. auto-tag by payee/date-range), or manual-only for v1? The trace story (855) implies programmatic tagging, but that may be out of scope for this story.", status: :resolved, resolution: nil},
        %{body: "Report surface: a dedicated per-tag report (MCP tool + workbench page) vs. adding a tag filter to existing transaction/P&L views? And does \"spend total\" reuse the existing P&L/expense logic or a new aggregation?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 855,
    status: :completed,
    title: "Trace a transaction and auto-tag downstream withdrawals",
    description:
      "As a user, I want to trace a transaction forward through my accounts and have the system automatically tag the withdrawals/outflows it funded, so I can see where a big inflow actually went.

## Use case
A $140,000 USD transaction landed and I want to understand where the money went. I trace it forward and the system tags every downstream withdrawal / expense / transfer that the $140k funded, so I can pull a report (via the tagging feature) of exactly where it flowed.

## Resolved decisions (Three Amigos, 2026-07-09/10)
1. **Apportionment = FIFO by time.** The traced inflow funds later outflows in date order until exhausted.
2. **Commingled funds = the traced money funds the NEXT outflows** after it lands, ignoring the account's prior balance (simple trace-FIFO, not true account-FIFO). Matches \"follow THIS money forward.\"
3. **Partial funding = tag the whole transaction, marked partially-funded.** Never split into a dollar portion.
4. **Transfer depth = multi-hop, stop at external.** Follow through transfers between the owner's OWN accounts across as many hops as needed; stop when spent or when it leaves to an external/untracked account.
5. **One-shot snapshot.** The trace runs once and applies the tags; it is not a live/re-runnable definition in v1 (re-run manually if new transactions arrive).
6. The result is recorded as a single trace tag and reported via the tagging feature (story 854). This story owns the tracing/attribution logic; 854 owns tag storage + reporting.

## Depends on
\"Tag transactions and report by tag\" (story 854, DONE) — reuses its tagging surface to record + report the trace result.",
    tags: [%{name: "operator"}],
    criteria: [
      %{description: "Trace begins at the source inflow, forward only", verified: true},
      %{description: "FIFO attribution until the traced amount runs out", verified: true},
      %{description: "Trace follows a transfer into another own account", verified: true},
      %{description: "Trace stops at exhaustion or an external boundary", verified: true},
      %{description: "Partially-funded outflow tagged whole", verified: true},
      %{description: "Traced chain is reportable as a tag", verified: true},
      %{description: "View a completed trace in the app", verified: true},
      %{description: "Partially-funded outflows are marked in the trace view", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:pass, :pass]},
    three_amigos: %{
      persona: %{name: "John — Cross-Border Owner-Operator", slug: "cross-border-owner-operator", type: "proto"},
      rules: [
        %{
          statement: "A trace starts from a chosen source inflow and follows its money forward in time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Trace begins at the source inflow, forward only",
              body: "Given John's $140,000 USD inflow dated 2025-03-01
When he starts a trace from that transaction
Then the trace begins from that inflow
And only outflows dated on or after 2025-03-01 are considered"
            }
          ]
        },
        %{
          statement: "Traced money funds later outflows in date order (FIFO) until the traced amount is exhausted.",
          scenarios: [
            %{
              kind: "happy path",
              title: "FIFO attribution until the traced amount runs out",
              body: "Given the $140,000 landed and the account then has outflows of $50,000, $60,000, and $40,000 in date order
When John traces the $140,000
Then the $50,000 and $60,000 outflows are attributed to the trace
And the $40,000 outflow is attributed (it exhausts the remaining $30,000)
And any outflow after the $140,000 is used up is not tagged"
            }
          ]
        },
        %{
          statement: "A transfer of traced money into another of the owner's own accounts carries the trace into that account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Trace follows a transfer into another own account",
              body: "Given John transferred $80,000 of the traced $140,000 from checking to his savings account
When the trace runs
Then it follows the $80,000 into savings
And tags the outflows that the $80,000 funds from savings"
            }
          ]
        },
        %{
          statement: "The trace stops when the traced amount is exhausted or the money leaves to an external or untracked account.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Trace stops at exhaustion or an external boundary",
              body: "Given the traced $140,000 has been fully spent
When the trace reaches later transactions
Then it stops tagging them
And given traced money is sent to an external or untracked account
Then the trace stops following at that boundary"
            }
          ]
        },
        %{
          statement: "An outflow only partly funded by traced money is tagged in full and marked partially funded, never split.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Partially-funded outflow tagged whole",
              body: "Given a $40,000 outflow where only $30,000 of the traced money remained
When the trace attributes it
Then the whole $40,000 transaction is tagged
And it is marked as partially funded, not split into a $30,000 amount"
            }
          ]
        },
        %{
          statement: "Every transaction the trace touches is tagged with one trace tag, reportable through the tagging feature.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Traced chain is reportable as a tag",
              body: "Given a completed trace recorded under the tag \"trace:mar-2025-140k\"
When John pulls that tag's report
Then every transaction the traced money funded appears under the tag
And the report shows per-currency totals via the tagging feature"
            }
          ]
        },
        %{
          statement: "A completed trace is viewable in the web UI through its trace tag's page.",
          scenarios: [
            %{
              kind: "happy path",
              title: "View a completed trace in the app",
              body: "Given a completed trace recorded under the tag \"trace:mar-2025-140k\"
When John opens that tag's page in the app
Then every transaction the traced money funded is listed
And the per-currency totals of the traced chain are shown"
            }
          ]
        },
        %{
          statement: "A traced transaction's page indicates when an outflow was only partially funded by the traced money.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Partially-funded outflows are marked in the trace view",
              body: "Given a completed trace where one outflow was only partially funded
When John opens the trace tag's page
Then that outflow appears in the list
And it is visibly marked as partially funded"
            }
          ]
        }
      ],
      questions: [
        %{body: "One-shot vs live: is a trace a snapshot (tag applied once, frozen) or a re-runnable/live view that re-attributes when new transactions arrive? Affects whether the trace is stored as a definition it can replay vs. just the resulting tags.", status: :resolved, resolution: nil},
        %{body: "FIFO with commingled funds: if the account already held money BEFORE the traced inflow, does FIFO draw down the older pre-existing dollars first (so the inflow funds only outflows after the prior balance is spent), or does the trace treat the inflow as funding the immediate next outflows regardless of prior balance? True account-FIFO is more correct but needs the full balance's dollar queue.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  }
]
