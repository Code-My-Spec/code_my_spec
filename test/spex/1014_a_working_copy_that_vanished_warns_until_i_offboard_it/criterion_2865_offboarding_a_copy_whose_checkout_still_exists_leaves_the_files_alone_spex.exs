defmodule CodeMySpecSpex.Story1014.Criterion2865Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2865 — Offboarding a copy whose checkout still exists leaves the
  files alone.

  Rule: Offboarding never touches the checkout on disk.

  The row is ours; the directory is not. A server that deletes somebody's files
  because they clicked a button in a list is not a trade anyone asked for, and
  the button is one click from a list of many similar-looking rows.

  Offboarding a copy whose checkout is still there is also a legitimate thing to
  want — "I am done with this one" — so the case is not hypothetical. What it
  leaves behind is a directory that is simply no longer recognised: its
  `.cms_harness.json` still names an id the server has forgotten, and running
  onboarding again mints a new one. That is criterion 2868's half.

  The checkout is checked file by file rather than by `RealDisk.dir?` alone. A remedy
  that emptied the directory but left it standing would pass a directory check
  and would be the failure this criterion is about.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Removing a working copy is not removing a checkout" do
    scenario "Offboarding a copy whose checkout still exists leaves the files alone" do
      given_ "a working copy I am done with, whose checkout is still on disk", context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")

        joined =
          join_working_copy(context, root, "the copy I am finished with", device_id: device)

        working_copy_id = joined.working_copy_id

        config = Path.join(root, ".cms_harness.json")
        RealDisk.write!(config, Jason.encode!(%{working_copy_id: working_copy_id, root: root}))

        # Work in the checkout, so "the directory is untouched" means something
        # more than "an empty directory is still empty".
        source = Path.join([root, "lib", "kept.ex"])
        RealDisk.mkdir_p!(Path.dirname(source))
        RealDisk.write!(source, "defmodule Kept do\\nend\\n")

        harness(context, device, %{working_copy_id => root})

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:config, config)
         |> Map.put(:source, source)
         |> Map.put(:working_copy_id, working_copy_id)}
      end

      when_ "I offboard it", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        live
        |> element("#offboard-#{context.working_copy_id} [data-role='confirm-confirm']")
        |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      then_ "its row and its derived data are removed", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        refute has_element?(
                 live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.working_copy_id}']"
               ),
               "the offboard did nothing, so this criterion's real assertion — " <>
                 "that the checkout survived — would pass for the wrong reason"

        {:ok, context}
      end

      then_ "and the directory it named is untouched, config file and all", context do
        assert RealDisk.dir?(context.root),
               "offboarding deleted the checkout. The row is ours and the " <>
                 "directory is not, and this button sits one click away in a list " <>
                 "of rows that look alike."

        assert RealDisk.exists?(context.source),
               "the checkout is still standing but its contents are gone, which " <>
                 "is the same loss with a directory left behind to hide it"

        assert RealDisk.exists?(context.config),
               "`.cms_harness.json` was removed from a checkout the server no " <>
                 "longer knows about. Nothing on the server has any business " <>
                 "reaching into a working copy — and re-onboarding is what " <>
                 "rewrites that file, from the machine that owns it."

        {:ok, context}
      end
    end
  end
end
