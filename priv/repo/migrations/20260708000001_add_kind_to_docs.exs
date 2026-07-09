defmodule Aveline.Repo.Migrations.AddKindToDocs do
  use Ecto.Migration

  def change do
    alter table(:docs) do
      add :kind, :text, null: false, default: "doc"
    end

    create constraint(:docs, :kind_valid, check: "kind IN ('doc', 'notebook')")
  end
end
