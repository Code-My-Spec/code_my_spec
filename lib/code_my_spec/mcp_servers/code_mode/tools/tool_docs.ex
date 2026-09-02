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

  # Only ever used to build entries to *read*, never to call one — the invoker
  # in each is not run from here. Present because the machine catalog is built
  # per deadline, and reading has none.
  @docs_timeout 60_000

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
    name = Map.get(params, :name)
    machine = Layer.machine_catalog(scope, nil, @docs_timeout)

    case Map.has_key?(machine, name) do
      true -> machine_page(machine, name)
      false -> CodeMode.docs(Layer.catalog(scope), opts(params)) <> machine_note(machine)
    end
  end

  # Rendered by the same code that renders ours, off the schema the machine
  # itself published — so the arguments, their types, which of them are required
  # and the runnable example are all real.
  #
  # What this replaced was a paragraph saying the arguments were documented
  # elsewhere, printed by the tool that was supposed to be the elsewhere. The
  # machine had the schemas all along and `list_tool_names/1` mapped them away.
  defp machine_page(machine, name) do
    CodeMode.docs(machine, name: name) <>
      """

      Called from `run_browser_script`, not from `run_script` — the machine's
      tools run in their own sandbox because they wait where the project's tools
      answer immediately.
      """
  end

  defp machine_note(machine) when map_size(machine) == 0, do: ""

  defp machine_note(machine) do
    """

    #{map_size(machine)} more run on this project's machine, in a separate sandbox with
    its own deadline. Call these from `run_browser_script`, not from `run_script`:

    #{machine |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
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
