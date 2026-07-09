defmodule Aveline.Repo.Migrations.CreateCellRuns do
  use Ecto.Migration

  def change do
    create table(:cell_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict),
          null: false

      # Which cell, on which logical doc — and which version the source
      # came from (provenance, not a current-version pointer).
      add :base_doc_id, :binary_id, null: false
      add :doc_version_id, references(:docs, type: :binary_id, on_delete: :restrict), null: false
      add :block_id, :string, null: false

      # hash(cell source fields + upstream run hashes) — staleness is
      # derived at read by recomputing the expected chain.
      add :snapshot_hash, :string, null: false

      add :status, :string, null: false
      add :outputs, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :stdout, :text

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_type, :string, null: false

      add :duration_ms, :integer
      add :truncated, :boolean, null: false, default: false

      # Append-only: no updated_at.
      add :inserted_at, :timestamptz, null: false
    end

    create index(:cell_runs, [:base_doc_id, :block_id, :inserted_at])
    create index(:cell_runs, [:workspace_id])

    create constraint(:cell_runs, :status_valid, check: "status IN ('ok', 'error')")
    create constraint(:cell_runs, :actor_type_valid, check: "actor_type IN ('human', 'agent')")
  end
end
