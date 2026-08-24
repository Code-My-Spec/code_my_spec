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
             # Where an agent finishes what it was part-way through before the
             # process goes. Nothing on the wire sets it yet; the seam exists so
             # a graceful stop is observable rather than merely intended.
             on_stop: request["on_stop"]
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
  @spec message(String.t(), String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def message(agent_id, text, timeout \\ 180_000) when is_binary(text) do
    Engine.chat(agent_id, text, timeout)
  end

  @doc """
  Agent ids running here, read from the registry rather than from anything we
  were told — so it cannot disagree with what is actually alive.
  """
  @spec running() :: [String.t()]
  defdelegate running(), to: Engine

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
