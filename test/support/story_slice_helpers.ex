defmodule CodeMySpecSpex.StorySliceHelpers do
  @moduledoc "Surface setup and response readers for active-story execution acceptance tests."
  import ExUnit.Assertions
  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.WorkingCopies

  alias CodeMySpecSpex.{
    Fixtures,
    FullSatisfactionFixtures,
    GraphGivens,
    ProjectStateFixtures,
    StoryHelpers
  }

  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  def base(context) do
    context
    |> FullSatisfactionFixtures.apply_up_to_analysis()
    |> activate()
  end

  def activate(context) do
    call(context, SetActiveStory, %{story_number: context.story.number})
    context
  end

  def call(context, tool, params, assigns \\ %{}) do
    frame = %Frame{assigns: Map.merge(%{current_scope: context.scope}, assigns)}
    {:reply, response, _frame} = tool.execute(params, frame)
    refute response.isError, response_text(response)
    response_text(response)
  end

  def next(context, assigns \\ %{}) do
    call(context, GetNextRequirement, %{}, assigns)
  end

  def topology(context, triples) do
    context |> GraphGivens.write_component_specs(triples) |> GraphGivens.sync()
  end

  def component(context, name), do: Fixtures.get_component_by_module_name(context.scope, name)

  def missing(context, name) do
    :ok = Environments.delete_file(context.environment, Content.impl_path(name))
    GraphGivens.sync(context)
  end

  def implement(context, name) do
    :ok =
      Environments.write_file(
        context.environment,
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

    story =
      StoryHelpers.create_and_link(context.scope, module,
        title: "Waiting story B",
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
        call(context, CodeMySpec.McpServers.Stories.Tools.CreateEpic, %{name: "Future work"})

      [_, epic_id] = Regex.run(~r/ID: ([^,]+)/, result)

      call(context, CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic, %{
        story_number: story.number,
        epic_name: "Future work"
      })

      call(context, CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy, %{
        epic_id: epic_id,
        working_copy_id: context.scope.active_working_copy_id
      })
    end

    Map.put(context, :waiting, story)
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

  def complete(context) do
    context = FullSatisfactionFixtures.apply_without_deploy(context)
    activate(context)
  end
end
