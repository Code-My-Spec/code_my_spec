defmodule CodeMySpecSpex.Story1108.Criterion4650Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4650 — An app that fails to boot is reported, not waited on.

  Rule: The harness starts, restarts and stops a copy's app.

  A launch that succeeds (a real pid) but never answers health checks is
  reported as `down` once the bounded wait gives up — not held open, and not
  reported as `serving` on the strength of the process merely existing.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "An app that never answers is reported down, not waited on forever", criterion: 1526 do
    scenario "the process starts but nothing ever answers its health check" do
      given_ "a working copy whose app never answers", context do
        rig = app_instance_rig(probe: :down)
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app is reported down, not serving, with no address", context do
        assert %{"status" => "ok", "app_status" => "down"} = context.result
        refute Map.has_key?(context.result, "app_url")

        {:ok, context}
      end

      then_ "the harness did launch it — this is a boot that failed, not one skipped", context do
        assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1)),
               "a down report with no launch call would mean the harness gave up before trying"

        {:ok, context}
      end
    end
  end
end
