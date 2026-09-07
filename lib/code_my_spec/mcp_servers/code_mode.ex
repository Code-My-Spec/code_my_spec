defmodule CodeMySpec.McpServers.CodeMode do
  @moduledoc """
  Builds the catalog `CodeMySpec.CodeMode` runs scripts against.

  This is the half that knows about MCP: which tools are registered, how to
  build a frame, and how to read a `Response`. `CodeMode` itself knows none of
  it — Boundary saw to that, and it is why the runtime's tests need two fake
  tools rather than a server.

  The registrations come from `ScriptableTools`, not `LocalServer`. Story 971
  took the long tail off the advertised list, and taking them off `LocalServer`
  alone would have taken them away from scripts too — unregistered is
  unreachable, not merely unadvertised.

  ## Scope is captured here

  The catalog is built per call, closing over the scope of the agent that sent
  the script. That is the whole of "a script acts with exactly the authority of
  the agent that sent it": every binding is already bound to a frame before the
  VM exists, and nothing a script can write reaches it.

  ## What a script actually receives

  Data from a tool that implements `ScriptResult.script_result/2`, and the
  tool's prose from one that does not.

  The prose fallback is not a degraded mode; it is what every tool gave scripts
  before that callback existed. What it cannot do is be iterated — a formatted
  listing is a string — so composing over a result is exactly what opting in
  buys.

  Deliberately **not** `structured_content`. Anubis can put structured data on
  the wire, and Claude then ignores the text beside it — measured, and the
  reason every tool here answers with prose alone. Serving scripts that way
  would make every direct tool call pay for it. The script path is separate and
  a direct caller never sees it.
  """

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.McpServers.ScriptResult
  alias CodeMySpec.Users.Scope

  @doc "The catalog of tools a script may call, acting as `scope`."
  @spec catalog(term()) :: Catalog.t()
  def catalog(scope), do: catalog(scope, nil)

  @doc """
  The same, scoped to what one agent may call.

  `allowed` is the list on the agent's row — not its role. See
  `CodeMySpec.Agents.ToolSets`.
  """
  @spec catalog(Scope.t(), [String.t()] | nil) :: Catalog.t()
  def catalog(scope, allowed) do
    ScriptableTools.__components__()
    |> Catalog.from(&invoker(&1, scope), allowed)
  end

  @doc """
  The machine's tools, as their own catalog.

  Separated from ours because they are a different kind of thing under a wall
  clock. Roughly eighty-five of the tools reachable from a script are the
  browser's, and several of them *wait by design* — `browser_wait_for_text`,
  `browser_wait_for_url`, `browser_sleep` all take a duration from the caller,
  and `browser_start` has been seen taking the better part of an hour. Ours are
  database reads.

  One wall clock cannot be right for both, and the old arrangement made that
  concrete: this catalog's calls were given a hardcoded 30s while the sandwich
  around them was also 30s, so they expired together and a browser call that
  used its budget left the script no time to do anything with the answer — if
  the brutal kill even let the timeout's error return.

  So they get their own sandbox, entered through `run_browser_script`, with a
  deadline the caller sets. John's call: they have very different properties and
  do not need to interact with our tools in one script.

  Costs exactly one tool on the agent. Story 1038's criterion 3017 asks that a
  third-party MCP server "arrives as one tool, not as its list" and the previous
  design beat it by arriving as none; this gives that up and still satisfies the
  rule, at one schema against eighty-five.
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

  `tool_docs` wants the names without invokers built for them — its job is to
  say a tool exists and where it is called from, and after the split the where
  is an answer worth giving.
  """
  @spec machine_tool_names(Scope.t(), [String.t()] | nil) :: [String.t()]
  def machine_tool_names(scope, allowed \\ nil) do
    scope
    |> machine_tools()
    |> Enum.filter(&permitted?(&1, allowed))
  end

  # The agent's list is about *our* tools, and this filters the *machine's*.
  #
  # Those are two vocabularies with nothing in common, so filtering one by the
  # other let exactly one thing through: nothing. An agent with no list got
  # every browser tool and an agent with any list got none — and the one whose
  # entire job is a browser had a list. On 2026-09-07 the war-epic QA agent's
  # browser sandbox bound 27 project tools, the exclusion stubs, and not one of
  # the 85 browser tools its machine was reporting as `ready`.
  #
  # So the browser is a capability rather than 85 names. `@browser_capability`
  # in the agent's list grants the machine's catalog whole, which is the only
  # useful grain: the names are published by the machine, change when the
  # browser server changes, and a role that may drive a browser may drive it.
  #
  # Per-name grants still work — a name that matches is still permitted — so a
  # future "this agent may only read the page" stays expressible without
  # unpicking this.
  @browser_capability "browser"

  @doc "The token that grants an agent the machine's browser tools."
  @spec browser_capability() :: String.t()
  def browser_capability, do: @browser_capability

  defp permitted?(_name, nil), do: true

  defp permitted?(name, allowed) when is_list(allowed),
    do: @browser_capability in allowed or name in allowed

  defp permitted?(_name, _allowed), do: false

  # The tools that live on the agent's machine — a browser, today.
  #
  # Mounted the same way ours are, which is the whole of criterion 3017: they go
  # into the catalog a script already reaches rather than onto the agent, so
  # twenty-nine browser schemas never reach a turn. Their invoker pushes down
  # the channel to the copy that reported them, because that is where Chrome is.
  #
  # Only the ones the agent carries. `allowed` is the list on its row, and a
  # machine tool it was not given is out of scope for the same reason one of
  # ours is.

  defp machine_tools(%{active_working_copy_id: id}) when is_binary(id) do
    case CodeMySpec.WorkingCopies.fetch(id) do
      {:ok, %{machine_tools: names}} when is_list(names) -> names
      _ -> []
    end
  end

  defp machine_tools(_scope), do: []

  # What the machine said each of its tools takes, reported with the manifest.
  #
  # `%{}` for a harness too old to have sent them, which is the case every entry
  # below has to survive: the tool is still callable, and what it takes is a
  # question only its own machine can answer.
  defp machine_tool_docs(%{active_working_copy_id: id}) when is_binary(id) do
    case CodeMySpec.WorkingCopies.fetch(id) do
      {:ok, %{machine_tool_docs: docs}} when is_map(docs) -> docs
      _ -> %{}
    end
  end

  defp machine_tool_docs(_scope), do: %{}

  # The call gets the script's budget less a margin, so a hung tool reports as a
  # timeout instead of being taken out by the sandbox at the same instant. They
  # used to be the same number, which meant whichever fired first the caller
  # could not tell which, and the brutal kill could take the error with it.
  @machine_call_margin_ms 2_000

  defp machine_tool(scope, name, doc, timeout) do
    call_timeout = max(timeout - @machine_call_margin_ms, 1_000)

    %{
      name: name,
      description: description(doc),
      # `:schema`, which is what `Catalog.describe/2` normalises `:input_schema`
      # into and what `Docs` reads. These entries are built here rather than
      # through `Catalog.from/3`, so the normalisation does not happen to them —
      # and the old key meant `tool_docs({name = "browser_click"})` would have
      # raised `KeyError` if anything had reached it.
      schema: schema(doc),
      # Stated on the entry, not only closed over. The deadline is derived, and
      # a derivation nothing can read is how the inner call and the sandbox
      # around it came to be the same thirty seconds with nobody noticing.
      timeout: call_timeout,
      invoke: fn args ->
        Transport.impl().call_machine_tool(
          scope.active_working_copy_id,
          name,
          args,
          call_timeout
        )
      end
    }
  end

  # The machine's own words when it sent them. The fallback is what every
  # machine tool used to say — and it pointed at `tool_docs`, which had nothing
  # to answer with, because the names arrived without the schemas beside them.
  # Now that they arrive together, the pointer is only for a harness that has
  # not reconnected since.
  defp description(%{"description" => text}) when is_binary(text) and text != "", do: text

  defp description(_doc) do
    "Runs on this project's machine. This machine has not reported what it " <>
      "takes — reconnect its harness, or call it and read what it asks for."
  end

  defp schema(%{"input_schema" => %{} = schema}) when map_size(schema) > 0, do: schema
  defp schema(_doc), do: %{"type" => "object"}

  @doc "What this agent may not call, of the tools that exist."
  @spec out_of_scope([String.t()] | nil) :: [String.t()]
  def out_of_scope(allowed), do: Catalog.out_of_scope(ScriptableTools.__components__(), allowed)

  defp invoker(tool, scope) do
    frame = %Frame{assigns: %{current_scope: scope}}

    fn args ->
      with {:ok, params} <- validate(tool, args) do
        execute(tool, params, frame)
      end
    end
  end

  # The same casting a real MCP call goes through. Skipping it would make a
  # script a second, laxer door onto the same tools, and the casting is
  # load-bearing besides — the schema is what turns a Lua number into the
  # integer a tool expects.
  defp validate(%{validate_input: validate}, args) when is_function(validate, 1) do
    case validate.(args) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, "invalid arguments: #{describe(reason)}"}
    end
  end

  defp validate(_tool, args), do: {:ok, args}

  # Data when the tool can give it, prose when it cannot. The fallback is not a
  # degraded mode — it is what every tool gave scripts before `script_result/2`
  # existed, and most still do.
  defp execute(tool, params, frame) do
    case ScriptResult.implemented?(tool.handler) do
      true -> script_result(tool, params, frame)
      false -> reply(tool, params, frame)
    end
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

  # Validation errors arrive as structs carrying a readable sentence and a lot
  # of machinery around it. `inspect/1` on the struct puts the machinery in the
  # agent's context and buries the sentence — and in a loop, twenty times. Pull
  # the sentence out, name the field, drop the rest.
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
