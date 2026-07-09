defmodule Aveline.RunsPeerCodeCellTest do
  @moduledoc """
  One code cell through the full production path on the Peer backend:
  Runs.run_cell → session → peer node, with the frame("name") bridge —
  the resolver closure and the captured outputs cross to the peer, the
  dataframe is rebuilt and rendered THERE, and only strings come back
  into the cell_runs row.
  """
  # Mutates the global :deploy_mode application env, so no async.
  use Aveline.DataCase, async: false

  alias Aveline.DataSources
  alias Aveline.Docs
  alias Aveline.Fixtures
  alias Aveline.Runs
  alias Aveline.Runs.CellRun
  alias Aveline.Runtime.Backend.Peer
  alias Aveline.Runtime.Session

  @moduletag timeout: 120_000

  defp self_template do
    "postgres://#{System.get_env("PGUSER") || "postgres"}:<password>@#{System.get_env("PGHOST") || "localhost"}/aveline_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

  defp self_password, do: System.get_env("PGPASSWORD") || "postgres"

  setup do
    original = Application.fetch_env(:aveline, :deploy_mode)
    Application.put_env(:aveline, :deploy_mode, "local")

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aveline, :deploy_mode, value)
        :error -> Application.delete_env(:aveline, :deploy_mode)
      end
    end)

    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    {:ok, _ds} = DataSources.create(ws.id, "self", self_template(), self_password(), user.id)
    %{user: user, ws: ws}
  end

  test "frame(\"name\") bridges into the peer node", %{user: user, ws: ws} do
    frame = %{
      "type" => "frame",
      "name" => "orders",
      "input" => %{"source" => "self", "query" => "select 1 as amount"}
    }

    code = %{
      "type" => "code",
      "language" => "elixir",
      "content" => ~s{IO.puts("bridged")\nframe("orders") |> Explorer.DataFrame.n_rows()}
    }

    {:ok, doc} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: user.id,
        actor_user_id: user.id,
        actor_type: "agent",
        kind: "notebook",
        title: "Peer notebook",
        blocks: [frame, code],
        intent: "test"
      })

    [frame_block, code_block] = doc.blocks

    # A captured frame run stub — the bridge binds through cell_runs,
    # never the data source.
    %CellRun{}
    |> CellRun.changeset(%{
      workspace_id: doc.workspace_id,
      base_doc_id: doc.base_doc_id,
      doc_version_id: doc.id,
      block_id: frame_block["id"],
      snapshot_hash: Runs.snapshot_hash(frame_block, []),
      status: "ok",
      outputs: %{"columns" => ["region", "amount"], "rows" => [["emea", 50], ["amer", 250]]},
      actor_type: "agent",
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    # First-caller-wins backend choice: route this notebook's session
    # to the peer before run_cell starts it with the test default.
    {:ok, _pid} = Session.ensure(doc.base_doc_id, backend: Peer)

    assert {:ok, %CellRun{} = run} = Runs.run_cell(doc, code_block["id"], %{user_id: user.id, type: "agent"})
    assert run.status == "ok"
    assert run.outputs["result"] == "2"
    assert run.stdout == "bridged\n"
  end
end
