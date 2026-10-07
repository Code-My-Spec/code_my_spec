defmodule CodeMySpec.McpServers.CodeMode.Tools.RunScript do
  @moduledoc """
  Run a Lua script that calls this harness's tools.

  Use this to do several steps in one turn instead of one tool call per step —
  read a list, look at each item, and return only what you needed. Every tool
  is a function taking one table:

      local story = get_story({ story_number = 970 })
      print("checking", story.title)
      return story.title

  A tool that ran and could not answer returns nil and an error table rather
  than stopping the script, so a loop can report what it could not find:

      local story, err = get_story({ story_number = 12345 })
      if story == nil then return "missing: " .. err.message end

  A call the sandbox *rejects* — wrong argument type, missing required
  argument — is different: the tool never ran, and the script stops there. You
  do not have to check for it, and you cannot carry on past it. That is
  deliberate. A malformed call used to come back as `nil` and an error table
  too, which is indistinguishable at a glance from a tool that found nothing,
  and a script that discarded the second value would go on to answer from a
  call that never happened.

  Call `tool_docs` to see what tools there are and what each one takes.

  Most tools answer with text rather than data, so treat a result as a string
  unless its documentation says otherwise. Scripts are sandboxed: no
  filesystem, no network, no OS, and there are limits on run time, recursion
  and result size.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Result
  alias CodeMySpec.McpServers.AgentAlert
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.Validators

  schema do
    field :script, :string,
      required: true,
      description: "Lua source. Return a value to get it back; use print() for progress."

    field :agent_id, :string,
      description:
        "The agent running this, when one is. Its row says which tools it carries; " <>
          "omitted, the script may call everything the caller can."

    field :session_id, :string, description: "Injected by hook — do not set manually"
  end

  @impl true
  def execute(%{script: script} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        case grant_agent_id(frame, params) do
          {:ok, agent_id} ->
            # Which tools, from the agent's role as it stands now
            # (`Agents.tools_of/2`), not a list the caller supplies. An agent
            # we run is identified by its connection (`frame.assigns`), and
            # `grant_agent_id/2` has already refused a differing `agent_id`
            # param, so what remains here cannot borrow another agent's grant.
            {allowed, kind} = agent_scope(scope, agent_id)

            result =
              CodeMode.eval(Layer.catalog(scope, allowed, caller(params, frame)), script,
                out_of_scope: Layer.out_of_scope(allowed),
                agent_kind: kind,
                # What this caller carries, so a refusal can say whether "call
                # it directly" is advice it can take (`bd699695`). `nil` from
                # `agent_scope/2` means no restriction, the same meaning it has
                # everywhere else.
                carried: allowed || :all
              )

            {:reply, render(result, scope, params), frame}

          {:error, :agent_id_mismatch} ->
            {:reply,
             Response.tool()
             |> Response.error(
               "agent_id does not match this connection's own agent. Omit it to use your " <>
                 "own tools — a connected agent cannot borrow another agent's grant."
             ), frame}
        end

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  # The connection's own agent_id is authoritative when there is one: naming a
  # different agent used to only "borrow" its grant, which was harmless while
  # every agent could reach everything. Main-only tools (story 983) ended
  # that, so a differing id is now refused rather than honored.
  defp grant_agent_id(frame, params) do
    case frame.assigns[:agent_id] do
      nil -> {:ok, Map.get(params, :agent_id)}
      connection_id ->
        case Map.get(params, :agent_id) do
          nil -> {:ok, connection_id}
          ^connection_id -> {:ok, connection_id}
          _other -> {:error, :agent_id_mismatch}
        end
    end
  end

  # Who the tools inside the script are acting for.
  #
  # Two carriers, because there are two kinds of caller and neither can use the
  # other's: an agent we run is identified by its connection, so `agent_id` is
  # already on this frame; a Claude Code session is identified by a `session_id`
  # the `PreToolUse` hook injects into this tool's input. The script path used to
  # carry neither, so every tool that asks whose work it is refused — `list_tasks`,
  # `evaluate_task`, `start_task`, `cancel_task`, `assign_task`. A caller could
  # script everything except claiming or finishing a piece of work (`1a892606`).
  #
  # `agent_id` from the frame first. The parameter says which agent's *tool list*
  # to use and a caller may legitimately name another one; the connection says
  # who is actually calling, and that is the one whose tasks these are.
  defp caller(params, frame) do
    %{}
    |> put_present(:session_id, Map.get(params, :session_id))
    |> put_present(:agent_id, frame.assigns[:agent_id] || Map.get(params, :agent_id))
  end

  # Absent rather than nil: `list_tasks` guards on `is_binary(agent_id)`, so a
  # nil would be harmless, and leaving the key out keeps the frame honest about
  # what is actually known.
  defp put_present(caller, _key, nil), do: caller
  defp put_present(caller, key, value), do: Map.put(caller, key, value)

  # `nil` for a call nobody attributed to an agent — a person at an MCP client,
  # or an agent started before scoping existed. Both could already call
  # everything, and narrowing them here would be a scoping decision applied to
  # somebody who never asked for one.
  defp agent_scope(_scope, nil), do: {nil, nil}

  defp agent_scope(scope, agent_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(agent_id),
         {:ok, agent} <- CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      {CodeMySpec.Agents.tools_of(scope, agent), agent.role}
    else
      # An id that names no agent is a caller pointed at nothing, not a caller
      # to be narrowed: guessing a scope for an agent we cannot find would apply
      # a decision nobody made.
      _ -> {nil, nil}
    end
  end

  # The alert rides the answer, on success and on failure alike. A script that
  # blew up is exactly when knowing the tree is broken matters most, and an
  # agent told only on the happy path finds out least often when it counts.
  # Capped before the alert is appended, not after: the alert is the part that
  # says the tree is broken, and cutting the answer must not cut that off.
  defp render(%Result{} = result, scope, params) do
    if Result.failed?(result) do
      text = AgentAlert.append(CodeMode.cap(failure(result)), scope, params)
      Response.tool() |> Response.error(text)
    else
      text = AgentAlert.append(CodeMode.cap(success(result)), scope, params)
      Response.tool() |> Response.text(text)
    end
  end

  defp success(result) do
    [printed(result), value(result.value)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # The printed lines come with the failure too. Under the no-transaction
  # decision a script that fails halfway has already written, and what it
  # printed on the way is how its author works out which half.
  defp failure(%Result{error: error} = result) do
    [printed(result), "#{error.kind}: #{error.message}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp printed(%Result{printed: []}), do: ""
  defp printed(%Result{printed: lines}), do: "Output:\n" <> Enum.join(lines, "\n")

  defp value(nil), do: ""
  defp value(value) when is_binary(value), do: "Returned:\n" <> value

  defp value(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> "Returned:\n" <> json
      {:error, _reason} -> "Returned:\n" <> inspect(value, pretty: true)
    end
  end
end
