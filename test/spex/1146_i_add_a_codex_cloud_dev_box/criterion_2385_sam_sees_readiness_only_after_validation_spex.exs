defmodule CodeMySpecSpex.Story1146.Criterion2385Spex do
  @moduledoc "Exercises the shipped CLI against an external harness boundary; full release installation is integration QA."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.CodexCloudHelpers

  spex "Sam sees readiness only after validation", criterion: 2385 do
    scenario "A connected harness cannot bypass target validation" do
      given_ "a prepared generation target and its harness boundary", context do
        context = prepared_cloud(context)
        File.rm!(Path.join(context.cloud_state, "validation.json"))
        {:ok, context}
      end

      when_ "Sam runs the cloud environment command", context do
        {:ok, Map.put(context, :result, cloud_command(context, "check"))}
      end

      then_ "the command enforces the required lifecycle", context do
        assert context.result.status != 0
        assert String.downcase(context.result.output) =~ "validat"
        ready_validation(context)
        ready = cloud_command(context, "check")
        assert ready.status == 0
        assert ready.output =~ "ready"
        {:ok, context}
      end
    end

    scenario "Source changes invalidate a previously successful target validation" do
      given_ "a target whose previous contents passed validation", context do
        {:ok, prepared_cloud(context)}
      end

      when_ "Sam generates a migration without changing the dependency lock", context do
        directory = Path.join(context.cloud_root, "priv/repo/migrations")
        File.mkdir_p!(directory)

        File.write!(
          Path.join(directory, "20261023000000_add_widget.exs"),
          "defmodule AddWidget do\nend\n"
        )

        {:ok, Map.put(context, :result, cloud_command(context, "check"))}
      end

      then_ "the stale result cannot mark the changed target ready", context do
        assert context.result.status != 0
        assert String.downcase(context.result.output) =~ "validat"
        {:ok, context}
      end
    end

    scenario "A healthy harness belonging to another box is rejected" do
      given_ "a validated target with an unrelated machine on the local port", context do
        context = prepared_cloud(context)
        boundary_state(context, %{device_id: Ecto.UUID.generate()})
        {:ok, context}
      end

      when_ "Sam checks the cloud environment readiness", context do
        {:ok, Map.put(context, :result, cloud_command(context, "check"))}
      end

      then_ "the foreign device cannot satisfy readiness", context do
        assert context.result.status != 0
        assert String.downcase(context.result.output) =~ "device identity"
        refute context.result.output =~ ~s("ready": true)
        {:ok, context}
      end
    end
  end
end
