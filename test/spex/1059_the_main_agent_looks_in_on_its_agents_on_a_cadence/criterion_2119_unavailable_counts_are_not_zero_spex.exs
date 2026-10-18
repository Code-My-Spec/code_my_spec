defmodule CodeMySpecSpex.Story1059.Criterion2119Spex do
  @moduledoc "Unavailable evidence is a failure rather than invented zero progress"
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Unavailable evidence is a failure rather than invented zero progress", criterion: 2119 do
    scenario "Unavailable evidence is a failure rather than invented zero progress" do
      given_ "a source needed for the digest is unavailable", context do
        :ok = Fixtures.break_digest_source(context.scope)
        {:ok, context}
      end

      when_ "main requests the report", context do
        result =
          ToolLibrary.run(
            "check_in",
            %{},
            Map.put(
              Compact.frame(context).assigns,
              :scope,
              Compact.frame(context).assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "failure stays visible and no counts or healthy verdict are fabricated", context do
        assert match?({:error, _}, context.result)
        text = response_text(context.result)
        assert text =~ "could not be assembled"
        refute text =~ "0/0"
        refute text =~ "Nothing needs you"
        refute_received {:work_turn_requested, _, _, _}
        {:ok, context}
      end
    end
  end
end
