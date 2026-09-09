defmodule CodeMySpecSpex.Story1014.Criterion2860Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2860 — An offline device's copies are not flagged as missing.

  Rule: Absence of a report is never evidence that a path is gone.

  This is the criterion the whole rework exists for, and it is the one the
  previous model failed.

  That model asked "how long since we heard from this copy" and deleted its
  derived state past a threshold. Silence was the input, so a laptop that was
  shut for the weekend and a checkout that had been deleted produced the same
  answer — and the measured failure was worse than that: two harnesses whose
  agents were *working*, scanning and answering hooks continuously, read 2:21
  and 2:25 idle against a two hour window, because the signal only ever ran
  down. They were one sync away from losing their files.

  So the replacement has to be checked for the inverse property, not just the
  positive one. It is easy to build something that flags a copy when told it is
  gone; the question is whether it also stays quiet when told nothing at all.

  The `when_` is deliberately empty of harness activity. There is no report,
  because that is the premise — the machine is off. A criterion that reported
  "present" to arrange this would be testing something else.
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

  @observed_file "lib/away_copy/thing.ex"

  spex "Silence says nothing about a path" do
    scenario "An offline device's copies are not flagged as missing" do
      given_ "a device whose harness has been disconnected for hours, with working copies whose checkouts are all intact",
             context do
        device = device_id(context, hostname: "the-laptop-that-is-shut")

        root = checkout("placeholder")

        joined =
          join_working_copy(context, root, "the copy on the shut laptop", device_id: device)

        working_copy_id = joined.working_copy_id

        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        Fixtures.observe_files_as(context.scope, working_copy_id, [@observed_file])

        # The checkout is fine. Nothing is deleted here, and nothing is reported
        # either — the machine is off, which is precisely the state where the
        # old model went wrong.
        assert RealDisk.dir?(root),
               "the premise is an intact checkout on an unreachable machine; if " <>
                 "the directory were gone this would be a different criterion"

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:working_copy_id, working_copy_id)}
      end

      when_ "the working copies page is read", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "none of its copies is shown as missing", context do
        refute has_element?(
                 context.live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='path-missing']"
               ),
               "a copy nobody has reported on is being called gone. Nothing has " <>
                 "looked at that path — the machine is off — and 'we have not " <>
                 "been told' is not the same claim as 'it is not there'. This is " <>
                 "the exact substitution the previous model made, where a shut " <>
                 "laptop and a deleted checkout produced the same answer."

        {:ok, context}
      end

      then_ "and nothing of theirs is removed", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "the copy is gone from the list without anybody offboarding it"

        {:ok, files, html} = live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(files, "[data-test='file-row']") and html =~ @observed_file,
               "the copy's files were reclaimed while its machine was merely " <>
                 "unreachable. Got: #{html}"

        {:ok, context}
      end
    end
  end
end
