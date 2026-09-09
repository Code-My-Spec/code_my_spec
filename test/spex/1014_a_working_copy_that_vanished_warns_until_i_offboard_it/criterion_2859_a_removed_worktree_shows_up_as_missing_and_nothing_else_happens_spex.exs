defmodule CodeMySpecSpex.Story1014.Criterion2859Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2859 — A removed worktree shows up as missing and nothing else
  happens.

  Rule: A working copy whose path no longer exists is flagged, never reclaimed.

  Both halves are load-bearing and the second is the one that changed.

  This story used to reclaim automatically, after a configurable quiet window,
  riding on whichever agent next synced components. The signal was `last_seen_at`
  and it went stale while agents worked — measured on this project, two harnesses
  mid-session read 2:21 and 2:25 idle against a two hour window, one sync away
  from having their files deleted underneath them.

  So the trigger moved from elapsed time to an observation with a definite
  answer: is the checkout still at its path, according to the machine it is on.
  And the consequence moved from deletion to a warning, because the observation
  being definite does not make the decision obvious — a checkout can be gone
  because somebody is mid-rebase.

  The `then_` therefore asserts the flag **and** asserts nothing was taken. A
  page that warned and quietly reclaimed anyway would pass the first assertion
  alone, and would be the old failure wearing a new label.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  @observed_file "lib/the_copy/thing.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A checkout that is gone is reported, not reclaimed" do
    scenario "A removed worktree shows up as missing and nothing else happens" do
      given_ "a working copy its harness serves, holding files and problems", context do
        device = device_id(context, hostname: "the-laptop")

        # Minted the way a real checkout mints one — by joining — so the id the
        # harness reports is the id the server issued, rather than one invented
        # here and agreed with by nobody.
        root = checkout("placeholder")
        joined = join_working_copy(context, root, "the copy", device_id: device)
        working_copy_id = joined.working_copy_id

        # The config file names the id it was actually issued. Written after the
        # join because the join is what issues it.
        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        # Through the real channel handler, with this copy's id on the scope —
        # the same path a harness takes when it reports what it scanned. Files
        # are the state the old automatic reclaim deleted, so they are the right
        # evidence for whether anything was taken.
        Fixtures.observe_files_as(context.scope, working_copy_id, [@observed_file])

        reporter = harness(context, device, %{working_copy_id => root})

        {:ok,
         context
         |> Map.put(:device, device)
         |> Map.put(:root, root)
         |> Map.put(:working_copy_id, working_copy_id)
         |> Map.put(:reporter, reporter)}
      end

      when_ "its checkout is removed from disk and the harness next reports what it can see",
            context do
        remove(context.root)

        {:ok, Map.put(context, :observation, report(context.reporter))}
      end

      then_ "that working copy is shown as missing", context do
        assert context.observation[context.working_copy_id] == false,
               "the harness did not report the copy as gone. Its config file went " <>
                 "with the directory, so a reporter that reads only what it can " <>
                 "parse right now would drop the entry entirely — and an " <>
                 "unmentioned copy is treated as unchanged, which is silence. " <>
                 "Got: #{inspect(context.observation)}"

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='path-missing']"
               ),
               "the copy's checkout is gone and the page does not say so, so the " <>
                 "only thing that would ever tell somebody to offboard it is missing"

        {:ok, Map.put(context, :live, live)}
      end

      then_ "and the copy and its problems are all still there", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "the working copy is gone from the list, removed by an observation. " <>
                 "Observing is not deciding: this stopped happening automatically " <>
                 "because the automatic version deleted two mid-session agents' " <>
                 "state on a signal that had gone stale."

        {:ok, files, html} = live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(files, "[data-test='file-row']"),
               "the copy's files were reclaimed on the strength of a path check. " <>
                 "Nothing is removed until somebody offboards it — a checkout can " <>
                 "be absent because its owner is mid-rebase. Got: #{html}"

        assert html =~ @observed_file,
               "a file row survived but not the one this copy reported, which " <>
                 "means the reclaim happened and something else is being counted"

        {:ok, context}
      end
    end
  end
end
