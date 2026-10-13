defmodule CmsHarness.Channel do
  @moduledoc """
  What the rest of the harness asks of a working copy's channel to the server:
  each function finds that copy's `CmsHarness.Project.ChannelClient` process
  and calls or casts to it. Split from the client so the modules that send
  (agents, app instances, sync, the local web API) need not depend on the
  client, which itself dispatches the server's requests to them.
  """

  use Boundary, top_level?: true, deps: []

  require Logger

  alias CodeMySpec.Files.Scanner.ReadModel

  @default_decision_timeout 10_000

  @doc false
  def decision_timeout,
    do: Application.get_env(:code_my_spec, :harness_decision_timeout, @default_decision_timeout)

  @doc false
  def analysis_timeout,
    do: Application.get_env(:code_my_spec, :harness_analysis_await_timeout, :timer.minutes(32))

  @doc false
  def promotion_timeout,
    do: Application.get_env(:code_my_spec, :harness_promotion_await_timeout, :timer.minutes(20))

  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:channel, root}}}

  @doc """
  Whether this project's channel is joined right now.

  `false` covers "never connected", "dropped", and "refused" alike — from the
  caller's point of view they are the same fact: the harness cannot ask the
  server anything about this project.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :connected?, 5_000)
      [] -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Seconds since this project's channel joined, or `nil` if it is not joined.

  `connected?/1` answers "can I ask the server", which is the right question
  before sending. This answers a different one, asked *after* a request came
  back empty: how long has this channel been up?

  A channel that joined moments ago has usually just been rebuilt after dying,
  and a request in flight when it died is simply gone. Reporting that as "the
  channel is joined, so this is the server or the network" sent three agents
  after a connection that was fine — the server had crashed, dropped the
  channel, and the harness had reconnected before anyone looked. `1dc29224`.
  """
  @spec joined_ago(String.t()) :: non_neg_integer() | nil
  def joined_ago(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :joined_ago, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Seconds since the server last answered this project's channel, or `nil`.

  The question `connected?/1` cannot answer. That one reports this process's
  belief about its own socket, set at join — it cannot be wrong from where it
  stands, and it read `true` throughout an incident where the server's registry
  held no entry for this harness and every request came back
  `:harness_unreachable`. Both ends reported healthy because neither had done a
  round trip.

  A reply is evidence, because the server is what sent it. Recorded on replies
  that already happen, so this costs nothing to ask and cannot hang.
  """
  @spec server_replied_ago(String.t()) :: non_neg_integer() | nil
  def server_replied_ago(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :server_replied_ago, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Send a completed model turn to the server to be recorded.

  Fire and forget, and deliberately so. Recording is evidence for whoever is
  watching, never a step the agent's turn depends on — a cast cannot make the
  turn slower, cannot fail it, and cannot block it behind a server that is
  briefly unreachable. A turn lost from the record is a gap the operator is
  shown; a turn lost to the recorder would be work destroyed.
  """
  @spec record_turn(String.t(), map()) :: :ok
  def record_turn(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:record_turn, payload})
      [] -> :ok
    end

    :ok
  end

  @doc """
  Ask the server to decide a hook.

  Returns `{:error, :not_connected}`, `{:error, :no_credential}` or
  `{:error, :no_reply}` rather than anything resembling an answer. The caller
  turns that into a refusal; this must never invent one.
  """
  @spec decide_hook(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :no_credential | :no_reply}
  def decide_hook(root, hook, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, {:decide_hook, hook, payload}, decision_timeout() + 2_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Ask the server to resolve a skill invocation to a prompt.

  Same shape as `decide_hook/3` — resolving a skill is a DB-bound lookup
  (`StartAgentTask.run/2` creates a session row and returns a prompt string;
  it does not run the agent turn itself), not a `mix` invocation, so it shares
  `decide_hook/3`'s timeout class rather than `await_analysis/3`'s.
  """
  @spec start_skill(String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :no_credential | :no_reply}
  def start_skill(root, params) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, {:start_skill, params}, decision_timeout() + 2_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc "Authenticated mailbox transition, acknowledged by the database authority."
  def mailbox(root, params) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, {:mailbox, params}, 17_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Run one analyzer for the agent and wait for the server's answer.

  The agent's own `mix test`, rewritten by the PreToolUse hook. It goes to the
  server rather than straight to `mix` so the run gets a ledger row, joins an
  identical run already in flight instead of a second one contending for
  `_build`, and reconciles its Problems centrally — none of which a bare shell
  command can do, which is why the same suite used to be run twice.

  Blocks for as long as the suite takes. The server replies out of band, so no
  channel process is held while it does.
  """
  @spec await_analysis(String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def await_analysis(root, source, args) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_analysis, source, args}, analysis_timeout() + 5_000)

      [] ->
        {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Block until the project's analyzers are idle, then return their state.

  Backs `POST /api/analysis/wait`. Blocks for as long as the queue takes; the
  server replies out of band, so no channel process is held meanwhile.
  """
  @spec await_idle(String.t()) :: {:ok, map()} | {:error, term()}
  def await_idle(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :await_idle, analysis_timeout() + 5_000)
      [] -> {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc """
  Promote this working copy and wait for the outcome.

  Backs `POST /api/harnesses/<id>/promotion/run`. The promotion runs on the
  *server* — `Promotion.gate/1` reads the database and this machine has none —
  and its disk half comes straight back here as `fs_request` ops, so this waits
  on a round trip that passes through this process twice. Which is fine: the
  server replies out of band, so nothing is held while it does.

  `{:ok, %{"status" => "promoted" | "refused", "report" => text}}` for anything
  the promotion decided, including a refusal. `{:error, …}` only when it could
  not be attempted.
  """
  @spec await_promotion(String.t(), integer() | String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def await_promotion(root, story_number) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_promotion, story_number}, promotion_timeout() + 5_000)

      [] ->
        {:error, :not_connected}
    end
  catch
    :exit, _ -> {:error, :no_reply}
  end

  @doc "The read model this project last received. `nil` before the first join."
  @spec read_model(String.t()) :: ReadModel.t() | nil
  def read_model(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.call(pid, :read_model, 5_000)
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Scan the working copy and send the manifest.

  Asynchronous: a full scan of a few thousand files takes seconds, and doing it
  in this process would stall the socket that holds the lease.
  """
  @spec request_sync(String.t()) :: :ok
  def request_sync(root) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, :sync)
      [] -> :ok
    end
  end

  @doc "Called from the scanning task with the finished manifest."
  @spec deliver_observations(String.t(), [map()]) :: :ok
  def deliver_observations(root, observations) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:observations, observations})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with the app name read straight out of
  this checkout's own `mix.exs`.
  """
  @spec deliver_module_name(String.t(), String.t()) :: :ok
  def deliver_module_name(root, name) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:module_name, name})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with the health-route verdict, checked
  against this checkout's own real router.ex/endpoint.ex.
  """
  @spec deliver_health_route_status(String.t(), String.t()) :: :ok
  def deliver_health_route_status(root, status) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:health_route_status, status})
      [] -> :ok
    end
  end

  @doc """
  Called from the scanning task with `git rev-parse HEAD`, read straight out
  of this checkout.
  """
  @spec deliver_head_commit(String.t(), String.t()) :: :ok
  def deliver_head_commit(root, sha) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:head_commit, sha})
      [] -> :ok
    end
  end

  @doc "Whether this checkout's application is answering, measured on every scan."
  @spec deliver_preview_status(String.t(), String.t()) :: :ok
  def deliver_preview_status(root, status) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:preview_status, status})
      [] -> :ok
    end
  end

  @doc """
  A working copy's own app_status transition its background first-start
  watch just observed — starting → serving, or starting → erroring with a
  reason. Story 1108's `ensure_app_running`/`restart_app` replies already
  carry `app_status` on every call; this is the same fact, pushed
  unprompted for the one case nothing is calling back to ask — a first
  start left running in the background after its own short reply window.
  """
  @spec deliver_app_status(String.t(), map()) :: :ok
  def deliver_app_status(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:app_status, payload})
      [] -> :ok
    end
  end

  @doc "What the machine this checkout runs on is carrying, measured on its own clock."
  @spec deliver_machine_load(String.t(), map()) :: :ok
  def deliver_machine_load(root, load) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:machine_load, load})
      [] -> :ok
    end
  end

  @doc "Called from the analysis queue with the commit a run is starting on."
  @spec deliver_analysis_started(String.t(), map()) :: :ok
  def deliver_analysis_started(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:analysis_started, payload})
      [] -> :ok
    end
  end

  @doc "Called from the analysis queue with a finished (or failed) run."
  @spec deliver_analysis_result(String.t(), map()) :: :ok
  def deliver_analysis_result(root, payload) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:analysis_result, payload})

      [] ->
        # The channel died between the run starting and finishing. The server
        # closed that run's ledger row when the socket went, so this result has
        # nowhere to land — said out loud rather than dropped silently, because
        # the visible symptom otherwise is an analyzer that appears never to
        # have run.
        Logger.error(
          "[CmsHarness] #{payload["source"]} finished for project #{root} but the " <>
            "channel is gone — the result was discarded. It will be re-run on rejoin."
        )

        :ok
    end
  end

  @doc """
  One fragment of the text an agent is writing, for the live view.

  Never stored. Fragments are gathered per agent and pushed as the whole draft
  so far, every 100ms at most — so a view that missed one push is corrected
  by the next rather than showing a sentence with a hole in it.
  """
  def report_draft(root, agent_id, %{payload: text} = envelope) when is_binary(text) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:draft, agent_id, Map.get(envelope, :turn), text})
      [] -> :ok
    end
  end

  def report_draft(_root, _agent_id, _envelope), do: :ok

  @doc """
  Tell the server about one step an agent took.

  Cast rather than called: the agent is mid-turn and waiting on nothing here,
  and a server that is slow to take a step must not slow the work down.
  """
  @spec report_turn_event(String.t(), String.t(), map()) :: :ok
  def report_turn_event(root, agent_id, envelope) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [{pid, _}] -> GenServer.cast(pid, {:turn_event, agent_id, envelope})
      [] -> :ok
    end
  end
end
