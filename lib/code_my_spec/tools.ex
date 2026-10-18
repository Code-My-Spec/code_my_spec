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
          optional(:agent_id) => String.t(),
          optional(:working_dir) => String.t()
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

  @doc "The caller's scope, when it names a project: what a project's tool needs."
  @spec project_scope(context()) :: {:ok, Scope.t()} | {:error, :missing_active_project}
  def project_scope(%{scope: %{active_project_id: id} = scope}) when not is_nil(id),
    do: {:ok, scope}

  def project_scope(_context), do: {:error, :missing_active_project}

  @doc """
  A failure every tool can have, as the agent is told it. A domain answers its
  own reasons first and hands the rest here.
  """
  @spec error(term()) :: {:error, String.t()}
  def error(%Ecto.Changeset{} = changeset), do: {:error, changeset_errors(changeset)}

  def error(:story_not_found),
    do: {:error, "Story not found in the active project. list_story_titles shows the numbers."}

  def error(:missing_active_project),
    do:
      {:error,
       "Active project is not set on the scope. " <>
         "Run `init_project` to link your working directory to a project, then retry."}

  def error(reason) when is_binary(reason), do: {:error, reason}
  def error(reason) when is_atom(reason), do: {:error, to_string(reason)}
  def error(reason), do: {:error, inspect(reason)}

  @doc """
  The reply a tool that needs the project's files gives when this machine has
  none, saying what to do instead rather than only what failed.
  """
  @spec no_working_copy_message(String.t()) :: String.t()
  def no_working_copy_message(tool) do
    """
    `#{tool}` needs the project's files, and this server does not have them.

    The working copy lives on the harness — that is the design, not a \
    misconfiguration. Write the file there yourself; the harness syncs it back \
    and the requirement will clear on the next evaluation.

    (If you expected this server to hold the project, it was started without \
    CMS_MCP_WORKING_DIR.)\
    """
  end

  @doc "A changeset's errors as the text an agent is shown, with a hint where one helps."
  @spec changeset_errors(Ecto.Changeset.t()) :: String.t()
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    errors = changeset_error_map(changeset)

    error_lines =
      Enum.map_join(errors, "\n", fn {field, messages} ->
        Enum.map_join(messages, "\n", fn msg -> "- **#{field}**: #{msg}" end)
      end)

    """
    ## Validation Error

    #{error_lines}

    #{fix_guidance(errors)}
    """
    |> String.trim()
  end

  @doc "A changeset's errors by field, messages interpolated."
  @spec changeset_error_map(Ecto.Changeset.t()) :: map()
  def changeset_error_map(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp fix_guidance(errors) do
    hints =
      errors
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &field_hint(field, &1)) end)
      |> Enum.reject(&is_nil/1)

    if hints == [], do: "", else: "### How to fix\n#{Enum.join(hints, "\n")}"
  end

  defp field_hint(:title, "can't be blank"), do: "- Provide a non-empty title string"
  defp field_hint(:description, "can't be blank"), do: "- Provide a description of the story"

  defp field_hint(:acceptance_criteria, msg) when is_binary(msg) do
    if String.contains?(msg, "at least"),
      do: "- Provide at least one acceptance criterion as a list of strings"
  end

  defp field_hint(_, _), do: nil

  defp describe(errors) when is_list(errors), do: Enum.map_join(errors, "; ", &describe/1)

  defp describe(%{path: [_ | _] = path, message: message}),
    do: "#{Enum.join(path, ".")} #{message}"

  defp describe(%{message: message}), do: message
  defp describe(other), do: inspect(other)
end
