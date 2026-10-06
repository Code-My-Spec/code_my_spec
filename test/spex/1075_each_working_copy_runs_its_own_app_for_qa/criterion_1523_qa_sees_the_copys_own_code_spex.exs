defmodule CodeMySpecSpex.Story1108.Criterion1523Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 1523 — QA sees the copy's own code.

  Rule: A copy's app serves the copy's own commit, not main's.

  This is the criterion the whole story exists for (issue 2d612ae8): QA
  verified story 1103's fix on the feature copy, but the copy's URL
  silently served main's pre-fix code, so QA was shown a page the branch
  did not contain. The assertion that closes that bug is the one made
  here: asked for its app, the copy reports serving *its own* HEAD —
  a commit main does not have, distinct from main's — rather than
  whatever commit main happens to be on.

  Driven over the real wire: the server pushes `ensure_app_running` to
  the copy's connected harness, the copy's real `ChannelClient` and
  `AppInstance` answer, and `app_commit` is read off this copy's own
  root by `Runner.current_commit/1` at start.

  One copy per rig. `app_instance_rig/1` serves a single root and starts
  a single `AppInstance` for it, and `FakeServer` carries one connected
  harness channel, so main and a feature copy cannot both be driven from
  one spec file. Main's side of this rule — that main keeps serving
  main, at its own commit — is what criteria 1536 and 1537 already
  assert through the same surface.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A copy's app serves the copy's own commit, not main's", criterion: 1523 do
    scenario "a feature copy whose HEAD is a commit main does not have" do
      given_ "a working copy whose HEAD is a commit main does not have", context do
        rig = app_instance_rig(current_commit: "feed1523")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the copy's harness for its app", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app reports serving the feature copy's own commit", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => commit} =
                 context.result

        assert commit == "feed1523",
               "the copy's app reported #{inspect(commit)} — not the commit this copy has. " <>
                 "A copy whose URL serves a commit its branch does not contain is exactly " <>
                 "issue 2d612ae8: QA is shown code the branch never had."

        {:ok, context}
      end

      then_ "and the commit it reports was read off this copy's own checkout", context do
        roots =
          FakeAppInstanceRunner.calls()
          |> Enum.filter(&match?({:current_commit, _}, &1))
          |> Enum.map(fn {:current_commit, [root]} -> root end)

        assert context.root in roots,
               "the reported commit was not read off the copy's own root (#{context.root}) — " <>
                 "it came from somewhere else, which is how main's code ends up on a copy's URL"

        {:ok, context}
      end
    end
  end
end
