defmodule CodeMySpecSpex.Story1030.Criterion2962Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2962 — A worktree does not claim to be where the preview runs.

  Rule: Onboarding a checkout that is not the main one records no preview address.

  Every worktree can run the app and only one of them is the project's. If a
  second checkout could record the address, whichever rejoined last would own
  it, and the panel would follow whichever harness happened to restart — a
  founder watching their app would find it replaced by a colleague's branch with
  nothing anywhere saying why.

  The join surface rather than onboarding, because this is the case where a
  checkout *asserts* an address it should not have. Onboarding refuses to
  provision one for a worktree; this is the other half — a worktree that has one
  in its config anyway, from a copied file or a hand edit, and the server
  declining to believe it.

  ## The join must still succeed

  Asserted here because the tempting implementation refuses the join outright,
  and that takes a working checkout off the harness entirely — no stop hooks, no
  sync, no agent — to punish a field nothing else depends on. Declining the
  address is the correction; declining the checkout is a much larger one nobody
  asked for.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  # The panel lives in `CodeMySpecWeb`, not the local app the case template
  # points at by default. Without this the route 404s and `live/2` fails
  # inside LiveViewTest rather than saying which router it looked in.
  # Story 1025's criteria drive the same page and override it the same way.
  cloud_endpoint()

  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  @url "https://preview-someone-elses.example.test"

  spex "Only the project's own checkout says where its preview is" do
    scenario "A worktree does not claim to be where the preview runs" do
      given_ "the project's main checkout is already on the harness", context do
        reply = join_working_copy(context, "/workspace/main", "main")

        {:ok, Map.put(context, :main_id, reply.working_copy_id)}
      end

      when_ "a worktree joins claiming a preview address of its own", context do
        reply =
          join_working_copy(context, "/workspace/feature-branch", "worktree", preview_url: @url)

        {:ok, Map.put(context, :worktree_id, reply.working_copy_id)}
      end

      then_ "the worktree is on the harness", context do
        refute context.worktree_id == context.main_id,
               "the second root did not become a second working copy, so this " <>
                 "criterion is not exercising what it claims to"

        assert context.worktree_id,
               "the join was refused. Declining the address is right; declining the " <>
                 "checkout takes it off the harness entirely — no stop hooks, no sync, " <>
                 "no agent — over a field nothing else depends on."

        {:ok, context}
      end

      then_ "the project's preview is not the worktree's", context do
        {:ok, live, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        refute render(live) =~ @url,
               "a worktree's address became the project's preview. Whichever checkout " <>
                 "rejoined last would then own it, and the founder's panel would follow " <>
                 "whichever harness happened to restart."

        {:ok, context}
      end
    end
  end
end
