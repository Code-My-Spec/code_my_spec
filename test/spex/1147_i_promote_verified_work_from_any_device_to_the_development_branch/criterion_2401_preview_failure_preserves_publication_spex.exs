defmodule CodeMySpecSpex.Story1147.Criterion2401Spex do
  @moduledoc "Story 1147: a dirty preview is reported independently of successful remote publication."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.{DeviceSyncHelpers, RemotePromotionHelpers}
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = CodeMySpecSpex.Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John sees preview failure without undoing remote success", criterion: 2401 do
    scenario "the destination has uncommitted work" do
      given_ "a published story and local edits on its offline preview", context do
        {:ok,
         context
         |> RemotePromotionHelpers.remote_project()
         |> DeviceSyncHelpers.offline_destination()
         |> RemotePromotionHelpers.verified_candidate()
         |> RemotePromotionHelpers.request_publication()
         |> RemotePromotionHelpers.outcome()
         |> DeviceSyncHelpers.dirty_destination()}
      end

      when_ "the preview reconnects", context do
        {:ok, DeviceSyncHelpers.reconnect(context)}
      end

      then_ "device failure is visible and the remote publication remains complete", context do
        assert DeviceSyncHelpers.await_status(context, "failed") =~ "device sync failed"
        assert context.outcome =~ "published to origin/main"
        assert RemotePromotionHelpers.remote_head(context) == context.candidate

        assert RemotePromotionHelpers.git!(context.destination_root, [
                 "diff",
                 "--",
                 "lib/example.ex"
               ]) =~ "Uncommitted work must survive"

        {:ok, context}
      end
    end
  end
end
