defmodule CodeMySpec.Embeddings.FailedDocPackagesCanBeRetriedTest do
  @moduledoc """
  A `failed` marker is final to `pending/0`. When its cause is fixed — the
  version-blind index that made eight packages fail on a unique violation —
  `reset_failed/1` puts the markers back in the queue rather than anyone
  writing to `doc_packages` by hand.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.Serving

  defp marker!(package, status, error) do
    Repo.insert!(%DocPackage{
      package: package,
      version: "1.0.0",
      model: Serving.model_name(),
      status: status,
      error: error
    })
  end

  defp status(package), do: Repo.get_by!(DocPackage, package: package)

  setup do
    marker!("credo", "failed", "unique_violation on doc_embeddings_shared_path_chunk_index")
    marker!("bandit", "failed", "%Req.TransportError{reason: :closed}")
    marker!("chatterbox", "failed", "{:http_status, 404}")
    marker!("decimal", "embedded", nil)
    :ok
  end

  test "resets every failed marker, except those named, to pending with no attempts" do
    assert Embeddings.reset_failed_doc_packages(except: ["chatterbox"]) == 2

    assert %{status: "pending", attempts: 0, error: nil} = status("credo")
    assert %{status: "pending", attempts: 0} = status("bandit")
    assert %{status: "failed"} = status("chatterbox")
    assert %{status: "embedded"} = status("decimal")
  end

  test "narrows to an error class, or to named packages" do
    assert Embeddings.reset_failed_doc_packages(error_like: "unique_violation") == 1
    assert %{status: "failed"} = status("bandit")

    assert Embeddings.reset_failed_doc_packages(packages: ["bandit"]) == 1
    assert %{status: "failed"} = status("chatterbox")
  end

  test "the main agent's tool says how many it reset" do
    frame = %Frame{assigns: %{current_scope: full_scope_fixture()}}

    response =
      ToolLibrary.run(
        "reset_doc_packages",
        %{except: ["chatterbox"]},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert {:ok, text} = response
    assert text =~ "Reset 2 failed doc package(s)"
  end
end
