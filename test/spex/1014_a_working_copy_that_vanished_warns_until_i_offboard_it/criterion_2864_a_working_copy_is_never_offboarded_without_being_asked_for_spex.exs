defmodule CodeMySpecSpex.Story1014.Criterion2864Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2864 — A working copy is never offboarded without being asked for.

  Rule: Offboarding a working copy removes its row and everything derived from
  it.

  The other half of that rule: *only* offboarding does.

  This is a regression test against the model this story used to have. Reclaiming
  rode on `ComponentSync.sync_from_files/2` and on the stop hook, so any live
  agent doing ordinary work swept every other copy on the project. The reasoning
  was that a project nobody is touching has nobody blocked, so reclaiming when
  somebody asks needs no scheduler — which was true, and beside the point once
  the input turned out to be a stale timestamp.

  Both call sites are gone. A copy that has been shown as missing for days is
  still there after every other agent has synced, analysed and stopped, because
  nothing removes a working copy except a person removing it.

  The `when_` therefore does the ordinary work — a stop hook, which is what an
  agent finishing a turn does — and the assertion is that it changed nothing.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Ordinary work by other agents never removes anybody's copy" do
    scenario "A working copy is never offboarded without being asked for" do
      given_ "a working copy that has been shown as missing for days", context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")
        joined = join_working_copy(context, root, "the abandoned copy", device_id: device)
        working_copy_id = joined.working_copy_id

        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        reporter = harness(context, device, %{working_copy_id => root})
        remove(root)
        report(reporter)

        {:ok, Map.put(context, :working_copy_id, working_copy_id)}
      end

      given_ "and another agent still working on the project", context do
        {:ok, Map.put(context, :live_agent, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "other agents sync components and run their analyses", context do
        # A stop hook is what an agent finishing a turn does, and it used to be
        # one of the two places reclaiming rode on. Driving it is the point:
        # this criterion asks whether the sweep is genuinely gone rather than
        # merely unreferenced from the page.
        post_hook(context.live_agent, "/api/hooks/stop", %{
          "session_id" => "spex-2864-#{System.unique_integer([:positive])}"
        })

        {:ok, context}
      end

      then_ "it is still there, still shown as missing", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "another agent's ordinary stop removed a copy nobody asked to be " <>
                 "removed. That is exactly the old behaviour: reclaiming rode on " <>
                 "the stop hook and on component sync, so any live agent swept " <>
                 "every other copy on the project — and it once came within one " <>
                 "sync of deleting two mid-session agents' files."

        assert has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='path-missing']"
               ),
               "the copy survived but the warning did not, so the one thing that " <>
                 "would tell somebody to offboard it has been cleared by an " <>
                 "unrelated agent's sync"

        {:ok, context}
      end

      then_ "and removing it is still something only I can do", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='offboard-working-copy']"
               ),
               "the copy survived somebody else's sync but there is no way to " <>
                 "remove it, which leaves it blocking with no remedy — the state " <>
                 "the automatic sweep existed to prevent, now with nothing in its " <>
                 "place"

        {:ok, context}
      end
    end
  end
end
