defmodule CodeMySpec.Agents do
  @moduledoc """
  The agents CodeMySpec has started, and the credential each one runs on.

  Server-side half of starting a coding agent. Owns which agents exist, on which
  working copy and on which provider; mints the per-copy Pi configuration from
  the account's integration; and holds the record a conversation attaches to.
  `CmsHarness.Agents` is the other half — the OS process on the device — reached
  over the harness channel. Same split as Provisioning: state and ordering live
  here, execution happens on the box, because the server holds no disk and
  cannot start a process on somebody's machine.

  ## Starting is refused before it is attempted

  `start_agent/2` resolves the credential first and refuses if there is not a
  usable one. That ordering is the point rather than an optimisation. An agent
  started without a working credential fails on its first model call — minutes
  later, in a log nobody is reading — which is why `agent.sh` ended up grepping
  its own output for expired-session text and bailing: retrying an
  unauthenticated agent burns twelve minutes to reach the same answer with the
  cause buried under supervisor noise.

  The two refusals are kept apart for the same reason. `:not_connected` sends
  someone to connect a provider; `:reconnect_required` sends them to reconnect
  one they know they connected. Reporting the second as the first sends them to
  set up something that already exists.

  ## Started means watchable

  A pid proves a fork. It does not prove the credential resolved, that a model
  answered, or that the harness was ever joined, and every one of those failures
  is quiet from the caller's side. So an agent is recorded `:starting` and only
  becomes `:running` when the device says it is — and its turns arrive in
  `Conversations` the same way a Claude Code agent's do, through
  `AgentHarness.relay_up/2`. An agent the server cannot observe is
  indistinguishable from one that never started.
  """

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Credential
  alias CodeMySpec.Agents.Defaults
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Agents.ModelSetting
  alias CodeMySpec.Agents.Providers
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  # How long the machine is given to wind the agent down before it insists.
  # Bounded on purpose: an unbounded stop is one the meter outlives.
  # Bounded *below* the MCP transport's own 30s request timeout, so a slow turn
  # is reported by us as still working rather than by the transport as an
  # internal error. The agent is not interrupted — this is how long we wait for
  # it, not how long it has.
  @message_timeout_ms 25_000

  @stop_timeout_ms 10_000

  # Ten, because that is roughly a conversation rather than a session: enough
  # for a visitor to be shown their project works and be answered about it,
  # short of an afternoon on our bill. Configurable, since the right number is
  # a commercial question rather than a technical one.
  @default_turn_cap 10

  # Long enough for a cold start on a loaded box, short enough that a machine
  # that is never going to answer does not hold the caller.
  @start_timeout_ms 15_000

  # Shorter than an operator's stop. This runs inside a reconcile that fires on
  # every lane diff, so a machine that is slow to answer must not hold it —
  # the next report tries again, and the row stays reachable meanwhile.

  @type start_error ::
          :missing_active_project
          | :not_connected
          | :reconnect_required
          | :unknown_provider
          | {:unknown_working_copy, String.t()}
          | Ecto.Changeset.t()
          | term()

  @doc """
  Subscribes to scoped notifications about agents.

    * {:agent_started, %Agent{}}
    * {:agent_stopped, %Agent{}}
  """
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(scope))
  end

  defdelegate list_agents(scope), to: AgentsRepository
  defdelegate list_running(scope), to: AgentsRepository
  defdelegate fetch_agent(scope, id), to: AgentsRepository
  defdelegate providers(), to: Providers, as: :names

  @doc """
  Starts an agent on a working copy, on the provider the caller named.

  The provider is an argument rather than ambient state. A machine-wide default
  answers correctly right up until two callers want different things, and then
  spends the wrong subscription for one of them — which nobody notices until a
  quota or a bill does.
  """
  @spec start_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, start_error()}
  def start_agent(%Scope{} = scope, attrs) do
    with {:ok, role} <- role_of(attrs),
         {:ok, provider, model} <- provider_for(scope, role, attrs),
         attrs =
           attrs |> Map.put(:role, role) |> Map.put(:provider, provider) |> Map.put(:model, model),
         {:ok, attrs} <- put_destination(scope, attrs),
         :ok <- main_copy_is_free(scope, attrs),
         {:ok, credential} <- Credential.fetch(scope, provider),
         {:ok, agent} <- AgentsRepository.create_agent(scope, base_attrs(scope, attrs)),
         {:ok, _conversation} <- open_conversation(scope, agent) do
      # Carried on the struct rather than stored: the machine needs both, and
      # the row must not become a second place a subscription lives or a second
      # copy of a transcript that already has a table.
      #
      # Hydrated after the conversation is opened, because that is what the
      # history is read from — an agent that has spoken before is being resumed
      # here even on a call named `start`, which is the whole of "it picks up
      # the same conversation every time".
      agent = launch(scope, LaunchRequest.hydrate(scope, %{agent | credential: credential}))
      broadcast(scope, {:agent_started, agent})
      {:ok, agent}
    end
  end

  # The main working copy holds one agent, and it is the project's own.
  #
  # Two agents in one checkout are two processes editing one tree — the failure
  # the working-copy grain exists to prevent — and in this checkout it is worse
  # than that: the user is told there is one thing to talk to, and a second
  # conversation appears on the copy that is supposed to have exactly one.
  #
  # Only the main copy is protected. Every other checkout may run as many as
  # somebody wants, which is what story 1023's "stop one and leave its siblings
  # running" is about.
  defp main_copy_is_free(scope, attrs) do
    case WorkingCopies.main(scope) do
      nil -> :ok
      copy -> if names?(attrs, copy), do: refuse_if_occupied(scope, copy), else: :ok
    end
  end

  # Where the agent will actually run, decided before anything is checked
  # against it.
  #
  # `base_attrs/2` used to fill this in *after* the guard, so a caller who named
  # no checkout was checked against a copy they had not mentioned and then
  # started on the one they had not named. That is not a corner: the MCP tool
  # drops nil keys, so every ordinary `start_agent` arrives naming nothing, and
  # a second agent got into the main checkout by leaving a field out. QA found
  # it by making the same call twice, once with the copy named and once
  # without — refused, then allowed.
  defp put_destination(%Scope{} = scope, attrs) do
    case resolve_destination(scope, attrs) do
      {:ok, root, working_copy_id} ->
        {:ok,
         attrs
         |> Map.put(:working_copy, root)
         |> Map.put(:working_copy_id, working_copy_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An id names a specific checkout unambiguously, so root has to be derived
  # from it, not defaulted independently from the caller's own scope. The
  # previous version always computed `root` as `attrs[:working_copy] ||
  # scope.cwd` before ever looking at an id — so a caller who passed only an
  # id (the identifier `list_working_copies` puts first) got that id kept
  # correctly, but `root` silently became the CALLER'S OWN checkout. When the
  # caller's own checkout is the main copy, `names?/2`'s root branch then
  # matched main by accident, and `start_agent` refused a start on some other
  # copy entirely while blaming the main checkout for it.
  #
  # An id this scope does not own is refused rather than defaulted, unlike an
  # unresolved root. The two look similar but are not: a root that resolves to
  # nothing is a checkout that has never joined and legitimately has no row
  # yet, which is what that fallback exists for. An id that resolves to
  # nothing — a typo, or another project's copy — has no such reading, and
  # defaulting it ran an agent in the caller's own tree while recording it
  # against a checkout from a different project entirely. Issue c0facd8e.
  defp resolve_destination(scope, %{working_copy_id: id} = attrs)
       when is_binary(id) and id != "" do
    case owned_copy(scope, id) do
      %{root: root} -> {:ok, root, id}
      nil -> {:error, {:unknown_working_copy, id}}
    end
  end

  defp resolve_destination(scope, attrs) do
    root = Map.get(attrs, :working_copy) || scope.cwd
    {:ok, root, id_for(scope, root)}
  end

  defp owned_copy(%Scope{active_project_id: project_id}, id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{project_id: ^project_id} = copy} -> copy
      _ -> nil
    end
  end

  # The id has to come from the root when a root was named, not from the caller.
  #
  # Defaulting both fields from scope was one field too many. Every ordinary
  # `start_agent` names a root and no id, so the id became the *caller's*
  # checkout — and `names?/2` tests the id first, so the main-copy guard fired on
  # starts that named somewhere else entirely. With an agent on the main copy,
  # nothing could be started anywhere, and the refusal named a checkout the
  # caller had not mentioned.
  #
  # It also placed the agent wrongly when the guard let it through: the row's
  # `working_copy_id` is what the working copies page groups by, so an agent
  # asked for on one copy was recorded on another.
  #
  # Falls back to the caller's own copy only when the root is the caller's own
  # or names nothing we recognise — an unknown root is not a reason to refuse,
  # because a checkout that has never joined has no row to find.
  defp id_for(%Scope{} = scope, root) do
    case WorkingCopies.by_root(scope, root) do
      %{id: id} ->
        id

      nil ->
        warn_substitution(scope, root)
        scope.active_working_copy_id
    end
  end

  # The fallback is deliberate — see above — but it used to be silent, and that
  # is what made it dangerous rather than merely lossy.
  #
  # QA of story 988 named `.../qa_sandbox`, was answered "Working copy:
  # .../qa_sandbox", and got a row pointing at the main checkout. The agent
  # really did run in qa_sandbox; only its record disagreed. `by_root/2` matches
  # project *and device* and root, and that root's row for this project sits on
  # a stale device, so the lookup missed and the caller's own copy stood in.
  # Issue `af85efc7`.
  #
  # It matters beyond a wrong column: the stop decision and the analyzer alert
  # are both computed from this id, so an agent editing one tree is told about
  # another. Nothing is moved here — rewriting the root would relocate the agent
  # itself, and relocating it *into the framework's own checkout* is worse than
  # the bug — so the substitution stands and is announced instead.
  defp warn_substitution(%Scope{} = scope, root) do
    if is_binary(root) and root != scope.cwd do
      Logger.warning(
        "[Agents] no working copy for #{root} on this device and project — recording the agent " <>
          "against #{inspect(scope.active_working_copy_id)} instead. It will run where you said " <>
          "and be judged where this points; if that is not what you meant, the copy at that root " <>
          "has not joined this project from this machine."
      )
    end

    :ok
  end

  # By id or by root, because callers name a checkout both ways and a guard
  # that only understands one of them does not fire on the other. `StartAgent`
  # passes a root and no id at all — the id is filled in from scope afterwards
  # — so reading only the id would leave the one surface that starts agents
  # unguarded.
  defp names?(attrs, copy) do
    id = attrs[:working_copy_id] || attrs["working_copy_id"]
    root = attrs[:working_copy] || attrs["working_copy"]

    id == copy.id or (is_binary(root) and root != "" and Path.expand(root) == copy.root)
  end

  defp refuse_if_occupied(scope, copy) do
    case main_agent(scope) do
      nil -> :ok
      %Agent{} -> {:error, {:main_copy_occupied, copy.root}}
    end
  end

  # Ask the machine to bring it up, and record what it reports.
  #
  # Best-effort on purpose, and the row already has a word for the outcome.
  # `:starting` means "we asked and no machine has confirmed", which is exactly
  # true when the copy's harness is not connected — and the working copies page
  # already renders it as "Starting · we asked for this one; no harness has
  # confirmed it". Failing the whole call instead would make an agent
  # unstartable whenever its machine happened to be offline, and would discard
  # the config directory that was just minted for it.
  defp launch(scope, %Agent{} = agent) do
    case Transport.impl().start_agent(agent.working_copy_id, agent, @start_timeout_ms) do
      {:ok, report} -> record_or_keep(scope, agent, report)
      {:error, reason} -> keep_starting(agent, reason)
    end
  end

  defp record_or_keep(scope, agent, report) do
    case record_started(scope, agent, report) do
      {:ok, running} -> running
      {:error, _reason} -> agent
    end
  end

  defp keep_starting(agent, reason) do
    Logger.info(
      "[Agents] agent #{agent.id} was not started on its machine (#{inspect(reason)}); " <>
        "it stays :starting, which is what the page shows as asked-for and unconfirmed"
    )

    agent
  end

  # An agent that cannot be watched is indistinguishable from one that never
  # started, so the conversation is opened as part of starting rather than when
  # the agent first says something. A Pi lane relays its turns up through
  # `AgentHarness.relay_up/2` into this same conversation, which is why a Pi
  # agent and a Claude Code agent land on one surface instead of two.
  #
  # Keyed by the working copy, not the agent id, because that is how a Pi lane
  # keys itself: `CodeMySpecLocalWeb.HarnessSocket` uses `pi:<cwd>` and the
  # conversation index renders it as `data-session`.
  #
  # Keying on the agent id instead produced a row reading `agent:<uuid>`, which
  # is unreadable the moment a project has more than one copy — QA had three at
  # once and could not tell them apart (18f50c87). It also split one copy's
  # transcript in two: the lane reporting over the channel wrote to
  # `pi:<cwd>` while the tool that started it wrote somewhere else, so the
  # agent's own turns did not land on the session that represented it.
  #
  # One conversation per working copy matches the harness's own model, where
  # every lane on a copy joins `harness:session:pi:<cwd>` and the whole team's
  # transcript lands together.
  # The agent's own thread. It was `pi:<working_copy>`, so every agent on a copy
  # opened the same one and their turns interleaved with nothing saying who
  # spoke.
  defp open_conversation(%Scope{} = scope, %Agent{} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )
  end

  @doc """
  Give a running agent something to do.

  The capability the engine change was chosen for, and the one that was missing
  after it: an agent could be started, listed and stopped, and never asked to do
  anything, so it idled until somebody stopped it.

  Answers with whatever the agent said. An agent that is not running, or whose
  machine cannot be reached, is an error rather than a silent nothing — an
  instruction that went nowhere and reported success is worse than one that
  failed.
  """
  @spec message_agent(Scope.t(), Ecto.UUID.t(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def message_agent(%Scope{} = scope, id, text, timeout \\ @message_timeout_ms)
      when is_binary(text) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id) do
      agent.working_copy_id
      |> Transport.impl().message_agent(agent, text, timeout)
      |> delivered_or_working()
    end
  end

  # Running out of our own patience is not the message failing. The machine took
  # it — it answers `harness_not_connected` immediately when it did not — so the
  # honest report is that the agent has it and is still working.
  #
  # Telling an operator it failed is the expensive direction: they send it
  # again, and two agents work the same checkout.
  defp delivered_or_working({:error, :message_timed_out}), do: {:ok, :still_working}
  defp delivered_or_working(result), do: result

  @doc """
  The project's own agent — the one in its main working copy.

  A position, not a label. `agents.role` defaults to "main", so every agent
  ever started carries that word and a project running three of them has three
  claiming to be the one you talk to. What makes this one unique is where it
  is: the checkout the project designated, which no other agent may run in.

  `nil` when the project has no main working copy, or has one and nothing is
  running there yet. Both are ordinary states with different remedies, which is
  why `ensure_main_agent/1` reports them apart.

  ## What is running, not what has ever run

  `list_running/1` and not `list_agents/1`, and the difference was a bug with
  no way out of it. Reading every agent ever started meant a *stopped* one
  still counted as the agent on the copy: `ensure_main_agent/1` short-circuited
  and never started a replacement, and `refuse_if_occupied/2` refused every
  future start there. Stopping the main agent — which is the entire point of
  story 961 — permanently removed the project's ability to have one, and the
  page went on saying it was getting ready. Any stopped agent did it, not only
  a main one, because `on_copy?/2` does not read the role.
  """
  @spec main_agent(Scope.t()) :: Agent.t() | nil
  def main_agent(%Scope{} = scope) do
    case WorkingCopies.main(scope) do
      nil -> nil
      copy -> AgentsRepository.list_running(scope) |> Enum.find(&on_copy?(&1, copy))
    end
  end

  defp on_copy?(%Agent{working_copy_id: id}, %{id: id}), do: true
  defp on_copy?(_agent, _copy), do: false

  @doc """
  The project's own agent, started if it does not exist yet.

  What "there without anybody starting it" means from the server's side:
  opening a project asks for its agent, and asking is enough. A non-technical
  user has no way to supply a provider, a checkout and a role, and should not
  have to know those are the things standing between them and a conversation.

  The two failures are kept apart because their remedies are nothing alike.
  `:no_main_working_copy` means run `mix cms.new`, or designate one of the
  checkouts you have. `:not_connected` means connect a provider — the agent has
  somewhere to run and nothing to run on.

  Starting is still best-effort underneath: `start_agent/2` records `:starting`
  and the machine confirms. A project whose laptop is closed has a main agent
  that is asked-for and unconfirmed, which is the honest state rather than an
  error.
  """
  @spec ensure_main_agent(Scope.t()) ::
          {:ok, Agent.t()} | {:error, :no_main_working_copy | start_error()}
  def ensure_main_agent(%Scope{} = scope) do
    case {WorkingCopies.main(scope), main_agent(scope)} do
      {nil, _} -> {:error, :no_main_working_copy}
      {_copy, %Agent{} = agent} -> {:ok, agent}
      {copy, nil} -> start_main_agent(scope, copy)
    end
  end

  defp start_main_agent(scope, copy) do
    with {:ok, provider, model} <- main_choice(scope) do
      start_agent(scope, %{
        provider: provider,
        model: model,
        working_copy: copy.root,
        working_copy_id: copy.id,
        role: :main
      })
    end
  end

  # An explicit choice wins, and is recorded.
  #
  # This path used to skip `resolve_model/2` entirely — it passed a provider it
  # had picked itself and no model at all — so `main` was the one agent type
  # where stories 983 and 984's setting had no effect, and the `model` column
  # 983 added so that "a running agent keeps the model it started on" was
  # always NULL for the one agent a non-technical user talks to. Someone who
  # pointed `main` at a provider got a different one with nothing saying so.
  #
  # Only the *unset* case still goes through `@provider_preference`, and that
  # is deliberate rather than tidy. See the note there.
  defp main_choice(scope) do
    case resolve_model(scope, :main) do
      {:ok, {provider, model}, :set} -> {:ok, provider, model}
      _unset_or_nothing_connected -> preferred_main(scope)
    end
  end

  defp preferred_main(scope) do
    with {:ok, provider} <- connected_provider(scope) do
      {:ok, provider, default_main_model(provider)}
    end
  end

  # The model `Defaults` names for whichever provider we landed on, so the row
  # says what it is running rather than nothing. `nil` for a provider with no
  # entry, which is the same as before and no worse.
  defp default_main_model(provider) do
    Defaults.for_role(:main)
    |> Enum.find_value(fn {candidate, model} -> candidate == provider && model end)
  end

  # The first connected provider, in an order somebody chose.
  #
  # Flat-rate before metered, and that is the whole point of writing the list
  # out. `Providers.names/0` is alphabetical, so taking its head would put
  # every main agent on `anthropic` — the one that bills per token — for a user
  # who has a subscription connected and never asked to spend credits on an
  # agent that is always on.
  #
  # `:not_connected` when none of them is, which is a different problem from
  # having nowhere to run and gets a different remedy in front of the user.
  #
  # ## Why this disagrees with `Defaults` on purpose, for now
  #
  # `Defaults.for_role(:main)` leads with `anthropic`, on the argument that the
  # main agent is the one explaining a project to somebody who cannot read the
  # code. This list leads with the subscription, on the argument above. Two
  # lists that disagree is normally the bug — it was reported as one — and
  # collapsing them was deferred deliberately, because neither is right.
  #
  # The missing dimension is **where the agent runs**. A subscription
  # credential is a subscription: the providers do not license it for a server
  # running agents on somebody's behalf, so a cloud-run agent has to use an API
  # key — the user's if they have one, ours if they do not. Locally, their
  # subscription is exactly what they should be spending. So the right ordering
  # is not one list at all; it is a different answer per location, and neither
  # `Defaults` nor this list has anywhere to say that.
  #
  # Until that exists, an explicit setting wins (see `main_choice/1`) and the
  # unset case keeps behaving as it always has, so nobody's bill moves because
  # of a refactor.
  @provider_preference ["openai-codex", "zai", "anthropic"]

  defp connected_provider(scope) do
    Enum.find_value(@provider_preference, {:error, :not_connected}, fn provider ->
      case Credential.fetch(scope, provider) do
        {:ok, _credential} -> {:ok, provider}
        {:error, _reason} -> nil
      end
    end)
  end

  @doc """
  Move the project's own agent to a different checkout.

  Called when the main working copy is re-designated. The agent keeps its id,
  so it keeps its conversation — the whole reason this is a move rather than a
  replacement.

  The machine is asked to run it in the new place, and best-effort for the same
  reason starting is: a copy whose harness is not connected leaves the row
  `:starting`, which is the honest state rather than a failure to re-designate.
  """
  @spec move_main_agent(Scope.t(), map()) :: {:ok, Agent.t()} | {:error, term()} | :none
  def move_main_agent(%Scope{} = scope, copy) do
    case main_agent_anywhere(scope) do
      nil ->
        :none

      %Agent{working_copy_id: id} when id == :erlang.map_get(:id, copy) ->
        :none

      %Agent{} = agent ->
        with {:ok, moved} <-
               AgentsRepository.update_agent(scope, agent, %{
                 working_copy_id: copy.id,
                 working_copy: copy.root
               }) do
          broadcast(scope, {:agent_started, moved})
          {:ok, moved}
        end
    end
  end

  # The project's agent wherever it currently is, which during a move is not
  # the main copy — that is the point of moving it.
  defp main_agent_anywhere(%Scope{} = scope) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.find(&(&1.role == :main and &1.status in [:starting, :running]))
  end

  @doc """
  Send an operator's message at a running agent, without waiting for the turn.

  `message_agent/4` waits and answers with what the agent said, which is right
  for an MCP caller and wrong for a person at a page: a turn is minutes. Here
  the answer arrives the way everything else an agent does arrives — as turn
  events, in the transcript they are already reading.

  ## Recorded after the machine answers, never before

  The message goes on the conversation only once the machine has said what
  became of it, and with that outcome on the row. Written first, a transcript
  claims the agent was told every time the machine could not be reached — and
  an operator reading it has no way to tell that from an agent ignoring them.

  `{:ok, :started}` means the agent has it. `{:ok, :queued}` means it will when
  the turn ends, and until then it can be taken back.
  """
  @spec dispatch_message(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, :started | :queued, Conversations.Message.t()} | {:error, term()}
  def dispatch_message(%Scope{} = scope, id, text) when is_binary(text) do
    ref = Ecto.UUID.generate()

    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- within_turn_cap(scope, agent),
         {:ok, disposition} <-
           Transport.impl().dispatch_message(
             agent.working_copy_id,
             agent,
             ref,
             text,
             @message_timeout_ms
           ),
         {:ok, conversation} <- open_conversation(scope, agent),
         {:ok, message} <- record_sent(conversation, text, ref, disposition) do
      {:ok, disposition, message}
    end
  end

  @doc """
  How many turns an agent on our credential gets, and how many are left.

  `{used, cap}` for an agent we are paying for, `:uncapped` for one the visitor
  is paying for themselves. The view needs both numbers rather than a boolean:
  a limit somebody discovers by hitting it is a worse experience than one they
  could see coming.
  """
  @spec turn_allowance(Scope.t(), Agent.t()) ::
          {non_neg_integer(), pos_integer()} | :uncapped
  def turn_allowance(%Scope{} = scope, %Agent{} = agent) do
    # `provider`, not `engine`. The engine is `:pi` -- what runs -- and the
    # provider is whose subscription it spends. Asking Credential about the
    # engine returns `:none` for every agent, which means the cap compiles,
    # every credential test passes, and it never once binds.
    case Credential.source(scope, agent.provider) do
      :platform -> {turns_used(scope, agent), turn_cap()}
      _ -> :uncapped
    end
  end

  @doc "Turns an agent on our credential gets before it stops answering."
  @spec turn_cap() :: pos_integer()
  def turn_cap do
    :code_my_spec
    |> Application.get_env(Credential, [])
    |> Keyword.get(:platform_turn_cap, @default_turn_cap)
  end

  # The cap exists because we are paying, so it is asked here rather than at
  # start: the visitor may connect their own provider mid-conversation, and
  # from that moment they are paying and the cap has no business applying.
  #
  # Refused at dispatch and nowhere else, because dispatch is the one door a
  # turn comes through. Capping at start would only stop the eleventh
  # conversation, not the eleventh turn of the first one.
  defp within_turn_cap(scope, agent) do
    case turn_allowance(scope, agent) do
      :uncapped -> :ok
      {used, cap} when used < cap -> :ok
      {_used, cap} -> {:error, {:turn_cap_reached, cap}}
    end
  end

  # What the visitor has said, not what the agent has answered. A turn is
  # something they spend; counting the agent's replies would charge them for a
  # model that answered twice.
  defp turns_used(scope, agent) do
    case open_conversation(scope, agent) do
      {:ok, conversation} -> Conversations.count_messages(conversation, :operator)
      _ -> 0
    end
  end

  # Started or queued, on the row. The difference is the only thing the sender
  # can still act on, so it is not something the view infers from a timestamp.
  defp record_sent(conversation, text, ref, disposition) do
    Conversations.add_message(conversation, :operator, text, "operator", [],
      delivery: delivery_of(disposition),
      delivery_ref: ref
    )
  end

  defp delivery_of(:started), do: :delivered
  defp delivery_of(:queued), do: :pending

  @doc """
  Take back a message the agent has not picked up yet.

  Asked of the machine first and recorded second, for the same reason as
  sending: the agent's process is the only thing that knows whether the turn
  ended a moment ago, and a withdrawal that only cleared the record would leave
  the operator believing the agent will not see something it is about to act
  on.

  `{:error, :already_delivered}` is the honest answer to a click that lost the
  race — which is most of them, because people click when a turn is about to
  end.
  """
  @spec withdraw_message(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Conversations.Message.t()} | {:error, term()}
  def withdraw_message(%Scope{} = scope, id, ref) when is_binary(ref) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <-
           Transport.impl().withdraw_message(
             agent.working_copy_id,
             agent,
             ref,
             @message_timeout_ms
           ),
         %Conversations.Message{} = message <- Conversations.pending_message_by_ref(ref) do
      Conversations.set_delivery(message, :withdrawn)
    else
      # The machine took it back and the row is already gone or already
      # settled. Nothing to correct, and nothing worth failing over.
      nil -> {:error, :not_pending}
      error -> error
    end
  end

  @doc """
  Write one step an agent took to the conversation it belongs to.

  Written on arrival rather than accumulated until the turn completes. A turn
  that fails has already left everything it did behind it, which is the whole
  point of watching one — an agent going wrong is exactly the turn that does
  not finish cleanly.

  Here rather than in the channel because the channel is the wire, not the
  decision. A spex driving "the machine reported a step" has to drive this, and
  a private function inside a channel handler cannot be driven at all.
  """
  @spec record_turn_event(Scope.t(), Ecto.UUID.t(), map()) :: :ok
  # A turn ending is not a step, so nothing is written to the transcript for it.
  # It is the moment the orchestrator gets to speak — the internal equivalent of
  # an external agent's Stop hook firing, which is the one thing this runtime
  # never had. Story 1043.
  def record_turn_event(%Scope{} = scope, agent_id, %{"kind" => "turn_ended"}) do
    case AgentsRepository.fetch_agent(scope, agent_id) do
      {:ok, agent} -> StopDecision.deliver(scope, agent)
      _ -> :ok
    end
  end

  def record_turn_event(%Scope{} = scope, agent_id, event) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, agent_id),
         {:ok, conversation} <- open_conversation(scope, agent) do
      write_turn_event(conversation, agent, event)
    else
      # An agent that is not ours, or a step for one nobody can find. Dropped
      # rather than written somewhere plausible: a transcript under the wrong
      # agent is worse than a missing one, because it reads as that agent's
      # work.
      _ -> :ok
    end
  end

  # A compaction is not a step either. It is what the agent will resume from,
  # and it goes in its own table: a row in the transcript would have to be
  # skipped by every renderer, every preview and every `role` clause, and the
  # one that forgot would show a user a summary of their own conversation as
  # though the agent had said it.
  defp write_turn_event(conversation, _agent, %{"kind" => "compacted"} = event) do
    case Conversations.record_checkpoint(conversation, event["messages"] || [],
           turn: event["turn"]
         ) do
      {:ok, _checkpoint} ->
        :ok

      {:error, _changeset} ->
        # A checkpoint that will not save costs a longer resume, and nothing
        # else: the transcript is untouched and the agent is still running on
        # the summary it just made.
        Logger.info("[Agents] a compaction checkpoint for #{conversation.id} was not saved")
        :ok
    end
  end

  # A message the agent has just picked up is not a step of a turn — it is the
  # end of the operator's ability to take it back, and the only thing to record
  # is that.
  defp write_turn_event(_conversation, _agent, %{"kind" => "message_delivered", "ref" => ref})
       when is_binary(ref) do
    case Conversations.pending_message_by_ref(ref) do
      nil -> :ok
      message -> with {:ok, _} <- Conversations.set_delivery(message, :delivered), do: :ok
    end
  end

  defp write_turn_event(conversation, agent, event) do
    Conversations.add_agent_message(
      conversation,
      # `to_string`, because `role` became an `Ecto.Enum` in story 983 and
      # `agent_role` on a message is a string column. Without it the insert
      # fails and the step never reaches the page — which reads as an agent
      # that went quiet rather than as a type error.
      to_string(agent.role || :main),
      turn_event_kind(event),
      turn_event_text(event)
    )

    :ok
  end

  # The kinds a conversation already renders. An event this server does not
  # know is still worth keeping — it is something the agent did — so it lands
  # as a message rather than being discarded for not matching a list.
  defp turn_event_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp turn_event_kind(_event), do: "step"

  defp turn_event_text(%{"text" => text}) when is_binary(text), do: text
  defp turn_event_text(event), do: inspect(event)

  @doc """
  Record what a harness reports it is actually running.

  `list_running/1` answers from the database — the agents we asked for. This is
  the other half: the set the device says it has, which is the only half that
  can spend a subscription. Anything the report omits is marked stopped.

  ## Why the device is the authority and we are not

  The harness already knows this without being asked. A lane is joined to
  `harness:session:<external_id>` for exactly as long as it is alive, and
  Presence is that fact — story 704 replaced a polled subagent-TTL registry with
  it precisely because a liveness record maintained by hand drifts from the
  processes it claims to describe. So the report is a projection of Presence,
  and an agent whose process died is absent from it without anybody having to
  notice or send anything.

  That is also what makes the orphan case real rather than arranged: nothing
  simulates the death, the lane simply stops being joined.
  """
  @spec record_reported(Scope.t(), [map()]) :: {:ok, [Agent.t()]}
  def record_reported(%Scope{} = scope, reported) when is_list(reported) do
    adopted = reported |> Enum.map(&adopt(scope, &1)) |> Enum.reject(&is_nil/1)
    Enum.each(adopted, &ensure_conversation(scope, &1))
    alive = MapSet.new(adopted, & &1.id)

    # The server half of `[LaneReporter]`. Both sides log because the two
    # failures look identical from either one alone: a report that was never
    # sent and a report that arrived and reconciled to nothing both leave the
    # page showing every checkout idle. Interleaving the pair is what tells them
    # apart, which is what the log table in CLAUDE.md exists for.
    Logger.info("[Agents] harness reported #{length(reported)} agent(s)")

    running =
      scope
      |> AgentsRepository.list_running()
      |> Enum.map(&reap_if_absent(scope, &1, MapSet.member?(alive, &1.id)))
      |> Enum.filter(&(&1.status in [:starting, :running]))

    # A report is the only moment the server learns an agent went away, so it is
    # the only moment a page watching one can find out. Without this the row
    # keeps claiming an agent is working until somebody reloads, which is the
    # stale-row failure the reconcile exists to prevent, moved to the browser.
    broadcast(scope, {:agents_reported, running})

    {:ok, running}
  end

  # A reported agent the server has no row for is adopted rather than refused.
  #
  # The harness is the authority on what is running, and it can be running
  # something we did not start — a lane an engineer launched by hand, or one
  # that survived a server restart. Refusing those would make the server's list
  # a record of its own requests rather than of what exists, which is the
  # distinction this whole reconcile is about.
  #
  # Keyed on the working copy's **id** and the lane's role.
  #
  # The role half: a checkout runs one or more agents, the harness tells them
  # apart by role, and finding "the copy's agent" made a second lane overwrite
  # the first — one row flickering between two engines instead of two rows.
  #
  # The id half: the copy used to be matched by comparing the reported path to
  # `harnesses.root`, which is also a reported path. Two strings that are meant
  # to be equal and are produced independently do not stay equal, and two
  # harness rows can share a root outright. The device knows which harness id it
  # holds — it wrote the file — so it says so, and nothing here guesses.
  defp adopt(%Scope{} = scope, report) when is_map(report) do
    adopt(scope, reported_copy_id(report), report)
  end

  # Both names, new one first — the compatibility window every other reader on
  # this wire already honours, and this one had been left out of it.
  defp reported_copy_id(%{"working_copy_id" => id}) when is_binary(id) and id != "", do: id
  defp reported_copy_id(%{"harness_id" => id}) when is_binary(id) and id != "", do: id
  defp reported_copy_id(_report), do: nil

  defp adopt(%Scope{} = scope, working_copy_id, report)
       when is_binary(working_copy_id) do
    role = role(report)

    scope
    |> AgentsRepository.list_agents()
    |> Enum.find(&(&1.working_copy_id == working_copy_id and &1.role == role))
    |> upsert(scope, report)
  end

  # A report that names no working copy is refused rather than guessed at. It
  # would otherwise create an agent attached to nothing, which renders nowhere
  # and reaps nothing — a row that exists only to be wrong.
  defp adopt(_scope, nil, report) do
    Logger.warning(
      "[Agents] ignoring a reported agent with no working copy id: #{inspect(report)}"
    )

    nil
  end

  defp upsert(nil, scope, report) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: engine(report),
        provider: report["provider"] || "unknown",
        working_copy: report["working_copy"],
        role: role(report),
        working_copy_id: reported_copy_id(report),
        os_pid: report["os_pid"],
        status: :running
      })

    agent
  end

  defp upsert(%Agent{} = agent, scope, report) do
    {:ok, updated} =
      AgentsRepository.update_agent(scope, agent, %{
        engine: engine(report),
        status: :running,
        os_pid: recorded_group_or_reported(agent, report)
      })

    updated
  end

  # What we recorded at launch wins over what a lane reports about itself.
  #
  # They are different things. The launcher records a process *group* id, so one
  # signal takes the agent and every tool it spawned; a lane reports its own pid,
  # which is one member of that group. Letting the report overwrite it would
  # quietly downgrade every stop to killing a single process and leaving the
  # tree — the exact failure the group exists to prevent — and it would strand
  # `os_boot_id`, which was written to go with the group id and nothing else.
  defp recorded_group_or_reported(%Agent{os_pid: pid, os_boot_id: boot}, _report)
       when is_integer(pid) and is_binary(boot),
       do: pid

  defp recorded_group_or_reported(%Agent{} = agent, report),
    do: report["os_pid"] || agent.os_pid

  # The harness says which engine it is running, and it matters downstream: the
  # engine decides whether an agent has presence or only a timestamp, and whether
  # it can be talked to at all. Defaulting every report to `:pi` made a Claude
  # Code agent claim presence it does not have — caught by story 1019's criterion
  # 2830, which exists to keep those two facts apart.
  defp engine(%{"engine" => "claude_code"}), do: :claude_code
  defp engine(_report), do: :pi

  # A harness that names no lane is running one, and "main" is what that one is
  # called. Falling back keeps every report written before roles existed landing
  # on the row it always did, rather than forking a duplicate the first time
  # this ships.
  defp role(%{"role" => role}) when is_binary(role) and role != "", do: role
  defp role(_report), do: "main"

  # An adopted Pi lane gets the same transcript one we started gets.
  #
  # `start_agent/2` opens the conversation as part of starting, on the reasoning
  # that an agent that cannot be watched is indistinguishable from one that
  # never started. Adoption is the *ordinary* way an agent arrives — the harness
  # starts its own lanes and reports them — so leaving those without one made
  # the common case the unwatchable one: the working copy had a live agent and
  # nothing to link at until the lane happened to say something.
  #
  # Keyed `pi:<working_copy>`, the same key the lane pushes under, so the
  # transcript opened here and the one written to are one thread.
  defp ensure_conversation(%Scope{} = scope, %Agent{engine: :pi} = agent) do
    Conversations.find_or_create_agent_conversation(
      scope.active_account_id,
      scope.active_project_id,
      agent.id
    )
  end

  # A Claude Code agent gets none. There is no lane to route a reply to, and a
  # conversation that exists is a conversation the page offers to open.
  defp ensure_conversation(_scope, _agent), do: :ok

  defp reap_if_absent(_scope, %Agent{} = agent, true), do: agent

  # Absent from a report the machine actually sent.
  #
  # This used to fork: an agent with no group id was recorded stopped, and one
  # with a group id had its machine asked to end it first, because an OS process
  # could outlive the lane that reported it. A supervised agent cannot — the
  # harness reports what its own registry holds, so the lane and the process are
  # the same fact and a report that arrives is the check.
  #
  # The distinction that still matters is upstream of here: no report is not a
  # report of absence. A harness that went quiet says nothing about its agents,
  # and nothing calls this without a report to reconcile against.
  defp reap_if_absent(scope, %Agent{} = agent, false) do
    {:ok, stopped} = record_stopped(scope, agent)
    stopped
  end

  @doc """
  Stops one agent, and only that one.

  Stopping is only useful if it stops the right one: a stop that reaps the tree,
  or kills by name and catches a sibling, looks identical from the caller's side
  and is worse than having no stop at all.
  """
  @spec stop_agent(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Agent.t()} | {:error, :not_found | :cross_project | Ecto.Changeset.t()}
  def stop_agent(%Scope{} = scope, id) do
    with {:ok, agent} <- AgentsRepository.fetch_agent(scope, id),
         :ok <- end_process(scope, agent),
         {:ok, stopped} <- record_stopped(scope, agent) do
      broadcast(scope, {:agent_stopped, stopped})
      {:ok, stopped}
    end
  end

  # Ask the machine holding the process to end it, and let its answer decide
  # whether this is a stop at all.
  #
  # This used to write `status: :stopped, os_pid: nil` and broadcast, which
  # ended nothing. Worse, clearing `os_pid` threw away the only handle anything
  # could have acted on — so an agent that survived the "stop" became
  # permanently unreachable, by the stop. That is criterion 2828 caused by its
  # own remedy.
  #
  # An agent still `:starting` never came up, so there is no process to end and
  # nothing to ask. That is a real state, not an error: it is the row for an
  # agent we asked for and no machine confirmed, and cancelling it has to work.
  #
  # This used to key on `os_pid` being nil. An agent is a supervised process now
  # and never has a group id, so that clause matched every stop: the row went to
  # `:stopped` and nothing was ever asked to end anything. The defect this story
  # exists for, reintroduced by deleting the field its guard happened to read.
  defp end_process(_scope, %Agent{status: :starting}), do: :ok

  defp end_process(_scope, %Agent{} = agent) do
    agent.working_copy_id
    |> Transport.impl().stop_agent(agent, @stop_timeout_ms)
    |> stopped?()
  end

  # An agent the machine is not running is stopped — asking again is how a
  # stop becomes idempotent. A machine that could not be *reached* is not, and
  # collapsing the two is what makes a row say stopped over something still
  # running.
  defp stopped?(:ok), do: :ok
  defp stopped?({:error, :not_running}), do: :ok
  defp stopped?({:error, _reason} = error), do: error

  # Only after something confirmed the process is gone. `os_pid` and
  # `os_boot_id` are cleared here rather than before, because until the process
  # is actually gone they are the only way to reach it again.
  defp record_stopped(scope, agent) do
    AgentsRepository.update_agent(scope, agent, %{
      status: :stopped,
      os_pid: nil,
      os_boot_id: nil
    })
  end

  @doc """
  Records what the device reported back about an agent it was asked to start.

  The machine confirms the id it was asked to run, and that is the whole report.

  It used to be a process **group** id and the boot it belonged to, written
  together because a group id without its boot cannot be told from a recycled
  number naming a stranger's process. A supervised agent needs neither: the id
  was already on the row, and it resolves through the harness's registry for
  exactly as long as the agent is alive.

  So `:running` here means a machine said so, which is the only thing that ever
  made this status trustworthy.
  """
  @spec record_started(Scope.t(), Agent.t(), map()) ::
          {:ok, Agent.t()} | {:error, :cross_project | Ecto.Changeset.t()}
  def record_started(%Scope{} = scope, %Agent{} = agent, %{agent_id: _id}) do
    AgentsRepository.update_agent(scope, agent, %{status: :running})
  end

  @doc """
  Which provider and model an agent type launches on, and why.

  Their setting when there is one and it still names a provider they hold, and
  `Defaults.resolve/2` against what they do hold otherwise. Public because the
  settings screen shows what a type *would* do before anybody chooses.

  ## A setting can outlive its credential

  Disconnecting a provider does not delete the rows naming it — deriving this
  instead of cleaning up means there is one place the answer comes from, and no
  window in which a row and the integrations table disagree. Read against what
  is connected right now, a stale row falls back on its own; cleaned up on
  disconnect, it would only be right if every path that removes a credential
  remembered to.

  Falling back rather than refusing, because the person already said what they
  want when there is a choice, and being asked again is being asked about
  something that has not changed.
  """
  @spec resolve_model(Scope.t(), atom()) ::
          {:ok, {String.t(), String.t() | nil}, :set | :default} | {:error, :no_provider}
  def resolve_model(%Scope{} = scope, role) do
    connected = connected_providers(scope)

    scope
    |> AgentsRepository.model_setting(role)
    |> honour_setting(role, connected)
  end

  defp honour_setting(%ModelSetting{provider: provider, model: model}, role, connected) do
    case provider in connected do
      true -> {:ok, {provider, model}, :set}
      false -> resolved_default(role, connected)
    end
  end

  defp honour_setting(nil, role, connected), do: resolved_default(role, connected)

  defp resolved_default(role, connected) do
    with {:ok, choice} <- Defaults.resolve(role, connected) do
      {:ok, choice, :default}
    end
  end

  @doc "The agent types there are."
  @spec roles() :: [atom()]
  defdelegate roles(), to: Agent

  @doc "Every provider that can be chosen, connected or not."
  @spec provider_names() :: [String.t()]
  defdelegate provider_names(), to: Providers, as: :names

  @doc """
  Every provider this account can actually launch on.

  Asked of `Credential.fetch/2` rather than of the integrations table, so it
  answers the same question the launcher will ask a moment later. A provider
  listed here and refused at launch is the mismatch this exists to prevent.
  """
  @spec connected_providers(Scope.t()) :: [String.t()]
  def connected_providers(%Scope{} = scope) do
    Enum.filter(Providers.names(), &match?({:ok, _}, Credential.fetch(scope, &1)))
  end

  @doc "What each type runs on today, for every type. The settings screen reads this."
  @spec model_settings(Scope.t()) :: [
          %{role: atom(), provider: String.t() | nil, model: String.t() | nil, source: atom()}
        ]
  def model_settings(%Scope{} = scope) do
    Enum.map(Agent.roles(), fn role ->
      case resolve_model(scope, role) do
        {:ok, {provider, model}, source} ->
          %{role: role, provider: provider, model: model, source: source}

        {:error, :no_provider} ->
          %{role: role, provider: nil, model: nil, source: :none}
      end
    end)
  end

  @doc "Point an agent type at a provider and model."
  @spec put_model_setting(Scope.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, ModelSetting.t()} | {:error, Ecto.Changeset.t() | :unknown_provider}
  def put_model_setting(%Scope{} = scope, role, provider, model) do
    # Refused here rather than at launch. A screen that stores a provider the
    # account cannot authenticate produces an agent that fails on its first
    # model call, minutes later, in a log nobody is reading — which is the
    # failure the credential ordering above exists to prevent, arriving through
    # the front door instead.
    case provider in connected_providers(scope) do
      true -> AgentsRepository.put_model_setting(scope, role, provider, model)
      false -> {:error, :unknown_provider}
    end
  end

  @doc """
  Let a type resolve from the defaults again.

  The counterpart to `put_model_setting/4`, and the thing whose absence made
  issue c6f5acce expensive: the settings form posts all four types at once, an
  untouched select posts the default's own value, so one Save converted every
  type from "whatever is sensible" to "this exact model, chosen deliberately" —
  and there was no way back.

  `ModelSetting`'s moduledoc argues against writing a default row at account
  creation, because it would freeze whatever the defaults were that day. Writing
  one on the first Save has the same effect; this is how it is undone.
  """
  @spec clear_model_setting(Scope.t(), atom()) :: :ok
  defdelegate clear_model_setting(scope, role), to: AgentsRepository

  # The type an agent is being started as. Refused rather than defaulted when it
  # names one that does not exist: `Agent.role` is an enum, and a caller asking
  # for a type nobody defined is a caller with the wrong idea about what exists.
  defp role_of(attrs) do
    case Map.get(attrs, :role, :main) do
      role when is_atom(role) -> known_role(role, role)
      role when is_binary(role) -> role |> safe_atom() |> known_role(role)
    end
  end

  # `asked` is carried separately from the atom, because the atom may be the
  # sentinel `safe_atom/1` returns for a name that does not exist — and a
  # refusal naming `:__unknown__` tells the caller a word it never sent.
  defp known_role(role, asked) do
    case role in Agent.roles() do
      true -> {:ok, role}
      false -> {:error, {:unknown_role, asked, Agent.roles()}}
    end
  end

  # `to_existing_atom` so a caller cannot grow the atom table by asking for
  # types that do not exist.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :__unknown__
  end

  # An explicit provider still wins — a caller that names one is asking for it,
  # and story 983 is about what happens when nobody does.
  defp provider_for(scope, role, attrs) do
    case Map.get(attrs, :provider) do
      nil ->
        with {:ok, {provider, model}, _source} <- resolve_model(scope, role) do
          {:ok, provider, model}
        end

      provider ->
        {:ok, provider, Map.get(attrs, :model)}
    end
  end

  # Computed at start, from the role and from what this agent's machine said it
  # could do.
  #
  # The machine half cannot come from a list here: a browser is an MCP server on
  # somebody's box, its tools are whatever that box's vibium reports, and a copy
  # written down here would drift the first time vibium ships one. So the
  # harness reports names on join and this reads them back.
  #
  # Only for the types that browse. A product agent shaping stories has no use
  # for a click, and handing it twenty-nine ways to make one is the catalogue
  # this story is about, one layer over.
  defp tools_for(%Scope{} = scope, attrs) do
    role = Map.fetch!(attrs, :role)

    case ToolSets.for_role(role) do
      # Everything, and not written down as a list — see `ToolSets.for_role/1`.
      # A machine's tools need no adding to "all of them".
      nil -> nil
      granted -> granted ++ machine_tools(scope, attrs, role)
    end
  end

  defp machine_tools(_scope, _attrs, role) when role not in [:main, :qa, :coding], do: []

  defp machine_tools(scope, attrs, _role) do
    with id when is_binary(id) <-
           Map.get(attrs, :working_copy_id) || scope.active_working_copy_id,
         {:ok, %{machine_tools: names}} when is_list(names) <- WorkingCopies.fetch(id) do
      names
    else
      _ -> []
    end
  end

  defp base_attrs(%Scope{} = scope, attrs) do
    %{
      engine: Map.get(attrs, :engine, :pi),
      provider: Map.fetch!(attrs, :provider),
      # Written down at start rather than derived at call time. A list on the
      # row survives a change to what a role means, answers "what may this
      # agent call" without a second lookup, and takes an exception without
      # inventing a role for it.
      tools: Map.get(attrs, :tools) || tools_for(scope, attrs),
      model: Map.get(attrs, :model),
      working_copy: Map.get(attrs, :working_copy) || scope.cwd,
      role: Map.fetch!(attrs, :role),
      working_copy_id: Map.get(attrs, :working_copy_id) || scope.active_working_copy_id,
      status: :starting
    }
  end

  defp broadcast(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(scope), message)
  end

  defp topic(%Scope{active_project_id: project_id}), do: "agents:#{project_id}"
end
