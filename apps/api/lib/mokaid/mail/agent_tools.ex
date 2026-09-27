defmodule Mokaid.Mail.AgentTools do
  @moduledoc "Read-only mailbox tools and explicit attachment copies for an authorized agent session."
  import Ecto.Query
  alias Mokaid.{Drive, Mail, Permissions, Repo, Storage}
  alias Mokaid.Drive.DriveItem
  alias Mokaid.Integrations.{IntegrationConnection, IntegrationProvider}
  alias Mokaid.Mail.{Account, Attachments, Message, MessageActions}

  @body_limit 50_000
  @attachment_limit 100
  @actions ~w(list search read save_attachment)

  # Authorization is supplied by WorkerMailToolsController, never by tool arguments.
  # Rechecking after network I/O prevents an expired/stopped session from publishing data.
  def call(%{workspace_id: workspace_id, member: member} = context, action, args)
      when action in @actions and is_map(args) and is_map(member) do
    with {:ok, _} <- Ecto.UUID.cast(workspace_id),
         true <- member.workspace_id == workspace_id,
         :ok <- reauthorize(context) do
      execute(context, action, args)
    else
      _ -> {:error, :mail_access_denied}
    end
  end

  def call(_, _, _), do: {:error, :invalid_mail_tool_request}

  defp execute(context, "list", args) do
    with :ok <- keys(args, []) do
      accounts = Mail.list_accounts(context.workspace_id)
      {:ok, %{accounts: Enum.map(accounts, &account_summary/1), coverage: coverage(accounts)}}
    end
  end

  defp execute(context, "search", args) do
    with :ok <-
           keys(
             args,
             ~w(account_id account query date_from date_to has_attachments page per_page)
           ),
         {:ok, accounts} <- selected_accounts(context.workspace_id, args),
         {:ok, query_text} <- optional_text(args["query"], 500),
         {:ok, from_date} <- date(args["date_from"]),
         {:ok, to_date} <- date(args["date_to"]),
         true <- is_nil(from_date) or is_nil(to_date) or Date.compare(from_date, to_date) != :gt,
         {:ok, page} <- integer(args["page"], 1, 20_000, 1),
         {:ok, per_page} <- integer(args["per_page"], 1, 50, 20),
         true <- is_nil(args["has_attachments"]) or is_boolean(args["has_attachments"]) do
      ids = Enum.map(accounts, & &1.id)

      query =
        from m in Message,
          where: m.workspace_id == ^context.workspace_id and m.mail_account_id in ^ids

      query = query |> text_filter(query_text) |> date_filter(from_date, to_date)

      query =
        if is_boolean(args["has_attachments"]),
          do: from(m in query, where: m.has_attachments == ^args["has_attachments"]),
          else: query

      total = Repo.aggregate(query, :count)
      offset = (page - 1) * per_page

      messages =
        Repo.all(
          from m in query,
            order_by: [desc_nulls_last: m.received_at, asc: m.id],
            offset: ^offset,
            limit: ^per_page
        )

      account_map = Map.new(accounts, &{&1.id, &1})

      {:ok,
       %{
         messages: Enum.map(messages, &message_summary(&1, account_map[&1.mail_account_id])),
         pagination: %{
           page: page,
           per_page: per_page,
           total: total,
           has_more: offset + length(messages) < total
         },
         coverage: coverage(accounts)
       }}
    else
      false -> {:error, :invalid_mail_tool_request}
      error -> error
    end
  end

  defp execute(context, "read", args) do
    with :ok <- keys(args, ~w(message_id)),
         {:ok, message, account} <- scoped_message(context.workspace_id, args["message_id"]) do
      {message, hydration_error} =
        case MessageActions.hydrate(message) do
          {:ok, hydrated} -> {hydrated, nil}
          _ -> {message, "mail_details_unavailable"}
        end

      with :ok <- reauthorize(context),
           {:ok, _, _} <- scoped_message(context.workspace_id, message.id) do
        body = message.body_text || ""

        detail =
          message_summary(message, account)
          |> Map.merge(%{
            body_text: String.slice(body, 0, @body_limit),
            body_truncated: String.length(body) > @body_limit,
            to_emails: Enum.take(message.to_emails || [], 100),
            cc_emails: Enum.take(message.cc_emails || [], 100)
          })

        {:ok, %{message: detail, hydration_error: hydration_error, coverage: coverage([account])}}
      end
    end
  end

  defp execute(context, "save_attachment", args) do
    with :ok <- keys(args, ~w(message_id attachment_id folder_id folder_name)),
         :ok <- drive_permission(context, "drive.upload"),
         {:ok, message, account} <- scoped_message(context.workspace_id, args["message_id"]),
         {:ok, attachment_id} <- required_text(args["attachment_id"], 1000),
         {:ok, destination} <- destination(context, args),
         {:ok, message} <- hydrate_for_export(message),
         {:ok, content} <- Attachments.download(message, attachment_id),
         :ok <- reauthorize(context),
         {:ok, _, _} <- scoped_message(context.workspace_id, message.id) do
      persist_attachment(context, message, account, attachment_id, destination, content)
    else
      {:error, :forbidden} -> {:error, :mail_file_permission_denied}
      {:error, _} = error -> error
    end
  end

  defp hydrate_for_export(message) do
    case MessageActions.hydrate(message) do
      {:ok, hydrated} -> {:ok, hydrated}
      _ -> {:error, :mail_details_unavailable}
    end
  end

  defp selected_accounts(workspace_id, args) do
    accounts = Mail.list_accounts(workspace_id)

    case {args["account_id"], args["account"]} do
      {nil, nil} ->
        {:ok, Enum.filter(accounts, &eligible_account?/1)}

      {id, nil} when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> one_account(Enum.filter(accounts, &(&1.id == uuid)))
          _ -> {:error, :invalid_mail_tool_request}
        end

      {nil, email} when is_binary(email) and byte_size(email) <= 320 ->
        email = email |> String.trim() |> String.downcase()
        one_account(Enum.filter(accounts, &(String.downcase(&1.email_address) == email)))

      _ ->
        {:error, :invalid_mail_tool_request}
    end
  end

  defp one_account([]), do: {:error, :mail_account_not_found}

  defp one_account([account]) do
    if eligible_account?(account),
      do: {:ok, [account]},
      else: {:error, :mail_reconnect_required}
  end

  defp one_account(_), do: {:error, :mail_account_ambiguous}

  defp scoped_message(workspace_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Message{} = message <- Mail.get_message(workspace_id, id),
         %Account{} = account <- Mail.get_account(workspace_id, message.mail_account_id),
         true <- eligible_account?(account) do
      {:ok, message, account}
    else
      false -> {:error, :mail_reconnect_required}
      _ -> {:error, :mail_message_not_found}
    end
  end

  # Cached message access also ends on disconnect. Inspect only binding metadata;
  # inventory/search must never decrypt or refresh provider credentials.
  defp eligible_account?(%Account{status: "active", provider: "imap"}), do: true

  defp eligible_account?(
         %Account{status: "active", provider: provider, connection_id: id} = account
       )
       when provider in ["gmail", "microsoft"] and not is_nil(id) do
    key = if provider == "gmail", do: "gmail", else: "outlook"
    email = String.downcase(String.trim(account.email_address))

    Repo.exists?(
      from c in IntegrationConnection,
        join: p in IntegrationProvider,
        on: p.id == c.provider_id,
        where:
          c.id == ^id and c.workspace_id == ^account.workspace_id and
            c.status == "connected" and p.key == ^key and
            fragment("lower(trim(?))", c.connected_account) == ^email
    )
  end

  defp eligible_account?(_), do: false

  defp text_filter(query, nil), do: query

  defp text_filter(query, text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    from m in query,
      where:
        ilike(m.subject, ^pattern) or ilike(m.from_email, ^pattern) or
          ilike(m.from_name, ^pattern) or ilike(m.snippet, ^pattern) or
          ilike(m.body_text, ^pattern)
  end

  defp date_filter(query, from_date, to_date) do
    query =
      if from_date,
        do:
          from(m in query,
            where: m.received_at >= ^DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC")
          ),
        else: query

    if to_date do
      upper = DateTime.new!(Date.add(to_date, 1), ~T[00:00:00], "Etc/UTC")
      from m in query, where: m.received_at < ^upper
    else
      query
    end
  end

  defp account_summary(account) do
    count =
      Repo.aggregate(
        from(m in Message,
          where: m.workspace_id == ^account.workspace_id and m.mail_account_id == ^account.id
        ),
        :count
      )

    %{
      id: account.id,
      email_address: account.email_address,
      display_name: bounded(account.display_name, 500),
      provider: account.provider,
      status: account.status,
      last_sync_at: account.last_sync_at,
      message_count: count
    }
  end

  defp message_summary(message, account) do
    %{
      message_id: message.id,
      account_id: account.id,
      account: account.email_address,
      subject: bounded(message.subject, 1000),
      from_name: bounded(message.from_name, 500),
      from_email: bounded(message.from_email, 500),
      received_at: message.received_at,
      snippet: bounded(message.snippet, 2000),
      has_attachments: message.has_attachments,
      attachments: attachment_manifest(message),
      attachments_truncated: length(message.attachments || []) > @attachment_limit
    }
  end

  defp attachment_manifest(message) do
    message.attachments
    |> List.wrap()
    |> Enum.take(@attachment_limit)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      %{
        id: bounded(item["id"], 1000),
        filename: Attachments.safe_filename(item["filename"]),
        mime_type: bounded(item["mime_type"], 200),
        size: safe_size(item["size"])
      }
    end)
  end

  defp coverage(accounts) do
    %{
      source: "synchronized_cache",
      exhaustive: false,
      date_timezone: "UTC",
      note:
        "Results cover synchronized messages only. Inactive or disconnected accounts are excluded from content searches. Older mail may still be importing; empty results do not prove that no matching mail exists.",
      accounts:
        Enum.map(
          accounts,
          &%{account_id: &1.id, status: &1.status, last_sync_at: &1.last_sync_at}
        )
    }
  end

  defp destination(context, args) do
    case {args["folder_id"], args["folder_name"]} do
      {nil, name} ->
        raw = name || "Mail Attachments"

        with true <- is_binary(raw) and not String.match?(raw, ~r/[\x00-\x1f\x7f\/\\]/u),
             {:ok, name} <- required_text(raw, 120),
             true <- not String.match?(name, ~r/[\x00-\x1f\x7f\/\\]/u) and name not in [".", ".."] do
          {:ok, {:name, name}}
        else
          _ -> {:error, :invalid_mail_folder}
        end

      {id, nil} ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             %DriveItem{} = folder <-
               Repo.get_by(DriveItem,
                 id: id,
                 workspace_id: context.workspace_id,
                 kind: "folder",
                 status: "active"
               ),
             true <- folder_allowed?(folder, context) do
          {:ok, {:id, id}}
        else
          _ -> {:error, :invalid_mail_folder}
        end

      _ ->
        {:error, :invalid_mail_folder}
    end
  end

  defp folder_allowed?(folder, context),
    do:
      folder.visibility == "workspace" or
        (folder.visibility == "private" and folder.owner_member_id == context.member.id)

  defp persist_attachment(context, message, account, attachment_id, destination, content) do
    Repo.transaction(
      fn ->
        # Serialize folder creation and retries. Scope includes task so a reused file
        # always remains readable through the managed runtime's task-bound file gate.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
          "mail-export:" <> context.workspace_id
        ])

        checked!(reauthorize(context))
        checked!(drive_permission(context, "drive.upload"))
        checked!(scoped_message(context.workspace_id, message.id))
        folder = export_folder!(context, destination)
        task_id = Map.get(context, :task_id)
        agent = scoped_agent!(context)
        task = scoped_task!(context, task_id)

        key =
          :crypto.hash(
            :sha256,
            Enum.join([message.id, attachment_id, folder.id, task_id || "conversation"], ":")
          )
          |> Base.encode16(case: :lower)

        existing =
          Repo.one(
            from d in DriveItem,
              where:
                d.workspace_id == ^context.workspace_id and d.kind == "file" and
                  d.status == "active" and d.parent_id == ^folder.id and
                  fragment("?->>'mail_attachment_export_key' = ?", d.metadata, ^key),
              limit: 1
          )

        if existing do
          export_summary(existing, message, attachment_id, true)
        else
          mime = passive_mime(content.bytes, content.filename)

          stored =
            case Storage.upload_content(
                   context.workspace_id,
                   content.filename,
                   content.bytes,
                   mime
                 ) do
              {:ok, stored} -> stored
              _ -> Repo.rollback(:mail_file_storage_unavailable)
            end

          item =
            with :ok <- reauthorize(context),
                 :ok <- drive_permission(context, "drive.upload"),
                 {:ok, _, _} <- scoped_message(context.workspace_id, message.id),
                 {:ok, folder} <- locked_folder(context, folder.id),
                 {:ok, item} <-
                   Drive.create_file(
                     context.workspace_id,
                     %{
                       "name" => content.filename,
                       "parent_id" => folder.id,
                       "mime_type" => mime,
                       "extension" =>
                         String.trim_leading(Path.extname(content.filename), ".")
                         |> String.downcase(),
                       "size_bytes" => stored.size_bytes,
                       "storage_key" => stored.storage_key,
                       "checksum" => stored.checksum,
                       "linked_task_id" => task_id,
                       "linked_project_id" => task && task.project_id,
                       "is_ai_readable" => true,
                       "visibility" => folder.visibility,
                       "owner_member_id" =>
                         if(folder.visibility == "private", do: context.member.id),
                       "metadata" => %{
                         "mail_attachment_export_key" => key,
                         "mail_message_id" => message.id,
                         "mail_account_id" => account.id,
                         "mail_attachment_id" => attachment_id,
                         "mail_received_at" => message.received_at,
                         "runtime_run_id" => Map.get(context, :run_id)
                       }
                     },
                     agent || context.member
                   ) do
              item
            else
              {:error, reason}
              when reason in [
                     :mail_access_denied,
                     :forbidden,
                     :mail_message_not_found,
                     :mail_reconnect_required,
                     :invalid_mail_folder
                   ] ->
                discard_upload(stored.storage_key)

                Repo.rollback(
                  if(reason == :forbidden, do: :mail_file_permission_denied, else: reason)
                )

              _ ->
                discard_upload(stored.storage_key)
                Repo.rollback(:mail_file_storage_unavailable)
            end

          export_summary(item, message, attachment_id, false)
        end
      end,
      timeout: 90_000
    )
  end

  defp export_folder!(context, {:id, id}) do
    case locked_folder(context, id) do
      {:ok, folder} -> folder
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp export_folder!(context, {:name, name}) do
    case Repo.one(
           from d in DriveItem,
             where:
               d.workspace_id == ^context.workspace_id and is_nil(d.parent_id) and d.name == ^name and
                 d.kind == "folder" and d.status == "active" and d.visibility == "workspace",
             limit: 1,
             lock: "FOR UPDATE"
         ) do
      nil ->
        checked!(drive_permission(context, "drive.create_folder"))

        case Drive.create_folder(context.workspace_id, %{"name" => name}, context.member) do
          {:ok, folder} -> folder
          _ -> Repo.rollback(:mail_file_storage_unavailable)
        end

      folder ->
        folder
    end
  end

  defp scoped_agent!(%{agent_id: id, workspace_id: workspace_id}) when not is_nil(id) do
    case Repo.get_by(Mokaid.Agents.Agent, id: id, workspace_id: workspace_id) do
      nil -> Repo.rollback(:mail_access_denied)
      agent -> agent
    end
  end

  defp scoped_agent!(_), do: nil

  defp locked_folder(context, id) do
    case Repo.one(
           from d in DriveItem,
             where:
               d.id == ^id and d.workspace_id == ^context.workspace_id and
                 d.kind == "folder" and d.status == "active",
             lock: "FOR UPDATE"
         ) do
      %DriveItem{} = folder ->
        if folder_allowed?(folder, context),
          do: {:ok, folder},
          else: {:error, :invalid_mail_folder}

      _ ->
        {:error, :invalid_mail_folder}
    end
  end

  defp scoped_task!(_context, nil), do: nil

  defp scoped_task!(context, id) do
    case Repo.get_by(Mokaid.Tasks.Task, id: id, workspace_id: context.workspace_id) do
      nil -> Repo.rollback(:mail_access_denied)
      task -> task
    end
  end

  defp export_summary(item, message, attachment_id, reused) do
    %{
      file_id: item.id,
      name: item.name,
      folder_id: item.parent_id,
      size_bytes: item.size_bytes,
      sha256: item.checksum,
      reused: reused,
      source: %{
        message_id: message.id,
        attachment_id: attachment_id,
        account_id: message.mail_account_id
      }
    }
  end

  # Untrusted HTML/SVG and unknown binary formats never become active inline Drive content.
  defp passive_mime(<<"%PDF-", _::binary>>, _), do: "application/pdf"
  defp passive_mime(<<137, "PNG", 13, 10, 26, 10, _::binary>>, _), do: "image/png"
  defp passive_mime(<<255, 216, 255, _::binary>>, _), do: "image/jpeg"
  defp passive_mime(_, _), do: "application/octet-stream"

  defp reauthorize(%{reauthorize: check}) when is_function(check, 0) do
    case check.() do
      {:ok, _} -> :ok
      _ -> {:error, :mail_access_denied}
    end
  end

  defp reauthorize(_), do: {:error, :mail_access_denied}

  defp drive_permission(context, permission) do
    context.workspace_id
    |> Mokaid.Members.get_member(context.member.id)
    |> Permissions.authorize(permission)
  end

  defp discard_upload(storage_key) do
    bucket =
      Application.get_env(:mokaid, :storage, [])[:bucket_uploads] || "mokaid-user-uploads-dev"

    bucket |> ExAws.S3.delete_object(storage_key) |> ExAws.request()
    :ok
  end

  defp checked!(:ok), do: :ok
  defp checked!({:ok, _, _}), do: :ok
  defp checked!({:error, :forbidden}), do: Repo.rollback(:mail_file_permission_denied)
  defp checked!({:error, reason}), do: Repo.rollback(reason)

  defp keys(args, allowed),
    do:
      if(Enum.all?(Map.keys(args), &(&1 in allowed)),
        do: :ok,
        else: {:error, :invalid_mail_tool_request}
      )

  defp optional_text(nil, _), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) and byte_size(value) <= max do
    case String.trim(value) do
      "" -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp optional_text(_, _), do: {:error, :invalid_mail_tool_request}

  defp required_text(value, max) do
    case optional_text(value, max) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_mail_tool_request}
    end
  end

  defp integer(nil, _, _, default), do: {:ok, default}

  defp integer(value, min, max, _) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(_, _, _, _), do: {:error, :invalid_mail_tool_request}
  defp date(nil), do: {:ok, nil}

  defp date(value) when is_binary(value) and byte_size(value) == 10 do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = date} when year in 1900..9998 -> {:ok, date}
      _ -> {:error, :invalid_mail_tool_request}
    end
  end

  defp date(_), do: {:error, :invalid_mail_tool_request}
  defp bounded(value, length) when is_binary(value), do: String.slice(value, 0, length)
  defp bounded(_, _), do: nil
  defp safe_size(size) when is_integer(size) and size >= 0, do: size
  defp safe_size(_), do: nil
end
