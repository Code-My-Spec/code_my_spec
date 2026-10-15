defmodule CodeMySpec.Tools do
  @moduledoc """
  The contract an agent-facing tool implements, and the operations every
  surface needs from one.

  A tool is a module implementing `CodeMySpec.Tools.Tool`: a name, a
  description, its parameters as a Peri schema, and `call/2`. It knows nothing
  of MCP or a frame, so it lives in its own domain and each surface (code mode,
  in-app agents, an MCP server) adapts it. `CodeMySpec.ToolLibrary` lists them.

  Peri is what Anubis validates with, so a tool's arguments are cast and
  refused exactly as they were when it was an Anubis component.

  See knowledge/tools, "Tool library".
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.Users.Scope], exports: [Tool]

  alias CodeMySpec.Tools.Tool
  alias CodeMySpec.Users.Scope

  @typedoc "Who is calling. `scope` always; the caller's ids when known."
  @type context :: %{
          required(:scope) => Scope.t(),
          optional(:session_id) => String.t(),
          optional(:agent_id) => String.t()
        }

  @doc "The JSON Schema for a tool's arguments, as an MCP client reads it."
  @spec input_schema(module()) :: map()
  def input_schema(tool), do: Peri.to_json_schema(tool.params(), exclude_meta_keys: [:default])

  @doc "Casts and checks arguments against the tool's parameters."
  @spec validate(module(), map()) :: {:ok, map()} | {:error, term()}
  def validate(tool, args), do: Peri.validate(tool.params(), args)

  @doc "Validates `args` and calls the tool."
  @spec run(module(), map(), context()) :: Tool.result()
  def run(tool, args, context) do
    case validate(tool, args) do
      {:ok, params} -> tool.call(params, context)
      {:error, errors} -> {:error, "invalid arguments: #{describe(errors)}"}
    end
  end

  @doc "A changeset's errors as the text an agent is shown."
  @spec changeset_errors(Ecto.Changeset.t()) :: String.t()
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("\n", fn {field, messages} ->
      Enum.map_join(List.wrap(messages), "\n", &"- **#{field}**: #{&1}")
    end)
    |> then(&"## Validation Error\n\n#{&1}")
  end

  defp describe(errors) when is_list(errors), do: Enum.map_join(errors, "; ", &describe/1)

  defp describe(%{path: [_ | _] = path, message: message}),
    do: "#{Enum.join(path, ".")} #{message}"

  defp describe(%{message: message}), do: message
  defp describe(other), do: inspect(other)
end
