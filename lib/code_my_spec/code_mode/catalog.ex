defmodule CodeMySpec.CodeMode.Catalog do
  @moduledoc """
  Which tools a script may call, and what each one's arguments are.

  ## The list is handed in, not read

  The obvious implementation reads `LocalServer.__components__/0` directly, and
  Boundary refused it: `McpServers` is a top-level boundary that depends on
  `CodeMySpec`, so a context reaching back into the server is the arrow pointing
  the wrong way. The refusal was right. A runtime that fetches its own tool list
  from a server can only be tested with that server standing up; one that is
  handed a list can be tested with two fake tools, which is what the tests here
  do.

  So the MCP layer — which already knows the server — builds the catalog and
  passes it in.

  ## Nothing here re-derives what already exists

  Anubis registrations carry all of it: a name, the description that is the
  tool's documentation, the JSON Schema for its arguments, the module that runs
  it, and the same input validation a real MCP call goes through. That is why
  code mode is cheap here and was not for the Ash implementation it was adapted
  from — that one had to build the introspection first.

  ## What is excluded, and why by behaviour rather than by name

  A tool that blocks on a person or spawns background work means something
  different inside a loop than a read does. `ask_user` waits on a human; twenty
  of them in a `for` is twenty questions nobody agreed to answer. `start_agent`
  spawns; a loop is a fleet.

  Those stay direct-call only. Story 971 carries the consequence: an excluded
  tool has to stay on the spine, or excluding it here makes it unreachable
  altogether.
  """

  @excluded ~w(
    ask_user
    check_answer
    list_user_questions
    start_agent
    assign_subagent
    stop_agent
    message_agent
    tap_out
    show_in_panel
  )

  @type invoke :: (map() -> {:ok, term()} | {:error, String.t()})

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          schema: map(),
          invoke: invoke()
        }

  @type t :: %{String.t() => tool()}

  @doc """
  A catalog from a list of registered tools, minus the ones a script may not
  call.

  `build_invoke` is given each registration and returns the function that
  actually runs that tool. It is a parameter rather than something this module
  does, and that is the second half of the boundary point above: running an
  Anubis tool means building a frame and reading a `Response`, which is the MCP
  layer's knowledge. Passing the invoker in leaves this module — and everything
  under `CodeMode` — free of Anubis entirely, and lets a test supply two tools
  that are just functions.

  Registrations are read structurally (`:name`, `:description`,
  `:input_schema`), so nothing here names the struct either.
  """
  @spec from(Enumerable.t(), (term() -> invoke())) :: t()
  def from(registered, build_invoke) when is_function(build_invoke, 1) do
    registered
    |> Enum.map(&describe(&1, build_invoke))
    |> Enum.reject(&(&1.name in @excluded))
    |> Map.new(&{&1.name, &1})
  end

  @doc "One tool by name."
  @spec fetch(t(), String.t()) :: {:ok, tool()} | :error
  def fetch(catalog, name) when is_binary(name), do: Map.fetch(catalog, name)

  @doc "Every tool name in the catalog, sorted."
  @spec names(t()) :: [String.t()]
  def names(catalog), do: catalog |> Map.keys() |> Enum.sort()

  @doc """
  Tool names a script may not call.

  Public because the refusal an agent reads has to name them, and because story
  971's rule — every excluded tool is on the spine — is only checkable against
  a list something else can read.
  """
  @spec excluded() :: [String.t()]
  def excluded, do: @excluded

  defp describe(tool, build_invoke) do
    %{
      name: to_string(Map.fetch!(tool, :name)),
      description: Map.get(tool, :description) || "",
      schema: Map.get(tool, :input_schema) || %{},
      invoke: build_invoke.(tool)
    }
  end
end
