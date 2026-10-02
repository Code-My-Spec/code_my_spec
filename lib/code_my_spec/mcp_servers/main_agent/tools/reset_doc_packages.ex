defmodule CodeMySpec.McpServers.MainAgent.Tools.ResetDocPackages do
  @moduledoc """
  Puts failed hex doc packages back in the queue: `failed` markers become
  `pending` with no attempts, and the next sweep tries them again. For
  failures whose cause has been fixed. Narrow with `packages`, `except` or
  `error_like`; with none, every failed package is reset. Returns the count.
  """

  # Main-only by role grant. The markers are shared across projects — a
  # package's docs are embedded once for everyone — so this is not scoped to
  # the caller's project.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Embeddings
  alias CodeMySpec.McpServers.Validators

  schema do
    field :packages, {:list, :string}, description: "Only these package names."
    field :except, {:list, :string}, description: "Not these package names."

    field :error_like, :string,
      description: "Only failures whose error contains this text, e.g. unique_violation."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, _scope} ->
        count =
          Embeddings.reset_failed_doc_packages(
            packages: Map.get(params, :packages),
            except: Map.get(params, :except),
            error_like: Map.get(params, :error_like)
          )

        {:reply,
         Response.tool() |> Response.text("Reset #{count} failed doc package(s) to pending."),
         frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(to_string(reason)), frame}
    end
  end
end
