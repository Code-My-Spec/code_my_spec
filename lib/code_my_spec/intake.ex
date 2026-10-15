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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Agents.Phase,
      CodeMySpec.Analytics,
      CodeMySpec.Conversations,
      CodeMySpec.Events,
      CodeMySpec.Faults,
      CodeMySpec.Personas,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Conversations
  alias CodeMySpec.Intake.{Plan, Planner, PlansRepository}
  alias CodeMySpec.Personas
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

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

  @doc """
  The most recent plans, newest first. For the dev route only.

  A visitor's session token is signed into the Phoenix session and unreadable
  from a browser, so this is how somebody testing the intake addresses the plan
  they just started — see `PlansRepository.recent/1`.
  """
  @spec recent_plans(pos_integer()) :: [Plan.t()]
  def recent_plans(limit \\ 20), do: PlansRepository.recent(limit)

  @doc """
  Projects this account chose to run locally and confirmed, that no harness
  has claimed with a checkout yet.

  What a device's own announce answers so an already-running harness can pick
  a fresh one up itself — see `CodeMySpecWeb.DeviceController`. The harness
  already polls on a heartbeat, so no push is needed.
  """
  @spec pending_local_projects(Ecto.UUID.t()) :: [Plan.t()]
  def pending_local_projects(account_id) when is_binary(account_id),
    do: PlansRepository.pending_local(account_id)

  @doc """
  The plan with this id, or nil.

  For the conversation process, which knows the plan it belongs to and re-reads
  before acting — two tabs are two callers, and the one that submits second has
  to build on the first's turn rather than on the row as its page saw it.
  """
  @spec get_plan_by_id(String.t()) :: Plan.t() | nil
  def get_plan_by_id(id) when is_binary(id), do: CodeMySpec.Repo.get(Plan, id)

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

  @doc """
  Subscribes to one plan's shaping. Broadcasts match `{:shaped, %Plan{}}`.
  """
  @spec subscribe(Plan.t() | String.t()) :: :ok | {:error, term()}
  def subscribe(%Plan{id: id}), do: subscribe(id)

  def subscribe(plan_id) when is_binary(plan_id),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(plan_id))

  defp topic(plan_id), do: "intake_plan:#{plan_id}"

  @doc """
  Asks the model what to do next, off the caller's process.

  Returns a `:thinking` plan immediately; the answer arrives as a broadcast. A
  caller that goes away (a reload, a dropped socket) does not take the call with
  it, and one that comes back reads `:thinking` off the row and waits. Under
  `CodeMySpec.TaskSupervisor`: the work outlives the request, and a crash in it
  must not take the requester down.
  """
  @spec shape_async(Plan.t(), module()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def shape_async(%Plan{} = plan, shaper \\ CodeMySpec.Intake.Shaper) do
    with {:ok, thinking} <- mark_thinking(plan) do
      if async?() do
        Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
          shape(thinking, shaper)
        end)

        {:ok, thinking}
      else
        # Inline in test, where a task in another process cannot see the
        # sandbox's transaction. Returns the finished plan.
        {:ok, shape(thinking, shaper)}
      end
    end
  end

  defp async?, do: Application.get_env(:code_my_spec, :intake_shaping_async, true)

  @doc """
  Asks the model and records what it said. Runs wherever it is called.

  Public because `Intake.Conversation` owns the task that runs it and must know
  whether a call is out.
  """
  @spec shape(Plan.t(), module()) :: Plan.t()
  def shape(%Plan{} = plan, shaper \\ CodeMySpec.Intake.Shaper), do: run_shaping(plan, shaper)

  @doc "Marks a model call as out."
  @spec mark_thinking(Plan.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def mark_thinking(%Plan{} = plan) do
    plan |> Plan.shaping_status_changeset(:thinking) |> PlansRepository.update()
  end

  @doc """
  Records that a call died without answering, and tells anyone watching.

  A crashed task leaves the row saying `:thinking`; without this a crash is
  indistinguishable from a call still running.
  """
  @spec mark_shaping_failed(Plan.t() | nil) :: :ok
  def mark_shaping_failed(%Plan{} = plan) do
    {:ok, failed} = plan |> Plan.shaping_status_changeset(:failed) |> PlansRepository.update()
    broadcast(failed)
    :ok
  end

  def mark_shaping_failed(nil), do: :ok

  # Written to the row before it is announced, so a subscriber that missed the
  # message and re-reads sees what one that got it saw.
  defp run_shaping(plan, shaper) do
    case shaped(plan, shaper) do
      {:ok, %Plan{} = updated} ->
        broadcast(updated)

      _ ->
        # `:failed`, not `:idle`: the failure must outlive the task, or a reload
        # renders a plan that looks merely unanswered.
        {:ok, settled} = Plan.shaping_status_changeset(plan, :failed) |> PlansRepository.update()
        broadcast(settled)
    end
  end

  defp shaped(plan, shaper) do
    case shaper.shape(plan, turns(plan)) do
      {:ask, question} ->
        ask(plan, question)

      {:ok, attrs} ->
        with {:ok, answered} <- answer(plan, attrs), do: generate_plan(answered)

      {:error, reason} ->
        Logger.warning("[Intake] shaping failed for plan #{plan.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp broadcast(%Plan{} = plan) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(plan.id), {:shaped, plan})
    plan
  end

  @doc "Records the question the visitor is now being asked."
  @spec ask(Plan.t(), String.t() | nil) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def ask(%Plan{} = plan, question) do
    plan |> Plan.pending_question_changeset(question) |> PlansRepository.update()
  end

  @doc "Records an answered turn and clears the question it answered."
  @spec record_turn(Plan.t(), String.t(), String.t()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def record_turn(%Plan{} = plan, question, answer) do
    plan |> Plan.turn_changeset(question, answer) |> PlansRepository.update()
  end

  @doc "The shaping turns this plan has recorded, oldest first."
  @spec turns(Plan.t()) :: [%{question: String.t(), answer: String.t()}]
  def turns(%Plan{shaping_turns: turns}) when is_list(turns) do
    Enum.map(turns, fn turn ->
      %{question: MapAccess.get(turn, :question), answer: MapAccess.get(turn, :answer)}
    end)
  end

  def turns(%Plan{}), do: []

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
  Fills a plan in directly from one form, no conversation involved.

  For a visitor who wants `/build/procedural` instead of the chat. Lands on
  `:planned` in one write, same as a model call finishing would — signup,
  payment and boot all read the plan row alone and cannot tell which door
  produced it.
  """
  @spec plan_procedurally(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def plan_procedurally(%Plan{} = plan, attrs) do
    plan
    |> Plan.procedural_changeset(attrs)
    |> PlansRepository.update()
  end

  @doc "A form-backing changeset for the procedural form."
  @spec change_procedural(Plan.t(), map()) :: Ecto.Changeset.t()
  def change_procedural(%Plan{} = plan, attrs \\ %{}), do: Plan.procedural_changeset(plan, attrs)

  @doc """
  The tier suggested for this visitor, before they have confirmed one.

  Not a decision — `confirm_tier/2` still requires an explicit choice; this is
  what the form pre-selects. A non-technical visitor could never act on the
  self-hosted option, so they are shown cloud.
  """
  @spec suggested_location(Plan.t()) :: Plan.location()
  def suggested_location(%Plan{technical: true}), do: :local
  def suggested_location(%Plan{}), do: :cloud

  @doc "Confirms which tier the visitor is actually buying."
  @spec confirm_tier(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def confirm_tier(%Plan{} = plan, attrs) do
    plan
    |> Plan.confirm_tier_changeset(attrs)
    |> PlansRepository.update()
  end

  @doc "A form-backing changeset for the tier confirmation, defaulted to the suggested one."
  @spec change_tier(Plan.t()) :: Ecto.Changeset.t()
  def change_tier(%Plan{} = plan) do
    Plan.confirm_tier_changeset(plan, %{location: plan.location || suggested_location(plan)})
  end

  @doc """
  Whether a visitor has already confirmed the account/project names.

  The same signal `confirmed_names/2` in `transcript/3` uses: `location` is set
  only by a confirmation (`confirm_names/2` or `confirm_tier/2`), never by the
  planner's own write, so its presence means the names are no longer guesses.

  Public because the LiveView re-derives it from the row on every mount rather
  than carrying it in a socket assign, which a reload loses.
  """
  @spec names_confirmed?(Plan.t()) :: boolean()
  def names_confirmed?(%Plan{
        location: location,
        account_name: account,
        project_name: project
      }),
      do: not is_nil(location) and is_binary(account) and is_binary(project)

  @doc """
  Everything said so far, in the order it was said.

  Derived from the plan row rather than accumulated anywhere, so it survives a
  reload and the signup gate, and two pages read one row. The opening question
  is part of it.

  The shaping half (turns, pending question) comes off `plan` itself, which
  keeps the name confirmation in its chronological place. `interview_turns` and
  `interview_question` are only the interview half, which happens strictly
  after confirmation.
  """
  @spec transcript(Plan.t(), [map()], String.t() | nil) :: [
          %{from: :agent | :visitor, text: String.t()}
        ]
  def transcript(%Plan{} = plan, interview_turns \\ [], interview_question \\ nil) do
    [%{from: :agent, text: "What do you want to build?"}]
    |> said(plan.description)
    |> shaping(plan)
    |> confirmed_names(plan)
    |> interview(interview_turns, interview_question)
  end

  defp shaping(transcript, plan) do
    transcript
    |> then(fn transcript ->
      Enum.reduce(turns(plan), transcript, fn turn, acc ->
        acc
        |> said(turn.question, :agent)
        |> said(turn.answer)
      end)
    end)
    |> said(plan.pending_question, :agent)
    |> planned(plan)
  end

  # A planned plan has no pending question, so without this line the chat goes
  # silent at the moment the agent answered.
  defp planned(transcript, %Plan{status: status}) when status in [:planned, :converted] do
    said(transcript, "Here's what I think you're building — take a look on the right.", :agent)
  end

  defp planned(transcript, %Plan{}), do: transcript

  defp interview(transcript, turns, question) do
    transcript
    |> then(fn transcript ->
      Enum.reduce(turns, transcript, fn turn, acc ->
        acc
        |> said(turn.question, :agent)
        |> said(turn.answer)
      end)
    end)
    |> said(question, :agent)
  end

  # An action taken in the panel is a turn in the conversation, not a silent
  # write.
  defp confirmed_names(transcript, %Plan{account_name: account, project_name: project} = plan) do
    if names_confirmed?(plan) do
      transcript
      |> said("Call it #{account} — the project is #{project}.")
      |> said("Got it — #{account}'s #{project} it is.", :agent)
    else
      transcript
    end
  end

  defp said(transcript, text, from \\ :visitor)

  defp said(transcript, text, from) when is_binary(text) and text != "",
    do: transcript ++ [%{from: from, text: text}]

  defp said(transcript, _text, _from), do: transcript

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
      carry_conversation(scope, project, plan)

      plan
      |> Plan.conversion_changeset(scope.active_account, project)
      |> PlansRepository.update()
    end
  end

  # The interview is copied onto a session conversation keyed `"intake:<id>"`,
  # which the project's first agent adopts
  # (`Conversations.find_or_create_agent_conversation/3`), so the visitor's
  # history and the agent's turns read as one thread. Outside the `with`: a
  # failed write must not cost the visitor their project.
  defp carry_conversation(%Scope{active_account: %Account{} = account}, project, %Plan{} = plan) do
    session_id = "intake:#{plan.id}"

    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(account.id, project.id, session_id)

    plan |> transcript() |> Enum.each(&echo_turn(conversation, &1))
  end

  defp echo_turn(conversation, %{from: :agent, text: text}),
    do: Conversations.add_message(conversation, :assistant, text)

  defp echo_turn(conversation, %{from: :visitor, text: text}),
    do: Conversations.add_message(conversation, :user, text)

  # Who the visitor said they are building for (`who_uses`), as a `:proto`
  # persona: `add_rule` refuses a story with no persona, so a project born here
  # would otherwise stall at its first Three Amigos. Outside the `with`: a
  # failed write must not cost the visitor their project.
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

  # Built from a sentence a stranger typed: anything outside the set collapses.
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
