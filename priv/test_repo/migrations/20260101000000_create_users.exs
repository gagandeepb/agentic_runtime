defmodule AgenticRuntime.TestRepo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      timestamps(type: :utc_datetime_usec)
    end
  end
end
