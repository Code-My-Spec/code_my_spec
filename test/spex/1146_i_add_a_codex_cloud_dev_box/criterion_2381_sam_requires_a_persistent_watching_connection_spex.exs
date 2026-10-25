defmodule CodeMySpecSpex.Story1146.Criterion2381Spex do
  @moduledoc "Exercises the shipped CLI against an external harness boundary; full release installation is integration QA."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.CodexCloudHelpers

  spex "Sam requires a persistent watching connection", criterion: 2381 do
    scenario "An HTTP harness alone does not establish project readiness" do
      given_ "a prepared generation target and its harness boundary", context do
        context = prepared_cloud(context)
        boundary_state(context, %{watching: false})
        {:ok, context}
      end

      when_ "Sam runs the cloud environment command", context do
        {:ok, Map.put(context, :result, cloud_command(context, "check"))}
      end

      then_ "the command enforces the required lifecycle", context do
        assert context.result.status != 0
        assert String.downcase(context.result.output) =~ "watch"
        boundary_state(context, %{watching: true})
        assert cloud_command(context, "check").status == 0
        {:ok, context}
      end
    end
  end
end
