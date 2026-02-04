defmodule CodeMySpec.Sessions.Session do
  @moduledoc false

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Sessions.Interaction
  alias CodeMySpec.Users.User
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          type: CodeMySpec.Sessions.SessionType.t() | nil,
          agent: :claude_code | nil,
          environment_type: :local | :vscode | :cli | nil,
          environment: Environment.t() | nil,
          execution_mode: :manual | :auto | :agentic | nil,
          status: :active | :complete | :failed | :cancelled | nil,
          state: map() | nil,
          display_name: String.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t() | nil,
          user_id: integer() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          component_id: Ecto.UUID.t() | nil,
          component: Component.t() | Ecto.Association.NotLoaded.t() | nil,
          session_id: Ecto.UUID.t() | nil,
          parent_session: t() | Ecto.Association.NotLoaded.t() | nil,
          child_sessions: [t()] | Ecto.Association.NotLoaded.t(),
          external_conversation_id: String.t() | nil,
          interactions: [Interaction.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "sessions" do
    field :type, CodeMySpec.Sessions.SessionType
    field :agent, Ecto.Enum, values: [:claude_code]
    field :environment_type, Ecto.Enum, values: [:local, :vscode, :cli]
    field :execution_mode, Ecto.Enum, values: [:manual, :auto, :agentic], default: :manual
    field :status, Ecto.Enum, values: [:active, :complete, :failed, :cancelled], default: :active
    field :external_conversation_id, :string
    field :display_name, :string, virtual: true

    field :state, :map

    embeds_one :environment, Environment, on_replace: :update

    belongs_to :project, Project, type: :binary_id
    belongs_to :account, Account, type: :binary_id
    belongs_to :user, User
    belongs_to :component, Component, type: :binary_id
    belongs_to :parent_session, __MODULE__, foreign_key: :session_id, type: :binary_id

    has_many :child_sessions, __MODULE__, foreign_key: :session_id, references: :id
    has_many :interactions, Interaction, preload_order: [desc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(session, attrs, user_scope) do
    session
    |> cast(attrs, [
      :id,
      :type,
      :agent,
      :environment_type,
      :execution_mode,
      :status,
      :state,
      :component_id,
      :session_id,
      :external_conversation_id
    ])
    |> cast_embed(:environment, with: &Environment.changeset/2)
    |> validate_required([:type])
    |> put_change(:account_id, user_scope.active_account_id)
    |> put_change(:project_id, user_scope.active_project_id)
    |> put_change(:user_id, user_scope.user_id)
    |> put_display_name()
  end

  def get_pending_interactions(session) do
    Enum.filter(session.interactions, &Interaction.pending?/1)
  end

  def get_completed_interactions(session) do
    Enum.filter(session.interactions, &Interaction.completed?/1)
  end

  defp put_display_name(%{changes: %{type: type}} = changeset) when not is_nil(type) do
    put_change(changeset, :display_name, format_display_name(type))
  end

  defp put_display_name(%{data: %{type: type}} = changeset) when not is_nil(type) do
    put_change(changeset, :display_name, format_display_name(type))
  end

  defp put_display_name(changeset), do: changeset

  def format_display_name(%__MODULE__{type: type}) when is_atom(type),
    do: format_display_name(type)

  def format_display_name(type) when is_atom(type) do
    type
    |> Module.split()
    |> List.last()
    |> String.replace_suffix("Sessions", "")
    |> Recase.to_title()
  end

  def format_display_name(_), do: nil
end
