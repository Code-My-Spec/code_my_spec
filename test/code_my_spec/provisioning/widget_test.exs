defmodule CodeMySpec.Provisioning.WidgetTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.CodeGeneration
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Widget
  alias CodeMySpec.Users.Scope

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    %{env: Environment.new(:local, tmp), scope: %Scope{}}
  end

  defp page(body), do: fn _url -> {:ok, %{status: 200, body: body}} end

  defp installed_page,
    do:
      ~s(<html><body><div data-cms-widget><button data-cms-widget-toggle></button></div></body></html>)

  defp from_site, do: fn _scope -> [%{origin: "deployed_site", body: "the widget works"}] end
  defp no_messages, do: fn _scope -> [] end

  describe "verify_present/2" do
    test "passes when the widget is both present and openable" do
      assert {:ok, %{present: true, openable: true, status: 200}} =
               Widget.verify_present("https://sams-site.com", fetch: page(installed_page()))
    end

    # Present-but-not-openable is the shape a broken bundle takes: the mount
    # point renders, the script never loads, and the HTML looks correct to
    # anyone reading it.
    test "a mount point with no bundle is not openable" do
      body = ~s(<html><body><div data-cms-widget></div></body></html>)

      assert {:error, %{present: true, openable: false}} =
               Widget.verify_present("https://sams-site.com", fetch: page(body))
    end

    test "a page without the widget at all fails" do
      assert {:error, %{present: false, openable: false}} =
               Widget.verify_present("https://sams-site.com", fetch: page("<html></html>"))
    end

    test "a non-200 fails rather than being read for markup" do
      fetch = fn _ -> {:ok, %{status: 503, body: installed_page()}} end

      assert {:error, %{status: 503, present: false}} =
               Widget.verify_present("https://sams-site.com", fetch: fetch)
    end

    test "an unreachable site is an error, not a crash" do
      fetch = fn _ -> {:error, :nxdomain} end

      assert {:error, %{present: false, openable: false}} =
               Widget.verify_present("https://sams-site.com", fetch: fetch)
    end
  end

  describe "probe_degraded/2 — a down backend must not break the page" do
    # Criterion 8043. A feedback widget that white-screens the site is worse
    # than no widget: it breaks the thing it was added to improve.
    test "passes when the page still serves and the widget says unavailable" do
      body =
        ~s(<html><body><h1>Sam's site</h1><div data-cms-widget data-cms-widget-state="unavailable"></div></body></html>)

      assert {:ok, %{page_status: 200, page_usable: true, widget_state: "unavailable"}} =
               Widget.probe_degraded("https://sams-site.com", fetch: page(body))
    end

    # The widget silently pretending to work is its own failure — it swallows
    # feedback the visitor believes was sent.
    test "a page claiming a live widget connection fails" do
      body =
        ~s(<html><body><h1>Sam's site</h1><div data-cms-widget data-cms-widget-state="connected"></div></body></html>)

      assert {:error, %{widget_state: "connected"}} =
               Widget.probe_degraded("https://sams-site.com", fetch: page(body))
    end

    # A page with no widget on it degrades perfectly and proves nothing, so
    # this used to report a site where the install had silently done nothing
    # as resilient.
    test "a page with no widget at all fails rather than degrading cleanly" do
      body = ~s(<html><body><h1>Sam's site</h1></body></html>)

      assert {:error, %{widget_state: "absent"}} =
               Widget.probe_degraded("https://sams-site.com", fetch: page(body))
    end

    test "a page broken by the outage fails even if the widget marks itself unavailable" do
      body = ~s(<html><body>Application error<div data-cms-widget data-cms-widget-state="unavailable"></div></body></html>)

      assert {:error, %{page_usable: false}} =
               Widget.probe_degraded("https://sams-site.com", fetch: page(body))
    end

    test "a 500 is a failure, not a degradation" do
      fetch = fn _ -> {:ok, %{status: 500, body: ""}} end

      assert {:error, %{page_status: 500, page_usable: false}} =
               Widget.probe_degraded("https://sams-site.com", fetch: fetch)
    end
  end

  describe "message_proof/2" do
    # Criterion 8044: proven by a message, not by markup.
    test "accepts a message that came from the deployed site", %{scope: scope} do
      assert {:ok, %{state: "received", origin: "deployed_site"}} =
               Widget.message_proof(scope, lookup: from_site())
    end

    # A message from a local dev server proves the backend works and says
    # nothing about the widget being installed where visitors are.
    test "rejects a message from anywhere else", %{scope: scope} do
      lookup = fn _ -> [%{origin: "localhost"}, %{origin: "seed"}] end

      assert {:error, :no_message} = Widget.message_proof(scope, lookup: lookup)
    end

    test "no messages at all is not proof", %{scope: scope} do
      assert {:error, :no_message} = Widget.message_proof(scope, lookup: no_messages())
    end

    test "reads origin from string-keyed messages too", %{scope: scope} do
      lookup = fn _ -> [%{"origin" => "deployed_site"}] end

      assert {:ok, _} = Widget.message_proof(scope, lookup: lookup)
    end
  end

  describe "run/3" do
    # Returns an absolute path rather than prepending to PATH — mutating PATH
    # from an async test leaks into every other test in the run.
    defp fake_mix(dir, exit_code) do
      path = Path.join(dir, "fake_mix")
      File.write!(path, "#!/bin/sh\necho generator ran\nexit #{exit_code}\n")
      File.chmod!(path, 0o755)
      path
    end

    # Records what the step actually shelled out to. The other tests here stub
    # `mix_bin` with a script that succeeds whatever it is passed, so a wrong
    # command passed them all.
    defp recorded_args(env, scope) do
      recorder = Path.join(env.cwd, "recording_mix")
      log = Path.join(env.cwd, "mix_args.txt")

      File.write!(recorder, "#!/bin/sh\necho \"$@\" > #{log}\necho generator ran\nexit 0\n")
      File.chmod!(recorder, 0o755)

      Widget.run(scope, env,
        site_url: "https://sams-site.com",
        deploy_key: "dk_live",
        mix_bin: recorder,
        fetch: page(installed_page()),
        lookup: from_site()
      )

      log |> File.read!() |> String.trim()
    end

    # The step ran `client_utils.gen.chat_widget` long after that task was
    # deprecated and dropped from the published package, so every run exited 1
    # on "the task could not be found". Pinning the name to the scaffolder's
    # list is the check that survives the next move: the widget provisioning
    # proves has to be the widget new projects are given.
    test "invokes a generator this project actually ships", %{env: env, scope: scope} do
      task = recorded_args(env, scope) |> String.split() |> List.first()

      shipped =
        CodeGeneration.generators()
        |> Enum.map(fn {_id, command, _desc, _dep, _artifact} -> command end)

      assert "mix #{task}" in shipped,
             "the widget step runs `mix #{task}`, which is not one of the generators " <>
               "this project installs: #{inspect(shipped)}"
    end

    # `mix run <task>` looks for a *file* of that name and exits, so the task
    # has to come first rather than behind a subcommand.
    test "invokes the generator as a mix task, not as a file", %{env: env, scope: scope} do
      assert recorded_args(env, scope) |> String.starts_with?("cms_gen.")
    end

    test "is proven only when a real message arrived", %{env: env, scope: scope} do
      mix = fake_mix(env.cwd, 0)

      result =
        Widget.run(scope, env,
          site_url: "https://sams-site.com",
          deploy_key: "dk_live",
          mix_bin: mix,
          fetch: page(installed_page()),
          lookup: from_site()
        )

      assert result.state == :proven
      assert %DateTime{} = result.proven_at
    end

    # Markup can be right while the socket, credential or CORS is wrong. Those
    # all produce a page that looks correct and a widget nobody can send
    # through, which is why installation is not the finish line.
    test "installed and openable but with no message is not done", %{env: env, scope: scope} do
      mix = fake_mix(env.cwd, 0)

      result =
        Widget.run(scope, env,
          site_url: "https://sams-site.com",
          deploy_key: "dk_live",
          mix_bin: mix,
          fetch: page(installed_page()),
          lookup: no_messages()
        )

      assert result.state == :not_proven
      assert result.proven_at == nil
      assert result.reason =~ ~r/no message/i
    end

    test "a failed generator reports what it said", %{env: env, scope: scope} do
      mix = fake_mix(env.cwd, 1)

      result =
        Widget.run(scope, env,
          site_url: "https://sams-site.com",
          deploy_key: "dk_live",
          mix_bin: mix,
          fetch: page(installed_page()),
          lookup: from_site()
        )

      assert result.state == :install_failed
      assert result.reason =~ "generator ran"
    end

    # Mix says why it failed on stderr — "The task could not be found" never
    # touches stdout. Without :stderr_to_stdout the step reported
    # "Widget generator failed (exit 1): " and nothing, which is the reason
    # a dead generator sat unnoticed: the failure named no cause to chase.
    test "reports a generator that failed on stderr only", %{env: env, scope: scope} do
      mix = Path.join(env.cwd, "stderr_mix")
      File.write!(mix, "#!/bin/sh\necho 'the task could not be found' >&2\nexit 1\n")
      File.chmod!(mix, 0o755)

      result =
        Widget.run(scope, env,
          site_url: "https://sams-site.com",
          deploy_key: "dk_live",
          mix_bin: mix,
          fetch: page(installed_page()),
          lookup: from_site()
        )

      assert result.state == :install_failed

      assert result.reason =~ "the task could not be found",
             "the failure has to carry the generator's own words. got: #{inspect(result.reason)}"
    end
  end
end
