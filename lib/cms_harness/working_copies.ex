defmodule CmsHarness.WorkingCopies do
  @moduledoc """
  Which working copy a harness id names, on this harness.

  A hook arrives addressed to an id and nothing else. Turning that into a
  directory is this module's whole job.

  ## Derived, never stored

  There is no local record of harnesses here, and there is not meant to be.
  Harness records belong to the server; a copy of them on the harness would be
  a second source of truth that has to be reconciled, and reconciling it is
  exactly the work the harness exists to avoid.

  Nor is there a database to put them in. The harness has to run standalone —
  that is the sprite, which is the case that matters most — so anything it
  needs before it can answer a hook has to come from its own configuration and
  the disk it is already watching. Both are present before the network is.

  So the mapping is computed: the roots this harness serves are its
  configuration, and the id of each is the file in it. A sprite serves one copy
  and the question is nearly vacuous. A laptop serving several answers it by
  looking at the few directories it was told about.

  ## An unknown id is refused

  Not resolved to the nearest plausible checkout. What this replaces walked up
  from whatever directory the hook fired in until it found a `mix.exs`, so a
  copy nobody had onboarded silently adopted whichever project sat above it,
  and two copies of one project could not be told apart at all.
  """

  alias CmsHarness.HarnessIdentity
  alias CmsHarness.Projects

  @doc """
  The directory this id names, or `:unknown`.

  Running subtrees are consulted first because they are the copies this harness
  is actually serving; configuration is the fallback for one that has not been
  started yet, which is the first hook after a cold boot.
  """
  @spec root(String.t()) :: {:ok, String.t()} | :unknown
  def root(harness_id) when is_binary(harness_id) and harness_id != "" do
    case find(Projects.list(), harness_id) do
      {:ok, root} -> {:ok, root}
      :unknown -> find(configured_roots(), harness_id)
    end
  end

  def root(_), do: :unknown

  @doc """
  Every working copy this harness could serve, as `id => root`.

  For the health endpoint and for saying, when an id is refused, what this
  harness does know about — a refusal that lists nothing is indistinguishable
  from a harness that is not running.
  """
  @spec all() :: %{String.t() => String.t()}
  def all do
    (Projects.list() ++ configured_roots())
    |> Enum.uniq()
    |> Enum.flat_map(&entry/1)
    |> Map.new()
  end

  defp find(roots, harness_id) do
    roots
    |> Enum.find(fn root -> identity(root) == harness_id end)
    |> case do
      nil -> :unknown
      root -> {:ok, root}
    end
  end

  defp entry(root) do
    case identity(root) do
      nil -> []
      id -> [{id, root}]
    end
  end

  # `CMS_HARNESS_ID` is honoured by `HarnessIdentity`, and on a sprite it is
  # how the container is told who it is without a writable checkout.
  defp identity(root) do
    case HarnessIdentity.read(root) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  # The copies this harness was told to serve. One on a sprite; a short list on
  # a laptop running several checkouts.
  defp configured_roots do
    from_env() ++ from_config()
  end

  defp from_env do
    case System.get_env("CMS_PROJECT_DIR") do
      dir when is_binary(dir) and dir != "" -> [Path.expand(dir)]
      _ -> []
    end
  end

  defp from_config do
    :code_my_spec
    |> Application.get_env(:harness_project_dirs, [])
    |> List.wrap()
    |> Enum.map(&Path.expand/1)
  end
end
