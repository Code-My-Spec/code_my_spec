defmodule CodeMySpec.HttpClientsAreStubbableTest do
  @moduledoc """
  Every module that calls Req either has a test plug pinned, or is listed here
  with a reason.

  A client whose plug is unset makes a **real** request when a credential
  happens to be present, and says nothing about it — a successful call logs
  nothing at all. That is not hypothetical:

    * `Analytics.GoogleAnalytics` delivered 2,407 events in one suite run to
      the live GA4 property, silently, for as long as `envs/test.env` carried
      real credentials. `runtime.exs` claimed a no-op adapter guarded it; there
      was no such adapter.
    * `hetzner_test` reached the live Hetzner API and got back
      `{:hetzner_error, 401, "the token you have provided is invalid"}` — a
      genuine reply, in a test whose subject was the *unconfigured* path.
    * `Deploy.probe/2` did real DNS lookups with a 2s timeout.

  Pinning `plug: {Req.Test, Mod}` in `config/test.exs` fixes both halves: the
  stub resolves per calling process, so two async tests never share one; and a
  call with **no** stub raises instead of reaching the internet.

  This test exists because that was a one-time cleanup and one-time cleanups
  rot. A new Req client fails here until someone decides which it is — pinned,
  or an exception with a reason. Same shape as `CassetteFilteringTest`.
  """

  use ExUnit.Case, async: true

  # Reasons, not a mute button. Each entry says why a pinned plug is not the
  # answer for that module — and several are worth revisiting.
  @allowed %{
    # Loopback only. These talk to a FakeUpstream or a local container the test
    # starts itself, so there is no external host to reach.
    CmsHarness.Web.McpController => :loopback,
    CmsHarness.Web.MessagesController => :loopback,
    CmsHarness.Web.PermissionController => :loopback,
    CodeMySpecLocalWeb.BootstrapController => :loopback,
    CodeMySpecLocalWeb.PermissionController => :loopback,
    CodeMySpec.Workspaces.Runner.Docker => :loopback,

    # Stubbable through a differently-named knob rather than `{Req.Test, Mod}`.
    # Fine, but it means this file cannot check them — if one of these grows a
    # live call, nothing here will notice.
    CodeMySpec.ProjectUsers.Client => :other_knob,
    CodeMySpec.Content.ExAwsReqClient => :other_knob,
    CodeMySpec.Migration.Client => :other_knob,
    CodeMySpec.Workspaces.PreviewAddress => :other_knob,

    # Funnelled through `Research.Http`, which carries the plug pinned under the
    # `CodeMySpec.Research` config key — one seam for both tools and all three
    # search providers, so there is nothing per-module to pin. What this file
    # would otherwise catch is caught instead by "every Research request is
    # built by Research.Http" below, which is the stronger claim.
    CodeMySpec.Research.Http => :shared_client,
    CodeMySpec.Research.Fetch => :shared_client,
    CodeMySpec.Research.Search.Brave => :shared_client,
    CodeMySpec.Research.Search.Serper => :shared_client,
    CodeMySpec.Research.Search.Tavily => :shared_client,

    # Mix tasks. Not run by the suite.
    Mix.Tasks.Cms.Harness.Onboard => :mix_task,
    Mix.Tasks.Google.Token => :mix_task,
    Mix.Tasks.ProdIssues.Pull => :mix_task,

    # Deliberately live, and documented as such: `dns_test` resolves real names
    # because a stubbed resolver would only prove the function calls
    # `:inet_res`. It is the one place in the suite that is *meant* to need the
    # network, and the reason the suite does not pass offline.
    CodeMySpec.Provisioning.Dns => :deliberately_live,

    # Reaches whatever `:base_url` names, which in test is
    # `https://dev.codemyspec.com` — so these do dial out. `working_copies_test`
    # asserts `{:unreachable, _}` and passes *because* that attempt fails,
    # which is a real request proving a negative. Worth pointing at a
    # FakeUpstream instead; left alone here because changing it changes what
    # those tests mean.
    CmsHarness.Config => :dials_configured_server,
    CmsHarness.Token => :dials_configured_server,
    CmsHarness.WorkingCopies => :dials_configured_server,

    # No injection point and no test reaches them today. If one ever does, it
    # will reach the internet — give it a plug rather than adding it here.
    CodeMySpec.Auth.OAuthClient => :unreached,
    CodeMySpec.IndexNow => :unreached,
    CodeMySpec.McpServers.Bootstrap.Tools.InitProject => :unreached,
    CodeMySpec.McpServers.Bootstrap.Tools.ListProjects => :unreached,
    CodeMySpec.Notifications.NotificationClient => :unreached,
    CodeMySpec.Notifications.QuestionClient => :unreached,
    CodeMySpec.Permissions.TapOut => :unreached,
    CodeMySpec.Transcripts.Player => :unreached,
    CodeMySpec.Transcripts.Replayer => :unreached
  }

  @req_call ~r/\bReq\.(get|post|put|patch|delete|request|new)\b/
  @defmodule ~r/defmodule ([A-Za-z0-9_.]+)/

  test "every Req client is pinned to a test plug or listed with a reason" do
    unaccounted = Enum.reject(req_callers(), &accounted?/1)

    assert unaccounted == [],
           """
           These modules call Req with no test plug pinned and no entry in @allowed:

           #{Enum.map_join(unaccounted, "\n", &"  * #{inspect(&1)}")}

           A client with an unset plug makes a real request the moment a
           credential is present, and logs nothing when it succeeds.

           Pin it in config/test.exs:

               config :code_my_spec, Mod, plug: {Req.Test, Mod}

           and stub it per test with `Req.Test.stub(Mod, fun)`. If it genuinely
           cannot be pinned, add it to @allowed with a reason.
           """
  end

  # The instrument itself: if this stops finding the modules it is supposed to
  # police, every assertion above passes vacuously.
  test "the scan actually finds Req clients, including known-pinned ones" do
    callers = req_callers()

    assert length(callers) > 30,
           "expected the scan to find the suite's Req clients, found #{length(callers)}"

    assert CodeMySpec.GitHub in callers,
           "GitHub is a Req client with a pinned plug — if the scan misses it, it misses everything"

    assert CodeMySpec.Provisioning.Hetzner in callers
  end

  test "every Research request is built by Research.Http" do
    # The five `:shared_client` entries above are only safe while this holds.
    # A module under `research/` that builds its own `Req` gets no plug, and a
    # search or fetch in the suite would then reach the live internet — the
    # failure this whole file exists to prevent, arriving through the one door
    # the module-name check cannot watch.
    builders =
      "lib/code_my_spec/research/**/*.ex"
      |> Path.wildcard()
      |> Kernel.++(["lib/code_my_spec/research.ex"])
      |> Enum.filter(fn path -> path |> File.read!() |> String.contains?("Req.new") end)

    assert builders == ["lib/code_my_spec/research/http.ex"],
           """
           Only `Research.Http` may build a `Req` — it is where the test plug is
           attached. These build their own:

           #{Enum.map_join(builders -- ["lib/code_my_spec/research/http.ex"], "\n", &"  * #{&1}")}

           Route them through `Research.Http.new/1` instead.
           """
  end

  test "no allowed entry is stale" do
    callers = MapSet.new(req_callers())
    stale = @allowed |> Map.keys() |> Enum.reject(&MapSet.member?(callers, &1))

    assert stale == [],
           "these are listed in @allowed but no longer call Req — drop them: #{inspect(stale)}"
  end

  defp accounted?(module) do
    Map.has_key?(@allowed, module) or pinned?(module)
  end

  # Read from the file rather than from application env: this is a claim about
  # what the repository configures, and an env read would also pass for a value
  # some other test happened to set.
  defp pinned?(module) do
    "config/test.exs"
    |> File.read!()
    |> String.contains?("{Req.Test, #{inspect(module)}}")
  end

  defp req_callers do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.map(&{&1, File.read!(&1)})
    |> Enum.filter(fn {_path, source} -> Regex.match?(@req_call, source) end)
    |> Enum.flat_map(&module_name/1)
  end

  defp module_name({_path, source}) do
    @defmodule
    |> Regex.run(source)
    |> module_name_match()
  end

  defp module_name_match([_, name]), do: [Module.concat([name])]
  defp module_name_match(_no_match), do: []
end
