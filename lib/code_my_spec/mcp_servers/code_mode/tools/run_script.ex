defmodule CodeMySpec.McpServers.CodeMode.Tools.RunScript do
  @moduledoc """
  Run a Lua script that calls this harness's tools.

  Use this to do several steps in one turn instead of one tool call per step —
  read a list, look at each item, and return only what you needed. Every tool
  is a function taking one table:

      local story = get_story({ story_id = 970 })
      print("checking", story.title)
      return story.title

  A tool that cannot answer returns nil and an error table rather than stopping
  the script, so a loop can report what it could not find:

      local story, err = get_story({ story_id = 12345 })
      if story == nil then return "missing: " .. err.message end

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
  end

  @impl true
  def execute(%{script: script} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # Which tools, read off the agent's row rather than worked out from its
        # role. The caller names *which* agent it is; the server decides what
        # that agent may do, so naming a different one cannot invent
        # permissions — it can only borrow another agent's, and both are ours.
        {allowed, kind} = agent_scope(scope, Map.get(params, :agent_id))

        result =
          CodeMode.eval(Layer.catalog(scope, allowed), script,
            out_of_scope: Layer.out_of_scope(allowed),
            agent_kind: kind
          )

        {:reply, render(result, scope, params), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  # `nil` for a call nobody attributed to an agent — a person at an MCP client,
  # or an agent started before scoping existed. Both could already call
  # everything, and narrowing them here would be a scoping decision applied to
  # somebody who never asked for one.
  defp agent_scope(_scope, nil), do: {nil, nil}

  defp agent_scope(scope, agent_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(agent_id),
         {:ok, agent} <- CodeMySpec.Agents.fetch_agent(scope, agent_id) do
      {agent.tools, agent.role}
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
    case Result.failed?(result) do
      true ->
        text = AgentAlert.append(CodeMode.cap(failure(result)), scope, params)
        Response.tool() |> Response.error(text)

      false ->
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
