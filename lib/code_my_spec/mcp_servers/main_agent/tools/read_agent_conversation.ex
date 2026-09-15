defmodule CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation do
  @moduledoc """
  Read what one of your agents has said, most recent turns last.

  For finding out what a stuck agent was doing without spending its turn on the
  question. `limit` bounds how many turns come back; a read that would be too
  large is cut to the recent end and says so.
  """

  # Why reading rather than asking
  #
  # The main agent supervises agents it cannot see inside, and the only way to
  # learn what one had done was to send it a message and wait. That spends the
  # agent's turn answering instead of working, and it fails exactly when it is
  # needed: an agent that is stuck, looping or mid-crash is the one least able
  # to give an account of itself. Story 1013's criterion 3280 states the rule
  # directly — the main agent must not have to ask the agent to explain itself.
  #
  # Scoped to this project's agents by `Agents.fetch_agent/2`, which resolves
  # within the caller's scope. Criterion 3289 says no agent's conversation is
  # closed to the main agent; that means every agent of *this* project, not
  # every agent on the machine.
  #
  # Comments rather than moduledoc: `Anubis.Server.Component` advertises the
  # moduledoc as the tool's description and `SpineTest` holds the whole spine
  # under 20 KB.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:agent_id, :string)
    field(:agent_ids, {:list, :string})
    field(:limit, :integer)
    field(:since, :string)
    field(:until, :string)
    field(:last_call_of, :string)
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, read(scope, params), frame}

      {:error, reason} ->
        {:reply, MainAgentMapper.error(reason), frame}
    end
  end

  defp read(scope, params) do
    case targets(params) do
      [] ->
        MainAgentMapper.error(:no_agent_named)

      agent_ids ->
        case MainAgent.read_agent_conversation(scope, agent_ids, opts(params)) do
          {:ok, result} -> MainAgentMapper.conversation(result)
          {:error, reason} -> MainAgentMapper.error(reason)
        end
    end
  end

  # One agent or several. `agent_ids` is what makes two agents answerable on one
  # timeline (criterion 3283); `agent_id` stays because the overwhelming case is
  # one agent and making every caller wrap it in a list would be ceremony.
  defp targets(params) do
    case fetch(params, :agent_ids) do
      ids when is_list(ids) and ids != [] -> ids
      _ -> params |> fetch(:agent_id) |> List.wrap()
    end
  end

  # Only pass an option on when one was given, so the context's own defaults
  # stay the single place those values live.
  defp opts(params) do
    [
      {:limit, fetch(params, :limit)},
      {:since, timestamp(fetch(params, :since))},
      {:until, timestamp(fetch(params, :until))},
      {:last_call_of, fetch(params, :last_call_of)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # A window given as text the caller can actually type. An unparseable one is
  # dropped rather than refused: the read still answers, and answering a wider
  # question is better than answering none — the alternative is a caller who
  # cannot tell a malformed timestamp from an agent that said nothing.
  defp timestamp(nil), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp timestamp(%DateTime{} = at), do: at
  defp timestamp(_other), do: nil

  defp fetch(params, key) do
    Map.get(params, key) || Map.get(params, to_string(key))
  end
end
