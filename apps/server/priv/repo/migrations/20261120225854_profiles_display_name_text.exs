defmodule TSpec.Repo.Migrations.ProfilesDisplayNameText do
  use Ecto.Migration

  # `display_name` was varchar(255), which counts code points, while its
  # limit is 50 graphemes: 50 emoji made of several code points each (a
  # family is seven) failed the insert with a 500. Its length is checked in
  # `Profile.changeset/2` (`TSpec.TextLimit`), as `bio`'s is. varchar to
  # text needs no table rewrite in Postgres.
  def change do
    alter table(:profiles) do
      modify :display_name, :text, from: :string
    end
  end
end
