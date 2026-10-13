defmodule CodeMySpec.Configurations.ProjectConfiguration do
  @moduledoc """
  Local quality gate configuration for a project.

  One record per project. Controls:

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
          compile_warnings: compile_mode(),
          advisory_findings: compile_mode(),
          credo: analyzer_mode(),
          exunit: analyzer_mode(),
          spex: analyzer_mode(),
          qa_validation: analyzer_mode(),
          architecture: analyzer_mode(),
          fix_issues_min_severity: severity(),
          subagent_ttl_minutes: pos_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_configurations" do
    field :project_id, :binary_id

    # Analyzer modes
    field :compile_warnings, Ecto.Enum, values: @compile_modes, default: :block
    # Whole copy, as promotion judges it (John, 2026-10-04): a finding in a
    # file the session did not touch still lands on main.
    field :credo, Ecto.Enum, values: @analyzer_modes, default: :block_all
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
    field :qa_validation, Ecto.Enum, values: @analyzer_modes, default: :block_changed

    # Story 1085 — whether live code names a dependency nobody planned, a
    # planned dependency the code never uses, a planned component with no
    # code, or code with no planned owner. Defaults to `:dont_block`
    # (criterion 1733): drift is worth reporting the moment a project exists,
    # but it should never be the thing that stops an agent by default — only
    # `:block_all`/`:block_changed` turn a finding into a block.
    field :architecture, Ecto.Enum, values: @analyzer_modes, default: :dont_block

    # Story 608 — minimum severity for the FixIssues loop. Accepted
    # issues at or above this gate the requirement; anything strictly
    # below is tracked but doesn't block. Default `:medium` keeps the
    # original "lows don't block" contract; operator can raise to
    # `:high` or `:critical` to tighten, or lower to `:low` / `:info`
    # to make everything block.
    field :fix_issues_min_severity, Ecto.Enum, values: @severities, default: :medium

    # Whether an advisory finding (`:info` — low-priority credo, low sobelow)
    # can block anything: promotion, task evaluation, the stop hook. Advisory
    # never blocks by default (John, 2026-10-04); this is the switch if that
    # changes. Read through `Validation.can_block?/2` everywhere.
    field :advisory_findings, Ecto.Enum, values: @compile_modes, default: :dont_block

    # Story 704 — TTL for sub-agent registrations (Session.active_subagents/2
    # filters out registrations whose last_heartbeat_at exceeds this).
    field :subagent_ttl_minutes, :integer, default: 10

    # How often this project's main agent is woken to look in on its agents.
    # Twenty minutes is a starting guess rather than a considered number — it is
    # the one value trading the feature's two costs against each other, and the
    # right one is not knowable in advance. Default here rather than in the
    # migration, so a reader of the struct sees it.
    field :main_agent_cadence_seconds, :integer, default: 1200

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
      :compile_warnings,
      :advisory_findings,
      :credo,
      :exunit,
      :spex,
      :qa_validation,
      :architecture,
      :fix_issues_min_severity,
      :subagent_ttl_minutes,
      :main_agent_cadence_seconds,
      :devops
    ])
    |> validate_required([:project_id])
    |> validate_number(:subagent_ttl_minutes, greater_than: 0)
    |> validate_number(:main_agent_cadence_seconds, greater_than: 0)
    |> unique_constraint(:project_id)
  end

  @doc """
  The project's devops level. A row predating the column loads `nil`, and nil
  means nobody said the project ships, the same as the schema default. Every
  reader asks here, so `nil` cannot mean `:off` to one and "on" to another.
  """
  @spec devops_level(t() | map() | nil) :: :off | :uat | :prod
  def devops_level(%{devops: devops}) when not is_nil(devops), do: devops
  def devops_level(_config), do: :off
end
