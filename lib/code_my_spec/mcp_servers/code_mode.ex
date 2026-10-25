defmodule CodeMySpec.McpServers.CodeMode do
  @moduledoc """
  Builds the catalog `CodeMySpec.CodeMode` runs scripts against.

  This is the half that knows about MCP: which tools are registered, how to
  build a frame, and how to read a `Response`. `CodeMode` itself knows none of
  it.

  The registrations come from `ScriptableTools`, not `LocalServer`: the long
  tail is registered there so scripts can reach it without it being advertised.

  ## Scope is captured here

  The catalog is built per call, closing over the scope of the agent that sent
  the script. That is the whole of "a script acts with exactly the authority of
  the agent that sent it": every binding is already bound to a frame before the
  VM exists, and nothing a script can write reaches it.

  ## What a script actually receives

  Data from a tool that implements `ScriptResult.script_result/2`, and the
  tool's prose from one that does not.

  Prose cannot be iterated, so composing over a result is what opting in buys.

  Deliberately **not** `structured_content`: Claude ignores the text beside
  structured data on the wire, so direct calls answer with prose alone. The
  script path is separate and a direct caller never sees it.
  """

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.McpServers.ScriptResult
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.Users.Scope

  @doc "The catalog of tools a script may call, acting as `scope`."
  @spec catalog(term()) :: Catalog.t()
  def catalog(scope), do: catalog(scope, nil, %{})

  @doc """
  The same, scoped to what one agent may call.

  `allowed` is the list on the agent's row — not its role. See
  `CodeMySpec.Agents.ToolSets`.
  """
  @spec catalog(Scope.t(), [String.t()] | nil) :: Catalog.t()
  def catalog(scope, allowed), do: catalog(scope, allowed, %{})

  @doc """
  The same, carrying who is asking.

  `caller` is `%{session_id: …, agent_id: …}`, either key optional, so tools
  that need to know whose work it is (`list_tasks`, `start_task`, …) work from
  a script.

  Two carriers because there are two kinds of caller. An agent we run is
  identified by its connection, so `agent_id` goes on the script's frame; a
  Claude Code session is identified by a `session_id` the `PreToolUse` hook
  injects into tool input, so it is added to the arguments (see
  `identified/3`).
  """
  @spec catalog(Scope.t(), [String.t()] | nil, map()) :: Catalog.t()
  def catalog(scope, allowed, caller) do
    ScriptableTools.registrations()
    |> Catalog.from(&invoker(&1, scope, caller), allowed)
  end

  @doc """
  The machine's tools, as their own catalog.

  Separate from ours because browser tools wait by design (they take
  durations from the caller) while ours are database reads, and one wall clock
  cannot suit both. They run in their own sandbox, entered through
  `run_browser_script`, with a deadline the caller sets; each call gets that
  deadline less `@machine_call_margin_ms`. The machine's tools arrive as one
  tool on the agent, not as their list.

  See knowledge/tools, "Machine tools".
  """
  @spec machine_catalog(Scope.t(), [String.t()] | nil, pos_integer()) :: Catalog.t()
  def machine_catalog(scope, allowed, timeout) do
    docs = machine_tool_docs(scope)

    scope
    |> machine_tool_names(allowed)
    |> Map.new(&{&1, machine_tool(scope, &1, docs[&1], timeout)})
  end

  @doc """
  What the machine reports it can do, scoped to what this agent carries.

  For `tool_docs`, which needs the names without invokers built for them.
  """
  @spec machine_tool_names(Scope.t(), [String.t()] | nil) :: [String.t()]
  def machine_tool_names(scope, allowed \\ nil) do
    scope
    |> machine_tools()
    |> Enum.filter(&permitted?(&1, allowed))
  end

  # The browser is a capability, not a list of names: `@browser_capability` in
  # the agent's list grants the machine's catalog whole, because the names are
  # the machine's and change with its browser server. A matching name is still
  # permitted on its own. See knowledge/tools, "Machine tools".
  @browser_capability "browser"

  @doc "The token that grants an agent the machine's browser tools."
  @spec browser_capability() :: String.t()
  def browser_capability, do: @browser_capability

  defp permitted?(_name, nil), do: true

  defp permitted?(name, allowed) when is_list(allowed),
    do: @browser_capability in allowed or name in allowed

  defp permitted?(_name, _allowed), do: false

  # The tools the agent's working copy reported, today a browser. Their invoker
  # pushes down the channel to that copy, because that is where Chrome is.
  defp machine_tools(%{active_working_copy_id: id}) when is_binary(id) do
    case CodeMySpec.WorkingCopies.fetch(id) do
      {:ok, %{machine_tools: names}} when is_list(names) -> names
      _ -> []
    end
  end

  defp machine_tools(_scope), do: []

  # What the machine said each of its tools takes, reported with the manifest;
  # `%{}` from a harness that sent none, and the tools stay callable.
  defp machine_tool_docs(%{active_working_copy_id: id}) when is_binary(id) do
    case CodeMySpec.WorkingCopies.fetch(id) do
      {:ok, %{machine_tool_docs: docs}} when is_map(docs) -> docs
      _ -> %{}
    end
  end

  defp machine_tool_docs(_scope), do: %{}

  # The call gets the script's budget less a margin, so a hung tool reports as a
  # timeout before the sandbox kills the script and the error with it.
  @machine_call_margin_ms 2_000

  defp machine_tool(scope, name, doc, timeout) do
    call_timeout = max(timeout - @machine_call_margin_ms, 1_000)

    %{
      name: name,
      description: description(doc),
      # `:schema`, the key `Catalog.describe/2` normalises to and `Docs` reads;
      # these entries do not go through `Catalog.from/3`.
      schema: schema(doc),
      # Stated on the entry, not only closed over, so the derived deadline is
      # readable.
      timeout: call_timeout,
      invoke: fn args ->
        Transport.impl().call_machine_tool(
          scope.active_working_copy_id,
          name,
          args,
          own_timeout(args, call_timeout)
        )
      end
    }
  end

  # A call that names its own wait (`browser_click({..., timeout = 5000})`)
  # gets that wait plus the margin, within the script's budget, so a hung click
  # fails as that click instead of running the whole script out (issues
  # 97770e7d, 98410523).
  defp own_timeout(args, call_timeout) do
    case Map.get(args, "timeout", Map.get(args, :timeout)) do
      ms when is_integer(ms) and ms > 0 -> min(ms + @machine_call_margin_ms, call_timeout)
      ms when is_float(ms) and ms > 0 -> min(trunc(ms) + @machine_call_margin_ms, call_timeout)
      _ -> call_timeout
    end
  end

  # The machine's own words when it sent them; the fallback is for a harness
  # that reported names without docs.
  defp description(%{"description" => text}) when is_binary(text) and text != "", do: text

  defp description(_doc) do
    "Runs on this project's machine. This machine has not reported what it " <>
      "takes — reconnect its harness, or call it and read what it asks for."
  end

  defp schema(%{"input_schema" => %{} = schema}) when map_size(schema) > 0, do: schema
  defp schema(_doc), do: %{"type" => "object"}

  @doc "What this agent may not call, of the tools that exist."
  @spec out_of_scope([String.t()] | nil) :: [String.t()]
  def out_of_scope(allowed), do: Catalog.out_of_scope(ScriptableTools.registrations(), allowed)

  defp invoker(tool, scope, caller) do
    frame = %Frame{assigns: Map.put(caller, :current_scope, scope)}

    fn args ->
      args = StoryRefs.normalize_args(Map.get(tool, :input_schema), args)

      with :ok <- known(tool, args),
           {:ok, params} <- validate(tool, identified(tool, args, caller)) do
        execute(tool, params, frame)
      end
    end
  end

  # `session_id` reaches a direct call as an argument, injected into the tool's
  # input by `Hooks.PreToolUse`, so a script has to arrive the same way rather
  # than through the frame — the tools read it from their params and there is no
  # reason for the script path to be the one place that differs.
  #
  # Only where the tool's schema declares it, since unknown arguments are
  # rejected. Never over a session the script named explicitly.
  defp identified(tool, args, %{session_id: session_id}) when is_binary(session_id) do
    if takes_session_id?(tool) and not Map.has_key?(args, "session_id") do
      Map.put(args, "session_id", session_id)
    else
      args
    end
  end

  defp identified(_tool, args, _caller), do: args

  defp takes_session_id?(tool) do
    tool
    |> Map.get(:input_schema, %{})
    |> Map.get("properties", %{})
    |> Map.has_key?("session_id")
  end

  # Validation drops keys the schema does not name, so an unknown argument
  # would silently run the call unfiltered. Checked after
  # `StoryRefs.normalize_args/2` has turned story aliases into declared
  # arguments.
  defp known(tool, args) do
    declared = tool |> Map.get(:input_schema, %{}) |> Map.get("properties", %{})

    case Enum.reject(Map.keys(args), &Map.has_key?(declared, &1)) do
      [] ->
        :ok

      ["_"] ->
        {:invalid_call,
         "arguments go in a table of names — `#{tool.name}({ name = value })`; " <>
           "valid arguments: " <> valid(declared)}

      unknown ->
        {:invalid_call,
         "unknown argument#{if length(unknown) > 1, do: "s"} " <>
           Enum.map_join(unknown, ", ", &"`#{&1}`") <> "; valid arguments: " <> valid(declared)}
    end
  end

  defp valid(declared) when map_size(declared) == 0, do: "none"

  defp valid(declared),
    do: declared |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`")

  # The same casting a real MCP call goes through, so a script is not a laxer
  # door; the schema also turns a Lua number into the integer a tool expects.
  #
  # A rejection is `:invalid_call`, not `:error`: the tool never ran, so the
  # script stops rather than answering from a call that did not happen.
  defp validate(%{validate_input: validate}, args) when is_function(validate, 1) do
    case validate.(args) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:invalid_call, "invalid arguments: #{describe(reason)}"}
    end
  end

  defp validate(_tool, args), do: {:ok, args}

  # Data when the tool implements `script_result/2`, prose otherwise.
  # A domain's tool (`CodeMySpec.ToolLibrary`) takes no frame, only who asks.
  defp execute(%{tool: tool}, params, frame) do
    context =
      frame.assigns
      |> Map.take([:session_id, :agent_id, :working_dir])
      |> Map.put(:scope, frame.assigns.current_scope)

    result =
      if function_exported?(Code.ensure_loaded!(tool), :script_result, 2),
        do: tool.script_result(params, context),
        else: tool.call(params, context)

    case result do
      {:error, reason} -> {:error, describe(reason)}
      ok -> ok
    end
  end

  defp execute(tool, params, frame) do
    if ScriptResult.implemented?(tool.handler),
      do: script_result(tool, params, frame),
      else: reply(tool, params, frame)
  end

  defp script_result(tool, params, frame) do
    case tool.handler.script_result(params, frame) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp reply(tool, params, frame) do
    case tool.handler.execute(params, frame) do
      {:reply, response, _frame} -> read(response)
      {:error, reason, _frame} -> {:error, describe(reason)}
      other -> {:error, "unexpected reply from #{tool.name}: #{inspect(other)}"}
    end
  end

  # `isError` is the tool saying it could not do the thing, which is a `nil,
  # err` pair in the script rather than a crash — the script decides whether
  # that ends its work.
  defp read(%Response{isError: true} = response), do: {:error, text(response)}
  defp read(%Response{structured_content: nil} = response), do: {:ok, text(response)}
  defp read(%Response{structured_content: structured}), do: {:ok, structured}

  defp text(%Response{} = response) do
    response
    |> Response.to_protocol()
    |> Map.get("content", [])
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp describe(reason) when is_binary(reason), do: reason

  # Validation errors are structs around one readable sentence. Pull the
  # sentence out and name the field rather than `inspect/1` the struct into the
  # agent's context.
  defp describe(errors) when is_list(errors) do
    case Enum.map(errors, &describe/1) do
      [] -> "invalid"
      described -> Enum.join(described, "; ")
    end
  end

  defp describe(%{message: message} = error) when is_binary(message) do
    case field(error) do
      nil -> message
      name -> "#{name} #{message}"
    end
  end

  defp describe(reason), do: inspect(reason)

  defp field(%{path: [name | _rest]}), do: name
  defp field(%{key: name}) when not is_nil(name), do: name
  defp field(_error), do: nil
end
