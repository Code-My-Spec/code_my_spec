defmodule CmsHarness.Agents do
  @moduledoc """
  Agents running on this machine — start one, say which are running, stop one.

  Harness-side because the working copy is here. An agent session is hundreds of
  read, edit and bash calls; server-side each one would be a channel round-trip
  whose failure mode is a broken turn rather than a deferred sync.

  ## What this used to be

  Starting `pi` as a detached OS process, in a process group of its own, with a
  boot id recorded beside the group id so a recycled number could not be
  mistaken for ours. That apparatus existed to make a foreign process reachable,
  and it never worked end to end: the extension that was supposed to join the
  harness and hold `pi` open was never published, so `pi` started, found nothing
  to do, and exited zero — silently, which is why it produced no diagnosis.

  `CmsHarness.Agents.Engine` replaces it with a supervised process. What is left
  here is translation: the server sends a request, this turns it into engine
  options, and the engine owns the loop.
  """

  alias CmsHarness.Agents.Engine

  @doc """
  Start the agent this request describes.

  Answers `{:ok, %{agent_id: id}}` — the id is the handle now. There is no
  process group and no boot id, because there is no foreign process to reach:
  the id resolves through the harness's registry while the harness is running,
  which is the honest scope for it.
  """
  @spec launch(map()) :: {:ok, %{agent_id: String.t()}} | {:error, atom()}
  def launch(%{"agent_id" => agent_id} = request) do
    with {:ok, %{agent_id: id}} <-
           Engine.start(
             agent_id: agent_id,
             provider: request["provider"],
             credential: credential(request),
             working_copy: request["working_copy"],
             model: request["model"],
             # What this agent already knows. An agent dies with its harness
             # and the transcript is the state — which is only true if the
             # transcript actually arrives, and until it did, a restarted agent
             # came back with no memory of anything it had been told.
             messages: request["messages"],
             # An OpenAI-compatible endpoint that is not the provider's own:
             # a self-hosted gateway, a proxy, a company's own deployment. The
             # provider has always read this and nothing has ever sent one.
             base_url: request["base_url"],
             # In front of the provider's HTTP client. A function, so only an
             # in-process caller can set it — which is what a recording of a
             # real turn needs and what nothing on the wire can carry.
             req_options: request["req_options"],
             # Where an agent finishes what it was part-way through before the
             # process goes. Nothing on the wire sets it yet; the seam exists so
             # a graceful stop is observable rather than merely intended.
             on_stop: request["on_stop"],
             # The channel for the copy this agent runs in, unless the caller
             # names somewhere else. Settable for the same reason `on_stop` is:
             # the default is right for the harness and it is not the only
             # caller.
             on_event: request["on_event"] || reporter_for(request["working_copy"])
           ) do
      {:ok, %{agent_id: id}}
    end
  end

  def launch(_request), do: {:error, :agent_id_required}

  @doc """
  Stop one agent, and say whether it was there to stop.

  One, and only one — a stop that reaps a tree, or matches by name and catches a
  sibling, is indistinguishable from this at the call site and is worse than
  having no stop at all.
  """
  @spec halt(String.t()) :: :ok | {:error, :not_running}
  defdelegate halt(agent_id), to: Engine, as: :stop

  @doc """
  Give a running agent something to do, and wait for the turn.

  The whole of what a held stdin pipe was for. `Engine.chat/3` is the call; this
  is the name the wire uses for it.
  """
  @spec message(String.t(), String.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def message(agent_id, text, timeout \\ 180_000) when is_binary(text) do
    case Engine.chat(agent_id, text, timeout) do
      {:ok, result} -> {:ok, said(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Hand a running agent a message without waiting for the turn.

  `ref` is the operator's handle on it. Answers `:started` or `:queued` — the
  difference is whether it can still be taken back, which is the only thing the
  sender can act on before the turn ends.
  """
  @spec send_message(String.t(), String.t(), String.t(), timeout()) ::
          {:ok, :started | :queued} | {:error, term()}
  def send_message(agent_id, ref, text, timeout \\ 180_000) when is_binary(text) do
    Engine.send_message(agent_id, ref, text, timeout)
  end

  @doc """
  Take back a message the agent has not picked up.

  `{:error, :already_delivered}` when it has, which is a real outcome rather
  than a failure to handle: the window is small and it is exactly the window in
  which people click.
  """
  @spec withdraw(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate withdraw(agent_id, ref), to: Engine

  @doc """
  What one agent is doing right now — mid-turn, and how much is behind it.
  """
  @spec status(String.t()) ::
          {:ok, %{busy?: boolean(), queued: non_neg_integer()}} | {:error, :not_running}
  defdelegate status(agent_id), to: Engine

  @doc """
  What one agent knows — the turns its loop is actually holding.

  Distinct from its transcript, which is what was written down. The two come
  apart exactly when an agent has been restarted, which is the case worth being
  able to ask about.
  """
  @spec history(String.t()) ::
          {:ok, [Alloy.Message.t()]} | {:error, :not_running | :busy}
  defdelegate history(agent_id), to: Engine

  # What the agent said, out of what Alloy hands back.
  #
  # The result carries the whole turn — every message, the tool manifest, the
  # prompt that went to the provider. Passed through whole it reached the
  # operator as four thousand tokens of scaffolding with the actual answer
  # somewhere inside, so the reply is narrowed here, where the wire contract
  # already says it is a string.
  #
  # Busy is one of the answers. Reported as what it is rather than as an empty
  # turn: an operator told "(no message)" concludes the agent ignored them, and
  # sends it again.
  defp said({:queued, _ref}), do: "(queued — the agent is mid-turn and will get this next)"

  # A turn that failed comes back as an `:ok` result carrying an error, and a
  # clause that only looks at `text` reports that as "(no message)" — the agent
  # ignoring you, rather than the agent's provider refusing.
  defp said(%{status: :error, error: reason}), do: "(the turn failed: #{inspect(reason)})"

  defp said(%{text: text}) when is_binary(text) and text != "", do: text

  defp said(%{tool_calls: calls}) when is_list(calls) and calls != [] do
    "(no message — the turn ended in #{length(calls)} tool call(s))"
  end

  defp said(_result), do: "(no message)"

  @doc """
  Agent ids running here, read from the registry rather than from anything we
  were told — so it cannot disagree with what is actually alive.
  """
  @spec running() :: [String.t()]
  defdelegate running(), to: Engine

  # A step, on its way to whoever is watching.
  #
  # Sent per event rather than accumulated, because the point of watching is
  # seeing an agent go wrong while it is going wrong. A batch that arrives when
  # the turn ends is a report, not a view — and a turn that fails never ends.
  #
  # Fire and forget: an agent's work does not stop because nobody is watching,
  # and a reporting failure must not become a turn failure.
  #
  # ## One channel, not every channel
  #
  # This looped over `Projects.list()` and pushed each step down every copy the
  # harness serves. One harness serves several checkouts, and several of those
  # are usually worktrees of the same project — so every channel on that
  # project recorded the same step, and a transcript held each line once per
  # sibling checkout. Two here; ten on a busy box.
  #
  # An agent runs in one working copy. That copy's channel is the one that
  # should hear about it, and a copy this harness does not serve is a cast that
  # finds no registry entry and stops — which is the right answer, because
  # there is nowhere to report to.
  defp reporter_for(working_copy) do
    fn agent_id, envelope ->
      CmsHarness.Project.ChannelClient.report_turn_event(working_copy, agent_id, envelope)
    end
  end

  # The server sends whatever the provider needs, and the shapes differ: a
  # subscription path names a file `codex exec` reads, an API-key path carries
  # the key. Passed through rather than interpreted, because deciding what a
  # credential means is `Provider`'s job, and doing it in two places is how the
  # two drift apart.
  defp credential(request) do
    %{}
    |> put_if(:auth_path, request["auth_path"] || request["config_dir"])
    |> put_if(:api_key, request["api_key"])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
