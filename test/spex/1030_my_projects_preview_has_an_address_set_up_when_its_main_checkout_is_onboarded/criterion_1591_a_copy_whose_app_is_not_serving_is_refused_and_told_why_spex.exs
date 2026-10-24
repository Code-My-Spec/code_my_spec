defmodule CodeMySpecSpex.Story1030.Criterion1591Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1591 — A copy whose app is not serving is refused, and told why.

  Rule: A copy's app gets a preview only when its own agent asks, and only
  once the app is serving.

  Sharing points a public hostname at a local port. A port nothing is
  listening on yet is exactly the gap between "reported" and "actually up"
  story 1108's `app_url` exists to close — so `ShareCopyApp` refuses before
  Cloudflare is ever asked anything, and says why, rather than handing back
  an address that resolves to nothing.

  No Cloudflare stub here at all: nothing should reach it. A test that stubs
  Cloudflare and then never receives a call proves less than one where there
  is nothing to stub — a forgotten call would raise instead of silently
  passing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.AppInstances

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.WorkingCopies

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A copy whose app is not serving is refused, and told why", criterion: 1591 do
    scenario "a copy that has never reported its app up asks for a preview" do
      given_ "a copy exists, having never reported its app serving", context do
        reply = join_working_copy(context, "/workspace/worktree", "worktree")

        {:ok, Map.put(context, :copy_id, reply.working_copy_id)}
      end

      when_ "that copy's own agent asks to share it", context do
        frame = %Frame{
          assigns: %{current_scope: %{context.scope | active_working_copy_id: context.copy_id}}
        }

        response =
          ToolLibrary.run(
            "share_copy_app",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused rather than handed an address pointing at nothing", context do
        assert match?({:error, _}, context.response),
               "a copy whose app has never been reported serving was handed a preview " <>
                 "anyway. Got: " <> response_text(context.response)

        assert response_text(context.response) =~ ~r/not serving/i,
               "the refusal did not say why, leaving the agent to guess. Got: " <>
                 response_text(context.response)

        {:ok, context}
      end

      then_ "nothing was recorded for it", context do
        {:ok, saved} = WorkingCopies.fetch(context.copy_id)

        assert AppInstances.for_working_copy(context.scope, saved.id).preview_tunnel_id == nil,
               "the copy holds a tunnel id despite being refused one"

        assert AppInstances.for_working_copy(context.scope, saved.id).preview_url == nil,
               "the copy holds an address despite being refused one"

        {:ok, context}
      end
    end
  end
end
