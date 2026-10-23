defmodule CodeMySpecSpex.Story1146.Criterion2384Spex do
  @moduledoc "The real resume CLI reuses target validation and preserves files. External database commands and harness HTTP are boundaries; real PostgreSQL persistence requires install QA."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.CodexCloudHelpers

  spex "Sam resumes without destroying state", criterion: 2384 do
    scenario "A previously validated cloud target resumes twice" do
      given_ "a validated checkout with generated work and private state", context do
        context = context |> prepared_cloud() |> database_boundary()
        File.write!(Path.join(context.cloud_root, "generated-work.txt"), "keep my work")
        File.write!(Path.join(context.cloud_state, "credential-sentinel"), "keep private state")
        {:ok, context}
      end

      when_ "Sam resumes the environment twice", context do
        results = Enum.map(1..2, fn _ -> cloud_command(context, "resume") end)
        {:ok, Map.put(context, :results, results)}
      end

      then_ "both resumes succeed while preserving work and state", context do
        Enum.each(context.results, fn result -> assert result.status == 0, result.output end)
        assert File.read!(Path.join(context.cloud_root, "generated-work.txt")) == "keep my work"

        assert File.read!(Path.join(context.cloud_state, "credential-sentinel")) ==
                 "keep private state"

        # This prepared target has no executable mix project: rerunning dependency
        # installation or compilation instead of reusing validation would fail.
        assert Enum.all?(cloud_requests(context), &(&1.path == "/health"))
        {:ok, context}
      end
    end
  end
end
