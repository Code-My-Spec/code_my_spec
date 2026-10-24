defmodule CodeMySpecSpex.Story1147.Criterion2397Spex do
  @moduledoc "Story 1147: verified remote landing completes even when the preview device is offline."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.{DeviceSyncHelpers, RemotePromotionHelpers}
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = CodeMySpecSpex.Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "John's promotion completes from verified remote landing", criterion: 2397 do
    scenario "the desktop preview is offline" do
      given_ "a certified source and an offline destination", context do
        {:ok,
         context
         |> RemotePromotionHelpers.remote_project()
         |> DeviceSyncHelpers.offline_destination()
         |> RemotePromotionHelpers.verified_candidate()}
      end

      when_ "the source agent promotes its story", context do
        {:ok,
         context
         |> RemotePromotionHelpers.request_publication()
         |> RemotePromotionHelpers.outcome()}
      end

      then_ "the agent hears successful landing while device application remains pending",
            context do
        assert context.outcome =~ "published to origin/main"
        assert RemotePromotionHelpers.remote_head(context) == context.candidate
        assert DeviceSyncHelpers.copies(context) =~ "device sync pending"

        assert RemotePromotionHelpers.git!(context.destination_root, ["rev-parse", "HEAD"]) ==
                 context.base

        {:ok, context}
      end
    end
  end
end
