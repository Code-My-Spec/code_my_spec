defmodule CodeMySpecWeb.DevStateController do
  @moduledoc """
  A GET that reconciles the ledger against the runtime, for whoever is debugging.

      GET /dev/state                       every project
      GET /dev/state?project_id=<uuid>     one
      GET /dev/state/run?working_copy_id=<uuid>&source=spex
                                           enqueue analyzers, say what the queue decided

  All GETs, including the one that enqueues. That is deliberate rather than
  sloppy REST: the caller here is a person or an agent with `curl` and a URL,
  and requiring a POST body is the difference between "check this in one line"
  and "write a script first". It is not idempotent and says so in its answer.

  `CodeMySpec.DevState` holds the reasoning and the queries — `CodeMySpecWeb`
  may not reach `Repo`, and a reconcile between two sources of truth is a domain
  question that happens to have a JSON view today.

  Behind `:dev_routes`, which is compile-time, so this is absent from a release
  rather than disabled in one. It reads across every project and tenant, which
  is exactly what must not ship by accident — the same argument
  `DevAgentController` makes for its own route.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.DevState

  def index(conn, params), do: json(conn, DevState.report(params["project_id"]))

  # Whether the agents are working, as opposed to what the database believes.
  #
  # `index` answers belief; this answers behaviour. Tool calls and files on disk
  # are the only two numbers that cannot be faked by a transcript, and the
  # window keeps a fleet that worked this morning from reading as one working
  # now.
  def fleet(conn, params) do
    case params["project_id"] do
      id when is_binary(id) and id != "" ->
        minutes = params |> Map.get("minutes", "15") |> String.to_integer()
        json(conn, DevState.fleet(id, minutes))

      _ ->
        conn |> put_status(422) |> json(%{error: "project_id is required"})
    end
  rescue
    error -> conn |> put_status(500) |> json(%{error: Exception.message(error)})
  end

  def run(conn, params) do
    case DevState.request_run(params["working_copy_id"], params["source"]) do
      {:ok, report} -> json(conn, report)
      {:error, message} -> conn |> put_status(422) |> json(%{error: message})
    end
  end
end
