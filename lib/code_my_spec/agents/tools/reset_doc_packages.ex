defmodule CodeMySpec.Agents.Tools.ResetDocPackages do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Embeddings

  @impl true
  def name, do: "reset_doc_packages"

  @impl true
  def description do
    """
    Puts failed hex doc packages back in the queue: `failed` markers become
    `pending` with no attempts, and the next sweep tries them again. For
    failures whose cause has been fixed. Narrow with `packages`, `except` or
    `error_like`; with none, every failed package is reset. Returns the count.
    """
  end

  @impl true
  def params do
    %{
      except: {:meta, {:list, :string}, [description: "Not these package names."]},
      error_like:
        {:meta, :string,
         [description: "Only failures whose error contains this text, e.g. unique_violation."]},
      packages: {:meta, {:list, :string}, [description: "Only these package names."]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, _scope} ->
        count =
          Embeddings.reset_failed_doc_packages(
            packages: Map.get(params, :packages),
            except: Map.get(params, :except),
            error_like: Map.get(params, :error_like)
          )

        {:ok, "Reset #{count} failed doc package(s) to pending."}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end
end
