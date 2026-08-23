defmodule CodeMySpec.WorkingCopiesReclaimTest do
  @moduledoc """
  Story 892's reclaim, asserted against the data rather than a view.

  The spex drive the stop hook and read the components page, which is the right
  surface but a slow instrument: a component that survives a reclaim and one
  that is deleted and immediately re-projected by the live agent's own sync
  render identically. That ambiguity cost most of a debugging session, and this
  removes it — here the delete rule is asserted directly, so a failure means the
  rule is wrong rather than the pipeline downstream of it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.WorkingCopies

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a quiet agent's component is gone from list_components", %{scope: scope} do
    component = component_fixture(scope, %{name: "GoneContext", module_name: "GoneContext"})

    assert component.id in Enum.map(Components.list_components(scope), & &1.id),
           "the premise failed: the component was not created"

    # Everything on this project has been quiet for days, and the caller is a
    # different agent entirely.
    {:ok, live} = WorkingCopies.issue(scope, nil, label: "the agent still working")

    from_h =
      Ecto.Query.from(h in WorkingCopies.WorkingCopy,
        where: h.project_id == ^scope.active_project_id
      )

    CodeMySpec.Repo.update_all(from_h,
      set: [last_seen_at: DateTime.add(DateTime.utc_now(), -96 * 3600, :second)]
    )

    {:ok, _} = WorkingCopies.issue(scope, live.id)

    WorkingCopies.reclaim_quiet(%{scope | active_working_copy_id: live.id})

    refute component.id in Enum.map(Components.list_components(scope), & &1.id),
           "the component survived the reclaim. It has no files and no story " <>
             "references it, so nothing an agent does in any working copy can " <>
             "resolve what the graph demands of it."
  end
end
