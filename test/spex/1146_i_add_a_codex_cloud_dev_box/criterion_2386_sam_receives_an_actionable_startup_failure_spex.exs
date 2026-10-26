defmodule CodeMySpecSpex.Story1146.Criterion2386Spex do
  @moduledoc "Exercises the shipped CLI against an external harness boundary; full release installation is integration QA."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.CodexCloudHelpers

  spex "Sam receives an actionable startup failure", criterion: 2386 do
    scenario "A lost cloud channel is not a ready environment" do
      given_ "a prepared generation target and its harness boundary", context do
        context = prepared_cloud(context)
        boundary_state(context, %{connected: false})
        {:ok, context}
      end

      when_ "Sam runs the cloud environment command", context do
        {:ok, Map.put(context, :result, cloud_command(context, "check"))}
      end

      then_ "the command enforces the required lifecycle", context do
        assert context.result.status != 0
        assert String.downcase(context.result.output) =~ "connect"
        refute context.result.output =~ ~s("ready": true)
        {:ok, context}
      end
    end
  end
end
