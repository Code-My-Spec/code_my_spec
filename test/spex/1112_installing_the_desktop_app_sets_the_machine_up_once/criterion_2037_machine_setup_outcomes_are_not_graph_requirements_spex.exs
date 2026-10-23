defmodule CodeMySpecSpex.Story1112.Criterion2037Spex do
  @moduledoc "Explicit provisioning keeps its recorded outcomes independently of app startup."
  use CodeMySpecSpex.Case, async: false

  spex "Provisioning attempts are recorded once", criterion: 2037 do
    scenario "Reopening an explicit setup run preserves its outcomes" do
      given_ "an isolated setup directory and unavailable development tools", context do
        {:ok, Map.put(context, :opts, CmsHarnessTest.SetupFixture.isolated_history())}
      end

      when_ "provisioning is explicitly run", context do
        {:ok, snapshot} = CmsHarnessTest.SetupFixture.check_prerequisites(context.opts)
        {:ok, Map.put(context, :snapshot, snapshot)}
      end

      then_ "reads and repeated checks preserve the original attempts", context do
        assert {:ok, context.snapshot} == CmsHarnessTest.SetupFixture.status(context.opts)

        assert {:ok, context.snapshot} ==
                 CmsHarnessTest.SetupFixture.check_prerequisites(context.opts)

        assert Enum.all?(context.snapshot["steps"], &is_binary(&1["finished_at"]))

        assert context.snapshot == CmsHarnessTest.SetupFixture.persisted_result(context.snapshot)

        {:ok, context}
      end
    end
  end
end
