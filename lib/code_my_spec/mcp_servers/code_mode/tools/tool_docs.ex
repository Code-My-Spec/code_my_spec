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
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.Validators

  # Only ever used to build entries to *read*, never to call one — the invoker
  # in each is not run from here. Present because the machine catalog is built
  # per deadline, and reading has none.
  @docs_timeout 60_000

  schema do
    field :name, :string, description: "A tool name, for its full documentation"

    field :names, {:list, :string},
      description: "Several tool names at once. Use instead of `name`, not with it"

    field :search, :string,
      description: "Search tool names and descriptions. Ignored when a name is given"
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
    machine = Layer.machine_catalog(scope, nil, @docs_timeout)

    case requested_names(params) do
      [] -> CodeMode.docs(Layer.catalog(scope), opts(params)) <> machine_note(machine)
      [one] -> page(scope, machine, one)
      many -> Enum.map_join(many, "\n\n---\n\n", &page(scope, machine, &1))
    end
  end

  # `names` as well as `name`, because agents ask about several at once and this
  # took one.
  #
  # A key the schema does not declare is dropped, so `tool_docs({ names = [...]
  # })` arrived as no arguments at all and answered with the general catalog —
  # confidently, and about everything except what was asked. Reported as
  # `684a54ee`: "tool_docs ignores requested tool names, always returns the
  # general catalog instead."
  #
  # Watched cost it on 2026-09-07: a QA agent guessed `browser_list_pages`, asked
  # `tool_docs` about it and four real browser tools, got the catalog, and was no
  # closer to learning that the name it guessed does not exist.
  defp requested_names(params) do
    [Map.get(params, :name)]
    |> Enum.concat(List.wrap(Map.get(params, :names)))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  # One tool's page, from whichever catalog holds it.
  #
  # A name in neither is said so plainly. That is the whole point of asking: an
  # agent that guessed needs to hear it guessed, and the catalog it used to get
  # back reads as an answer.
  defp page(scope, machine, name) do
    cond do
      Map.has_key?(machine, name) ->
        machine_page(machine, name)

      Map.has_key?(Layer.catalog(scope), name) ->
        CodeMode.docs(Layer.catalog(scope), name: name)

      direct?(name) ->
        direct_page(name)

      true ->
        "`#{name}` is not a tool on this project or this machine. " <>
          "Call `tool_docs` with `search` to find what is."
    end
  end

  # A tool that is real but not scriptable.
  #
  # `LocalServer` keeps a handful of tools off `run_script` on purpose —
  # `ask_user` waits on a person, `start_agent` spawns — and `CodeMode.Catalog`
  # refuses to bind them. They are still tools, in the caller's tool list, one
  # direct call away.
  #
  # This branch exists because the fallback below told an agent that
  # `start_agent` "is not a tool on this project or this machine" while
  # `start_agent` was sitting in its own tool list. Reported as
  # `5473a1f9`: "tool_docs says start_agent and stop_agent are unavailable even
  # though they are exposed as tools, creating contradictory capability
  # discovery."
  #
  # The false half is what makes it expensive. An agent that hears "no such
  # tool" stops looking and works around the absence; one that hears "not from a
  # script" calls it. `LocalServer.moved?/1` already answers the mirror-image
  # question — a scriptable tool called directly — and this is that answer
  # pointing the other way.
  defp direct?(name), do: Enum.any?(LocalServer.__components__(), &(&1.name == name))

  defp direct_page(name) do
    """
    `#{name}` is a tool on this server, but not one `run_script` can call.

    Call it directly, the way you call `run_script` itself — its schema is
    already in your tool list. A few tools are kept out of scripts on purpose:
    they wait on a person, or they spawn something, and neither belongs inside
    a sandbox with a deadline.

    `tool_docs` documents the scriptable catalog, which is why there is no page
    for it here.
    """
    |> String.trim()
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
