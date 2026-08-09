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
  setup :connect_providers

  spex "Each environment answers on its domain over HTTPS" do
    scenario "every provisioned environment serves on its own host" do
      given_ "the project has its environments provisioned", context do
        # Provisioned by running setup. A visitor gets an answer only if
        # something is serving, so the thing that makes something serve has to
        # run before the request in `when_`.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        with_provider_cassette(@cassette <> "_setup", fn ->
          {:reply, _response, _frame} =
            RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)
        end)

        {:ok, context}
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

  defp environment_hosts(context) do
    context
    |> Map.get(:environments, [])
    |> Enum.map(fn env -> {env.name, env.host} end)
  end
end
