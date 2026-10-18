defmodule CodeMySpec.Agents.Tools.ReadAgentConversation do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.MainAgentResponses, as: MainAgentMapper

  @impl true
  def name, do: "read_agent_conversation"

  @impl true
  def description do
    """
    Read what one or more of your agents has said, most recent turns last.

    For finding out what a stuck agent was doing without spending its turn on
    the question. `agent_id` reads one agent; `agent_ids` merges several onto
    one timeline. `limit` bounds how many turns come back; a read that would
    be too large is cut to the recent end and says so. `since`/`until` (ISO8601)
    narrow to a window. `last_call_of` skips the transcript and answers only
    the last call to that tool and what it returned.
    """
  end

  @impl true
  def params do
    %{
      until: {:meta, :string, [description: "ISO8601 — only turns at or before this time."]},
      limit: {:meta, :integer, [description: "Most recent N turns. Defaults to a page."]},
      since: {:meta, :string, [description: "ISO8601 — only turns at or after this time."]},
      agent_id:
        {:meta, :string,
         [
           description:
             "From `list_agent_work`, or its conversation id. One of this or `agent_ids`."
         ]},
      agent_ids:
        {:meta, {:list, :string}, [description: "Several agents, merged onto one timeline."]},
      last_call_of:
        {:meta, :string,
         [
           description:
             "Skip the transcript — answer only the last call to this tool and its result."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        read(scope, params)

      {:error, reason} ->
        MainAgentMapper.error(reason)
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
          # `:not_found` alone reads as the escalation clause, which blamed
          # another project (aeb22e38).
          {:error, :not_found} -> MainAgentMapper.error(:no_such_agent)
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
