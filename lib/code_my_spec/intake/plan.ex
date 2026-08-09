defmodule CodeMySpec.Intake.Plan do
  @moduledoc "Schema for a pre-signup intake plan."

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type status :: :describing | :answering | :planned | :converted

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          session_token: String.t(),
          status: status(),
          description: String.t() | nil,
          needs_sign_in: boolean() | nil,
          separate_copies: boolean() | nil,
          who_uses: String.t() | nil,
          summary: String.t() | nil,
          first_build: String.t() | nil,
          account_name: String.t() | nil,
          project_name: String.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "intake_plans" do
    field :session_token, :string
    field :status, Ecto.Enum, values: [:describing, :answering, :planned, :converted]

    field :description, :string
    field :needs_sign_in, :boolean
    field :separate_copies, :boolean
    field :who_uses, :string

    field :summary, :string
    field :first_build, :string

    field :account_name, :string
    field :project_name, :string

    belongs_to :account, Account
    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc "A brand new plan for an anonymous visitor who has typed nothing yet."
  def start_changeset(session_token) when is_binary(session_token) do
    change(%__MODULE__{}, session_token: session_token, status: :describing)
  end

  @doc "The visitor's own words. Moves the plan on to the shaping questions."
  def description_changeset(%__MODULE__{} = plan, attrs) do
    plan
    |> cast(attrs, [:description])
    |> validate_required([:description])
    |> validate_length(:description, min: 1, max: 5000)
    |> put_change(:status, :answering)
  end

  @doc """
  One answer to one question.

  The questions are asked one at a time, so they are recorded one at a time.
  `answers_changeset/2` still exists for anything setting them together, but
  it validates all three as a unit, which a conversation never has.
  """
  def answer_changeset(%__MODULE__{} = plan, field, value)
      when field in [:needs_sign_in, :separate_copies, :who_uses] do
    plan
    |> cast(%{field => value}, [field])
    |> validate_required([field])
    |> then(fn changeset ->
      if field == :who_uses, do: validate_length(changeset, :who_uses, max: 500), else: changeset
    end)
  end

  @doc "The two generator inputs plus who uses it. Booleans are required — an unanswered question is not a `false`."
  def answers_changeset(%__MODULE__{} = plan, attrs) do
    plan
    |> cast(attrs, [:needs_sign_in, :separate_copies, :who_uses])
    |> validate_required([:needs_sign_in, :separate_copies])
    |> validate_length(:who_uses, max: 500)
  end

  @doc "What the planner inferred. Names land here as proposals the visitor can still correct."
  def plan_changeset(%__MODULE__{} = plan, attrs) do
    plan
    |> cast(attrs, [:summary, :first_build, :account_name, :project_name])
    |> validate_required([:summary, :first_build, :account_name, :project_name])
    |> put_change(:status, :planned)
  end

  @doc "A correction from the visitor. Overwrites the proposal in place — nothing keeps the superseded name."
  @doc """
  What the visitor confirms before it is built.

  Carries the two generator conclusions as well as the names. They were prose
  the visitor could only read, which made the two most consequential
  inferences in the plan the two they could not correct — and a wrong one
  costs them the app they get, not a label.
  """
  def names_changeset(%__MODULE__{} = plan, attrs) do
    plan
    |> cast(attrs, [:account_name, :project_name, :needs_sign_in, :separate_copies])
    |> validate_required([:account_name, :project_name, :needs_sign_in, :separate_copies])
    |> validate_length(:account_name, min: 1, max: 100)
    |> validate_length(:project_name, min: 1, max: 100)
  end

  @doc "The gate. Records what was created so a second visit adopts it rather than creating again."
  def conversion_changeset(%__MODULE__{} = plan, %Account{} = account, %Project{} = project) do
    change(plan,
      account_id: account.id,
      project_id: project.id,
      status: :converted
    )
  end
end
