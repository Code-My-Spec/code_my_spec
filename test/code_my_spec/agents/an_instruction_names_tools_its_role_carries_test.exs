defmodule CodeMySpec.Agents.AnInstructionNamesToolsItsRoleCarriesTest do
  @moduledoc """
  An instruction reaches an agent two ways, and both have been wrong the same
  way.

  `ARoleCarriesTheToolsItsWorkNamesTest` reads the task module a requirement
  names. That is one of the two. The other is the **playbook**: a task prompt
  says "read `fix_issues/workflow.md` via `read_knowledge`" and the procedure
  lives there, so a tool named only in the markdown is named just as surely as
  one in the source, and nothing was checking it. `fix_issues/workflow.md` told
  the coding agent to "use subagents (Agent tool)" -- a tool the coding role
  has never carried (83b63a76, f823d224).

  This file checks both surfaces, for a role's own work:

    * every tool named in a prompt or a playbook the prompt points at is one
      the role receiving it carries, and
    * every argument named for one of those tools is one the tool declares.

  The second half is the same defect one layer in. `triage_issues` told product
  to "call `dismiss_issue` with the issue `id`" and every issue tool declares
  `issue_id`; a script calling `dismiss_issue({id = ...})` is refused with
  "unknown argument" and the refusal aborts the whole `run_script` call, with
  the writes earlier in that script already committed (3cb32d0d).

  ## Why the prompt text is read, not executed

  A prompt is built from a scope this test does not have -- a task, a story, a
  project. Reading the module's source is the same choice the sibling test
  makes, for the same reason: the names are in the text either way, and a
  prompt that only names the tool on a branch the test cannot reach is a gap in
  a different place.

  ## What this deliberately does not check

  Only backticked names that are **real tools**. A word in backticks that no
  tool answers to is a word in backticks, and treating prose as a promise makes
  the list impossible to keep. Direct-call-only tools are skipped: they are in
  `Catalog.excluded()`, so `ToolSets` does not gate them and every agent has
  them.

  `:main` carries everything (`for_role/1` answers `nil`), so it cannot fail
  this and is skipped rather than special-cased into a pass.

  ## What this still cannot see

  This is the static half. An instruction one agent generates for another at
  run time never passes through a prompt or a playbook, so nothing here reads
  it -- main told a coding agent to call `update_issue`, which is product-only
  (0074e1b8), and no file in this repository contains that instruction. The
  run-time half is a separate guard, and it is not this one.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.Requirements.RequirementDefinitionData, as: Definitions

  @component_types ~w(context coordination_context live_context controller schema
                      behaviour json liveview liveview_component other)

  # Where the framework knowledge library lives. A prompt addresses a playbook
  # by its path under this root, e.g. `fix_issues/workflow.md`.
  @knowledge_root "priv/knowledge"

  # The words a prompt uses to hand over a call. See `arguments_on_line/2`.
  @call_cues ~w(pass passes passing with using takes)

  defp referenced_docs(source) do
    ~r/`([a-z0-9_]+(?:\/[a-z0-9_\-]+)+\.md)`/
    |> Regex.scan(source)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
    |> Enum.filter(&File.exists?(Path.join(@knowledge_root, &1)))
  end

  defp scoped_tool_names do
    (LocalServer.__components__() ++ ScriptableTools.__components__())
    |> MapSet.new(& &1.name)
    |> MapSet.difference(MapSet.new(Catalog.excluded()))
  end

  # Every argument the server declares for a tool, read off the component's
  # schema rather than a copy of it here -- a renamed field is picked up
  # without anybody maintaining this.
  defp declared_arguments do
    ScriptableTools.__components__()
    |> Map.new(fn component -> {component.name, argument_names(component)} end)
  end

  defp argument_names(%{input_schema: %{"properties" => properties}}), do: Map.keys(properties)
  defp argument_names(_component), do: []

  defp definitions do
    component =
      Enum.flat_map(@component_types, fn type ->
        CodeMySpec.Requirements.Registry.get_requirements_for_type(type)
      end)

    Definitions.project_requirements() ++ Definitions.story_requirements() ++ component
  end

  defp source_of(module) do
    module.__info__(:compile)[:source] |> read_source()
  end

  defp read_source(nil), do: nil

  defp read_source(path) do
    path |> to_string() |> File.read() |> read_result()
  end

  defp read_result({:ok, source}), do: source
  defp read_result(_error), do: nil

  # The instruction as one agent receives it: the prompt, plus every playbook
  # the prompt points that agent at. Each is tagged with where it came from, so
  # a failure says which file to open.
  defp instruction_sources(module), do: instruction_sources(module, source_of(module))

  defp instruction_sources(_module, nil), do: []

  defp instruction_sources(_module, prompt) do
    [{prompt, "the prompt"} | Enum.map(referenced_docs(prompt), &playbook_source/1)]
  end

  defp playbook_source(path),
    do: playbook_source(path, File.read(Path.join(@knowledge_root, path)))

  defp playbook_source(path, {:ok, source}), do: {source, path}
  defp playbook_source(path, _error), do: {"", path}

  defp tool_gaps(catalogue) do
    for definition <- definitions(),
        role = definition.role,
        not is_nil(role),
        role != :main,
        module = definition.satisfied_by,
        not is_nil(module),
        carried = ToolSets.for_role(role),
        is_list(carried),
        {source, where} <- instruction_sources(module),
        tool <- tools_named_in(source, catalogue),
        tool not in carried,
        do: "#{definition.name} (#{role}) names `#{tool}` in #{where}"
  end

  defp argument_gaps(catalogue) do
    declared = declared_arguments()

    for definition <- definitions(),
        role = definition.role,
        not is_nil(role),
        role != :main,
        module = definition.satisfied_by,
        not is_nil(module),
        {source, where} <- instruction_sources(module),
        {tool, argument} <- arguments_named_for(source, catalogue),
        declared[tool] != nil,
        argument not in declared[tool],
        do: "#{definition.name} (#{role}) names `#{argument}` for `#{tool}` in #{where}"
  end

  defp tools_named_in(source, catalogue) do
    ~r/`([a-z][a-z0-9_]{2,})`/
    |> Regex.scan(source)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(catalogue, &1))
  end

  test "every tool a prompt or playbook names is one its role carries" do
    gaps = tool_gaps(scoped_tool_names()) |> Enum.uniq() |> Enum.sort()

    assert gaps == [],
           """
           An instruction tells its agent to call a tool that role does not have.

           #{Enum.map_join(gaps, "\n", &("  " <> &1))}

           Either add the tool to that role in `CodeMySpec.Agents.RoleProfile`, or
           stop naming it in the prompt or the playbook. An agent told to do a
           thing it cannot do has no way to say so except to tap out, and from the
           outside that reads as the agent failing rather than the instruction
           being impossible.
           """
  end

  test "every argument a prompt or playbook names is one its tool declares" do
    gaps = argument_gaps(scoped_tool_names()) |> Enum.uniq() |> Enum.sort()

    assert gaps == [],
           """
           An instruction names an argument its tool does not declare.

           #{Enum.map_join(gaps, "\n", &("  " <> &1))}

           A call with a name the tool does not declare is refused, and the
           refusal aborts the whole `run_script` call it was made in -- with any
           writes earlier in that script already committed. Name the argument the
           tool declares, or declare the name the prompt uses.
           """
  end

  # The floor under both checks above. A checker that reads nothing passes
  # everything, and both of the ways this one reads can be broken by an edit
  # nobody thinks of as breaking it: the knowledge root a prompt's playbook
  # paths are resolved against, and the regex the tool names come out of.
  # Neither has a symptom -- the failing test goes green.
  #
  # These are floors on what the reader currently sees, not targets, and
  # deliberately loose: a prompt gaining a name is not a defect. What is a
  # defect is the reader answering zero.
  test "the reader still finds tools and arguments in the instructions" do
    catalogue = scoped_tool_names()

    read =
      for definition <- definitions(),
          module = definition.satisfied_by,
          not is_nil(module),
          {source, _where} <- instruction_sources(module),
          do: source

    tool_count = read |> Enum.flat_map(&tools_named_in(&1, catalogue)) |> Enum.uniq() |> length()

    argument_count =
      read |> Enum.flat_map(&arguments_named_for(&1, catalogue)) |> Enum.uniq() |> length()

    assert tool_count >= 20,
           "the prompt reader found #{tool_count} tool names across #{length(read)} " <>
             "instruction sources. It has gone blind, and the two checks above are " <>
             "now passing because there is nothing left to fail them."

    assert argument_count >= 5,
           "the argument reader found #{argument_count} named arguments across " <>
             "#{length(read)} instruction sources. See the tool count above."
  end

  # The pair this half of the check was written for, pinned by name. The
  # general check goes quiet if a prompt stops naming the argument at all, and
  # "no arguments named" is exactly how a prompt stops being wrong about one.
  test "the issue prompts hand over the argument the issue tools declare" do
    catalogue = scoped_tool_names()
    named = arguments_named_for(source_of(CodeMySpec.AgentTasks.TriageIssues), catalogue)

    for tool <- ~w(get_issue accept_issue dismiss_issue) do
      assert {tool, "issue_id"} in named,
             "TriageIssues no longer tells its agent to pass `issue_id` to `#{tool}`. " <>
               "The tool declares `issue_id`; `id` is the name that refused the call " <>
               "and aborted the whole run_script it was made in (3cb32d0d)."
    end

    assert {"dismiss_issue", "reason"} in named
  end

  # The playbook half, pinned the same way: a prompt points at markdown and the
  # markdown is read. This fails the day the path resolution stops working,
  # whether or not a tool named in the markdown is wrong.
  test "a playbook a prompt names is read by the reader" do
    assert referenced_docs(source_of(CodeMySpec.AgentTasks.FixIssues)) ==
             ["fix_issues/workflow.md"]

    catalogue = scoped_tool_names()
    playbook = playbook_source("fix_issues/workflow.md") |> elem(0)

    assert "resolve_issue" in tools_named_in(playbook, catalogue)
  end

  # The shape being read, shown working. A test rather than a comment because
  # it is the one piece of this file that has to be right for all of it to mean
  # anything: prose that names no call, a call that names an argument, and two
  # instructions on one line.
  test "the argument reader reads calls and not prose" do
    catalogue = MapSet.new(~w(get_issue dismiss_issue list_issues))

    assert arguments_named_for("- `get_issue` - read it (pass the issue `id`)", catalogue) ==
             [{"get_issue", "id"}]

    assert arguments_named_for("- `dismiss_issue` - drop it (pass `id` and `reason`)", catalogue) ==
             [{"dismiss_issue", "id"}, {"dismiss_issue", "reason"}]

    # Prose: no cue, so no call, so no argument -- and a tool-shaped word in
    # the same line is a word, not an argument of anything.
    assert arguments_named_for(
             "`list_issues` need the scope to carry an `active_project_id`",
             catalogue
           ) == []

    # Two instructions on one line. The first gets no argument, because the
    # next tool name ends its window; the second gets its own.
    assert arguments_named_for("`get_issue` and `dismiss_issue` with `reason`", catalogue) ==
             [{"dismiss_issue", "reason"}]
  end

  ## Reading the instructions

  defp arguments_named_for(source, catalogue) do
    source
    |> String.split("\n")
    |> Enum.flat_map(&arguments_on_line(&1, catalogue))
    |> Enum.uniq()
  end

  # The shape a prompt uses to hand over a call: a tool name in backticks, a
  # cue that a call is being described, and then the arguments it wants, in
  # backticks, after the cue on the same line.
  #
  #   - `get_issue` -- read full issue details (pass the issue `id`)
  #   - `dismiss_issue` -- dismiss with a reason (pass `id` and `reason`)
  #   - Use the `resolve_issue` MCP tool with the issue `id` and `resolution`
  #
  # The cue is what keeps prose out. A line that merely mentions two
  # tool-shaped words -- "`link_persona_to_story` need the scope to carry an
  # `active_project_id`", "matching the `architecture_proposal` document spec
  # ... and call `execute_proposal`" -- names no call and no argument, and
  # without the cue every one of those reads as one.
  defp arguments_on_line(line, catalogue) do
    for {name, offset} <- backticked_names_with_offsets(line),
        MapSet.member?(catalogue, name),
        tail = tail_after(line, offset, catalogue),
        not MapSet.disjoint?(cue_set(tail), MapSet.new(@call_cues)),
        argument <- backticked_names(tail),
        argument != name,
        not MapSet.member?(catalogue, argument),
        do: {name, argument}
  end

  # Everything after `offset` on the line, up to the next backticked name that
  # is itself a tool: that one is the next instruction, not an argument of this
  # one.
  defp tail_after(line, offset, catalogue) do
    rest = String.slice(line, offset..-1//1)

    rest
    |> backticked_names_with_offsets()
    |> Enum.find_value(rest, fn {name, next_offset} ->
      tool_slice(catalogue, name, rest, next_offset)
    end)
  end

  defp tool_slice(catalogue, name, rest, next_offset) do
    (MapSet.member?(catalogue, name) && String.slice(rest, 0, next_offset)) || nil
  end

  defp backticked_names_with_offsets(text) do
    ~r/`([a-z][a-z0-9_]{1,})`/
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [whole, name] ->
      {offset, length} = whole
      {_argument_offset, argument_length} = name
      # The name sits one character inside the backticks.
      {String.slice(text, offset + 1, argument_length), offset + length}
    end)
  end

  defp cue_set(text) do
    text
    |> String.split(~r/[^a-z]+/)
    |> MapSet.new()
  end

  defp backticked_names(text) do
    ~r/`([a-z][a-z0-9_]{1,})`/
    |> Regex.scan(text)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
  end
end
