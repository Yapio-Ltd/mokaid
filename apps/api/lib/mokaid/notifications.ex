defmodule Mokaid.Notifications do
  @moduledoc "In-app notifications."

  import Ecto.Query

  alias Mokaid.Notifications.Notification
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def list_for_user(workspace_id, user_id, limit \\ 50) do
    notifications =
      Repo.all(
        from n in Notification,
          where: n.workspace_id == ^workspace_id and n.user_id == ^user_id,
          order_by: [desc: n.inserted_at],
          limit: ^limit
      )

    agents_by_task = agents_by_task_id(workspace_id, notifications)

    Enum.map(notifications, fn n ->
      agent =
        if n.resource_type == "task" and is_binary(n.resource_id) do
          Map.get(agents_by_task, n.resource_id)
        end

      %{n | agent: agent}
    end)
  end

  def notify(workspace_id, user_id, kind, title, opts \\ []) do
    result =
      %Notification{}
      |> Notification.changeset(%{
        "workspace_id" => workspace_id,
        "user_id" => user_id,
        "kind" => kind,
        "title" => title,
        "body" => Keyword.get(opts, :body),
        "resource_type" => Keyword.get(opts, :resource_type),
        "resource_id" => Keyword.get(opts, :resource_id)
      })
      |> Repo.insert()

    with {:ok, notification} <- result do
      Realtime.broadcast_notification(user_id, %{
        notification_id: notification.id,
        kind: kind,
        title: title
      })

      {:ok, notification}
    end
  end

  @doc "Notifies every workspace member whose role is in `role_names` (e.g. approvers)."
  def notify_roles(workspace_id, role_names, kind, title, opts \\ []) do
    user_ids =
      Repo.all(
        from m in Mokaid.Members.Member,
          join: r in assoc(m, :role),
          where:
            m.workspace_id == ^workspace_id and m.status == "active" and r.name in ^role_names,
          select: m.user_id
      )

    Enum.each(user_ids, &notify(workspace_id, &1, kind, title, opts))
    :ok
  end

  @doc "Notifies the user behind a member id. No-op when the member is missing."
  def notify_member(workspace_id, member_id, kind, title, opts \\ [])
  def notify_member(_workspace_id, nil, _kind, _title, _opts), do: :ok

  def notify_member(workspace_id, member_id, kind, title, opts) do
    case Repo.one(
           from m in Mokaid.Members.Member,
             where: m.workspace_id == ^workspace_id and m.id == ^member_id,
             select: m.user_id
         ) do
      nil -> :ok
      user_id -> notify(workspace_id, user_id, kind, title, opts)
    end
  end

  def mark_read(workspace_id, user_id, id) do
    case Repo.one(
           from n in Notification,
             where: n.workspace_id == ^workspace_id and n.user_id == ^user_id and n.id == ^id
         ) do
      nil ->
        {:error, :not_found}

      notification ->
        notification
        |> Ecto.Changeset.change(read_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Turns raw provider / toolchain errors into short, actionable copy for humans.

  The technical detail stays on the AI run (`run.error`) for debugging —
  notifications should never dump JSON or SDK exception strings.
  """
  def humanize_error(nil),
    do: "Something went wrong while working on this task. Open it to retry."

  def humanize_error(message) when is_binary(message) do
    trimmed = String.trim(message)

    cond do
      trimmed == "" ->
        humanize_error(nil)

      already_friendly?(trimmed) ->
        trimmed

      true ->
        lower = String.downcase(trimmed)
        extracted = extract_provider_message(trimmed)
        extracted_lower = if extracted, do: String.downcase(extracted), else: ""

        cond do
          credit_error?(lower) or credit_error?(extracted_lower) ->
            "We couldn't complete this task because your AI credit balance is too low. Top up credits, then try again."

          rate_limit_error?(lower) or rate_limit_error?(extracted_lower) ->
            "The AI service is temporarily overloaded. Wait a moment, then try again."

          auth_error?(lower) or auth_error?(extracted_lower) ->
            "The AI service rejected the request (authentication). Check your API or billing settings, then try again."

          timeout_error?(lower) or timeout_error?(extracted_lower) ->
            "The agent ran out of time before finishing. Open the task and try again."

          network_error?(lower) or network_error?(extracted_lower) ->
            "We couldn't reach the AI service. Check your connection and try again."

          context_length_error?(lower) or context_length_error?(extracted_lower) ->
            "This task was too large for the AI to process in one go. Try splitting it into smaller steps."

          content_policy_error?(lower) or content_policy_error?(extracted_lower) ->
            "The AI couldn't complete this task because of a content policy restriction. Try rephrasing the request."

          is_binary(extracted) and String.length(extracted) > 0 and
              not looks_technical?(extracted) ->
            capitalize_sentence(extracted)

          looks_technical?(trimmed) ->
            "Something went wrong while the agent was working. Open the task to see details and retry."

          true ->
            capitalize_sentence(trimmed)
        end
    end
  end

  def humanize_error(other), do: humanize_error(to_string(other))

  ## ---------- Private ----------

  defp agents_by_task_id(_workspace_id, []), do: %{}

  defp agents_by_task_id(workspace_id, notifications) do
    task_ids =
      notifications
      |> Enum.filter(&(&1.resource_type == "task" and is_binary(&1.resource_id)))
      |> Enum.map(& &1.resource_id)
      |> Enum.uniq()

    if task_ids == [] do
      %{}
    else
      Repo.all(
        from t in Mokaid.Tasks.Task,
          join: a in assoc(t, :assigned_agent),
          where: t.workspace_id == ^workspace_id and t.id in ^task_ids,
          select: {t.id, a}
      )
      |> Map.new()
    end
  end

  defp already_friendly?(message) do
    # Messages we (or chat) already wrote for humans — leave them alone.
    String.starts_with?(message, "We couldn't") or
      String.starts_with?(message, "The agent") or
      String.starts_with?(message, "The AI") or
      String.starts_with?(message, "Something went wrong") or
      String.starts_with?(message, "Sorry") or
      String.starts_with?(message, "Je ") or
      String.starts_with?(message, "Voilà")
  end

  defp credit_error?(text) when text == "", do: false

  defp credit_error?(text) do
    String.contains?(text, "credit balance") or
      String.contains?(text, "insufficient credit") or
      String.contains?(text, "insufficient_credits") or
      String.contains?(text, "out of credits") or
      String.contains?(text, "billing soft limit") or
      String.contains?(text, "exceeded your current quota") or
      String.contains?(text, "payment required") or
      String.contains?(text, "purchase credits")
  end

  defp rate_limit_error?(text) when text == "", do: false

  defp rate_limit_error?(text) do
    String.contains?(text, "rate limit") or
      String.contains?(text, "rate_limit") or
      String.contains?(text, "too many requests") or
      String.contains?(text, "error code: 429")
  end

  defp auth_error?(text) when text == "", do: false

  defp auth_error?(text) do
    String.contains?(text, "invalid api key") or
      String.contains?(text, "incorrect api key") or
      String.contains?(text, "authentication") or
      String.contains?(text, "unauthorized") or
      String.contains?(text, "error code: 401") or
      String.contains?(text, "error code: 403")
  end

  defp timeout_error?(text) when text == "", do: false

  defp timeout_error?(text) do
    String.contains?(text, "timeout") or
      String.contains?(text, "timed out") or
      String.contains?(text, "deadline exceeded")
  end

  defp network_error?(text) when text == "", do: false

  defp network_error?(text) do
    String.contains?(text, "connection") or
      String.contains?(text, "network") or
      String.contains?(text, "unreachable") or
      String.contains?(text, "dns")
  end

  defp context_length_error?(text) when text == "", do: false

  defp context_length_error?(text) do
    String.contains?(text, "context length") or
      String.contains?(text, "maximum context") or
      String.contains?(text, "token limit") or
      String.contains?(text, "too many tokens")
  end

  defp content_policy_error?(text) when text == "", do: false

  defp content_policy_error?(text) do
    String.contains?(text, "content policy") or
      String.contains?(text, "content_policy") or
      String.contains?(text, "content_filter") or
      String.contains?(text, "safety system") or
      String.contains?(text, "refused to")
  end

  defp looks_technical?(message) do
    String.contains?(message, "Error code:") or
      String.contains?(message, "{'type'") or
      String.contains?(message, "\"type\":") or
      String.contains?(message, "invalid_request_error") or
      String.contains?(message, "Traceback") or
      String.contains?(message, "Exception") or
      String.match?(message, ~r/\b(APIStatusError|HTTPError|StatusCodeError)\b/)
  end

  # Pull the nested `message` from OpenAI/Anthropic-style dumps, e.g.
  # "Error code: 400 - {'error': {'message': 'Your credit balance is too low...'}}"
  defp extract_provider_message(raw) do
    patterns = [
      ~r/['"]message['"]\s*:\s*['"]([^'"]+)['"]/i,
      ~r/message['"]?\s*[:=]\s*['"]([^'"]+)['"]/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, raw) do
        [_, msg] -> String.trim(msg)
        _ -> nil
      end
    end)
  end

  defp capitalize_sentence(text) do
    text = String.trim(text)
    # Cap length so notification bodies stay scannable.
    text = if String.length(text) > 180, do: String.slice(text, 0, 177) <> "…", else: text

    case String.first(text) do
      nil -> text
      first -> String.upcase(first) <> String.slice(text, 1..-1//1)
    end
  end
end
