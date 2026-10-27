defmodule CodeMySpecSpex.StorySliceHelpers do
  @moduledoc "Surface setup and response readers for active-story execution acceptance tests."
  import ExUnit.Assertions
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies

  alias CodeMySpecSpex.{
    Fixtures,
    FullSatisfactionFixtures,
    GraphGivens,
    ProjectStateFixtures,
    StoryHelpers
  }

  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  def base(context) do
    context
    |> FullSatisfactionFixtures.apply_up_to_analysis()
    |> activate()
  end

  def activate(context) do
    context = staff(context)
    call(context, "set_active_story", %{story_number: context.story.number})
    context
  end

  @doc "Use the fixture's in-memory runtime for an explicitly joined working copy."
  def scope_for_copy(%{scope: scope, execution_context: environment}, copy_id, root) do
    :ok = ExecutionContexts.unregister({:working_copy, copy_id})
    :ok = ExecutionContexts.register({:working_copy, copy_id}, environment)
    %{scope | active_working_copy_id: copy_id, cwd: root}
  end

  @doc """
  A coding and a QA agent on the scope's copy, unless it already has a team.
  A story goes to the copy's team (a31f1cd6), so a copy needs one to hold it.
  """
  def staff(context) do
    copy_id = context.scope.active_working_copy_id

    staffed? =
      context.scope
      |> CodeMySpec.Agents.list_agents()
      |> Enum.any?(&(&1.working_copy_id == copy_id and &1.role in [:coding, :qa]))

    staff(context, staffed?)
  end

  defp staff(context, true) do
    team =
      context.scope
      |> CodeMySpec.Agents.list_agents()
      |> Enum.filter(
        &(&1.working_copy_id == context.scope.active_working_copy_id and
            &1.role in [:coding, :qa] and is_nil(&1.retired_at))
      )

    Map.put(context, :team, team)
  end

  defp staff(context, false) do
    team = for role <- ~w(coding qa), do: Fixtures.running_agent(context.scope, role: role)
    Map.put(context, :team, team)
  end

  def call(context, name, params, assigns \\ %{}) do
    case ToolLibrary.run(name, params, tool_context(context, assigns)) do
      {:ok, text} -> text
      {:error, text} -> flunk("#{name} refused: #{text}")
    end
  end

  @doc "Call a tool and return `{error?, text}` — for a step whose refusal is the point."
  def attempt(context, name, params, assigns \\ %{}) do
    case ToolLibrary.run(name, params, tool_context(context, assigns)) do
      {:ok, text} -> {false, text}
      {:error, text} -> {true, text}
    end
  end

  @doc """
  A main copy beside the scope's own, with the main agent on it. Designated
  first, so the scope's copy and any copy joined later are feature copies.
  """
  def main_copy(context) do
    {:ok, copy} =
      WorkingCopies.issue(context.scope, nil,
        label: "the main checkout",
        device: Fixtures.device_fixture(context.scope)
      )

    {:ok, _} = WorkingCopies.designate_main(context.scope, copy.id)
    {:ok, _} = WorkingCopies.report_root(copy, context.scope.cwd)
    main_scope = scope_for_copy(context, copy.id, context.scope.cwd)
    main = Fixtures.running_agent(main_scope, role: "main")
    Map.merge(context, %{main_copy: copy, main_scope: main_scope, main: main})
  end

  # Settled first: the tool reads under a one-second deadline and answers "being
  # rebuilt" while the projector is still on what the fixture just wrote, which
  # a loaded box made it do (0c35c198, the_team_finishes_a_story_together_test).
  def next(context, assigns \\ %{}) do
    :ok = Fixtures.settle_graph(context.scope)
    call(context, "get_next_requirement", %{}, assigns)
  end

  def topology(context, triples) do
    context |> GraphGivens.design_components(triples) |> GraphGivens.sync()
  end

  def component(context, name), do: Fixtures.get_component_by_module_name(context.scope, name)

  def missing(context, name) do
    :ok = ExecutionContexts.delete_file(context.execution_context, Content.impl_path(name))
    GraphGivens.sync(context)
  end

  def implement(context, name) do
    :ok =
      ExecutionContexts.write_file(
        context.execution_context,
        Content.impl_path(name),
        Content.impl_file(name)
      )

    GraphGivens.sync(context)
  end

  def child(context, names \\ ["Reservations.Booking"]) do
    context = topology(context, Enum.map(names, &{&1, :schema, []}))
    Enum.reduce(names, context, &missing(&2, &1))
  end

  def waiting(context, opts \\ []) do
    module = Keyword.get(opts, :module, "Waiting")

    context =
      if module == "Waiting", do: topology(context, [{module, :context, []}]), else: context

    # The persona three-amigos links below must exist before it is linked, and
    # only the chains (`base/1`, `complete/1`, through
    # `apply_project_kickoff/2`) ever made one. Every caller used to run a chain
    # first, so this read `context.persona_id` and always found it — until
    # criterion 2064/2065, whose premises are a free team and a waiting story
    # and which therefore have no reason to settle a story chain. On those the
    # key was simply absent and `waiting/2` raised `KeyError`, three frames
    # down and naming neither the persona nor this fixture.
    #
    # A persona that already exists is the same persona: this guarantees one is
    # there, and `apply_persona/2` is idempotent for exactly that reason.
    context =
      if context[:persona_id], do: context, else: ProjectStateFixtures.apply_persona(context)

    story =
      StoryHelpers.create_and_link(context.scope, module,
        title: Keyword.get(opts, :title, "Waiting story B"),
        description: "Future work",
        acceptance_criteria: ["Waiting works"],
        priority: 0
      )

    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
        persona_id: context.persona_id
      )

    if Keyword.get(opts, :bdd, true),
      do: ProjectStateFixtures.apply_bdd_spec_for_story(context, story)

    if Keyword.get(opts, :assigned, false) do
      buildable(context)

      result =
        call(context, "create_epic", %{name: "Future work"})

      [_, epic_id] = Regex.run(~r/ID: ([^,]+)/, result)

      call(context, "assign_story_to_epic", %{
        story_number: story.number,
        epic_name: "Future work"
      })

      call(context, "assign_epic_to_working_copy", %{
        epic_id: epic_id,
        working_copy_id: context.scope.active_working_copy_id
      })
    end

    Map.put(context, :waiting, story)
  end

  @doc """
  A real git repository at the copy's root, with one commit.

  `staff/1`'s copy has no root (`buildable/1`'s stub is a directory marker,
  not a checkout, and has no `.git` either), and a step that reads HEAD
  (`Fixtures.fresh_analysis_runs(context.scope, ..., at_head: true)`) needs
  `git rev-parse HEAD` to find an actual repository there.
  """
  def git_backed(context) do
    root = CodeMySpec.TempFile.owned_dir("story-slice-git")

    {_, 0} =
      ExecutionContexts.cmd(context.execution_context, "git", [
        "init",
        "--quiet",
        "--initial-branch=main",
        root
      ])

    {_, 0} =
      ExecutionContexts.cmd(
        context.execution_context,
        "git",
        [
          "-c",
          "user.email=spex@example.com",
          "-c",
          "user.name=Spex",
          "commit",
          "--allow-empty",
          "-m",
          "root"
        ],
        cd: root
      )

    {:ok, copy} = WorkingCopies.fetch(context.scope.active_working_copy_id)
    {:ok, _} = WorkingCopies.report_root(copy, root)
    context
  end

  # A copy is only assignable once it has a checkout on disk, which is what a
  # harness reports when it joins. `setup_active_project` builds the copy
  # without one and leaves `root` nil, so `AssignEpicToWorkingCopy` refuses —
  # correctly, since nothing can be built on a rootless copy. The scope already
  # points at a real stub directory; this tells the copy about it.
  defp buildable(context) do
    {:ok, copy} = WorkingCopies.fetch(context.scope.active_working_copy_id)
    report_root(copy, context.scope.cwd)
  end

  defp report_root(%{root: root}, _cwd) when is_binary(root), do: :ok

  defp report_root(copy, cwd) do
    {:ok, _} = WorkingCopies.report_root(copy, cwd)
    :ok
  end

  def offered?(text, entity_id), do: text =~ "entity_id=`#{entity_id}`"

  def assert_active(text, context, status) do
    assert text =~ "# Story #{context.story.number}:"
    assert text =~ "Status: #{status}"
    if context[:waiting], do: refute(offered?(text, context.waiting.id))
  end

  # Complete for the team and not landed: certified, QA passed, no promotion
  # stamp. A scenario that asserts the move lands the story with `land/1`.
  def complete(context) do
    context |> FullSatisfactionFixtures.apply_without_deploy() |> activate()
  end

  @doc """
  Land the team's story: stamp it promoted, the only fact that says a story is
  finished for its team. A scenario about a story that keeps its team does not
  call this.
  """
  def land(context) do
    story = CodeMySpec.Stories.get_story!(context.scope, context.story.id)

    {:ok, _} =
      Fixtures.record_story_publication(context.scope, story.id, "2.0.44",
        candidate_commit: story.qa_ready_commit,
        commit: story.qa_ready_commit
      )

    context
  end

  defp tool_context(context, assigns),
    do: assigns |> Map.take([:agent_id, :session_id]) |> Map.put(:scope, context.scope)
end
