defmodule CodeMySpec.Requirements.PlainLanguage do
  @moduledoc """
  What each of a project's own requirements means, for somebody who does not
  read code.

  Every requirement already carries a `description` on its definition, and every
  one of those is written for an engineer — "Integration specs exist and all
  verified", "Spex boundary readiness gate". They are accurate and they are not
  for the person story 965 is for.

  So this is the other description, beside the definitions rather than inside
  them: adding a field to `RequirementDefinition` would mean touching the struct
  every graph template stamps 1562 nodes from, for text that only one component
  reads.

  ## The rules the text has to keep

  Two sentences, give or take. One is a label and four is a paragraph nobody
  reads at the top of a page.

  No module names, file paths, ids or counts of internals. That is not style —
  criterion 2927 asserts it, because this is the line a non-technical user reads
  to find out how their project is doing, and every one of those sends them
  somewhere they cannot follow.

  Static, by John's decision. A sentence written by a model is a different
  sentence every time, and there would be nothing to assert about it except its
  length.
  """

  @steps %{
    "personas_complete" => %{
      phase: :shaping,
      title: "Who it is for",
      abbrev: "who",
      detail:
        "We are working out who will use your software and what they need from it. " <>
          "Everything after this is built around those people."
    },
    "stories_exist" => %{
      phase: :shaping,
      title: "What it should do",
      abbrev: "stories",
      detail:
        "Your ideas are being turned into a list of things the software should do. " <>
          "You can read every one of them in your own words."
    },
    "technical_strategy" => %{
      phase: :design,
      title: "How it will be built",
      abbrev: "strategy",
      detail:
        "We are deciding the big technical choices once, up front, so they do not get " <>
          "made differently in ten places later."
    },
    "code_generation" => %{
      phase: :design,
      title: "The starting shape",
      abbrev: "scaffold",
      detail:
        "The skeleton of your application is being laid down. It does nothing useful " <>
          "yet, but everything else is built on top of it."
    },
    "qa_integration_plan" => %{
      phase: :design,
      title: "Talking to other services",
      abbrev: "services",
      detail:
        "We are working out which outside services your software needs, and how we will " <>
          "check each one really works."
    },
    "architecture_designed" => %{
      phase: :design,
      title: "How the pieces fit",
      abbrev: "arch",
      detail:
        "Your list of things to do is being organised into parts that fit together. " <>
          "This is what stops the software becoming a tangle as it grows."
    },
    "spex_boundary_ready" => %{
      phase: :design,
      title: "Ready to be checked",
      abbrev: "specs",
      detail:
        "We are setting up the machinery that proves your software does what you asked " <>
          "for. Without it, working and looking like it works are the same thing."
    },
    "work_dispatched" => %{
      phase: :building,
      title: "Building it",
      abbrev: "build",
      detail:
        "Your software is being written, one piece of what you asked for at a time. " <>
          "Several pieces can be underway at once, which is why this is a single step."
    },
    "issues_triaged" => %{
      phase: :checking,
      title: "Looking at what turned up",
      abbrev: "triage",
      detail:
        "Everything testing found is being read and sorted. Nothing gets quietly " <>
          "dropped, and you decide what matters."
    },
    "issues_resolved" => %{
      phase: :checking,
      title: "Fixing what mattered",
      abbrev: "fixes",
      detail:
        "The problems worth fixing are being fixed. The ones you decided to live with " <>
          "stay written down rather than forgotten."
    },
    "qa_setup" => %{
      phase: :proving,
      title: "Getting ready to test",
      abbrev: "qa setup",
      detail:
        "We are working out how to test your software the way a real person would use " <>
          "it, rather than only in pieces."
    },
    "qa_journey_plan" => %{
      phase: :proving,
      title: "Planning the walkthrough",
      abbrev: "plan",
      detail:
        "We are writing down the journeys a real user takes through your software, so " <>
          "each one can be walked start to finish."
    },
    "qa_journey_execute" => %{
      phase: :proving,
      title: "Walking it through",
      abbrev: "walk",
      detail:
        "Somebody is going through your software the way your users will, and writing " <>
          "down what actually happens."
    },
    "qa_journey_wallaby" => %{
      phase: :proving,
      title: "Keeping it working",
      abbrev: "keep",
      detail:
        "Those journeys are being turned into checks that run on their own, so a change " <>
          "later cannot quietly break what already worked."
    }
  }

  # In order. The project graph is a sequence — you cannot triage problems that
  # do not exist yet — which is what makes a timeline honest here at all. The
  # story work sits where it does because it needs the design finished and
  # produces the problems the checking phase reads.
  @order ~w(
    personas_complete
    stories_exist
    technical_strategy
    code_generation
    qa_integration_plan
    architecture_designed
    spex_boundary_ready
    work_dispatched
    issues_triaged
    issues_resolved
    qa_setup
    qa_journey_plan
    qa_journey_execute
    qa_journey_wallaby
  )

  @phases [
    {:shaping, "Shaping"},
    {:design, "Design"},
    {:building, "Building"},
    {:checking, "Checking"},
    {:proving, "Proving"}
  ]

  @doc "Every step, in the order a project moves through them."
  @spec order() :: [String.t()]
  def order, do: @order

  @doc "The phases, in order, with the name a person reads."
  @spec phases() :: [{atom(), String.t()}]
  def phases, do: @phases

  @doc """
  What this requirement means in plain language, or `nil` if it has none.

  `nil` rather than a generic fallback: a step with invented text is worse than
  a step with none, because it reads as though somebody wrote it about this
  project.
  """
  @spec fetch(String.t()) ::
          %{phase: atom(), title: String.t(), abbrev: String.t(), detail: String.t()} | nil
  def fetch(name), do: Map.get(@steps, name)
end
