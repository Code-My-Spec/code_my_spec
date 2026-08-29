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
        docs = CodeMode.docs(Layer.catalog(scope), opts(params))
        {:reply, Response.tool() |> Response.text(docs), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{inspect(reason)}"), frame}
    end
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
