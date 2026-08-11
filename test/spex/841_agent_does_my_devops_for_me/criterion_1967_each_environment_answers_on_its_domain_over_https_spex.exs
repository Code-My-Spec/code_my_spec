defmodule CodeMySpecSpex.Story841.Criterion1967Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1967 — Each environment answers on its domain over HTTPS.

  Each, and its own. Two environments that answer on one host are not two
  environments, and a certificate that is merely issued proves nothing until
  something serves behind it.

  Surface: HTTP. The criterion is about what a visitor gets, so the check is an
  outbound request with certificate validation on — the same thing a browser
  does. A page saying "done" is not evidence.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.RunDevopsSetup

  @cassette "841_1967_environments_answer_over_https"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :provider_credentials_on_file
  setup :connect_providers
  # sops and age are real binaries reading real files. The default fixture's
  # memory environment is invisible to them, so the server step's write of
  # DATABASE_URL into envs/<env>.enc.env landed nowhere sops could see and it
  # exited 100 with "cannot operate on non-existent file".
  setup :real_working_directory

  spex "Each environment answers on its domain over HTTPS" do
    scenario "every provisioned environment serves on its own host" do
      given_ "the project has its environments provisioned", context do
        # Registered before anything provisions, so a run that dies partway
        # still returns its boxes.
        #
        # Hetzner's server limit on this account is 5 and two are permanently
        # John's, so a recording has three slots. None of story 841's
        # setup-running criteria returned any, so they accumulated *within a
        # single run*: the first took two, the second took the third, and every
        # one after it got `resource_limit_exceeded` — which then went into the
        # cassette as the story's expected behaviour. No amount of cleaning
        # between runs could have helped, because the exhaustion happens inside
        # one.
        tear_down_after(context.scope, [:server, :storage, :dns])
        tear_down_repository(context.project)

        # Provisioned by running setup. A visitor gets an answer only if
        # something is serving, so the thing that makes something serve has to
        # run before the request in `when_`.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        with_provider_cassette(@cassette <> "_setup", fn ->
          {:reply, _response, _frame} =
            RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)
        end)

        # What setup actually provisioned, carried into the scenario.
        # `environment_hosts/1` read `context[:environments]` and nothing ever
        # put it there, so every run had nothing to fetch and failed on its own
        # premise — "expected at least one provisioned environment to check" —
        # without ever making a request.
        {:ok, Map.put(context, :environments, CodeMySpecSpex.Fixtures.environments(context.scope))}
      end

      when_ "each environment's host is fetched over HTTPS", context do
        results =
          with_provider_cassette(@cassette, fn ->
            Enum.map(environment_hosts(context), fn {name, host} ->
              {name, host, Req.get("https://#{host}", retry: false, receive_timeout: 15_000)}
            end)
          end)

        {:ok, Map.put(context, :results, results)}
      end

      then_ "each answers 200 over a certificate that validates", context do
        assert context.results != [],
               "expected at least one provisioned environment to check"

        for {name, host, result} <- context.results do
          assert {:ok, %{status: 200}} = result,
                 "expected #{name} to answer on #{host} over HTTPS with a valid certificate, " <>
                   "got: #{inspect(result)}"
        end

        {:ok, context}
      end

      then_ "no two environments share a host", context do
        hosts = Enum.map(context.results, fn {_name, host, _result} -> host end)

        assert hosts == Enum.uniq(hosts),
               "two environments answering on one host are not two environments, got: #{inspect(hosts)}"

        {:ok, context}
      end
    end
  end

  # Refuses an environment with no host rather than fetching one.
  #
  # `Req.get("https://" <> nil_host)` dies inside Finch with
  # `host is required for url: https://` — an ArgumentError that names neither
  # the environment nor the step that failed to give it a host, and arrives
  # before any assertion has run. What it actually means is that setup did not
  # get as far as recording a host for that environment, which is worth saying.
  defp environment_hosts(context) do
    environments = Map.get(context, :environments, [])

    for env <- environments do
      assert is_binary(env.host) and env.host != "",
             "environment #{env.name} has no host — setup did not get far enough to " <>
               "record one, so there is nothing to fetch. Check which step errored " <>
               "and why before reading this criterion as an HTTPS failure."

      {env.name, env.host}
    end
  end
end
