[
  %{
    story_id: 860,
    status: :completed,
    title: "Transcribe a hearing recording locally",
    description:
      "As a hearing documenter, I want to import a recording of a public proceeding (or record it live) and get an accurate transcript produced entirely on my own machine, so that public-but-unpublished hearings become searchable, quotable documents without any audio ever leaving my device.

Seed context: EarWitness's founding customer wants to transcribe tenant-board dispute proceedings that are public but published nowhere; the founder wants the same private capture for his own meetings. Decision drivers from persona research (hearing-documenter): privacy/confidentiality, no bot joining calls, zero marginal cost at volume, and support for multi-hour recordings.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Import a WAV file into the library", verified: true},
      %{description: "Reject a corrupt or unsupported file without touching the library", verified: true},
      %{description: "Record live audio and land it in the library", verified: true},
      %{description: "No input device available", verified: true},
      %{description: "Transcribe successfully with networking disabled", verified: true},
      %{description: "Transcribe a three-hour hearing block", verified: true},
      %{description: "Every transcript passage carries its audio timestamp", verified: true},
      %{description: "Keep using the app while transcription runs", verified: true},
      %{description: "Interrupted transcription resumes after restart", verified: true},
      %{description: "Reopen a transcript after restarting the app", verified: true},
      %{description: "Imported recording waits for an explicit transcribe action", verified: true}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "A user can import audio files in common formats (WAV/MP3/M4A/OGG/FLAC) into the library",
          scenarios: [
            %{
              kind: "happy path",
              title: "Import a WAV file into the library",
              body: "Given the app is running with an empty library
When the user imports a WAV recording of a hearing from disk
Then the recording appears in the library with its title and duration"
            },
            %{
              kind: "failure path",
              title: "Reject a corrupt or unsupported file without touching the library",
              body: "Given the app is running
When the user imports a corrupt or unsupported file
Then a clear error explains the problem and the library is unchanged"
            }
          ]
        },
        %{
          statement: "A user can record live audio directly into the library",
          scenarios: [
            %{
              kind: "happy path",
              title: "Record live audio and land it in the library",
              body: "Given an input device is selected
When the user starts recording and later stops it
Then the captured recording appears in the library ready to transcribe"
            },
            %{
              kind: "failure path",
              title: "No input device available",
              body: "Given no audio input device is available
When the user tries to start recording
Then an actionable message explains that a device must be connected or selected"
            }
          ]
        },
        %{
          statement: "Transcription runs entirely on the user's machine with no network access",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transcribe successfully with networking disabled",
              body: "Given a recording in the library and no network connectivity
When the user transcribes the recording
Then a complete transcript is produced without any network request"
            }
          ]
        },
        %{
          statement: "Multi-hour recordings transcribe to completion without arbitrary length caps",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transcribe a three-hour hearing block",
              body: "Given an imported three-hour hearing recording
When the user transcribes it
Then the transcript covers the full recording from start to end"
            }
          ]
        },
        %{
          statement: "Transcripts are timestamped so every passage traces to a point in the audio",
          scenarios: [
            %{
              kind: "happy path",
              title: "Every transcript passage carries its audio timestamp",
              body: "Given a completed transcript
When the user reads any passage
Then the passage shows the start time where it occurs in the audio"
            }
          ]
        },
        %{
          statement: "Transcription runs in the background with visible progress without blocking the app",
          scenarios: [
            %{
              kind: "happy path",
              title: "Keep using the app while transcription runs",
              body: "Given a transcription job has started
When the user browses the library during the job
Then the UI stays responsive and shows the job's progress"
            },
            %{
              kind: "failure path",
              title: "Interrupted transcription resumes after restart",
              body: "Given a transcription job is in progress
When the app quits and is reopened
Then the job resumes or restarts automatically and completes"
            }
          ]
        },
        %{
          statement: "Completed transcripts persist across app restarts",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reopen a transcript after restarting the app",
              body: "Given a completed transcript
When the user restarts the app
Then the transcript is still in the library with all its content"
            }
          ]
        },
        %{
          statement: "Transcription starts only when the user explicitly requests it for a recording",
          scenarios: [
            %{
              kind: "happy path",
              title: "Imported recording waits for an explicit transcribe action",
              body: "Given a recording was just imported into the library
When the user takes no further action
Then no transcription starts until the user explicitly requests it"
            }
          ]
        }
      ],
      questions: [
        %{body: "Should transcription auto-start on import/record, or be a manual action per recording?", status: :resolved, resolution: nil},
        %{body: "Exact import format list for v1 — WAV/MP3/M4A only, or also OGG/FLAC and audio tracks from video containers?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 861,
    status: :completed,
    title: "Capture my own meetings without a bot",
    description:
      "As a meeting participant, I want EarWitness to record both sides of my calls — my microphone and the system audio output — so that I get a complete record of meetings I'm in without a notetaker bot sitting in the participant list.

Context: capture is platform-native behind a common capture-source seam (see the miniaudio-capture and macos-system-audio-tap ADRs — this replaces the earlier Membrane/PortAudio approach, which could not build on Windows). Microphone capture works on all platforms via the miniaudio C NIF. System-audio *output* capture (the other side of the call) uses miniaudio's WASAPI loopback on Windows and a PulseAudio/PipeWire monitor source on Linux; on macOS it uses a native Core Audio process tap (macOS 14.4+, driverless, permission-gated) — there is no cross-platform path for macOS system output. Recording without notifying other participants has legal implications, handled by the separate consent story (\"Stay on the right side of recording law\"). \"Guided setup when the tap is missing\" now means granting the OS system-audio permission (or showing an unsupported-OS/version notice) rather than installing a virtual audio device.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Select the tap as the capture source", verified: true},
      %{description: "A recorded call contains both sides of the conversation", verified: true},
      %{description: "Nothing joins the meeting when capture runs", verified: true},
      %{description: "Capture starts when the policy allows it", verified: true},
      %{description: "Capture refused when the policy's conditions are unmet", verified: true},
      %{description: "Guided setup when the tap is missing", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "The user can choose the system audio tap as a capture source alongside the microphone",
          scenarios: [
            %{
              kind: "happy path",
              title: "Select the tap as the capture source",
              body: "Given the tap device is available on this machine
When the user selects the system audio tap in capture settings
Then the next capture uses the tap as its source"
            }
          ]
        },
        %{
          statement: "A tap capture records both sides of the call into a single recording",
          scenarios: [
            %{
              kind: "happy path",
              title: "A recorded call contains both sides of the conversation",
              body: "Given the user is in a call and tap capture is active
When the user and the remote participant both speak
Then the resulting recording contains both voices in one recording"
            }
          ]
        },
        %{
          statement: "Recording adds no bot or visible participant to the meeting",
          scenarios: [
            %{
              kind: "happy path",
              title: "Nothing joins the meeting when capture runs",
              body: "Given the user is in a meeting
When tap capture starts and runs for the whole meeting
Then no bot or extra participant ever appears in the meeting"
            }
          ]
        },
        %{
          statement: "The active consent policy is honored before any tap capture starts",
          scenarios: [
            %{
              kind: "happy path",
              title: "Capture starts when the policy allows it",
              body: "Given the active consent policy permits capture in this situation
When the user starts a tap capture
Then recording begins"
            },
            %{
              kind: "failure path",
              title: "Capture refused when the policy's conditions are unmet",
              body: "Given the active consent policy requires notification before capture
When the user tries to start a tap capture without the notification step
Then the capture is refused with an explanation of what the policy requires"
            }
          ]
        },
        %{
          statement: "When the tap device is not set up, the app guides the user through enabling it",
          scenarios: [
            %{
              kind: "happy path",
              title: "Guided setup when the tap is missing",
              body: "Given the tap device is not set up on this machine
When the user selects the tap as a capture source
Then the app walks them through enabling it instead of failing silently"
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
    story_id: 862,
    status: :completed,
    title: "Know who said what",
    description:
      "As a hearing documenter, I want transcripts to distinguish the speakers (adjudicator, landlord, tenant, interpreter — or my meeting counterparts) and recognize recurring voices across recordings so that every quote is attributable to a person without me re-listening to the audio.

Covers on-device diarization (segmenting who spoke when) plus speaker identification via clustering voice signatures across the library, so people I record regularly get recognized automatically.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Two-person hearing shows two distinct speakers", verified: true},
      %{description: "Naming a speaker relabels all their segments", verified: true},
      %{description: "A known voice is recognized in a new recording", verified: true},
      %{description: "Diarize with networking disabled", verified: true},
      %{description: "Overlapping or unclear speech is marked unknown, not misattributed", verified: true},
      %{description: "Deleting a voice signature stops future recognition", verified: true}
    ],
    qa: %{final: :pass, attempts: 3, history: [:fail, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "Every transcript segment is attributed to a distinct detected speaker",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two-person hearing shows two distinct speakers",
              body: "Given a recording of a two-person hearing
When the transcript is produced
Then its segments are attributed to two distinct speakers"
            }
          ]
        },
        %{
          statement: "The user can name a detected speaker and the name applies across the whole transcript",
          scenarios: [
            %{
              kind: "happy path",
              title: "Naming a speaker relabels all their segments",
              body: "Given a transcript with segments attributed to \"Speaker 1\"
When the user names Speaker 1 as \"Adjudicator\"
Then every segment of that speaker shows \"Adjudicator\""
            }
          ]
        },
        %{
          statement: "A named speaker is recognized automatically in future recordings",
          scenarios: [
            %{
              kind: "happy path",
              title: "A known voice is recognized in a new recording",
              body: "Given \"Adjudicator\" was named in an earlier recording
When a new recording containing the same voice is transcribed
Then that voice's segments are attributed to \"Adjudicator\" automatically"
            }
          ]
        },
        %{
          statement: "Speaker detection runs entirely on-device",
          scenarios: [
            %{
              kind: "happy path",
              title: "Diarize with networking disabled",
              body: "Given a recording in the library and no network connectivity
When speaker detection runs
Then speakers are detected without any network request"
            }
          ]
        },
        %{
          statement: "When confidence is low, segments stay unnamed rather than being guessed",
          scenarios: [
            %{
              kind: "happy path",
              title: "Overlapping or unclear speech is marked unknown, not misattributed",
              body: "Given a passage with overlapping or unclear speech
When the transcript is produced
Then those segments are marked as an unknown speaker instead of being guessed"
            }
          ]
        },
        %{
          statement: "The user can delete a speaker's stored voice signature at any time",
          scenarios: [
            %{
              kind: "happy path",
              title: "Deleting a voice signature stops future recognition",
              body: "Given \"Adjudicator\" has a stored voice signature
When the user deletes that speaker's signature
Then future recordings no longer auto-attribute that voice, and past transcripts keep their labels"
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
    story_id: 863,
    status: :completed,
    title: "Fix the transcript like Otter",
    description:
      "As a hearing documenter, I want an editor where I can rename and swap speaker labels, correct transcription mistakes, and replay the audio behind any passage so that the final transcript is accurate enough to publish, cite, or share.

The Otter-style experience: transcript and audio side by side, click a segment to hear it, reassign a segment to the right speaker, and edit text inline — all changes staying on my machine.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Fix a mis-heard word inline", verified: true},
      %{description: "Move a segment to the right speaker", verified: true},
      %{description: "Click a passage to hear it", verified: true},
      %{description: "Edits are still there after a restart", verified: true},
      %{description: "Undo walks back through edits", verified: true},
      %{description: "Revert a segment to what the machine heard", verified: true},
      %{description: "Follow-along highlighting during playback", verified: true}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "The user can edit a segment's text inline",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fix a mis-heard word inline",
              body: "Given a transcript segment with a mis-heard word
When the user edits the segment text inline
Then the transcript shows the corrected text"
            }
          ]
        },
        %{
          statement: "The user can reassign a segment to a different speaker",
          scenarios: [
            %{
              kind: "happy path",
              title: "Move a segment to the right speaker",
              body: "Given a segment wrongly attributed to \"Adjudicator\"
When the user reassigns it to \"Tenant\"
Then the segment shows \"Tenant\" as its speaker"
            }
          ]
        },
        %{
          statement: "Clicking a segment plays the audio behind it",
          scenarios: [
            %{
              kind: "happy path",
              title: "Click a passage to hear it",
              body: "Given a transcript open in the editor
When the user clicks a segment
Then audio playback starts at that segment's timestamp"
            }
          ]
        },
        %{
          statement: "Edits save automatically and survive restarts",
          scenarios: [
            %{
              kind: "happy path",
              title: "Edits are still there after a restart",
              body: "Given the user edited several segments
When the app is quit and reopened
Then the transcript shows all edits without any explicit save step"
            }
          ]
        },
        %{
          statement: "The user can undo editing steps with a full history within the editor",
          scenarios: [
            %{
              kind: "happy path",
              title: "Undo walks back through edits",
              body: "Given the user made three edits in a row
When the user triggers undo three times
Then the transcript returns to its state before those edits"
            }
          ]
        },
        %{
          statement: "Any segment can be reverted to the original machine transcription",
          scenarios: [
            %{
              kind: "happy path",
              title: "Revert a segment to what the machine heard",
              body: "Given a segment that was edited
When the user reverts the segment
Then the segment shows the original machine transcription again"
            }
          ]
        },
        %{
          statement: "During playback the currently spoken segment is highlighted",
          scenarios: [
            %{
              kind: "happy path",
              title: "Follow-along highlighting during playback",
              body: "Given audio playback is running in the editor
When the recording moves from one segment to the next
Then the highlight moves to the segment currently being spoken"
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
    story_id: 864,
    status: :in_progress,
    title: "Find anything ever said",
    description:
      "As a knowledge worker, I want to search across all my transcripts — by phrase, speaker, or date — so that I can find what was discussed or committed to in seconds instead of replaying hours of audio.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "A phrase search hits across multiple recordings", verified: false},
      %{description: "Narrow results to one speaker and a date range", verified: false},
      %{description: "Results are readable without opening them", verified: false},
      %{description: "Jump from a hit into the transcript", verified: false},
      %{description: "Corrected words become findable", verified: false},
      %{description: "Find a recording by its title", verified: false}
    ],
    qa: %{final: :partial, attempts: 1, history: [:partial]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "Search matches words and phrases across every transcript in the library",
          scenarios: [
            %{
              kind: "happy path",
              title: "A phrase search hits across multiple recordings",
              body: "Given transcripts from several hearings mention \"rent arrears\"
When the user searches for \"rent arrears\"
Then results include matching passages from each of those recordings"
            }
          ]
        },
        %{
          statement: "Results can be filtered by speaker and by date range",
          scenarios: [
            %{
              kind: "happy path",
              title: "Narrow results to one speaker and a date range",
              body: "Given search results spanning several speakers and months
When the user filters to speaker \"Adjudicator\" within the last month
Then only that speaker's matches from that period remain"
            }
          ]
        },
        %{
          statement: "Each result shows surrounding context and which recording it came from",
          scenarios: [
            %{
              kind: "happy path",
              title: "Results are readable without opening them",
              body: "Given a search with matches
When the user reads the result list
Then each hit shows a snippet of surrounding text, the recording title, and the timestamp"
            }
          ]
        },
        %{
          statement: "Opening a result lands in the editor at the matching segment",
          scenarios: [
            %{
              kind: "happy path",
              title: "Jump from a hit into the transcript",
              body: "Given a search result for a passage in a hearing
When the user opens the result
Then the transcript editor opens scrolled to the matching segment"
            }
          ]
        },
        %{
          statement: "Search reflects the user's edits, not just the original machine text",
          scenarios: [
            %{
              kind: "happy path",
              title: "Corrected words become findable",
              body: "Given the user corrected a mis-heard word to \"abatement\"
When the user searches for \"abatement\"
Then the corrected segment appears in the results"
            }
          ]
        },
        %{
          statement: "Search also matches recording titles, collection names, and speaker names",
          scenarios: [
            %{
              kind: "happy path",
              title: "Find a recording by its title",
              body: "Given a recording titled \"LTB hearing — 123 Main St\"
When the user searches for \"123 Main\"
Then the recording itself appears in the results alongside any transcript matches"
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
    story_id: 865,
    status: :in_progress,
    title: "Keep recordings organized",
    description:
      "As a hearing documenter, I want recordings grouped into cases/matters (or meetings/projects) with titles, dates, and participants so that related sessions stay together and I can manage a growing library of multi-hour recordings without drowning in a flat file list.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Create a case and add hearings to it", verified: false},
      %{description: "One recording appears in two collections", verified: false},
      %{description: "Browse the library by collection", verified: false},
      %{description: "Removing a case keeps its recordings", verified: false},
      %{description: "Restore a recording from the trash", verified: false}
    ],
    qa: %{final: :partial, attempts: 1, history: [:partial]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "Recordings can be grouped into collections (cases, matters, meetings, projects)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Create a case and add hearings to it",
              body: "Given two hearing recordings in the library
When the user creates a collection \"LTB — 123 Main St\" and adds both recordings
Then the collection shows both hearings together"
            }
          ]
        },
        %{
          statement: "A recording has a title, date, and participants the user can edit",
          scenarios: [
          ]
        },
        %{
          statement: "A recording can belong to any number of collections",
          scenarios: [
            %{
              kind: "happy path",
              title: "One recording appears in two collections",
              body: "Given a recording already in the collection \"LTB — 123 Main St\"
When the user also adds it to \"Weekly advocacy review\"
Then the recording appears in both collections without duplication"
            }
          ]
        },
        %{
          statement: "The library shows collections with their recordings together",
          scenarios: [
            %{
              kind: "happy path",
              title: "Browse the library by collection",
              body: "Given several collections with recordings
When the user browses the library
Then recordings are grouped under their collections rather than one flat list"
            }
          ]
        },
        %{
          statement: "Deleting a collection never deletes its recordings",
          scenarios: [
            %{
              kind: "happy path",
              title: "Removing a case keeps its recordings",
              body: "Given a collection containing two recordings
When the user deletes the collection
Then both recordings remain in the library, no longer grouped"
            }
          ]
        },
        %{
          statement: "Deleted recordings go to a trash and can be restored for 30 days before permanent removal",
          scenarios: [
            %{
              kind: "happy path",
              title: "Restore a recording from the trash",
              body: "Given the user deleted a recording yesterday
When they open the trash and restore it
Then the recording is back in the library with its transcript intact"
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
    story_id: 866,
    status: :in_progress,
    title: "Working transcriber minutes after install",
    description:
      "As a new user, I want the app to walk me through picking and downloading a transcription model on first launch so that EarWitness transcribes my first recording minutes after install, with no manual file placement or technical setup.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Fresh install greets the user with a model picker", verified: false},
      %{description: "large-v3-turbo is preselected", verified: false},
      %{description: "Download with progress and checksum verification", verified: false},
      %{description: "Transcribe right after the download finishes", verified: false},
      %{description: "Record a meeting during the download", verified: false},
      %{description: "Network drop mid-download recovers cleanly", verified: false},
      %{description: "Swap the active model in settings", verified: false}
    ],
    qa: %{final: :partial, attempts: 1, history: [:partial]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "On first launch without a model, the app offers a guided model choice with size and quality guidance",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fresh install greets the user with a model picker",
              body: "Given a fresh install with no model on disk
When the user launches the app for the first time
Then a guided model picker appears explaining size and quality tradeoffs"
            }
          ]
        },
        %{
          statement: "The recommended default model is large-v3-turbo with lighter options offered",
          scenarios: [
            %{
              kind: "happy path",
              title: "large-v3-turbo is preselected",
              body: "Given the first-run model picker is shown
When the user accepts the recommendation without changing anything
Then large-v3-turbo is downloaded, with lighter models visible as alternatives"
            }
          ]
        },
        %{
          statement: "Model downloads show progress and verify integrity before use",
          scenarios: [
            %{
              kind: "happy path",
              title: "Download with progress and checksum verification",
              body: "Given the user chose a model
When the download runs
Then progress is visible and the file is checksum-verified before activation"
            }
          ]
        },
        %{
          statement: "Once a model is installed transcription works immediately without a restart",
          scenarios: [
            %{
              kind: "happy path",
              title: "Transcribe right after the download finishes",
              body: "Given the model download just completed
When the user transcribes a recording
Then transcription runs without restarting the app"
            }
          ]
        },
        %{
          statement: "The app stays usable while a model downloads",
          scenarios: [
            %{
              kind: "happy path",
              title: "Record a meeting during the download",
              body: "Given a model download is in progress
When the user records or imports audio
Then those actions work normally while the download continues"
            }
          ]
        },
        %{
          statement: "A failed or interrupted download can be retried without corruption",
          scenarios: [
            %{
              kind: "failure path",
              title: "Network drop mid-download recovers cleanly",
              body: "Given a model download is interrupted by a network failure
When the user retries
Then the download completes and verification passes, with no corrupt model activated"
            }
          ]
        },
        %{
          statement: "The user can switch or add models later in settings",
          scenarios: [
            %{
              kind: "happy path",
              title: "Swap the active model in settings",
              body: "Given large-v3-turbo is the active model
When the user downloads and selects a lighter model in settings
Then subsequent transcriptions use the newly selected model"
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
    story_id: 867,
    status: :in_progress,
    title: "Stay on the right side of recording law",
    description:
      "As a meeting participant, I want to choose how recording consent and notification are handled — from silent capture where that's lawful, to explicit notification or an audible announcement where it isn't — so that I can use the audio tap without breaking the wiretap/consent rules that apply to my jurisdiction and situation.

Context: recording without notifying participants is legal in some places (one-party consent) and not others; the behavior needs to be a pluggable policy of the capture system rather than a hardcoded stance.",
    tags: [%{name: "documenter"}],
    criteria: [
      %{description: "Pick the notify policy in settings", verified: false},
      %{description: "Capture proceeds only on the policy's terms", verified: false},
      %{description: "Capture refused when the policy cannot be satisfied", verified: false},
      %{description: "Policies are explained where they are chosen", verified: false},
      %{description: "Participants hear the recording notice", verified: false},
      %{description: "Fresh install defaults to the protective policy", verified: false}
    ],
    qa: %{final: :fail, attempts: 2, history: [:partial, :fail]},
    three_amigos: %{
      persona: %{name: "Dana the Hearing Documenter", slug: "hearing-documenter", type: "proto"},
      rules: [
        %{
          statement: "The user chooses a recording consent policy (silent, notify, or announce) in settings",
          scenarios: [
            %{
              kind: "happy path",
              title: "Pick the notify policy in settings",
              body: "Given the settings screen is open
When the user selects the \"notify\" consent policy
Then notify becomes the active policy for future captures"
            }
          ]
        },
        %{
          statement: "The chosen policy is enforced at every capture start",
          scenarios: [
            %{
              kind: "happy path",
              title: "Capture proceeds only on the policy's terms",
              body: "Given the announce policy is active
When the user starts a tap capture
Then the announcement runs first and recording starts only after it completes"
            },
            %{
              kind: "failure path",
              title: "Capture refused when the policy cannot be satisfied",
              body: "Given the announce policy is active but the notice cannot be delivered
When the user tries to start a capture
Then the capture is refused with an explanation instead of recording silently"
            }
          ]
        },
        %{
          statement: "Each policy choice is explained in plain language with a not-legal-advice disclaimer",
          scenarios: [
            %{
              kind: "happy path",
              title: "Policies are explained where they are chosen",
              body: "Given the settings screen shows the three policies
When the user reads each option
Then each has a plain-language explanation of what it does, plus a disclaimer that this is not legal advice"
            }
          ]
        },
        %{
          statement: "The announce policy delivers an audible recording notice before capture begins",
          scenarios: [
            %{
              kind: "happy path",
              title: "Participants hear the recording notice",
              body: "Given the announce policy is active during a call
When capture starts
Then an audible recording notice is played to the other participants before any audio is kept"
            }
          ]
        },
        %{
          statement: "The policy defaults to notify until the user changes it",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fresh install defaults to the protective policy",
              body: "Given a fresh install where the user never touched consent settings
When the first capture starts
Then the notify policy governs it"
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
    story_id: 868,
    status: :in_progress,
    title: "Let my AI assistant work my conversations",
    description:
      "As a knowledge worker, I want my AI assistant (Claude or any MCP client) to securely search, read, and summarize my conversation library so that I can ask \"what did we decide about X?\" or get a meeting summary written without copy-pasting transcripts around.

EarWitness exposes MCP tools over the local library; what leaves the machine is only what I explicitly ask my own assistant to read.",
    tags: [%{name: "builder"}],
    criteria: [
      %{description: "Claude Code connects and lists the tools", verified: false},
      %{description: "Ask the assistant what was decided", verified: false},
      %{description: "Assistant saves a meeting summary onto the recording", verified: false},
      %{description: "Assistant cannot edit transcripts or rename speakers", verified: false},
      %{description: "Revoking access shuts the assistant out", verified: false},
      %{description: "No network listener for the MCP surface", verified: false}
    ],
    qa: %{final: :partial, attempts: 1, history: [:partial]},
    three_amigos: %{
      persona: %{name: "Marcus the Meeting-Heavy Builder", slug: "meeting-heavy-builder", type: "proto"},
      rules: [
        %{
          statement: "An MCP client on the same machine can connect to EarWitness's tools over stdio",
          scenarios: [
            %{
              kind: "happy path",
              title: "Claude Code connects and lists the tools",
              body: "Given assistant access is enabled
When the user's MCP client starts the EarWitness stdio server
Then the client lists EarWitness's search, read, and summary tools"
            }
          ]
        },
        %{
          statement: "The assistant can search the library and read transcripts with speakers and timestamps",
          scenarios: [
            %{
              kind: "happy path",
              title: "Ask the assistant what was decided",
              body: "Given transcripts mentioning a rent decision exist
When the assistant searches \"rent arrears\" and reads the matching transcript
Then it receives the passages with speaker names and timestamps"
            }
          ]
        },
        %{
          statement: "The assistant can attach a summary or note to a recording while all other writes stay in the UI",
          scenarios: [
            %{
              kind: "happy path",
              title: "Assistant saves a meeting summary onto the recording",
              body: "Given the assistant read a meeting transcript
When it calls the summary tool with its write-up
Then the summary appears on that recording in the app"
            },
            %{
              kind: "failure path",
              title: "Assistant cannot edit transcripts or rename speakers",
              body: "Given assistant access is enabled
When the assistant looks for tools to edit transcript text or rename speakers
Then no such tools exist on the MCP surface"
            }
          ]
        },
        %{
          statement: "Assistant access is something the user explicitly enables and can revoke",
          scenarios: [
            %{
              kind: "happy path",
              title: "Revoking access shuts the assistant out",
              body: "Given assistant access was enabled and used
When the user disables assistant access in settings
Then subsequent MCP connections and tool calls are refused"
            }
          ]
        },
        %{
          statement: "The MCP surface opens no network port; conversation data leaves the machine only through the user's own assistant",
          scenarios: [
            %{
              kind: "happy path",
              title: "No network listener for the MCP surface",
              body: "Given assistant access is enabled
When the MCP surface is in use over stdio
Then no additional network port is opened by EarWitness for assistant access"
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
    story_id: 871,
    status: :in_progress,
    title: "Announce a recording notice participants actually hear",
    description:
      "As a person recording a conversation under an \"announce\" consent policy, I want an audible recording notice to reach the other participants, so that consent is genuine and legally meaningful — not just an on-screen claim.

Deferred out of story 867 (PM decision, John, 2026-07-12). Story 867's `:announce` policy currently returns a `:delivered` status without playing any real audio (documented stub in `EarWitness.Audio.ConsentPolicy`); that \"real audible notice\" behavior is descoped to this story.

Architecture notes from the 2026-07-12 discussion:
- The four audio paths are independent. Capturing the *other side* of a call needs the macOS Core Audio process tap / Windows WASAPI loopback (a separate capture concern). Playing a notice out the *speakers* is plain miniaudio playback (works everywhere, no tap) and reaches only in-room/mic-picked-up listeners.
- The real target chosen is to put the notice **on the user's outgoing voice channel** so remote conferencing participants hear it. Software cannot inject into another app's mic input; that requires a **virtual audio INPUT device driver** per OS (macOS AudioServerPlugIn, Windows driver) — signed/notarized, install-time, permission-heavy, and *heavier and separate* from the driverless Core Audio output tap.
- Likely v1 path: deliver the notice through the **meeting bot** (story 869), which plays it into the meeting's own audio with no native audio work on the user's machine. The virtual-mic / heavier-native-component route is later work.

A prototype that plays a bundled 16kHz-mono-PCM16 clip via a miniaudio `play_notice/1` playback NIF was built and verified (69/69 spex) but intentionally NOT merged — it only covered the speakers path. Recoverable from session history if useful.

Run start_three_amigos_session to derive acceptance criteria.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 872,
    status: :in_progress,
    title: "Live transcription and segmentation while recording",
    description:
      "As someone recording a conversation, I want the transcript and its segments to appear live as I record — not only after I stop — so I can see the conversation being captured in real time and trust it's working.

Context / why this is a new story: live transcription existed under the original Membrane capture pipeline but was lost in the 2026-07-12 cross-platform rewrite. Membrane was superseded (miniaudio-capture ADR + macos-system-audio-tap ADR) because shmex/POSIX shared memory has no Windows port and Membrane never delivered the macOS system-audio tap. The replacement miniaudio pipeline (EarWitness.Audio.Pipeline) captures to a WAV file and only transcribes on stop (batch). Restoring live transcription is therefore net-new work against the current architecture, not a simple regression fix.

Desired behavior (from operator UAT): while a recording is in progress, stream captured PCM in chunks, run transcription + segmentation as fast as possible on the rolling audio, and surface partial/finalized segments in the RecordingLive UI live. Speaker clustering/diarization runs AFTER (cluster once enough audio exists), consistent with the diarization-v1 approach — live pass prioritizes fast transcribe+segment; speaker assignment refines afterward.

Likely implementation surface (for Three Amigos to refine, not prescriptive): the miniaudio capture NIF (c_src/ear_witness/audio_capture.cpp) currently writes to a WAV and finalizes on stop_capture — live mode needs it to emit PCM chunks to Elixir during capture (or expose an incremental read of the growing buffer); EarWitness.Transcription (server/engine/worker) then transcribes rolling windows incrementally; RecordingLive renders partial segments; diarization clusters post-hoc. Cross-platform constraint stands: whatever streams must work on macOS Core Audio tap, Windows WASAPI, and Linux — no Membrane/shmex.

Non-goals: perfect real-time speaker labels during the live pass (clustering is deferred); changing the on-stop batch path for existing recordings.",
    tags: [%{name: "builder"}],
    criteria: [
    ],
    three_amigos: %{
      persona: %{name: "Marcus the Meeting-Heavy Builder", slug: "meeting-heavy-builder", type: "proto"},
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  }
]
