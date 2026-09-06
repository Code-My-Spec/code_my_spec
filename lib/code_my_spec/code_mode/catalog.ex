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

  `message_agent` was excluded on that reasoning too — "it acts on agents, which
  a script cannot start" — and the premise stopped being true. Agents get their
  work by role, routed to them, rather than by being spawned on request; what one
  agent needs of another is not the ability to start it but the ability to talk
  to it. A loop around a message is noise, which is a smaller thing than a fleet
  and bounded by the agents that already exist. So it is scriptable, and
  `start_agent`, `stop_agent` and `assign_subagent` are not.

  Those stay direct-call only. Story 971 carries the consequence: an excluded
  tool has to stay on the spine, or excluding it here makes it unreachable
  altogether.

  Code mode's own two tools are excluded for a different reason. The catalog is
  built from every tool the server registers, which after registration includes
  `run_script` — so without this a script could call `run_script`, and that one
  could call it again, each nesting a fresh VM inside a tool call of the last.
  The limits are per-evaluation and would not see it.
  """

  # Name to the reason a script may not call it. The reason is not decoration:
  # it is what an agent is told when it tries, and "attempt to call a nil value
  # (global 'ask_user')" — which is what absence alone produces — reads like a
  # typo in the script rather than a rule about the tool. QA on story 970 found
  # an agent would most likely try spelling variations rather than learn.
  @excluded %{
    "ask_user_question" =>
      "it waits on a person, and a loop around it is questions nobody agreed to answer",
    "send_message" => "it waits on a person, the same as `ask_user_question`",
    "check_answer" => "it belongs with the asking tools, which a script cannot call",
    "list_user_questions" => "it belongs with the asking tools, which a script cannot call",
    "start_agent" => "it spawns background work, and a loop around it is a fleet",
    "assign_subagent" => "it spawns background work, and a loop around it is a fleet",
    "stop_agent" => "it acts on agents, which a script cannot start",
    "tap_out" => "it ends your turn, which is yours to do and not a script's",
    "show_in_panel" => "it puts something in front of a person, who is not watching a script",
    "run_script" =>
      "you are already in one — a script starting a script nests a VM inside a tool call",
    "tool_docs" => "read the documentation before writing the script, not from inside it",

    # The spine. These are on `LocalServer` rather than `ScriptableTools`, so a
    # script never had them bound — and absence alone is exactly the failure the
    # comment above describes. Observed 2026-09-05: a main agent wrote
    # `get_next_requirement()` inside `run_script` and got
    # "attempt to call a nil value (global 'get_next_requirement')", which says
    # nothing about where the tool actually is.
    #
    # They are excluded for a different reason from the ones above — not "a
    # script must not do this" but "you already have it directly, and going
    # through Lua to reach it buys nothing". The reason says so, because an
    # agent told the wrong reason looks in the wrong place.
    "get_next_requirement" =>
      "it is one of the four tools you already have directly — call it as a tool",
    "sync_project" => "it is one of the four tools you already have directly — call it as a tool",
    "start_task" => "it is one of the four tools you already have directly — call it as a tool",
    "evaluate_task" => "it is one of the four tools you already have directly — call it as a tool"
  }

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
  def from(registered, build_invoke), do: from(registered, build_invoke, nil)

  @doc """
  The same, scoped to what one agent may call.

  `allowed` is a list of names, or `nil` for an agent that predates scoping and
  could call everything. A list rather than a role, so an exception is a
  different list on one row rather than a new role or a `case` in here.

  Out-of-scope tools are *removed* from the catalog and named separately, so
  `Bindings` can bind each to a stub that says why. Dropping them silently
  produces "attempt to call a nil value", which reads as a misspelling — and an
  agent that reads that tries variations of a name that exists.
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
  is "not for an agent of this kind". They read alike to an agent and want
  different sentences, which is the same distinction `Credential` draws between
  never-connected and needs-reconnecting.
  """
  @spec out_of_scope(Enumerable.t(), [String.t()] | nil) :: [String.t()]
  def out_of_scope(_registered, nil), do: []

  def out_of_scope(registered, allowed) do
    registered
    |> Enum.map(& &1.name())
    |> Enum.reject(&Map.has_key?(@excluded, &1))
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
  end

  defp in_scope?(_name, nil), do: true
  defp in_scope?(name, allowed), do: name in allowed

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
