defmodule CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation do
  @moduledoc """
  Read what one or more of your agents has said, most recent turns last.

  For finding out what a stuck agent was doing without spending its turn on
  the question. `agent_id` reads one agent; `agent_ids` merges several onto
  one timeline. `limit` bounds how many turns come back; a read that would
  be too large is cut to the recent end and says so. `since`/`until` (ISO8601)
  narrow to a window. `last_call_of` skips the transcript and answers only
  the last call to that tool and what it returned.
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
  # `since`/`until` arrive over MCP as ISO8601 strings; `MainAgent` compares
  # them as `DateTime` directly, so parsing them is this layer's job rather
  # than the context's — the same reason `RunReport` parses dates before
  # calling into a context that only ever sees structured time.
  #
  # Comments rather than moduledoc: `Anubis.Server.Component` advertises the
  # moduledoc as the tool's description and `SpineTest` holds the whole spine
  # under 20 KB.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:agent_id, :string, doc: "From `list_agent_work`. One of this or `agent_ids`.")
    field(:agent_ids, {:list, :string}, doc: "Several agents, merged onto one timeline.")
    field(:limit, :integer, doc: "Most recent N turns. Defaults to a page.")
    field(:since, :string, doc: "ISO8601 — only turns at or after this time.")
    field(:until, :string, doc: "ISO8601 — only turns at or before this time.")

    field(:last_call_of, :string,
      doc: "Skip the transcript — answer only the last call to this tool and its result."
    )
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
    case agent_id_or_ids(params) do
      # Neither id given. Refused here rather than passed on, because
      # `read_agent_conversation/3` matches a binary or a list and `nil` matches
      # neither — so without this a caller that names no agent gets a
      # `FunctionClauseError` instead of being told what to pass.
      nil ->
        MainAgentMapper.error(:no_agent_named)

      target ->
        case MainAgent.read_agent_conversation(scope, target, opts(params)) do
          {:ok, result} -> MainAgentMapper.conversation(result)
          {:error, reason} -> MainAgentMapper.error(reason)
        end
    end
  end

  defp agent_id_or_ids(params) do
    case fetch(params, :agent_ids) do
      ids when is_list(ids) and ids != [] -> ids
      _ -> fetch(params, :agent_id)
    end
  end

  defp opts(params) do
    []
    |> put_opt(:limit, fetch(params, :limit))
    |> put_opt(:since, parse_time(fetch(params, :since)))
    |> put_opt(:until, parse_time(fetch(params, :until)))
    |> put_opt(:last_call_of, fetch(params, :last_call_of))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_time(nil), do: nil

  defp parse_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp fetch(params, key) do
    Map.get(params, key) || Map.get(params, to_string(key))
  end
end
