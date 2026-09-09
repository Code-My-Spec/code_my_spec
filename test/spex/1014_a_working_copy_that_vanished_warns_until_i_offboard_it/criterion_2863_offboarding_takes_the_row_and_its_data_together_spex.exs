defmodule CodeMySpecSpex.Story1014.Criterion2863Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2863 — Offboarding takes the row and its data together.

  Rule: Offboarding a working copy removes its row and everything derived from
  it.

  The row goes too, and that is the part that changed.

  The previous model kept it, on the argument that identity lives in
  `.cms_harness.json` so a returning agent presents the id it always had and
  resumes. That argument does not survive the new trigger: the config file is
  *inside* the checkout, so a removed worktree took it with it. There is nothing
  left to present and nothing to come back to, and a row kept for a return that
  cannot happen is a row in a list that means nothing.

  "Together" is the other half. A half-offboard — row gone, files left — leaves
  rows whose owner does not exist, which is the orphan state this whole story is
  about, arrived at through its own remedy.
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

  @observed_file "lib/gone_copy/thing.ex"

  spex "Offboarding is one act that takes everything with it" do
    scenario "Offboarding takes the row and its data together" do
      given_ "a working copy shown as missing, holding files and problems", context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")
        joined = join_working_copy(context, root, "the copy to offboard", device_id: device)
        working_copy_id = joined.working_copy_id

        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        Fixtures.observe_files_as(context.scope, working_copy_id, [@observed_file])

        reporter = harness(context, device, %{working_copy_id => root})
        remove(root)
        report(reporter)

        {:ok,
         context
         |> Map.put(:working_copy_id, working_copy_id)
         |> Map.put(:device, device)}
      end

      when_ "I offboard it", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        # The trigger only adds a class — the dialog is already in the DOM, and
        # `render_click/1` refuses a JS command with no push in it. That is the
        # component working as designed: `confirm_dialog` exists because
        # `data-confirm` renders outside the DOM where no automation can reach
        # it, so both of its buttons are ordinary elements a test can click.
        assert has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='offboard-working-copy']"
               ),
               "there is no way to offboard this copy from the page, so the only " <>
                 "thing that ever removes one is unreachable"

        html =
          live
          |> element("#offboard-#{context.working_copy_id} [data-role='confirm-confirm']")
          |> render_click()

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "the working copy, its files and its problems are gone", context do
        {:ok, files, files_html} = live(context.conn, "/app/projects/#{context.project.id}/files")

        refute has_element?(files, "[data-test='file-row']") and files_html =~ @observed_file,
               "the copy was offboarded and the files it reported are still " <>
                 "listed. Those rows now belong to a working copy that does not " <>
                 "exist, which is the orphan state this story is about — reached " <>
                 "through its own remedy. Got: #{files_html}"

        {:ok, context}
      end

      then_ "and it no longer appears under its device", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        refute has_element?(
                 live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "the row survived the offboard. It used to, on the argument that a " <>
                 "returning agent presents the id from its checkout — but the " <>
                 "checkout is gone and took `.cms_harness.json` with it, so there " <>
                 "is nothing left to present and the row is a list entry that " <>
                 "means nothing."

        {:ok, context}
      end
    end
  end
end
