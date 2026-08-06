defmodule CodeMySpec.Resources do
  @moduledoc """
  What the account should have, against what it actually has.

  ## Two checks, one answer

  **Per project** the expected set comes from `Provisioning.Sequence` and the
  project's chosen options — the same source the run itself uses, so the
  checklist cannot disagree with the thing that does the work. A second
  manifest would be a second truth, and this page exists because the first one
  was already hard enough to trust.

  **Across the account** the checks no single project can make: a DNS record
  aimed at an address no server holds, a bucket no environment names. Neither
  the record nor the server is wrong on its own. What is wrong is the
  relationship, and only something looking at everything can see a relationship.

  ## Which projects count

  `devops != :off`. That setting is the statement "this one is meant to be
  deployed", and it is the only thing that should decide. Inferring intent from
  whether setup happens to have run would let a project you turned on and never
  provisioned report as healthy — the case most worth flagging.

  ## Never from stored step state

  `provisioning_steps.state` records what happened on the last run. A
  certificate that expired since then still reads `done`. The expected side is
  ours; the actual side is the providers', every time.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Resources.Inventory
  alias CodeMySpec.Users.Scope

  @type report :: %{
          status: :healthy | :unhealthy,
          problems: non_neg_integer(),
          resources: [map()],
          checklist: [map()],
          errors: %{atom() => term()}
        }

  @doc """
  The account's health: what exists, what should and does not, and what points
  at nothing.
  """
  @spec report(Scope.t()) :: report()
  def report(%Scope{} = scope) do
    answers = Inventory.list(scope)
    errors = for {provider, {:error, reason}} <- answers, into: %{}, do: {provider, reason}
    found = for {_p, {:ok, list}} <- answers, resource <- list, do: resource

    checklist = checklist(scope)
    resources = Enum.map(found, &classify(&1, found, scope))

    problems =
      Enum.count(resources, &(&1.status == :dangling)) +
        Enum.count(checklist, &(&1.state == :missing))

    %{
      # An unreadable provider is not a clean bill. We do not know what it
      # holds, and saying "healthy" would be a guess dressed as an all-clear.
      status: if(problems == 0 and errors == %{}, do: :healthy, else: :unhealthy),
      problems: problems,
      resources: Enum.sort_by(resources, &{&1.owner, &1.kind, &1.location}),
      checklist: checklist,
      errors: errors
    }
  end

  # What each project meant to be deployed should have, from the same sequence
  # the run uses. `plan/2` fills the gaps a run never reached, which is the
  # only reason a step nobody started can appear here at all.
  defp checklist(scope) do
    for project <- deployable(scope),
        step <- Provisioning.plan(project_scope(scope, project), Provisioning.setup_options(project)) do
      %{
        project_id: project.id,
        project_name: project.name,
        key: step.key,
        state: if(step.state == :done, do: :present, else: :missing),
        detail: step.provider_error
      }
    end
  end

  defp deployable(scope) do
    Enum.filter(Projects.list_projects(scope), &(devops(scope, &1) != :off))
  end

  # Read, never `get_or_create/1`. Loading a page must not write: the first
  # version of this used the get-or-create and silently created a
  # configuration row for every project in the account the moment anyone
  # opened `/app/resources`.
  #
  # No row, or a row predating the column, means nobody has said this project
  # ships — which is `:off`, the same answer the schema default gives.
  defp devops(scope, project) do
    case Configurations.get(project_scope(scope, project)) do
      %{devops: devops} when not is_nil(devops) -> devops
      _ -> :off
    end
  rescue
    _ -> :off
  end

  defp project_scope(%Scope{} = scope, project) do
    %Scope{scope | active_project: project, active_project_id: project.id}
  end

  # Dangling is defined per kind, because "points at nothing" means something
  # different for each. One generic rule would either miss the DNS case or
  # flag things that are fine, and a flag that is wrong often enough stops
  # being read.
  defp classify(%{kind: "dns_record"} = resource, found, _scope) do
    addresses = for %{kind: "server", identifier: ip} <- found, is_binary(ip), do: ip

    status =
      case address_of(resource) do
        nil -> :present
        ip -> if ip in addresses, do: :present, else: :dangling
      end

    put(resource, :domain, status)
  end

  defp classify(%{kind: "bucket"} = resource, _found, scope) do
    named = bucket_names(scope)
    name = resource.location |> String.split("/") |> List.last()

    put(resource, :account, if(name in named, do: :present, else: :dangling))
  end

  defp classify(%{kind: kind} = resource, _found, _scope) when kind in ~w(ssh_key firewall) do
    put(resource, :account, :present)
  end

  defp classify(%{kind: "server"} = resource, _found, _scope), do: put(resource, :server, :present)
  defp classify(resource, _found, _scope), do: put(resource, :project, :present)

  # Only an A record can dangle against a server address. A CNAME or TXT points
  # at a name or a string, and checking those against IPs would flag every one
  # of them.
  defp address_of(%{identifier: "A " <> address}), do: String.trim(address)
  defp address_of(_resource), do: nil

  defp bucket_names(scope) do
    for project <- Projects.list_projects(scope),
        environment <- Provisioning.environments(project_scope(scope, project)),
        into: MapSet.new() do
      "#{Provisioning.Repository.default_name(project)}-#{environment.name}"
    end
  end

  defp put(resource, owner, status) do
    resource
    |> Map.put(:owner, owner)
    |> Map.put(:status, status)
    # Everything the providers report is something that exists; whether *we*
    # made it is a separate question, and one story 999 needs answered before
    # it can offer to delete anything.
    |> Map.put_new(:origin, :unrecorded)
  end
end
