defmodule CodeMySpec.Requirements.UiPublishRespectsDefaultCheckoutTest do
  @moduledoc """
  A UI publish computes and stores under the same checkout, once one is the
  project's default (276c2afe).

  Follow-up to cc4745dc, which made `NodeRepository.upsert_all/2` **write** a
  UI scope's rows under `Projection.vantage/1` — the project's default working
  copy — while `Preloader.load/1` and `GraphCache` still decided what to
  **compute** and where to **cache** from the raw, unresolved
  `active_working_copy_id: nil`. That let a UI publish blend every checkout's
  files into its computation and then persist the blended, over-satisfying
  answer under the specific default checkout's row identity — silently
  overwriting that checkout's own accurately-scoped verdict, the same
  over-satisfaction `Preloader`'s own moduledoc measured at 303 skipped specs,
  arriving through the UI path instead of an agent one.

  Driven through `RequirementGraph.compute_all/1` rather than
  `NodeRepository` directly, because the defect lived in what got computed,
  not just where it landed — a synthetic `Requirement` struct handed to
  `upsert_all/2` cannot exercise `Preloader.load/1`'s file query at all.

  Uses `implementation_file` (`artifact_type: :code`) rather than `spec_file`
  — the latter is filtered out of the graph entirely under this fixture's
  default `require_specs: false` config, which would make the node this test
  watches simply not exist rather than exist and read satisfied.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.{Preloader, Projection, RequirementGraph}
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp impl_node(nodes, component) do
    Enum.find(nodes, fn n ->
      n.entity_type == "component" and n.entity_id == component.id and
        n.name == "implementation_file"
    end)
  end

  defp stored_impl_node(scope, component) do
    {:ok, ctx} = Preloader.load(scope)
    {nodes, _edges} = Projection.load(scope, ctx)
    impl_node(nodes, component)
  end

  test "a UI publish does not overwrite the default checkout's verdict with a blend of every checkout's files" do
    scope = full_scope_fixture()
    default_wc_id = scope.active_working_copy_id

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{
        default_working_copy_id: default_wc_id
      })

    scope = %{scope | active_project: project}

    {:ok, other_wc} =
      WorkingCopies.issue(scope, nil, label: "a different checkout", device: device_fixture(scope))

    component = component_fixture(scope, %{module_name: "MyApp.Stale", type: "schema"})

    # The implementation file exists only in a checkout OTHER than the
    # project's default — exactly the shape that flips `implementation_file`
    # to satisfied under a blended computation but not under one scoped to
    # the default checkout alone.
    {1, _} =
      Files.upsert_files(%{scope | active_working_copy_id: other_wc.id}, [
        %{
          path: "lib/my_app/stale.ex",
          role: :implementation,
          component_id: component.id,
          mtime: DateTime.utc_now(),
          size: 1,
          fingerprint: "abc"
        }
      ])

    default_scope = %{scope | active_working_copy_id: default_wc_id}

    # The default checkout computes and publishes its own honest verdict
    # first — the same as an agent working from that checkout syncing and
    # recomputing.
    nodes_from_default = RequirementGraph.compute_all(default_scope)

    refute impl_node(nodes_from_default, component).satisfied,
           "the premise failed: the default checkout must not see an " <>
             "implementation file that lives only in a different checkout"

    # A person looking at the project in a browser has no checkout to name.
    ui_scope = %{scope | active_working_copy_id: nil}
    nodes_from_ui = RequirementGraph.compute_all(ui_scope)

    refute impl_node(nodes_from_ui, component).satisfied,
           """
           A UI publish computed the graph blended across every checkout
           instead of scoped to the project's default working copy, so it saw
           the file that only the other checkout has and marked
           implementation_file satisfied — the over-satisfaction `Preloader`
           exists to prevent, arriving through the UI path instead of an
           agent path.
           """

    # And the UI publish must not have overwritten the default checkout's own
    # stored rows with that (would-be) blended answer.
    refute stored_impl_node(default_scope, component).satisfied,
           "a UI publish overwrote the default checkout's own accurate rows " <>
             "with a blended, over-satisfying verdict"
  end
end
