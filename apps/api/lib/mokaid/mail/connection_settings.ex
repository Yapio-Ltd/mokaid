defmodule Mokaid.Mail.ConnectionSettings do
  @moduledoc "Validated, explicit TLS settings shared by mailbox probes and the sync worker."
  import Ecto.Changeset

  @types %{
    email_address: :string,
    display_name: :string,
    username: :string,
    password: :string,
    imap_host: :string,
    imap_port: :integer,
    imap_security: :string,
    smtp_host: :string,
    smtp_port: :integer,
    smtp_security: :string,
    smtp_username: :string,
    smtp_password: :string
  }
  @settings ~w(imap_host imap_port imap_security smtp_host smtp_port smtp_security username smtp_username)

  def normalize(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_security("imap", "tls")
      |> normalize_security("smtp", "starttls")

    changeset =
      {%{}, @types}
      |> cast(attrs, Map.keys(@types))
      |> trim_fields()
      |> default(
        :username,
        if(is_binary(attrs["email_address"]), do: attrs["email_address"], else: nil)
      )
      |> default(:imap_port, if(attrs["imap_security"] == "starttls", do: 143, else: 993))
      |> default(:smtp_port, if(attrs["smtp_security"] == "tls", do: 465, else: 587))
      |> validate_required([:email_address, :username, :password, :imap_host])
      |> validate_format(:email_address, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
      |> validate_length(:email_address, max: 254)
      |> validate_length(:username, max: 320)
      |> validate_length(:password, max: 4096)
      |> validate_length(:smtp_username, max: 320)
      |> validate_length(:smtp_password, max: 4096)
      |> validate_format(:username, ~r/^[^\x00\r\n]+$/)
      |> validate_format(:password, ~r/^[^\x00\r\n]+$/)
      |> validate_format(:smtp_username, ~r/^[^\x00\r\n]+$/)
      |> validate_format(:smtp_password, ~r/^[^\x00\r\n]+$/)
      |> validate_host(:imap_host)
      |> validate_host(:smtp_host)
      |> validate_number(:imap_port, greater_than: 0, less_than: 65_536)
      |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
      |> validate_inclusion(:imap_security, ~w(tls starttls))
      |> validate_inclusion(:smtp_security, ~w(tls starttls))

    case apply_action(changeset, :insert) do
      {:ok, normalized} ->
        {:ok, Map.new(normalized, fn {key, value} -> {Atom.to_string(key), value} end)}

      error ->
        error
    end
  end

  def settings(attrs), do: Map.take(attrs, @settings)

  def credentials(attrs) do
    Map.take(attrs, ~w(username password smtp_username smtp_password))
  end

  defp normalize_security(attrs, protocol, default) do
    legacy = attrs[protocol <> "_ssl"]

    inferred =
      cond do
        legacy in [false, "false", "0", 0] -> "starttls"
        legacy in [true, "true", "1", 1] -> "tls"
        attrs[protocol <> "_port"] in [143, "143", 587, "587"] -> "starttls"
        attrs[protocol <> "_port"] in [993, "993", 465, "465"] -> "tls"
        true -> default
      end

    Map.update(attrs, protocol <> "_security", inferred, fn value ->
      if value in [nil, ""], do: inferred, else: value
    end)
  end

  defp trim_fields(changeset) do
    Enum.reduce(
      [:email_address, :username, :imap_host, :smtp_host, :smtp_username],
      changeset,
      fn field, acc ->
        update_change(acc, field, fn value ->
          if is_binary(value), do: String.trim(value), else: value
        end)
      end
    )
  end

  defp default(changeset, field, value) do
    if get_field(changeset, field) in [nil, ""] do
      put_change(changeset, field, if(is_binary(value), do: String.trim(value), else: value))
    else
      changeset
    end
  end

  defp validate_host(changeset, field) do
    changeset
    |> validate_length(field, max: 253)
    |> validate_format(field, ~r/\A(?=.{1,253}\z)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/,
      message: "must be a server hostname, without a URL, path or port"
    )
  end
end
