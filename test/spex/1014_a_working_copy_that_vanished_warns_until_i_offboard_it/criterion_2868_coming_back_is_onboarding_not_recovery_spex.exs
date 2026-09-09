defmodule CodeMySpecSpex.Story1014.Criterion2868Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2868 — Coming back is onboarding, not recovery.

  Rule: A checkout that comes back is onboarded as a new working copy, never
  repaired into the old one.

  Offboard and onboard are inverses, and nothing sits between them.

  The alternative is a repair path: something that recognises a returning
  checkout and reattaches it to the row it used to have. That is a third state to
  build, test and reason about, and its whole value would be preserving derived
  data that regenerates on the next scan anyway — files and problems are a
  projection of the checkout, so a returning copy rebuilds them by doing its job.

  It is also unbuildable in the case that matters. The identity file lives inside
  the checkout, so a removed worktree took it with it; a directory recreated at
  the same path has nothing to present. Recognising it would mean matching on the
  path, and story 1020's criterion 2843 exists because paths do not identify
  anything — every container is at `/workspace/app`.

  So a copy that comes back is a new copy. It gets a new id, and it earns its
  state by scanning.
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

  spex "There is no repair path between offboarding and onboarding" do
    scenario "Coming back is onboarding, not recovery" do
      given_ "a checkout that was offboarded and is created again at the same path",
             context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")
        joined = join_working_copy(context, root, "the first copy", device_id: device)
        first_id = joined.working_copy_id

        RealDisk.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: first_id, root: root})
        )

        reporter = harness(context, device, %{first_id => root})
        remove(root)
        report(reporter)

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        live
        |> element("#offboard-#{first_id} [data-role='confirm-confirm']")
        |> render_click()

        # The directory comes back — a fresh `git worktree add` at the same path.
        # It carries no identity, because the file that held one went with the
        # checkout that was removed.
        RealDisk.mkdir_p!(root)

        refute RealDisk.exists?(Path.join(root, ".cms_harness.json")),
               "the premise is a checkout with nothing to present; a config file " <>
                 "here would make this a different scenario"

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:device, device)
         |> Map.put(:first_id, first_id)}
      end

      when_ "it is onboarded", context do
        # Joining with no id is what onboarding a fresh checkout does: the server
        # mints one. Same route criterion 2859's copy took the first time.
        joined =
          join_working_copy(context, context.root, "the copy that came back",
            device_id: context.device
          )

        {:ok, Map.put(context, :second_id, joined.working_copy_id)}
      end

      then_ "it is issued a new working copy that syncs its files and runs its own analysis",
            context do
        assert is_binary(context.second_id) and context.second_id != context.first_id,
               "the returning checkout was handed the id of the copy that was " <>
                 "offboarded. Nothing could have recognised it: its identity file " <>
                 "went with the directory, so the only thing left to match on is " <>
                 "the path — and paths do not identify anything, which is why " <>
                 "identity is issued here at all. Got: #{inspect(context.second_id)}"

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.second_id}']"
               ),
               "the returning checkout is not on the list, so it did not onboard " <>
                 "and it did not recover either"

        {:ok, Map.put(context, :live, live)}
      end

      then_ "and no step tries to repair it back into the copy that was offboarded",
            context do
        refute has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.first_id}']"
               ),
               "the offboarded copy is back on the list. Onboarding at its old " <>
                 "path resurrected it, which means offboarding is not the inverse " <>
                 "of onboarding but something a later join can undo — and the row " <>
                 "the operator removed is holding state again without them asking."

        refute has_element?(
                 context.live,
                 "[data-working-copy-id='#{context.second_id}'] [data-test='path-missing']"
               ),
               "the new copy inherited the old one's warning, so something did " <>
                 "carry state across the boundary these two acts are meant to " <>
                 "have between them"

        {:ok, context}
      end
    end
  end
end
