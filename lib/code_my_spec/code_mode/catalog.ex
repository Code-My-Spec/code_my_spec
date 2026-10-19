defmodule CodeMySpec.CodeMode.Catalog do
  @moduledoc """
  Which tools a script may call, and what each one's arguments are.

  ## The list is handed in, not read

  The MCP layer, which knows the server, builds the catalog and passes it in.
  Reading `LocalServer` from here would point the Boundary arrow the wrong way,
  and a handed-in list lets tests use fake tools.

  ## Nothing here re-derives what already exists

  Anubis registrations carry all of it: a name, the description that is the
  tool's documentation, the JSON Schema for its arguments, the module that runs
  it, and the same input validation a real MCP call goes through.

  ## What is excluded

  A tool that blocks on a person, spawns background work, or dispositions the
  caller's own turn means something different inside a loop than a read does.
  The workflow spine (`get_next_requirement`, `start_task`, `evaluate_task`,
  `sync_project`, `cancel_task`, `promote`) is excluded because the caller
  already has it directly. Code mode's own tools are excluded so a script
  cannot nest a VM inside a tool call. Every excluded tool must stay directly
  callable, or excluding it here makes it unreachable.

  The agent lifecycle (`start_agent`, `turn_off_agent`, …) is scriptable; who
  may manage the fleet is a role grant in `ToolSets`.

  See knowledge/tools, "Exclusions".
  """

  # Name to the reason a script may not call it. The reason is what an agent is
  # told when it tries, so it must say where the tool actually is.
  @excluded %{
    "ask_question" =>
      "it waits on a person, and a loop around it is questions nobody agreed to answer",
    "check_answer" => "it belongs with the asking tools, which a script cannot call",
    "list_user_questions" => "it belongs with the asking tools, which a script cannot call",
    "start_analysis" =>
      "it spawns a sweep that runs for minutes, and a loop around it is a queue " <>
        "of them nobody asked for",
    "tap_out" => "it ends your turn, which is yours to do and not a script's",
    "reject_offer" =>
      "declining work is a decision about your own turn, made once, not a script's",
    "show_in_panel" => "it puts something in front of a person, who is not watching a script",
    "run_script" =>
      "you are already in one — a script starting a script nests a VM inside a tool call",
    "tool_docs" => "read the documentation before writing the script, not from inside it",

    # The spine: already a direct tool, so going through Lua buys nothing. The
    # reason says so, because an agent told the wrong reason looks in the
    # wrong place.
    "promote" =>
      "you already have it directly — call it as a tool. It returns at once and " <>
        "messages you the outcome, so a script would have nothing to wait for",
    "promote_sync" =>
      "it blocks for the length of a merge, an analyzer sweep and an application " <>
        "restart, which outlives any script. You are an agent: use `promote`, " <>
        "which answers immediately and tells you when it lands",
    "get_next_requirement" =>
      "it is one of the four tools you already have directly — call it as a tool",
    "sync_project" => "it is one of the four tools you already have directly — call it as a tool",
    "start_task" => "it is one of the four tools you already have directly — call it as a tool",
    "evaluate_task" =>
      "it is one of the four tools you already have directly — call it as a tool",

    # A disposition of the held task, like `evaluate_task`.
    "cancel_task" =>
      "it dispositions the task you are holding, which you already have directly — " <>
        "call it as a tool"
  }

  # `:error` is the tool saying it could not do the thing; a script decides what
  # that means. `:invalid_call` is the call itself being wrong: the tool never
  # ran, so the script stops.
  @type invoke :: (map() -> {:ok, term()} | {:error, String.t()} | {:invalid_call, String.t()})

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
  runs that tool. Running an Anubis tool (a frame, a `Response`) is the MCP
  layer's knowledge, so passing the invoker in keeps `CodeMode` free of Anubis
  and lets a test supply plain functions.

  Registrations are read structurally (`:name`, `:description`,
  `:input_schema`), so nothing here names the struct either.
  """
  @spec from(Enumerable.t(), (term() -> invoke())) :: t()
  def from(registered, build_invoke), do: from(registered, build_invoke, nil)

  @doc """
  The same, scoped to what one agent may call.

  `allowed` is a list of names, or `nil` for a caller with no scoping (it may
  call everything). A list rather than a role, so an exception is a different
  list on one row.

  Out-of-scope tools are removed here and named by `out_of_scope/2`, so
  `Bindings` can bind each to a stub that says why.
  """
  @spec from(Enumerable.t(), (term() -> invoke()), [String.t()] | nil) :: t()
  def from(registered, build_invoke, allowed) when is_function(build_invoke, 1) do
    registered
    |> Enum.map(&describe(&1, build_invoke))
    |> Enum.reject(&Map.has_key?(@excluded, &1.name))
    |> Enum.filter(&in_scope?(&1.name, allowed))
    |> Map.new(&{&1.name, &1})
  end

  @doc """
  Names this agent may not call, of the ones that exist.

  Separate from `excluded/0`: that is "no script may call this, ever", and this
  is "not for an agent of this kind". They want different sentences.
  """
  @spec out_of_scope(Enumerable.t(), [String.t()] | nil) :: [String.t()]
  def out_of_scope(_registered, nil), do: []

  def out_of_scope(registered, allowed) do
    registered
    # A registration is a map (the shape `describe/2` reads), not a module.
    |> Enum.map(&to_string(Map.fetch!(&1, :name)))
    |> Enum.reject(&(Map.has_key?(@excluded, &1) or &1 in allowed))
    |> Enum.sort()
  end

  defp in_scope?(_name, nil), do: true
  defp in_scope?(name, allowed), do: name in allowed

  @doc """
  Registered tools that are not scriptable and not this caller's to call.

  The third group beside `out_of_scope/2` (scriptable, withheld from the role)
  and `excluded/0` (no script may call). `registered` is anything with a
  `:name`; `nil` for `allowed` answers `[]`. Computed rather than named,
  because the spine and each role's grant change without this module.
  """
  @spec direct_only(Enumerable.t(), [String.t()] | nil) :: [String.t()]
  def direct_only(registered, allowed \\ nil)

  def direct_only(_registered, nil), do: []

  def direct_only(registered, allowed) do
    registered
    |> Enum.map(&to_string(Map.fetch!(&1, :name)))
    |> Enum.uniq()
    |> Enum.reject(&(Map.has_key?(@excluded, &1) or &1 in allowed))
    |> Enum.sort()
  end

  @doc "One tool by name."
  @spec fetch(t(), String.t()) :: {:ok, tool()} | :error
  def fetch(catalog, name) when is_binary(name), do: Map.fetch(catalog, name)

  @doc "Every tool name in the catalog, sorted."
  @spec names(t()) :: [String.t()]
  def names(catalog), do: catalog |> Map.keys() |> Enum.sort()

  @doc """
  Tool names a script may not call.

  Public because the refusal an agent reads names them, and because the rule
  that every excluded tool stays directly callable is checked against it.
  """
  @spec excluded() :: [String.t()]
  def excluded, do: @excluded |> Map.keys() |> Enum.sort()

  @doc "Why that tool is not callable from a script, in a sentence."
  @spec exclusion_reason(String.t()) :: String.t() | nil
  def exclusion_reason(name), do: Map.get(@excluded, name)

  defp describe(tool, build_invoke) do
    %{
      name: to_string(Map.fetch!(tool, :name)),
      description: Map.get(tool, :description) || "",
      schema: Map.get(tool, :input_schema) || %{},
      invoke: build_invoke.(tool)
    }
  end
end
