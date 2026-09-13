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

    # The shaping conversation, on the row rather than in socket assigns.
    # `transcript/3` always claimed to survive a reload; without these it
    # survived only as far as the description, and resuming meant asking the
    # model again — a different question from the same first message, every
    # reload.
    field :shaping_turns, {:array, :map}, default: []
    field :pending_question, :string

    # Whether a model call is out for this plan. The LiveView used to be the
    # only record of one, so a reload mid-call lost it -- the process died with
    # the request and the answer landed nowhere.
    field :shaping_status, Ecto.Enum, values: [:idle, :thinking, :failed], default: :idle

    field :summary, :string
    field :first_build, :string

    field :account_name, :string
    field :project_name, :string

    # Where the visitor wants their project to run. Nullable on purpose: a plan
    # that has not reached the confirmation card has not been asked, and that is
    # a different state from either answer.
    field :location, Ecto.Enum, values: [:local, :cloud]

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

  @doc "Marks a model call as out, or done."
  def shaping_status_changeset(%__MODULE__{} = plan, status) do
    cast(plan, %{shaping_status: status}, [:shaping_status])
  end

  @doc "Records the question now awaiting an answer, or clears it."
  def pending_question_changeset(%__MODULE__{} = plan, question) do
    cast(plan, %{pending_question: question, shaping_status: :idle}, [
      :pending_question,
      :shaping_status
    ])
  end

  @doc """
  Appends one answered turn and clears the question it answered.

  One changeset for both, because they are one event: a question stops pending
  at the moment it becomes a turn, and any window where the row holds both is a
  window where the transcript renders the question twice.
  """
  def turn_changeset(%__MODULE__{} = plan, question, answer) do
    turn = %{"question" => to_string(question), "answer" => to_string(answer)}

    cast(plan, %{shaping_turns: (plan.shaping_turns || []) ++ [turn], pending_question: nil}, [
      :shaping_turns,
      :pending_question
    ])
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
    # The plan arriving ends the call, exactly as a question arriving does.
    # Only the question path cleared it, so a conversation that went straight to
    # a plan left `:thinking` on the row and every viewer kept the "Thinking…"
    # bubble under a finished plan card, forever.
    |> put_change(:shaping_status, :idle)
  end

  @doc """
  A correction from the visitor, applied before anything is built. Overwrites
  the proposal in place — nothing keeps the superseded value.

  Carries the two generator conclusions as well as the names. They were prose
  the visitor could only read, which made the two most consequential
  inferences in the plan the two they could not correct — and a wrong one
  costs them the app they get, not a label.
  """
  def names_changeset(%__MODULE__{} = plan, attrs) do
    plan
    |> cast(attrs, [:account_name, :project_name, :needs_sign_in, :separate_copies, :location])
    |> default_location()
    |> validate_required([
      :account_name,
      :project_name,
      :needs_sign_in,
      :separate_copies,
      :location
    ])
    |> validate_length(:account_name, min: 1, max: 100)
    |> validate_length(:project_name, min: 1, max: 100)
  end

  # Cloud unless they say otherwise. Not a default column — a plan abandoned
  # before the card was ever shown must still read as "never asked" — just what
  # the select starts on, so the visitor sees a choice already made rather than
  # an empty dropdown they have to discover.
  #
  # Applied to the changeset via `put_change/3`, not by pre-mutating the
  # struct handed to `cast/3`: `cast/3` only records a field in `changes` when
  # the casted value differs from `data`'s current value, so a struct already
  # defaulted to `:cloud` made "the visitor accepted the pushed default" (the
  # common case, `attrs["location"] == "cloud"`) look like no change at all.
  # The changeset returned in-memory still read `location: :cloud` — copied
  # straight from `data` — so it looked confirmed to whichever process just
  # built it, but the column was never actually written: a fresh read from
  # the row (a reload, or another page mounting the same plan) saw `nil` and
  # nothing it gated ever fired. Reading the *cast* value with `get_field/2`
  # and only defaulting what is still genuinely unset makes the default a
  # real, persisted change instead of a value that merely looks set.
  defp default_location(changeset) do
    if get_field(changeset, :location) do
      changeset
    else
      put_change(changeset, :location, :cloud)
    end
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
