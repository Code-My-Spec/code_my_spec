defmodule CodeMySpecSpex.Story1112.Criterion2037Spex do
  @moduledoc "Explicit provisioning keeps its recorded outcomes independently of app startup."
  use CodeMySpecSpex.Case, async: false

  spex "Provisioning attempts are recorded once", criterion: 2037 do
    scenario "Reopening an explicit setup run preserves its outcomes" do
      given_ "an isolated setup directory and unavailable development tools", context do
        root = Path.join(System.tmp_dir!(), "setup-history-#{System.unique_integer([:positive])}")
        File.mkdir_p!(root)
        previous = System.get_env("PATH")
        System.put_env("PATH", root)

        on_exit(fn ->
          System.put_env("PATH", previous)
          File.rm_rf!(root)
        end)

        {:ok, Map.put(context, :opts, directory: Path.join(root, "results"))}
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

        assert context.snapshot ==
                 context.snapshot["results_path"] |> File.read!() |> Jason.decode!()

        {:ok, context}
      end
    end
  end
end
