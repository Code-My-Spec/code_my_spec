defmodule CodeMySpec.Provisioning.ApexRepointTest do
  @moduledoc """
  Whether a run will move a live apex without being asked.

  `assign_hosts/2` gives production the apex and every other environment a
  subdomain, and every project starts with a `prod` row. So once a domain is
  set, a run points the apex at a freshly created, empty box — and if that apex
  is serving a site today, it goes dark. Nothing warned at the point of
  decision, and the only opt-out was deleting the environment, which you have
  to already know about.

  The pause mirrors the one a domain purchase already requires. Registration is
  not refundable; overwriting a live apex is less reversible in the way that
  matters, because the money comes back and the downtime does not.

  Driven through `Cloudflare.find_zone/2` and `list_dns_records/2` seams so the
  decision is tested without a zone.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.{EnvironmentRepository, Steps}

  @apex "example.com"
  @live_ip "172.64.80.1"
  @new_ip "5.161.1.1"

  setup do
    scope = full_scope_fixture()

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @apex})

    scope = %{scope | active_project: project}
    {:ok, _} = EnvironmentRepository.put(scope, "prod", %{host: @apex, ip: @new_ip})

    {:ok, scope: scope}
  end

  defp opts(existing, extra \\ []) do
    Keyword.merge(
      [
        zone: %{"id" => "z1", "name" => @apex},
        dns_records: existing,
        write_dns_record: fn _s, _z, name, ip, _o ->
          send(self(), {:wrote, name, ip})
          {:ok, %{"result" => %{}}}
        end,
        # The step now fails a record that no public resolver returns, so it
        # performs a real DNS-over-HTTPS lookup. `example.com` resolves, so
        # these passed either way — on the network, to decide something that
        # has nothing to do with repointing an apex. Stubbed, or a dns.google
        # outage fails a test about Cloudflare.
        resolver: fn _url ->
          {:ok, %{status: 200, body: %{"Answer" => [%{"data" => @new_ip}]}}}
        end
      ],
      extra
    )
  end

  describe "when the apex already points somewhere else" do
    test "the step pauses and names both addresses", %{scope: scope} do
      existing = [%{"name" => @apex, "type" => "A", "content" => @live_ip}]

      assert {:paused, message} = Steps.run(:dns, scope, opts(existing))

      assert message =~ @live_ip, "expected the address it would replace"
      assert message =~ @new_ip, "expected the address it would point at"

      assert message =~ "remove the `prod` environment",
             "expected the way out to be named — deleting the row is not discoverable otherwise"
    end

    test "confirming lets it through, and the apex is actually repointed", %{scope: scope} do
      existing = [%{"name" => @apex, "type" => "A", "content" => @live_ip}]

      assert {:ok, _resources} =
               Steps.run(:dns, scope, opts(existing, confirm_apex_repoint: true))

      assert_received {:wrote, @apex, @new_ip},
                      "expected the confirmed run to write the apex, not merely to stop pausing"
    end
  end

  describe "when there is nothing to overwrite" do
    # A first run. Pausing here would make the guard a nuisance rather than a
    # safeguard, and would block the case setup exists to serve.
    test "the step does not pause", %{scope: scope} do
      refute match?({:paused, _}, Steps.run(:dns, scope, opts([])))
    end
  end

  describe "when the apex already points at the address we would write" do
    test "the step does not pause", %{scope: scope} do
      existing = [%{"name" => @apex, "type" => "A", "content" => @new_ip}]

      refute match?({:paused, _}, Steps.run(:dns, scope, opts(existing)))
    end
  end

  describe "a subdomain pointing somewhere else" do
    # This run's to move. The apex is the valuable hostname and the one a
    # person did not necessarily choose to give us.
    test "does not pause", %{scope: scope} do
      {:ok, _} = EnvironmentRepository.put(scope, "uat", %{host: "uat.#{@apex}", ip: @new_ip})
      existing = [%{"name" => "uat.#{@apex}", "type" => "A", "content" => @live_ip}]

      refute match?({:paused, _}, Steps.run(:dns, scope, opts(existing)))
    end
  end

  describe "a record that does not resolve" do
    # The step checked this and threw the answer away: `dns_verification/2`
    # returned an empty resource list and the step reported done, with no
    # `verify(:dns, …)` clause to catch it either. The failure then surfaced
    # ten minutes later at `tls`, as a certificate problem, on a host teardown
    # was about to destroy.
    test "fails this step instead of the one ten minutes later", %{scope: scope} do
      silent = [resolver: fn _url -> {:ok, %{status: 200, body: %{}}} end]

      assert {:error, message} = Steps.run(:dns, scope, opts([], silent))
      assert message =~ @apex
      assert message =~ "no public resolver returns it"
    end

    test "the address it wrote is named, so there is something to check", %{scope: scope} do
      silent = [resolver: fn _url -> {:ok, %{status: 200, body: %{}}} end]

      assert {:error, message} = Steps.run(:dns, scope, opts([], silent))
      assert message =~ @new_ip
    end
  end
end
