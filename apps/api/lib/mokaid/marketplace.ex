defmodule Mokaid.Marketplace do
  @moduledoc """
  Agent marketplace: publish level-10+ AI agents for sale (unlimited copies)
  or rent (monthly subscription or fixed 7/30/90-day term). Payments go
  through Stripe Connect with a platform application fee.
  """

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Agents.Agent
  alias Mokaid.Agents.Transfer
  alias Mokaid.Billing
  alias Mokaid.Billing.Stripe
  alias Mokaid.Knowledge.KnowledgeItem
  alias Mokaid.Marketplace.{ConnectAccount, Lease, Listing, Order}
  alias Mokaid.Members
  alias Mokaid.Realtime
  alias Mokaid.Repo

  @min_level 10
  @min_price_cents 100

  def min_level, do: @min_level
  def min_price_cents, do: @min_price_cents

  def fee_percent do
    case System.get_env("MARKETPLACE_FEE_PERCENT") do
      nil ->
        Application.get_env(:mokaid, :marketplace, [])
        |> Keyword.get(:fee_percent, 15)

      value ->
        case Integer.parse(value) do
          {n, _} when n >= 0 and n <= 100 -> n
          _ -> 15
        end
    end
  end

  def application_fee_cents(amount_cents) when is_integer(amount_cents) and amount_cents > 0 do
    max(div(amount_cents * fee_percent(), 100), 1)
  end

  def application_fee_cents(_), do: 0

  ## ---------- Connect ----------

  def get_connect_account(workspace_id) do
    Repo.get_by(ConnectAccount, workspace_id: workspace_id)
  end

  def connect_ready?(workspace_id) do
    case get_connect_account(workspace_id) do
      %ConnectAccount{} = account -> ConnectAccount.ready?(account)
      _ -> false
    end
  end

  def start_connect_onboarding(workspace_id, country, return_path \\ "/marketplace/return") do
    country = country |> to_string() |> String.upcase()

    with true <- country_ok?(country) || {:error, :invalid_country},
         true <- Stripe.enabled?() || {:error, :stripe_disabled},
         {:ok, account} <- ensure_connect_account(workspace_id, country),
         {:ok, link} <-
           Stripe.create_account_link(%{
             account_id: account.stripe_account_id,
             refresh_path: return_path,
             return_path: return_path
           }) do
      {:ok, %{url: link["url"], account: account}}
    end
  end

  defp country_ok?(country) when is_binary(country), do: String.match?(country, ~r/^[A-Z]{2}$/)
  defp country_ok?(_), do: false

  defp ensure_connect_account(workspace_id, country) do
    case get_connect_account(workspace_id) do
      %ConnectAccount{} = existing ->
        {:ok, existing}

      nil ->
        with {:ok, remote} <-
               Stripe.create_express_account(%{
                 country: country,
                 workspace_id: workspace_id
               }) do
          %ConnectAccount{}
          |> ConnectAccount.changeset(%{
            workspace_id: workspace_id,
            stripe_account_id: remote["id"],
            country: country,
            charges_enabled: remote["charges_enabled"] == true,
            payouts_enabled: remote["payouts_enabled"] == true,
            details_submitted: remote["details_submitted"] == true
          })
          |> Repo.insert()
        end
    end
  end

  def sync_connect_account(%{"id" => stripe_account_id} = object) do
    case Repo.get_by(ConnectAccount, stripe_account_id: stripe_account_id) do
      nil ->
        {:ignored, :unknown_account}

      account ->
        account
        |> ConnectAccount.changeset(%{
          charges_enabled: object["charges_enabled"] == true,
          payouts_enabled: object["payouts_enabled"] == true,
          details_submitted: object["details_submitted"] == true
        })
        |> Repo.update()
    end
  end

  def sync_connect_account(_), do: {:ignored, :invalid}

  ## ---------- Catalog / mine ----------

  def list_public_listings(buyer_workspace_id, filters \\ %{}) do
    mode = filters["mode"]

    from(l in Listing,
      join: a in Agent,
      on: a.id == l.agent_id,
      where: l.status == "active" and l.workspace_id != ^buyer_workspace_id and is_nil(a.archived_at),
      preload: [agent: a],
      order_by: [desc: l.inserted_at]
    )
    |> maybe_mode(mode)
    |> maybe_search(filters["q"])
    |> Repo.all()
  end

  defp maybe_mode(query, mode) when mode in ["sale", "rent"],
    do: where(query, [l], l.mode == ^mode)

  defp maybe_mode(query, _), do: query

  defp maybe_search(query, q) when is_binary(q) and byte_size(q) > 0 do
    like = "%#{String.replace(q, "%", "\\%")}%"
    where(query, [l, a], ilike(a.display_name, ^like) or ilike(a.role_title, ^like) or ilike(l.title, ^like))
  end

  defp maybe_search(query, _), do: query

  def list_my_agents(workspace_id) do
    agents = Agents.list_agents(workspace_id, %{"kind" => "ai"})
    open_listings = open_listings_by_agent(workspace_id)
    knowledge_counts = knowledge_counts(workspace_id, Enum.map(agents, & &1.id))

    Enum.map(agents, fn agent ->
      listing = Map.get(open_listings, agent.id)
      level = agent.level || 1
      knowledge = Map.get(knowledge_counts, agent.id, 0)

      %{
        agent: agent,
        listing: listing,
        knowledge_item_count: knowledge,
        level: level,
        eligible: level >= @min_level and agent.status != "training" and is_nil(agent.archived_at),
        levels_remaining: max(@min_level - level, 0)
      }
    end)
  end

  defp open_listings_by_agent(workspace_id) do
    from(l in Listing,
      where: l.workspace_id == ^workspace_id and l.status in ["active", "paused"],
      preload: [:agent]
    )
    |> Repo.all()
    |> Map.new(&{&1.agent_id, &1})
  end

  defp knowledge_counts(_workspace_id, []), do: %{}

  defp knowledge_counts(workspace_id, agent_ids) do
    from(i in KnowledgeItem,
      where: i.workspace_id == ^workspace_id and i.agent_id in ^agent_ids,
      group_by: i.agent_id,
      select: {i.agent_id, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def earnings(workspace_id) do
    connect = get_connect_account(workspace_id)

    orders =
      from(o in Order,
        where: o.seller_workspace_id == ^workspace_id and o.status in ["paid", "fulfilled"],
        order_by: [desc: o.paid_at],
        limit: 50,
        preload: [:listing, :source_agent, :cloned_agent]
      )
      |> Repo.all()

    leases =
      from(l in Lease,
        where: l.seller_workspace_id == ^workspace_id and l.status == "active",
        preload: [:cloned_agent, :source_agent]
      )
      |> Repo.all()

    listings =
      from(l in Listing,
        where: l.workspace_id == ^workspace_id and l.status in ["active", "paused"],
        preload: [:agent]
      )
      |> Repo.all()

    gross = Enum.reduce(orders, 0, fn o, acc -> acc + (o.amount_cents || 0) end)
    fees = Enum.reduce(orders, 0, fn o, acc -> acc + (o.application_fee_cents || 0) end)

    %{
      connect: connect,
      connect_ready: connect_ready?(workspace_id),
      fee_percent: fee_percent(),
      listings: listings,
      orders: orders,
      active_leases: leases,
      gross_cents: gross,
      fee_cents: fees,
      net_cents: max(gross - fees, 0)
    }
  end

  ## ---------- Publish / pause ----------

  def create_listing(workspace_id, member, attrs) do
    attrs = stringify(attrs)
    agent_id = attrs["agent_id"]

    with {:ok, agent} <- fetch_publishable_agent(workspace_id, agent_id),
         :ok <- ensure_no_open_listing(agent.id),
         true <- connect_ready?(workspace_id) || {:error, :connect_incomplete},
         {:ok, listing_attrs} <- build_listing_attrs(workspace_id, member, agent, attrs) do
      %Listing{}
      |> Listing.changeset(listing_attrs)
      |> Repo.insert()
    end
  end

  defp fetch_publishable_agent(workspace_id, agent_id) do
    case Agents.get_agent(workspace_id, agent_id) do
      nil ->
        {:error, :not_found}

      %Agent{} = agent ->
        cond do
          agent.kind != "ai" -> {:error, :only_ai_agents}
          not is_nil(agent.archived_at) -> {:error, :not_found}
          agent.status == "training" -> {:error, :agent_in_training}
          (agent.level || 1) < @min_level -> {:error, :level_too_low}
          true -> {:ok, agent}
        end
    end
  end

  defp ensure_no_open_listing(agent_id) do
    exists? =
      Repo.exists?(
        from l in Listing,
          where: l.agent_id == ^agent_id and l.status in ["active", "paused"]
      )

    if exists?, do: {:error, :listing_already_open}, else: :ok
  end

  defp build_listing_attrs(workspace_id, member, agent, attrs) do
    mode = attrs["mode"]
    price = parse_int(attrs["price_cents"])

    with true <- mode in Listing.modes() || {:error, :invalid_mode},
         true <- is_integer(price) and price >= @min_price_cents || {:error, :price_too_low},
         {:ok, rent_fields} <- rent_fields(mode, attrs) do
      knowledge = Map.get(knowledge_counts(workspace_id, [agent.id]), agent.id, 0)

      {:ok,
       Map.merge(
         %{
           "workspace_id" => workspace_id,
           "agent_id" => agent.id,
           "created_by_member_id" => member && member.id,
           "mode" => mode,
           "price_cents" => price,
           "currency" => Stripe.currency(),
           "title" => attrs["title"] || agent.display_name,
           "description" => attrs["description"],
           "status" => "active",
           "knowledge_item_count" => knowledge,
           "agent_level_snapshot" => agent.level || @min_level
         },
         rent_fields
       )}
    end
  end

  defp rent_fields("rent", attrs) do
    billing = attrs["rent_billing"]

    cond do
      billing == "subscription" ->
        {:ok, %{"rent_billing" => "subscription", "fixed_days" => nil}}

      billing == "fixed" ->
        days = parse_int(attrs["fixed_days"])

        if days in Listing.fixed_days_options() do
          {:ok, %{"rent_billing" => "fixed", "fixed_days" => days}}
        else
          {:error, :invalid_fixed_days}
        end

      true ->
        {:error, :invalid_rent_billing}
    end
  end

  defp rent_fields(_, _), do: {:ok, %{}}

  def pause_listing(workspace_id, listing_id) do
    update_listing_status(workspace_id, listing_id, "paused", "active")
  end

  def resume_listing(workspace_id, listing_id) do
    update_listing_status(workspace_id, listing_id, "active", "paused")
  end

  defp update_listing_status(workspace_id, listing_id, to_status, from_status) do
    case Repo.get_by(Listing, id: listing_id, workspace_id: workspace_id) do
      %Listing{status: ^from_status} = listing ->
        listing |> Listing.changeset(%{"status" => to_status}) |> Repo.update()

      %Listing{} ->
        {:error, :invalid_status}

      nil ->
        {:error, :not_found}
    end
  end

  ## ---------- Checkout ----------

  def start_checkout(buyer_workspace_id, buyer_member, buyer_user, listing_id) do
    with %Listing{} = listing <- get_active_listing(listing_id),
         true <- listing.workspace_id != buyer_workspace_id || {:error, :own_listing},
         true <- connect_ready?(listing.workspace_id) || {:error, :seller_connect_incomplete},
         %ConnectAccount{} = connect <- get_connect_account(listing.workspace_id),
         :ok <- ensure_buyer_capacity(buyer_workspace_id),
         %Agent{} = source <- Agents.get_agent(listing.workspace_id, listing.agent_id),
         true <- source.kind == "ai" and is_nil(source.archived_at) || {:error, :agent_unavailable},
         {:ok, order} <- insert_pending_order(listing, buyer_workspace_id, buyer_member, buyer_user, source) do
      if Stripe.enabled?() do
        open_stripe_checkout(order, listing, connect, buyer_user)
      else
        fulfill_dev_checkout(order, listing, buyer_workspace_id, buyer_member)
      end
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  defp get_active_listing(listing_id) do
    Repo.one(
      from l in Listing,
        where: l.id == ^listing_id and l.status == "active",
        preload: [:agent]
    )
  end

  defp ensure_buyer_capacity(workspace_id) do
    cond do
      Agents.active_agent_count(workspace_id) >= Billing.agent_limit(workspace_id) ->
        {:error, :agent_limit_reached}

      match?({:error, :office_full}, Agents.next_free_seat(workspace_id)) ->
        {:error, :office_full}

      true ->
        :ok
    end
  end

  defp insert_pending_order(listing, buyer_workspace_id, buyer_member, buyer_user, source) do
    fee = application_fee_cents(listing.price_cents)

    %Order{}
    |> Order.changeset(%{
      listing_id: listing.id,
      seller_workspace_id: listing.workspace_id,
      buyer_workspace_id: buyer_workspace_id,
      buyer_member_id: buyer_member && buyer_member.id,
      buyer_user_id: buyer_user && buyer_user.id,
      source_agent_id: source.id,
      mode: listing.mode,
      rent_billing: listing.rent_billing,
      fixed_days: listing.fixed_days,
      amount_cents: listing.price_cents,
      application_fee_cents: fee,
      currency: listing.currency || Stripe.currency(),
      status: "pending"
    })
    |> Repo.insert()
  end

  defp open_stripe_checkout(order, listing, connect, buyer_user) do
    description = checkout_description(listing)

    attrs = %{
      order_id: order.id,
      listing_id: listing.id,
      amount_cents: order.amount_cents,
      application_fee_cents: order.application_fee_cents,
      application_fee_percent: fee_percent(),
      description: description,
      destination: connect.stripe_account_id,
      buyer_email: buyer_user && buyer_user.email,
      buyer_workspace_id: order.buyer_workspace_id,
      seller_workspace_id: order.seller_workspace_id,
      mode: listing.mode,
      rent_billing: listing.rent_billing,
      return_path: "/marketplace/return"
    }

    result =
      case {listing.mode, listing.rent_billing} do
        {"rent", "subscription"} -> Stripe.create_marketplace_subscription_checkout(attrs)
        _ -> Stripe.create_marketplace_payment_checkout(attrs)
      end

    with {:ok, session} <- result,
         url when is_binary(url) <- session["url"],
         {:ok, order} <-
           order
           |> Order.changeset(%{
             stripe_checkout_session_id: session["id"],
             stripe_customer_id: Stripe.stripe_id(session["customer"])
           })
           |> Repo.update() do
      {:ok, %{sale_url: url, checkout_url: url, order_id: order.id}}
    else
      nil -> {:error, :stripe_error}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp checkout_description(%Listing{} = listing) do
    name = listing.title || (listing.agent && listing.agent.display_name) || "Agent"

    case {listing.mode, listing.rent_billing, listing.fixed_days} do
      {"sale", _, _} -> "Mokaid Marketplace — buy #{name}"
      {"rent", "subscription", _} -> "Mokaid Marketplace — rent #{name} (monthly)"
      {"rent", "fixed", days} -> "Mokaid Marketplace — rent #{name} (#{days} days)"
      _ -> "Mokaid Marketplace — #{name}"
    end
  end

  defp fulfill_dev_checkout(order, listing, buyer_workspace_id, buyer_member) do
    with {:ok, order} <-
           order
           |> Order.changeset(%{
             status: "paid",
             paid_at: DateTime.utc_now(),
             stripe_checkout_session_id: "dev_" <> order.id
           })
           |> Repo.update(),
         {:ok, _} <- fulfill_paid_order(order, listing, buyer_workspace_id, buyer_member) do
      {:ok, %{sale_url: nil, checkout_url: nil, order_id: order.id, fulfilled: true}}
    end
  end

  ## ---------- Fulfillment (webhooks) ----------

  def handle_checkout_completed(session) when is_map(session) do
    meta = session["metadata"] || %{}

    if meta["kind"] != "marketplace" do
      {:ignored, :not_marketplace}
    else
      order_id = meta["order_id"] || session["client_reference_id"]

      with {:ok, _} <- Ecto.UUID.cast(order_id),
           %Order{} = order <- Repo.get(Order, order_id) |> Repo.preload([:listing]),
           true <- session["payment_status"] in ["paid", "no_payment_required"] || {:ignored, :unpaid} do
        attrs = %{
          status: "paid",
          paid_at: DateTime.utc_now(),
          stripe_checkout_session_id: session["id"],
          stripe_payment_intent_id: Stripe.stripe_id(session["payment_intent"]),
          stripe_subscription_id: Stripe.stripe_id(session["subscription"]),
          stripe_customer_id: Stripe.stripe_id(session["customer"])
        }

        {:ok, order} = order |> Order.changeset(attrs) |> Repo.update()
        fulfill_paid_order(order, order.listing, order.buyer_workspace_id, nil)
      else
        :error -> {:ignored, :bad_order_id}
        nil -> {:ignored, :unknown_order}
        other -> other
      end
    end
  end

  def handle_checkout_completed(_), do: {:ignored, :invalid}

  def fulfill_paid_order(%Order{status: status} = order, listing, buyer_workspace_id, buyer_member)
      when status in ["paid", "fulfilled"] do
    if order.cloned_agent_id do
      {:ok, order}
    else
      listing = listing || Repo.get!(Listing, order.listing_id)
      member = buyer_member || Members.get_member(buyer_workspace_id, order.buyer_member_id)

      with {:ok, clone} <-
             Transfer.clone_for_marketplace(
               order.seller_workspace_id,
               order.source_agent_id,
               buyer_workspace_id,
               member,
               marketplace_meta(order)
             ),
           {:ok, order} <-
             order
             |> Order.changeset(%{cloned_agent_id: clone.id, status: "fulfilled"})
             |> Repo.update(),
           {:ok, _lease} <- maybe_create_lease(order, listing, clone) do
        Realtime.broadcast_workspace(buyer_workspace_id, "agent.created", %{agent_id: clone.id})
        Realtime.broadcast_workspace(buyer_workspace_id, "marketplace.purchase", %{order_id: order.id})
        {:ok, order}
      end
    end
  end

  def fulfill_paid_order(order, _, _, _), do: {:ok, order}

  defp marketplace_meta(order) do
    %{
      "marketplace_order_id" => order.id,
      "mode" => order.mode,
      "rent_billing" => order.rent_billing
    }
  end

  defp maybe_create_lease(%Order{mode: "rent"} = order, listing, clone) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    expires_at =
      case listing.rent_billing do
        "fixed" -> DateTime.add(now, (listing.fixed_days || 30) * 86_400, :second)
        _ -> nil
      end

    %Lease{}
    |> Lease.changeset(%{
      order_id: order.id,
      listing_id: listing.id,
      seller_workspace_id: order.seller_workspace_id,
      buyer_workspace_id: order.buyer_workspace_id,
      source_agent_id: order.source_agent_id,
      cloned_agent_id: clone.id,
      rent_billing: listing.rent_billing,
      fixed_days: listing.fixed_days,
      status: "active",
      starts_at: now,
      expires_at: expires_at,
      stripe_subscription_id: order.stripe_subscription_id
    })
    |> Repo.insert()
  end

  defp maybe_create_lease(_order, _listing, _clone), do: {:ok, nil}

  def handle_subscription_invoice_paid(stripe_invoice) when is_map(stripe_invoice) do
    sub_id = Stripe.stripe_id(stripe_invoice["subscription"])
    reason = stripe_invoice["billing_reason"]

    if is_binary(sub_id) and reason in ["subscription_cycle", "subscription_update"] do
      case Repo.get_by(Lease, stripe_subscription_id: sub_id) do
        %Lease{status: "active"} = lease ->
          # Monthly renewals extend access; fixed terms are not renewed here.
          {:ok, lease}

        %Lease{status: status} = lease when status in ["canceled", "expired"] ->
          lease
          |> Lease.changeset(%{status: "active", canceled_at: nil, expires_at: nil})
          |> Repo.update()

        nil ->
          {:ignored, :unknown_lease}
      end
    else
      :ok
    end
  end

  def handle_subscription_invoice_paid(_), do: :ok

  def handle_subscription_deleted(%{"id" => sub_id}) when is_binary(sub_id) do
    case Repo.get_by(Lease, stripe_subscription_id: sub_id) do
      nil ->
        {:ignored, :unknown_lease}

      lease ->
        end_lease(lease, "canceled")
    end
  end

  def handle_subscription_deleted(_), do: :ok

  def expire_due_leases(now \\ DateTime.utc_now()) do
    from(l in Lease,
      where: l.status == "active" and not is_nil(l.expires_at) and l.expires_at <= ^now
    )
    |> Repo.all()
    |> Enum.map(&end_lease(&1, "expired"))
  end

  def end_lease(%Lease{} = lease, status) when status in ["canceled", "expired"] do
    now = DateTime.utc_now()

    {:ok, lease} =
      lease
      |> Lease.changeset(%{
        status: status,
        canceled_at: if(status == "canceled", do: now, else: lease.canceled_at)
      })
      |> Repo.update()

    if lease.cloned_agent_id do
      case Agents.get_agent(lease.buyer_workspace_id, lease.cloned_agent_id) do
        %Agent{} = agent ->
          Agents.archive_agent(agent)

        _ ->
          :ok
      end
    end

    Realtime.broadcast_workspace(lease.buyer_workspace_id, "marketplace.lease_ended", %{
      lease_id: lease.id,
      agent_id: lease.cloned_agent_id,
      status: status
    })

    {:ok, lease}
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> v
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
