defmodule CodeMySpecSpex.Story1030.Criterion1588Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1588 — The harness launches a non-main copy's app told that it
  is not main.

  Rule: A non-main working copy's app starts no Cloudflare tunnel of its
  own. The harness tells the booting app whether it is main via
  `CMS_MAIN_COPY`; unset or true reads as main (unchanged default),
  explicitly false disables every `ClientUtils.CloudflareTunnel` child the
  app would otherwise start.

  Found live: a non-main copy's dev boot reads main's own hardcoded tunnel
  hostname, id and account tag straight out of `config/dev.exs` — the same
  config every `:dev` boot reads, main or not — so every copy that came up
  ran a second `cloudflared` answering for main's tunnel from a different
  port. Harmless only because every copy's config named the same origin
  main's did; a live risk the moment one didn't (Cloudflare splitting
  main's public traffic between the two apps). This is the safe, shipped
  subset of the (project, device) tunnel-sharing design also on this
  story — it stops the stray connector; it does not yet give a non-main
  copy a working preview of its own (the ingress-sharing half is not yet
  built).

  Two `spex` blocks, not two scenarios in one: `app_instance_rig/1` starts a
  fake server singleton per test process, and scenarios inside one `spex`
  block share that process (see criterion 1541's own file for the pattern
  this follows for a single scenario).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A non-main copy is launched told that it is not main", criterion: 1588 do
    scenario "the harness ensures a non-main copy's app is running" do
      given_ "a non-main working copy with a serve recipe", context do
        rig = app_instance_rig(database_exists?: true)
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running, not as main", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app comes up serving", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "launch was told this copy is not main", context do
        assert [{:launch, [_root, _port, _https_port, _database, _log_path, main?, _tunnel_held?]}] =
                 Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

        refute main?,
               "a non-main copy's launch should be told it is not main, so its own " <>
                 "config/dev.exs can skip starting a Cloudflare tunnel for it — " <>
                 "without this every copy runs a second connector answering for " <>
                 "main's tunnel."

        {:ok, context}
      end
    end
  end

  spex "Main's own launch is unaffected", criterion: 1588 do
    scenario "the harness ensures main's own app is running" do
      given_ "main's own working copy with a serve recipe", context do
        rig = app_instance_rig(database_exists?: true)
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure main's app is running", context do
        {:ok, Map.put(context, :result, push_app_event_as_main("ensure_app_running"))}
      end

      then_ "the app comes up serving", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "launch was told this copy is main, same as before this existed", context do
        assert [{:launch, [_root, _port, _https_port, _database, _log_path, main?, _tunnel_held?]}] =
                 Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

        assert main?,
               "main's own launch should still be told it is main, so its tunnel " <>
                 "keeps starting exactly as it always has."

        {:ok, context}
      end
    end
  end
end
