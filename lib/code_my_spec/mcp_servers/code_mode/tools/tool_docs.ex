defmodule CodeMySpec.McpServers.CodeMode.Tools.ToolDocs do
  @moduledoc """
  What tools `run_script` can call, and what each one takes.

  Call with nothing for the index — every tool and a one-line summary. Call
  with `name` for one tool's arguments and a runnable example. Call with
  `search` when you know what you want to do but not what it is called.

  This exists so the arguments are looked up when they are needed rather than
  carried in context the whole session.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.CodeMode
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.Validators

  schema do
    field :name, :string, description: "A tool name, for its full documentation"

    field :search, :string,
      description: "Search tool names and descriptions. Ignored when name is given"
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, Response.tool() |> Response.text(docs(scope, params)), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  # Two sandboxes, one index. The machine's tools are not in `run_script`'s
  # catalog any more, and leaving them out of here as well would make
  # eighty-five tools undiscoverable — an agent has no other way to learn that
  # `browser_wait_for_text` exists. So they are named, and named as belonging
  # somewhere else, which is the part a bare listing would get wrong.
  defp docs(scope, params) do
    machine = Layer.machine_tool_names(scope)
    name = Map.get(params, :name)

    case name in machine do
      true -> machine_page(name)
      false -> CodeMode.docs(Layer.catalog(scope), opts(params)) <> machine_note(machine)
    end
  end

  # No schema to render: the machine reports names, not arguments. Saying so is
  # better than a page of empty headings, and the browser's own documentation is
  # where the arguments actually are.
  defp machine_page(name) do
    """
    # #{name}

    Runs on this project's machine, in the browser sandbox. It is not callable
    from `run_script` — call it from `run_browser_script`, which takes its own
    `timeout` because browser tools wait where ours answer immediately.

    ```lua
    local result, err = #{name}({})
    if result == nil then return "failed: " .. err.message end
    return result
    ```

    The machine reports these tools by name only, so their arguments are not
    described here. They are the browser's own — a selector, a url, a timeout —
    and a call with the wrong ones answers with what it wanted.
    """
  end

  defp machine_note([]), do: ""

  defp machine_note(names) do
    """

    #{length(names)} more run on this project's machine, in a separate sandbox with
    its own deadline. Call these from `run_browser_script`, not from `run_script`:

    #{Enum.join(names, ", ")}
    """
  end

  defp opts(params) do
    []
    |> put(:name, Map.get(params, :name))
    |> put(:search, Map.get(params, :search))
  end

  defp put(opts, _key, nil), do: opts
  defp put(opts, _key, ""), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
