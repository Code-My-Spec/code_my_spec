defmodule CodeMySpec.Agents.ModelSetting do
  @moduledoc """
  Which provider and model one agent type runs on, for one account.

  Story 983. The launcher does not know what a QA agent is; it looks up the
  row for the type it was asked to start. A QA agent runs on something cheap
  because this says so, not because anything branches on the word "qa".

  ## Account-scoped, not project-scoped

  Agents belong to the account — `Agents.start_agent/2` resolves its credential
  from the account's integration, and a working copy is a place an agent runs
  rather than a thing that owns it. A per-project setting would also mean an
  account with twenty projects configures the same four types twenty times to
  say the same thing.

  ## Absent is a real state, not a missing row to paper over

  There is no row until somebody chooses, and the absence is what
  `Agents.Defaults` answers. Writing a default row at account creation would
  freeze whatever the defaults were that day: the account would keep running
  last year's cheap model long after a better one existed, and nothing would
  say why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Agents.Agent

  @type t :: %__MODULE__{}

  schema "agent_model_settings" do
    field :role, Ecto.Enum, values: Agent.roles()
    field :provider, :string
    field :model, :string
    field :account_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:role, :provider, :model, :account_id])
    |> validate_required([:role, :provider, :account_id])
    |> unique_constraint([:account_id, :role])
  end
end
