defmodule CodeMySpec.Intake do
  @moduledoc """
  Pre-signup plans.

  A visitor describes what they want to build, answers two shaping questions,
  and gets back a plan — all before an account exists. The plan is keyed to an
  anonymous session token and never expires, so leaving and coming back in the
  same browser finds it waiting.

  At the gate the confirmed names become an account and a project. No name
  collision is ever surfaced: names are not unique, and the account slug
  de-dupes itself underneath.
  """

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Personas
  alias CodeMySpec.Intake.{Plan, Planner, PlansRepository}
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @token_bytes 32

  @doc "A fresh anonymous session token for the intake cookie."
  @spec new_session_token() :: String.t()
  def new_session_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  The plan behind this token, or nil.

  A token from another browser resolves to nil — the caller offers a fresh
  start rather than reporting a fault.
  """
  @spec get_plan(String.t() | nil) :: Plan.t() | nil
  def get_plan(nil), do: nil
  def get_plan(session_token), do: PlansRepository.get_by_token(session_token)

  @doc "The plan behind this token, starting one if there isn't one yet."
  @spec start_plan(String.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def start_plan(session_token) when is_binary(session_token) do
    case PlansRepository.get_by_token(session_token) do
      nil -> PlansRepository.start(session_token)
      %Plan{} = plan -> {:ok, plan}
    end
  end

  @doc "Records what the visitor typed and moves on to the shaping questions."
  @spec describe(Plan.t(), String.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def describe(%Plan{} = plan, description) do
    plan
    |> Plan.description_changeset(%{description: description})
    |> PlansRepository.update()
  end

  @doc "Records the answers to the shaping questions."
  @spec answer(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def answer(%Plan{} = plan, attrs) do
    plan
    |> Plan.answers_changeset(attrs)
    |> PlansRepository.update()
  end

  @doc """
  Generates the plan and stores it with its proposed names.

  Every inference lands on the record as something the visitor can still
  correct — nothing here is applied silently.
  """
  @spec generate_plan(Plan.t()) :: {:ok, Plan.t()} | {:error, term()}
  def generate_plan(%Plan{} = plan) do
    with {:ok, attrs} <- Planner.generate(plan) do
      plan
      |> Plan.plan_changeset(attrs)
      |> PlansRepository.update()
    end
  end

  @doc "Applies a correction to the proposed names, overwriting them in place."
  @spec confirm_names(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def confirm_names(%Plan{} = plan, attrs) do
    plan
    |> Plan.names_changeset(attrs)
    |> PlansRepository.update()
  end

  @doc "A form-backing changeset for the name corrections."
  @spec change_names(Plan.t(), map()) :: Ecto.Changeset.t()
  def change_names(%Plan{} = plan, attrs \\ %{}), do: Plan.names_changeset(plan, attrs)

  @doc """
  Turns a confirmed plan into an account and a project for the signed-in user.

  Goes through `Accounts.create_account/2` deliberately — that path picks an
  available slug before inserting, so a name someone else already uses is
  accepted rather than refused.

  An already-converted plan returns what it created. A visitor who signs in
  with an existing account gets a project added under it and no second account.
  """
  @spec convert(Plan.t(), Scope.t()) :: {:ok, Plan.t()} | {:error, term()}
  def convert(%Plan{status: :converted} = plan, %Scope{}), do: {:ok, plan}

  def convert(%Plan{} = plan, %Scope{} = scope) do
    with {:ok, scope} <- ensure_account(scope, plan),
         {:ok, project} <- Projects.create_project(scope, %{name: plan.project_name}) do
      record_persona(scope, project, plan)

      plan
      |> Plan.conversion_changeset(scope.active_account, project)
      |> PlansRepository.update()
    end
  end

  # Who the visitor said they are building for, as a persona on the project.
  #
  # Intake asks this already — `who_uses` feeds the plan — but the answer was
  # only ever prose used to write a summary, and the project was created with no
  # persona at all. That is a structural hole rather than a missing nicety:
  # `personas_complete` is a project requirement, and `add_rule` refuses a story
  # with no persona linked, so the first Three Amigos on a project born here
  # stops until somebody invents one by hand — at which point the answer the
  # visitor actually gave has been thrown away.
  #
  # `:proto` because that is what it is: an identity and a headline, taken from
  # one sentence. Researching it is `personas_complete`'s job and happens later
  # against this record rather than instead of it.
  #
  # Deliberately not part of the `with` above. A project with no persona is
  # worse than one with; a visitor who cannot get a project at all because the
  # persona write failed is worse than both.
  defp record_persona(%Scope{} = scope, project, %Plan{who_uses: who})
       when is_binary(who) and who != "" do
    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    case Personas.create_persona(scope, %{
           name: who |> String.trim() |> String.slice(0, 80),
           slug: persona_slug(who),
           headline: "Who #{plan_name(project)} is for, as described at intake.",
           persona_type: :proto
         }) do
      {:ok, persona} ->
        {:ok, persona}

      {:error, reason} ->
        Logger.warning(
          "[Intake] could not record a persona for #{project.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp record_persona(_scope, _project, _plan), do: :none

  defp plan_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp plan_name(_project), do: "this project"

  # Slugs are an identifier, and this one is built from a sentence a stranger
  # typed. Anything outside the set gets collapsed rather than escaped.
  defp persona_slug(who) do
    who
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> case do
      "" -> "who-it-is-for"
      slug -> slug
    end
  end

  defp ensure_account(%Scope{active_account: %Account{}} = scope, _plan), do: {:ok, scope}

  defp ensure_account(%Scope{active_account_id: account_id} = scope, _plan)
       when not is_nil(account_id) do
    {:ok, %Scope{scope | active_account: Accounts.get_account_by_id(account_id)}}
  end

  defp ensure_account(%Scope{} = scope, %Plan{} = plan) do
    with {:ok, account} <- Accounts.create_account(scope, %{name: plan.account_name}) do
      {:ok, %Scope{scope | active_account: account, active_account_id: account.id}}
    end
  end
end
