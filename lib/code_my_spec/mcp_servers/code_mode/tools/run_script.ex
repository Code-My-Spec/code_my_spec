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
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.Validators

  schema do
    field :script, :string,
      required: true,
      description: "Lua source. Return a value to get it back; use print() for progress."
  end

  @impl true
  def execute(%{script: script}, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        result = CodeMode.eval(Layer.catalog(scope), script)
        {:reply, render(result), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
  end

  defp render(%Result{} = result) do
    case Result.failed?(result) do
      true -> Response.tool() |> Response.error(failure(result))
      false -> Response.tool() |> Response.text(success(result))
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
