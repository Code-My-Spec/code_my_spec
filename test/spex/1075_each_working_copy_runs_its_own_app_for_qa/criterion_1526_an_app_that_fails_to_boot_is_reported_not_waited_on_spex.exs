defmodule CodeMySpecSpex.Story1108.Criterion4650Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4650 — An app that fails to boot is reported, not waited on.

  Rule: The harness starts, restarts and stops a copy's app.

  2026-09-29 revision, Harness session: a first start's launch can
  legitimately take minutes (a cold `npm install`, a compile) that a copy
  which has already run once never needs again, so a fresh copy's own bounded
  wait no longer ends in `down` — it ends in `starting`, with the address, and
  keeps checking in the background toward a 10-minute ceiling. Genuinely never
  coming up still reads as a failure once that ceiling passes: `erroring`,
  pushed unprompted the moment the background watch gives up, with the
  reason. `down` is what `probe/1` answers on its own; it was never this
  criterion's real subject — "reported, not waited on forever" is.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "An app that never answers is reported, not waited on forever", criterion: 1526 do
    scenario "the process starts but nothing ever answers its health check" do
      given_ "a working copy whose app never answers, with no patience left to give it", context do
        set_first_start_ceiling(0)
        rig = app_instance_rig(probe: :down)
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "it is not held open — answered right away, with the address it will be at", context do
        assert %{"status" => "ok", "app_status" => "starting", "app_url" => url} = context.result
        assert url, "starting still names where the app will answer once it is up"

        {:ok, context}
      end

      then_ "the harness did launch it — this is a boot that is failing, not one skipped", context do
        assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1)),
               "a starting report with no launch call would mean the harness gave up before trying"

        {:ok, context}
      end

      then_ "once its ceiling passes without ever answering, it is reported erroring", context do
        assert_receive {:app_status, %{"status" => "erroring"} = payload}, 1_000,
                       "the background watch never reported the ceiling passing"

        assert payload["reason"] =~ "first start exceeded",
               "the erroring report named no reason for an agent to act on"

        {:ok, context}
      end
    end
  end
end
