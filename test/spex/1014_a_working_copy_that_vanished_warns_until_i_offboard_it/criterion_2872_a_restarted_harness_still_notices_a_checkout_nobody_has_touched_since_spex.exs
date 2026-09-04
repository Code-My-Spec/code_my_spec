defmodule CodeMySpecSpex.Story1014.Criterion2872Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2872 — A restarted harness still notices a checkout nobody has
  touched since.

  Rule: A harness answers for every copy the server says is on its machine, not
  only the ones it has served.

  Found by checking the live harness rather than by reasoning, and it was the
  main case rather than an edge.

  `CmsHarness.WorkingCopies.all/0` is built from `Projects.list/0` — the roots
  this harness has been *asked* to serve since it started — and it is asked by a
  hook arriving. So a restarted harness knows only the copies somebody is
  actively working in. The copy whose worktree was deleted is exactly the one
  nobody will work in again, so it never enters the list, is never stated, and
  the server reads that as no news forever.

  The first cut had the reporter remember every copy it had ever read, which
  covers a deletion *while it is up* and covers nothing across a restart — and
  harness restarts here are routine (`just refresh-harness`). Persisting the
  memory was the other option and is worse: a second source of truth that drifts,
  and still blind to a copy served by a different install on the same box.

  The server already knows, because `working_copies.device_id` is set on join.
  So the announce became an exchange in both directions — the machine says what
  it can see, the server says what it is carrying — and the harness looks where
  it is told.

  The two reports in the `when_` are the real shape, not a workaround. A harness
  with nothing to say still has something to ask, and it can only answer for
  what it has been told about on the report after being told.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A harness looks where the server tells it, not only where it has been" do
    scenario "A restarted harness still notices a checkout nobody has touched since" do
      given_ "a working copy whose checkout was deleted, on a device whose harness has since restarted and been asked to serve nothing",
             context do
        device = device_id(context, hostname: "the-laptop")

        root = checkout("placeholder")

        joined =
          join_working_copy(context, root, "the copy nobody came back to", device_id: device)

        working_copy_id = joined.working_copy_id

        File.write!(
          Path.join(root, ".cms_harness.json"),
          Jason.encode!(%{working_copy_id: working_copy_id, root: root})
        )

        # The checkout goes, and then the harness restarts — in that order,
        # which is the order that hurts. Nothing hooks into this copy again,
        # because there is nothing there to work in.
        remove(root)

        # A harness that has served nothing: `known` empty, exactly as it is
        # after a restart until the first hook arrives for some other copy.
        restarted = harness(context, device, %{})

        {:ok,
         context
         |> Map.put(:working_copy_id, working_copy_id)
         |> Map.put(:harness, restarted)}
      end

      when_ "the harness reports what it can see", context do
        # It can see nothing, so this report is a question.
        first = report(context.harness)

        # And this one is the answer to it.
        second = report(context.harness)

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      then_ "it asks the server what it is carrying, and answers for that copy on its next report",
            context do
        # About *this* copy, not about the machine holding none at all.
        #
        # It asserted `context.first == %{}` and that held only while nothing in
        # the run had started `CmsHarness.Registry`. `WorkingCopyReporter`'s
        # `current_roots/0` answers `%{}` until the registry is up and reads
        # `CmsHarness.WorkingCopies.all/0` afterwards — which includes the
        # checkout the suite is running in, because its own `.cms_harness.json`
        # is right there. Any scenario that starts an agent brings the registry
        # up, and it is unlinked on purpose so it outlives the one that did.
        #
        # So the old form was passing on ordering. The premise it exists to
        # state is that the harness has never served *this* copy, and that is
        # what is asserted now.
        refute Map.has_key?(context.first, context.working_copy_id),
               "the premise is a harness that has never served this copy; if it " <>
                 "had something to say about it here it learned it somewhere this " <>
                 "criterion is not testing. Got: #{inspect(context.first)}"

        assert context.second[context.working_copy_id] == false,
               "the harness never found out it was carrying this copy. Its own " <>
                 "list only ever holds roots a hook has asked it to serve, and " <>
                 "nobody will hook into a directory that is not there — so the " <>
                 "copy this whole story is about is the one copy the harness " <>
                 "could not see, and the server would wait for a report that " <>
                 "never came. Got: #{inspect(context.second)}"

        {:ok, context}
      end

      then_ "and the copy is shown as missing without anybody having worked in it again",
            context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        assert has_element?(
                 live,
                 "[data-working-copy-id='#{context.working_copy_id}'] [data-test='path-missing']"
               ),
               "the harness reported the copy gone and the page does not say so"

        {:ok, context}
      end
    end
  end
end
