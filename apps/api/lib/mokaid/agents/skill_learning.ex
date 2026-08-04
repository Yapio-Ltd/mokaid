defmodule Mokaid.Agents.SkillLearning do
  @moduledoc """
  Autonomous skill learning and specialisation for AI agents.

  After each completed mission, `record_mission/3` is called with the agent,
  the task and the run output.  It:

    1. Detects which domain(s) the mission belongs to, using the same category
       logic as the heuristic dispatcher.  If the AI worker embedded
       `output["category"]` or `output["skills_used"]`, those take priority.
    2. Increments each matching skill in `agent.skills` with diminishing returns
       (new skills start at 25; existing ones gain `max(1, div(100-level, 8))`).
    3. Persists the learning state in `agent.capabilities["learning"]` — a free-
       form map field that already exists on the schema, so **no migration**.
    4. After every update, checks whether the agent has earned enough experience
       to auto-assign a `role_title` and `department`.  An auto-assigned title is
       flagged `"role_source" => "auto"` and will not overwrite a manually set one.
  """

  alias Mokaid.Agents
  alias Mokaid.Agents.Agent
  alias Mokaid.Tasks.Task, as: WorkTask

  @skill_initial_level 25
  @specialty_min_missions 3
  @specialty_min_ratio 0.50

  # Mirrors the category detection in Dispatcher.
  @file_categories %{
    "design" => ~w(fig sketch xd psd),
    "data" => ~w(csv xlsx xls json parquet sql),
    "document" => ~w(pdf doc docx txt md rtf odt),
    "media" => ~w(png jpg jpeg gif webp svg mp4 mov avi),
    "code" => ~w(js ts tsx py ex exs rb go java rs c cpp html css zip),
    "slides" => ~w(ppt pptx key)
  }

  # Keep in sync with Mokaid.AI.Dispatcher.@category_keywords and the domains
  # of Mokaid.Agents.Archetypes — learning and dispatch must agree on domains.
  @category_keywords %{
    "design" => ~w(design figma maquette wireframe prototype logo brand branding),
    "data" => ~w(data analyse analysis spreadsheet tableur report rapport metrics kpi excel),
    "document" => ~w(document redaction writing resume summary contrat brief write),
    "media" => ~w(image photo video visuel media asset),
    "code" => ~w(code development developpement bug feature api script deploy),
    "slides" => ~w(presentation slides deck pitch),
    "legal" =>
      ~w(legal juridique contract rgpd gdpr compliance conformite clause nda avocat lawyer),
    "finance" =>
      ~w(finance budget comptable comptabilite invoice facture forecast tresorerie cashflow fiscal tax),
    "marketing" => ~w(marketing seo campagne campaign newsletter social ads audience growth),
    "sales" => ~w(sales vente prospection pipeline lead deal crm),
    "research" => ~w(research recherche etude benchmark veille survey sondage),
    "sciences" => ~w(scientifique scientific experiment hypothesis laboratoire laboratory),
    "ops" => ~w(recrutement recruiting onboarding hiring rh embauche),
    "product" => ~w(roadmap backlog user-story spec produit product),
    "security" => ~w(securite security vulnerabilite vulnerability pentest phishing),
    "devops" => ~w(devops deployment deploiement docker kubernetes terraform infra ci/cd),
    "support" => ~w(support ticket faq helpdesk sav)
  }

  @domain_role_map %{
    "code" => {"Software Engineer", "Engineering"},
    "design" => {"Designer", "Design"},
    "data" => {"Data Analyst", "Data"},
    "document" => {"Content Specialist", "Content"},
    "media" => {"Media Specialist", "Marketing"},
    "slides" => {"Presentation Specialist", "Content"},
    "legal" => {"Legal Advisor", "Legal"},
    "finance" => {"Finance Specialist", "Finance"},
    "marketing" => {"Marketing Specialist", "Marketing"},
    "sales" => {"Sales Specialist", "Sales"},
    "research" => {"Research Analyst", "Research"},
    "sciences" => {"Scientific Analyst", "Research"},
    "ops" => {"Operations Specialist", "Operations"},
    "product" => {"Product Manager", "Product"},
    "security" => {"Security Specialist", "Engineering"},
    "devops" => {"DevOps Engineer", "Engineering"},
    "support" => {"Customer Support Specialist", "Support"}
  }

  # ─── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Records a completed mission for the agent and updates its skills, learning
  state and (when ready) its specialisation.

  Returns `{:ok, updated_agent}` or `{:error, reason}`.
  """
  def record_mission(%Agent{} = agent, %WorkTask{} = task, run_output \\ %{}) do
    output = run_output || %{}
    categories = detect_categories(task, output)

    if categories == [] do
      {:ok, agent}
    else
      learning = get_learning(agent)
      learning = increment_learning(learning, categories)
      new_skills = update_skills(agent.skills || [], categories)
      {role_title, department} = maybe_specialize(agent, learning)

      attrs =
        %{"skills" => new_skills, "capabilities" => put_learning(agent, learning)}
        |> maybe_put("role_title", role_title)
        |> maybe_put("department", department)

      Agents.apply_internal_update(agent, attrs)
    end
  end

  # ─── Domain detection ────────────────────────────────────────────────────────

  @doc "Detect categories from a task and run output.  Exported for Dispatcher."
  def detect_categories(%WorkTask{} = task, output \\ %{}) do
    from_output = detect_output_categories(output)

    if from_output != [] do
      from_output
    else
      text = "#{task.title} #{task.description}"
      file_names = get_file_names(task)
      detect_from_text_and_files(text, file_names)
    end
  end

  # ─── Private helpers ─────────────────────────────────────────────────────────

  defp detect_output_categories(output) when is_map(output) do
    category = output["category"]
    skills_used = output["skills_used"]

    categories_from_category =
      cond do
        is_binary(category) and Map.has_key?(@domain_role_map, category) -> [category]
        is_list(category) -> Enum.filter(category, &Map.has_key?(@domain_role_map, &1))
        true -> []
      end

    categories_from_skills =
      case skills_used do
        list when is_list(list) ->
          list
          |> Enum.flat_map(fn skill ->
            for {cat, kws} <- @category_keywords,
                Enum.any?(kws, &String.contains?(String.downcase(to_string(skill)), &1)),
                do: cat
          end)
          |> Enum.uniq()

        _ ->
          []
      end

    Enum.uniq(categories_from_category ++ categories_from_skills)
  end

  defp detect_output_categories(_), do: []

  defp detect_from_text_and_files(text, file_names) do
    ext_categories =
      file_names
      |> Enum.flat_map(fn name ->
        ext = name |> Path.extname() |> String.trim_leading(".")
        for {cat, exts} <- @file_categories, ext in exts, do: cat
      end)

    lower = String.downcase(text)

    kw_categories =
      for {cat, keywords} <- @category_keywords,
          Enum.any?(keywords, &String.contains?(lower, &1)),
          do: cat

    Enum.uniq(ext_categories ++ kw_categories)
  end

  defp get_file_names(%WorkTask{metadata: meta}) when is_map(meta) do
    # Drive item names may be stored in metadata by the dispatcher.
    meta
    |> Map.get("file_names", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp get_file_names(_), do: []

  # ─── Learning state ──────────────────────────────────────────────────────────

  defp get_learning(%Agent{capabilities: caps}) when is_map(caps) do
    Map.get(caps, "learning") || fresh_learning()
  end

  defp get_learning(_), do: fresh_learning()

  defp fresh_learning do
    %{"missions_total" => 0, "domain_counts" => %{}, "specialty" => nil, "specialized_at" => nil}
  end

  defp increment_learning(learning, categories) do
    counts =
      Enum.reduce(categories, learning["domain_counts"] || %{}, fn cat, acc ->
        Map.update(acc, cat, 1, &(&1 + 1))
      end)

    total = learning["missions_total"] + 1
    specialty = dominant_domain(counts, total)

    learning
    |> Map.put("missions_total", total)
    |> Map.put("domain_counts", counts)
    |> maybe_set_specialty(specialty, learning)
  end

  defp maybe_set_specialty(learning, nil, _old), do: Map.put(learning, "specialty", nil)

  defp maybe_set_specialty(learning, specialty, old_learning) do
    learning
    |> Map.put("specialty", specialty)
    |> then(fn l ->
      if l["specialty"] != old_learning["specialty"] and l["specialized_at"] == nil do
        Map.put(l, "specialized_at", DateTime.to_iso8601(DateTime.utc_now()))
      else
        l
      end
    end)
  end

  defp dominant_domain(counts, total) when total >= @specialty_min_missions do
    {top_domain, top_count} =
      Enum.max_by(counts, fn {_k, v} -> v end, fn -> {nil, 0} end)

    if top_domain != nil and top_count / total >= @specialty_min_ratio do
      top_domain
    else
      nil
    end
  end

  defp dominant_domain(_, _), do: nil

  defp put_learning(%Agent{capabilities: caps}, learning) do
    base = if is_map(caps), do: caps, else: %{}
    Map.put(base, "learning", learning)
  end

  # ─── Skill progression ───────────────────────────────────────────────────────

  defp update_skills(current_skills, categories) do
    # Map current skills by name for fast lookup.
    by_name =
      Map.new(current_skills, fn skill ->
        name = skill["name"] || skill[:name]
        {name, skill}
      end)

    skill_names = Enum.flat_map(categories, &domain_skill_names/1)

    updated =
      Enum.reduce(skill_names, by_name, fn name, acc ->
        case Map.get(acc, name) do
          nil ->
            Map.put(acc, name, %{"name" => name, "level" => @skill_initial_level})

          existing ->
            level = existing["level"] || existing[:level] || 0
            gain = max(1, div(100 - level, 8))
            Map.put(acc, name, %{"name" => name, "level" => min(level + gain, 100)})
        end
      end)

    Map.values(updated)
  end

  defp domain_skill_names("code"), do: ["coding", "debugging", "code-review"]
  defp domain_skill_names("design"), do: ["ui-design", "figma", "branding"]
  defp domain_skill_names("data"), do: ["data-analysis", "spreadsheets", "reporting"]
  defp domain_skill_names("document"), do: ["writing", "editing", "research"]
  defp domain_skill_names("media"), do: ["image-editing", "video", "content"]
  defp domain_skill_names("slides"), do: ["presentations", "storytelling", "design"]
  defp domain_skill_names(_), do: ["research", "planning"]

  # ─── Specialisation ──────────────────────────────────────────────────────────

  defp maybe_specialize(agent, learning) do
    specialty = learning["specialty"]
    role_source = get_in(agent.capabilities, ["learning", "role_source"])
    manual = role_source != "auto" and agent.role_title not in [nil, "", "Generalist"]

    cond do
      specialty == nil ->
        {nil, nil}

      manual ->
        {nil, nil}

      true ->
        case Map.get(@domain_role_map, specialty) do
          {title, dept} -> {title, dept}
          nil -> {nil, nil}
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
