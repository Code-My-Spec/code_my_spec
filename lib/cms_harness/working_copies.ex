defmodule CmsHarness.WorkingCopies do
  @moduledoc """
  Which working copy a harness id names.

  A hook arrives addressed to an id. The answer comes from the working copy's
  own config — `CmsHarness.HarnessConfig`, minted at onboarding — which says
  both which harness it is and where it is.

  ## Nothing is discovered

  This used to walk up from the directory a hook fired in, then it read a list
  of directories out of the environment, then it asked the server. Each was
  wrong in its own way: the walk resolved one session differently depending on
  the subdirectory and resolved a nested checkout to the outer one; the list
  put the operator back in the business of registering paths; the lookup made
  the harness unable to answer a hook until the network came up, to fetch a
  fact the checkout already had written down.

  So there is no discovery here at all. The harness serves the working copy it
  was started in, that copy's config says who it is, and a hook naming any
  other id is refused — not resolved to something nearby.
  """

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Projects

  @doc """
  The directory this id names, or `:unknown`.

  Copies already being served answer first — that is every hook after the
  first. Otherwise the harness's own working copy is consulted, which is what
  answers the first one.
  """
  @spec root(String.t()) :: {:ok, String.t()} | :unknown
  def root(harness_id) when is_binary(harness_id) and harness_id != "" do
    case Enum.find(known(), fn {id, _root} -> id == harness_id end) do
      {_id, root} -> {:ok, root}
      nil -> :unknown
    end
  end

  def root(_), do: :unknown

  @doc """
  Every working copy this harness can answer for, as `id => root`.

  The copies it is serving, plus the one it was started in — which is the same
  set once the first hook has arrived, and differs only before it.
  """
  @spec all() :: %{String.t() => String.t()}
  def all, do: Map.new(known())

  defp known do
    [File.cwd!() | Projects.list()]
    |> Enum.uniq()
    |> Enum.flat_map(&entry/1)
  end

  defp entry(root) do
    case HarnessConfig.read(root) do
      {:ok, %{harness_id: id, root: configured}} -> [{id, configured || root}]
      _ -> []
    end
  end
end
