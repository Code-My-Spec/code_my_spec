defmodule CodeMySpec.Configurations.ProjectConfiguration do
  @moduledoc """
  Local quality gate configuration for a project.

  One record per project. Controls:

  - Requirement toggles (what's required for a component to be "done")
  - Analyzer modes (what runs at stop time and whether it blocks)

  Lives only in the local DB — never synced to the server. The engineer
  is the only persona who touches this.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @analyzer_modes [:off, :block_all, :block_changed, :dont_block]
  @compile_modes [:block, :dont_block]
  @severities [:critical, :high, :medium, :low, :info]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type analyzer_mode :: :off | :block_all | :block_changed | :dont_block
  @type compile_mode :: :block | :dont_block
  @type severity :: :critical | :high | :medium | :low | :info

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          require_specs: boolean(),
          require_reviews: boolean(),
          require_unit_tests: boolean(),
          compile_warnings: compile_mode(),
          credo: analyzer_mode(),
          exunit: analyzer_mode(),
          spex: analyzer_mode(),
          spec_validation: analyzer_mode(),
          qa_validation: analyzer_mode(),
          fix_issues_min_severity: severity(),
          subagent_ttl_minutes: pos_integer(),
          working_copy_idle_hours: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_configurations" do
    field :project_id, :binary_id

    # Requirement toggles.
    #
    # All three default off: a fresh project writes BDD spex and code, and
    # nothing else. Markdown specs, design reviews and unit tests are real
    # artifacts with real value, but requiring them from the first commit means
    # a new project's first hours go into paperwork about code that does not
    # exist yet — and the spex already say what the code has to do, from the
    # outside, in the language of the story.
    #
    # Off is also the cheaper mistake. Turning one on later costs a
    # configuration change; turning one off after the graph has demanded
    # eighty spec files costs eighty files nobody asked for.
    field :require_specs, :boolean, default: false
    field :require_reviews, :boolean, default: false
    field :require_unit_tests, :boolean, default: false

    # Analyzer modes
    field :compile_warnings, Ecto.Enum, values: @compile_modes, default: :block
    field :credo, Ecto.Enum, values: @analyzer_modes, default: :block_changed
    field :exunit, Ecto.Enum, values: @analyzer_modes, default: :block_all
    # Off for NEW projects, on for existing ones (see the migration that
    # flips established projects to `:block_all`). A project on its first
    # day has no story that has ever gone green, so enforcement has
    # nothing to protect and only adds noise; an established project has
    # shipped stories worth holding the line on.
    #
    # Turning it on later costs nothing, because the mode governs BLOCKING
    # only — the suite runs either way, since the specs-passing gate needs
    # a current run to flip a story. So a young project still accumulates
    # specs-ready stories while the mode is `:off`, and they are already
    # protected the moment the mode changes.
    field :spex, Ecto.Enum, values: @analyzer_modes, default: :off
    field :spec_validation, Ecto.Enum, values: @analyzer_modes, default: :block_changed
    field :qa_validation, Ecto.Enum, values: @analyzer_modes, default: :block_changed

    # Story 608 — minimum severity for the FixIssues loop. Accepted
    # issues at or above this gate the requirement; anything strictly
    # below is tracked but doesn't block. Default `:medium` keeps the
    # original "lows don't block" contract; operator can raise to
    # `:high` or `:critical` to tighten, or lower to `:low` / `:info`
    # to make everything block.
    field :fix_issues_min_severity, Ecto.Enum, values: @severities, default: :medium

    # Story 704 — TTL for sub-agent registrations (Session.active_subagents/2
    # filters out registrations whose last_heartbeat_at exceeds this).
    field :subagent_ttl_minutes, :integer, default: 10

    # Story 892 — how long an agent may be quiet before its derived state is
    # reclaimed. Measured on this project rather than guessed: live agents were
    # 0.12h, 0.16h and 0.23h since last seen, with one alive-but-idle at 2.89h;
    # retired ones were 93.9h, 94.0h and 94.3h. The gap between working and gone
    # is days, so the threshold is not delicate — 2h is safe and anything from 6h
    # to 48h separates them unambiguously.
    #
    # `0` means immediately: any agent other than the one asking is reclaimable.
    # An integer rather than a `nil`/`:immediate` special case, because a number
    # that already means "hours of tolerance" reaches zero honestly — no branch,
    # no second type, and the comparison that implements the window implements
    # this too.
    field :working_copy_idle_hours, :integer, default: 2

    # Story 858 — one ordered level, not independent flags (prod requires
    # UAT requires deploy-enabled):
    #   :off  — don't touch my infra; the graph never demands DevOps work
    #   :uat  — stand up staging only; the user promotes to prod themselves
    #   :prod — full promotion: clears QA → rides to UAT → rides to prod
    #
    # Defaults to `:off` — opt in, not out. Every project is a project;
    # only some are meant to have infrastructure. Defaulting to `:prod`
    # made `/app/resources` report every project as missing all fifteen
    # steps, which buries the one project that has a real problem, and
    # made the requirement graph demand DevOps work of projects nobody
    # intends to deploy. Turning it on is the act of saying "this one
    # ships".
    field :devops, Ecto.Enum, values: [:off, :uat, :prod], default: :off

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :project_id,
      :require_specs,
      :require_reviews,
      :require_unit_tests,
      :compile_warnings,
      :credo,
      :exunit,
      :spex,
      :spec_validation,
      :qa_validation,
      :fix_issues_min_severity,
      :subagent_ttl_minutes,
      :working_copy_idle_hours,
      :devops
    ])
    |> validate_required([:project_id])
    |> validate_number(:subagent_ttl_minutes, greater_than: 0)
    # Zero is allowed and meaningful; negative is not a shorter window.
    |> validate_number(:working_copy_idle_hours, greater_than_or_equal_to: 0)
    |> unique_constraint(:project_id)
  end
end
