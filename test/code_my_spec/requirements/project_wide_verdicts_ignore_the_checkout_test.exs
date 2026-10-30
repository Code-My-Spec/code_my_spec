defmodule CodeMySpec.Requirements.ProjectWideVerdictsIgnoreTheCheckoutTest do
  @moduledoc """
  The verdicts stored once per project are the same from every checkout.

  `GraphStore.project_wide_names/0` names the requirements whose checkers read
  only the project's records, or every checkout's files. Stored once, they are
  computed at whichever checkout a drain settles first, so a checker that began
  reading its checkout would serve one copy's answer to all of them. Each is
  computed from two scopes that differ only in the checkout, with a file only
  one of them has.
  """
  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphStore, Preloader, Registry}
  alias CodeMySpec.Requirements.{RequirementCalculator, RequirementDefinitionData}
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies

  # Check types and delegates that read only records, or every checkout's files.
  # Not `IssuesChecker.triaged?/2`, `resolved?/2` or `DispatchChecker`: a
  # checkout leaves out the issues on stories placed at another.
  @record_checks [
    :always,
    :component_exists,
    :field_present,
    :field_true,
    :deployed,
    :all_deployed
  ]
  @record_delegates [
    CodeMySpec.Promotion.RunningCopy,
    CodeMySpec.Qa.Verdict,
    CodeMySpec.Requirements.BddRulesChecker,
    {CodeMySpec.Requirements.IssuesChecker, :story_triaged?},
    CodeMySpec.Requirements.PersonasChecker,
    CodeMySpec.Requirements.QaDocumentChecker,
    CodeMySpec.Requirements.StoriesChecker
  ]

  test "the project-wide names are exactly the definitions whose checkers read no checkout" do
    {wide, per_checkout} = Enum.split_with(definitions(), &project_wide?/1)

    assert wide
           |> MapSet.new(& &1.name)
           |> MapSet.equal?(MapSet.new(GraphStore.project_wide_names()))

    assert MapSet.disjoint?(MapSet.new(wide, & &1.name), MapSet.new(per_checkout, & &1.name)),
           "a name is project-wide for one owner and per checkout for another"
  end

  test "each project-wide verdict is the same from two checkouts" do
    first = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(first, nil, label: "Other", device: device_fixture(first))
    second = %{first | active_working_copy_id: copy.id}

    {:ok, context} =
      Components.create_component(first, %{
        name: "Accounts",
        type: "context",
        module_name: "Example.Accounts"
      })

    story = story_fixture(first, %{ready_for_dev: true, component_id: context.id})
    issue_fixture(first, %{story_id: story.id, severity: :high})

    # A story placed at the second checkout, with an incoming and an accepted
    # issue: what a checkout filtering by placement would answer differently.
    placed = story_fixture(first, %{ready_for_dev: true, component_id: context.id})
    Repo.update_all(from(s in Story, where: s.id == ^placed.id), set: [working_copy_id: copy.id])
    placed = Repo.get!(Story, placed.id)
    issue_fixture(first, %{story_id: placed.id, severity: :high})
    accepted = issue_fixture(first, %{story_id: placed.id, severity: :high})
    Repo.update_all(from(i in Issue, where: i.id == ^accepted.id), set: [status: :accepted])

    # Only the first checkout has the component's file and a persona's.
    for {path, role, component_id} <- [
          {"lib/example/accounts.ex", :implementation, context.id},
          {".code_my_spec/personas/operator/summary.md", :persona_summary, nil}
        ] do
      Repo.insert!(%FileRecord{
        project_id: first.active_project_id,
        working_copy_id: first.active_working_copy_id,
        component_id: component_id,
        path: path,
        role: role,
        valid: true
      })
    end

    {:ok, at_first} = Preloader.load(first)
    {:ok, at_second} = Preloader.load(second)

    owners = [
      {first.active_project, Registry.get_project_requirements()},
      {story, Registry.get_story_requirements()},
      {placed, Registry.get_story_requirements()},
      {context, Registry.get_requirements_for_type("context")}
      | Enum.map(at_first.story_issues, &{&1, RequirementDefinitionData.story_issue_graph()})
    ]

    for {entity, defs} <- owners,
        definition <- defs,
        definition.name in GraphStore.project_wide_names() do
      assert verdict(first, entity, definition, at_first) ==
               verdict(second, entity, definition, at_second),
             "#{definition.name} differs between two checkouts of one project"
    end
  end

  defp verdict(scope, entity, definition, ctx) do
    files = Map.get(ctx.files_by_component, Map.get(entity, :id), [])
    RequirementCalculator.compute_one(scope, entity, definition, files, ctx)
  end

  defp definitions do
    types = ~w(context coordination_context live_context controller schema behaviour json
               liveview liveview_component module infrastructure)

    Enum.flat_map(types, &Registry.get_requirements_for_type/1) ++
      Registry.get_story_requirements() ++
      RequirementDefinitionData.story_issue_graph() ++ Registry.get_project_requirements()
  end

  defp project_wide?(%{check_type: :delegate, config: config}) do
    module = MapAccess.get(config, :module)
    function = MapAccess.get(config, :function, :check)
    module in @record_delegates or {module, function} in @record_delegates
  end

  defp project_wide?(%{check_type: check_type}), do: check_type in @record_checks
end
