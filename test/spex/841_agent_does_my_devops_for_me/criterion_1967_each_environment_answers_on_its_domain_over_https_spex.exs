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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem, so a step reading what an
  # earlier step wrote finds it.
  setup :fake_working_directory

  spex "Each environment answers on its domain over HTTPS" do
    scenario "every provisioned environment serves on its own host" do
      given_ "the project has its environments provisioned", context do
        # Its own domain, or the domain step refuses and every step behind it
        # reports nothing — the gap 1961 had.
        own_domain(context.project, "c1967.legwork.ca")

        # And a zone covering it, so `ensure_domain` adopts rather than
        # offering to buy the name.
        zone_exists(context, "legwork.ca")

        # A checkout the deploy step accepts, after the domain because the
        # generated `config/deploy.yml` names the host it deploys to.
        deploy_ready_checkout(context)

        # Provisioned by running setup. A visitor gets an answer only if
        # something is serving, so the thing that makes something serve has to
        # run before the request in `when_`.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

        # What setup actually provisioned, carried into the scenario.
        # `environment_hosts/1` read `context[:environments]` and nothing ever
        # put it there, so every run had nothing to fetch and failed on its own
        # premise — "expected at least one provisioned environment to check" —
        # without ever making a request.
        {:ok,
         Map.put(context, :environments, CodeMySpecSpex.Fixtures.environments(context.scope))}
      end

      when_ "each environment's host is fetched over HTTPS", context do
        # Fetched the way a visitor would, one host at a time. Under fakes the
        # site is served from the zone rather than unconditionally, so an
        # environment setup never published a record for does not answer —
        # which is what keeps "each environment answers on *its own* host" a
        # claim rather than a formality.
        results =
          Enum.map(environment_hosts(context), fn {name, host} ->
            {name, host, fetch_site(host)}
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
