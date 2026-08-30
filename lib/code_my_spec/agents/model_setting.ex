defmodule CodeMySpec.Agents.ModelSetting do
  @moduledoc """
  Which provider and model one agent type runs on, for one person.

  Story 983. The launcher does not know what a QA agent is; it looks up the
  row for the type it was asked to start. A QA agent runs on something cheap
  because this says so, not because anything branches on the word "qa".

  ## User-scoped, because the credential is

  Story 984. The setting names a provider, and the provider is reached through
  `integrations`, which is keyed by `user_id`. Held against the account, a row
  saying "QA runs on Z.ai" was true for whoever pasted the key and false for
  everybody else on it — and the settings screen could not tell which, so it
  named a model no agent would start on.

  Not project-scoped either: a working copy is a place an agent runs rather
  than a thing that owns it, and an account with twenty projects would
  otherwise configure the same four types twenty times to say the same thing.

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
    field :user_id, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:role, :provider, :model, :user_id])
    |> validate_required([:role, :provider, :user_id])
    |> unique_constraint([:user_id, :role])
  end
end
