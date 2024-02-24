require Logger

defmodule BorsNG.GitHub.Server do
  use GenServer
  alias BorsNG.GitHub

  @moduledoc """
  Provides a real connection to GitHub's REST API.
  This doesn't currently do rate limiting, but it will.
  """

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: GitHub)
  end

  @installation_content_type "application/vnd.github.machine-man-preview+json"
  @team_content_type "application/vnd.github.hellcat-preview+json"
  @content_type_raw "application/vnd.github.v3.raw"
  @content_type "application/vnd.github.v3+json"

  @type tconn :: GitHub.tconn()
  @type ttoken :: GitHub.ttoken()
  @type trepo :: GitHub.trepo()
  @type tuser :: GitHub.tuser()
  @type tpr :: GitHub.tpr()
  @type tcollaborator :: GitHub.tcollaborator()
  @type tuser_repo_perms :: GitHub.tuser_repo_perms()

  @typedoc """
  The token cache.
  """
  @type ttokenreg :: %{number => {binary, number}}

  @spec config() :: keyword
  defp config do
    Confex.fetch_env!(:bors, GitHub.Server)
  end

  @spec site() :: bitstring
  defp site do
    Confex.fetch_env!(:bors, :api_github_root)
  end

  def init(:ok) do
    {:ok, %{}}
  end

  def handle_call({type, {{_, _} = token, repo_xref}, args}, _from, state) do
    use_token!(token, state, fn token ->
      do_handle_call(type, {token, repo_xref}, args)
    end)
  end

  def handle_call({type, {_, _} = token, args}, _from, state) do
    use_token!(token, state, fn token ->
      do_handle_call(type, token, args)
    end)
  end

  def handle_call(:get_app, _from, state) do
    result =
      "Bearer #{get_jwt_token()}"
      |> tesla_client(@installation_content_type)
      |> Tesla.get!("/app")
      |> case do
        %{body: raw, status: 200} ->
          app_link =
            raw
            |> Jason.decode!()
            |> Map.get("html_url")

          {:ok, app_link}

        %{body: body, status: status} ->
          {:error, :get_app, status, body}
      end

    {:reply, result, state}
  end

  def handle_call(:get_installation_list, _from, state) do
    jwt_token = get_jwt_token()

    list =
      get_installation_list_!(
        jwt_token,
        "#{site()}/app/installations",
        []
      )

    {:reply, {:ok, list}, state}
  end

  def do_handle_call(:get_pr_files, repo_conn, {pr_xref}) do
    case get!(repo_conn, "pulls/#{pr_xref}/files") do
      %{body: raw, status: 200} ->
        pr =
          raw
          |> Jason.decode!()
          |> Enum.map(&GitHub.File.from_json!/1)

        {:ok, pr}

      e ->
        {:error, :get_pr_files, e.status, pr_xref}
    end
  end

  def do_handle_call(:get_pr, repo_conn, {pr_xref}) do
    case get!(repo_conn, "pulls/#{pr_xref}") do
      %{body: raw, status: 200} ->
        pr =
          raw
          |> Jason.decode!()
          |> GitHub.Pr.from_json!()

        {:ok, pr}

      e ->
        {:error, :get_pr, e.status, pr_xref}
    end
  end

  def do_handle_call(:update_pr_base, repo_conn, pr) do
    repo_conn
    |> patch!(
      "pulls/#{pr.number}",
      Jason.encode!(%{
        title: pr.title,
        body: pr.body,
        state: pr.state,
        base: pr.base_ref
      })
    )
    |> case do
      %{body: raw, status: 200} ->
        pr =
          raw
          |> Jason.decode!()
          |> GitHub.Pr.from_json!()

        {:ok, pr}

      %{body: body, status: status} ->
        {:error, :push, status, body}
    end
  end

  def do_handle_call(:update_pr, repo_conn, pr) do
    repo_conn
    |> patch!(
      "pulls/#{pr.number}",
      Jason.encode!(%{
        title: pr.title,
        body: pr.body,
        state: pr.state
      })
    )
    |> case do
      %{body: raw, status: 200} ->
        pr =
          raw
          |> Jason.decode!()
          |> GitHub.Pr.from_json!()

        {:ok, pr}

      %{body: body, status: status} ->
        {:error, :push, status, body}
    end
  end

  def do_handle_call(:get_pr_commits, {{:raw, token}, repo_xref}, {pr_xref}) do
    get_pr_commits_(token, "#{site()}/repositories/#{repo_xref}/pulls/#{pr_xref}/commits", [])
  end

  def do_handle_call(:get_open_prs, {{:raw, token}, repo_xref}, {}) do
    {:ok,
     get_open_prs_!(
       token,
       "#{site()}/repositories/#{repo_xref}/pulls?state=open",
       []
     )}
  end

  def do_handle_call(:get_open_prs_with_base, {{:raw, token}, repo_xref}, {base}) do
    {:ok,
     get_open_prs_!(
       token,
       "#{site()}/repositories/#{repo_xref}/pulls?state=open&base=#{base}",
       []
     )}
  end

  def do_handle_call(:push, repo_conn, {sha, to}) do
    repo_conn
    |> patch!("git/refs/heads/#{to}", Jason.encode!(%{sha: sha}))
    |> case do
      %{body: _, status: 200} ->
        {:ok, sha}

      %{body: body, status: status} ->
        IO.inspect({:error, :push, body})
        {:error, :push, status, body}
    end
  end

  def do_handle_call(:get_branch, repo_conn, {branch}) do
    case get!(repo_conn, "branches/#{branch}") do
      %{body: raw, status: 200} ->
        r = Jason.decode!(raw)["commit"]
        {:ok, %{commit: r["sha"], tree: r["commit"]["tree"]["sha"]}}

      %{body: body, status: status} ->
        {:error, :get_branch, status, body}
    end
  end

  def do_handle_call(:delete_branch, repo_conn, {branch}) do
    case delete!(repo_conn, "git/refs/heads/#{branch}") do
      %{status: 204} ->
        :ok

      _ ->
        {:error, :delete_branch}
    end
  end

  def do_handle_call(
        :merge_branch,
        repo_conn,
        {%{
           from: from,
           to: to,
           commit_message: commit_message
         }}
      ) do
    msg = %{base: to, head: from, commit_message: commit_message}

    repo_conn
    |> post!("merges", Jason.encode!(msg))
    |> case do
      %{body: raw, status: 201} ->
        data = Jason.decode!(raw)

        res = %{
          commit: data["sha"],
          tree: data["commit"]["tree"]["sha"]
        }

        {:ok, res}

      %{status: 409} ->
        {:ok, :conflict}

      %{status: 204} ->
        {:ok, :conflict}

      %{body: body, status: status, headers: headers} ->
        {:error, :merge_branch, status, body, Map.new(headers)["x-github-request-id"]}
    end
  end

  def do_handle_call(
        :squash_merge_branch,
        repo_conn,
        {%{
           pull_number: pull_number,
           commit_title: commit_title,
           commit_message: commit_message
         }}
      ) do
    msg = %{merge_method: "squash", commit_title: commit_title}

    msg =
      if commit_message != nil do
        Map.put_new(msg, :commit_message, commit_message)
      else
        msg
      end

    repo_conn
    |> put!("pulls/#{pull_number}/merge", Jason.encode!(msg))
    |> case do
      %{body: raw, status: 200} ->
        data = Jason.decode!(raw)

        res = %{
          commit: data["sha"]
        }

        {:ok, res}

      %{status: 409} ->
        {:ok, :conflict}

      %{status: 204} ->
        {:ok, :conflict}

      %{body: body, status: status, headers: headers} ->
        {:error, :squash_merge_branch, status, body, Map.new(headers)["x-github-request-id"]}
    end
  end

  def do_handle_call(
        :create_commit,
        repo_conn,
        {%{
           tree: tree,
           parents: parents,
           commit_message: commit_message,
           committer: committer
         }}
      ) do
    msg = %{parents: parents, tree: tree, message: commit_message}

    msg =
      if is_nil(committer) do
        msg
      else
        Map.put(msg, "author", %{
          name: committer.name,
          email: committer.email
        })
      end

    resp =
      repo_conn
      |> post!("git/commits", Jason.encode!(msg))
      |> case do
        %{body: raw, status: 201} ->
          Logger.info("Raw response from GH #{inspect(raw)}")
          data = Jason.decode!(raw)

          res = %{
            commit: data["sha"]
          }

          {:ok, res.commit}

        %{status: 409} ->
          {:ok, :conflict}

        %{status: 204} ->
          {:ok, :conflict}

        %{body: body, status: status, headers: headers} ->
          {:error, :create_commit, status, body, Map.new(headers)["x-github-request-id"]}
      end

    resp
  end

  def do_handle_call(
        :synthesize_commit,
        repo_conn,
        {%{
           branch: branch,
           tree: tree,
           parents: parents,
           commit_message: commit_message,
           committer: committer
         }}
      ) do
    msg = %{parents: parents, tree: tree, message: commit_message}

    msg =
      if is_nil(committer) do
        msg
      else
        Map.put(msg, "author", %{
          name: committer.name,
          email: committer.email
        })
      end

    repo_conn
    |> post!("git/commits", Jason.encode!(msg))
    |> case do
      %{body: raw, status: 201} ->
        sha = Jason.decode!(raw)["sha"]
        do_handle_call(:force_push, repo_conn, {sha, branch})

      %{body: body, status: status, headers: headers} ->
        {:error, :synthesize_commit, status, body, Map.new(headers)["x-github-request-id"]}
    end
  end

  def do_handle_call(:force_push, repo_conn, {sha, to}) do
    repo_conn
    |> get!("branches/#{to}")
    |> case do
      %{status: 404} ->
        msg = %{ref: "refs/heads/#{to}", sha: sha}

        repo_conn
        |> post!("git/refs", Jason.encode!(msg))
        |> case do
          %{status: 201} ->
            {:ok, sha}

          %{status: status, body: body} ->
            {:error, :force_push, status, body}
        end

      %{body: raw, status: 200} ->
        if sha != Jason.decode!(raw)["commit"]["sha"] do
          msg = %{force: true, sha: sha}

          repo_conn
          |> patch!("git/refs/heads/#{to}", Jason.encode!(msg))
          |> case do
            %{status: 200} ->
              {:ok, sha}

            %{status: status, body: body} ->
              {:error, :force_push, status, body}
          end
        else
          {:ok, sha}
        end

      %{body: body, status: status, headers: headers} ->
        {:error, :force_push, status, body, Map.new(headers)["x-github-request-id"]}
    end
  end

  def do_handle_call(:get_commit_status, {{:raw, token}, repo_xref}, {sha}) do
    with {:ok, status} <-
           get_statuses_!(
             token,
             "#{site()}/repositories/#{repo_xref}/commits/#{sha}/status",
             %{}
           ),
         {:ok, check} <-
           get_checks_!(
             token,
             "#{site()}/repositories/#{repo_xref}/commits/#{sha}/check-runs",
             %{}
           ),
         do: {:ok, Map.merge(status, check)}
  end

  def do_handle_call(:get_labels, repo_conn, {issue_xref}) do
    repo_conn
    |> get!("issues/#{issue_xref}/labels")
    |> case do
      %{body: raw, status: 200} ->
        res =
          Jason.decode!(raw)
          |> Enum.map(fn %{"name" => name} -> name end)

        {:ok, res}

      %{body: body, status: status} ->
        {:error, :get_labels, status, body}
    end
  end

  def do_handle_call(:get_reviews, {{:raw, token}, repo_xref}, {issue_xref, sha}) do
    reviews =
      token
      |> get_reviews_json_!("#{site()}/repositories/#{repo_xref}/pulls/#{issue_xref}/reviews", [])
      |> GitHub.Reviews.filter_sha!(sha)
      |> GitHub.Reviews.from_json!()

    {:ok, reviews}
  end

  def do_handle_call(:get_reviews, repo_conn, {issue_xref}) do
    do_handle_call(:get_reviews, repo_conn, {issue_xref, nil})
  end

  def do_handle_call(:get_file, repo_conn, {branch, path}) do
    %{body: raw, status: status} =
      get!(
        repo_conn,
        "contents/#{path}",
        @content_type_raw,
        query: [ref: branch]
      )

    res =
      case status do
        404 -> nil
        200 -> raw
      end

    {:ok, res}
  end

  def do_handle_call(:post_comment, repo_conn, {number, body}) do
    repo_conn
    |> post!("issues/#{number}/comments", Jason.encode!(%{body: body}))
    |> case do
      %{status: 201} ->
        :ok

      %{status: status, body: raw} ->
        {:error, :post_comment, status, raw}
    end
  end

  def do_handle_call(:post_commit_status, repo_conn, {sha, status, msg, url}) do
    state = GitHub.map_status_to_state(status)
    body = %{state: state, context: "bors", description: msg, target_url: url}

    repo_conn
    |> post!("statuses/#{sha}", Jason.encode!(body))
    |> case do
      %{status: 201} ->
        :ok

      %{status: status, body: raw} ->
        {:error, :post_commit_status, status, raw}
    end
  end

  def do_handle_call(:belongs_to_team, repo_conn, {org, team_slug, username}) do
    IO.inspect(repo_conn)
    {{:raw, token}, _installation_id} = repo_conn

    "token #{token}"
    |> tesla_client()
    |> Tesla.get!(URI.encode("/orgs/#{org}/teams/#{team_slug}/memberships/#{username}"))
    |> case do
      %{status: 200} ->
        true

      %{status: 404} ->
        false

      _ ->
        false
    end
  end

  def do_handle_call(:get_collaborators_by_repo, {{:raw, token}, repo_xref}, {}) do
    get_collaborators_by_repo_(
      token,
      "#{site()}/repositories/#{repo_xref}/collaborators",
      []
    )
  end

  def do_handle_call(
        :get_user_by_login,
        {:raw, token},
        {login}
      ) do
    "token #{token}"
    |> tesla_client()
    |> Tesla.get!("/users/#{URI.encode_www_form(login)}")
    |> case do
      %{body: raw, status: 200} ->
        user =
          raw
          |> Jason.decode!()
          |> GitHub.FullUser.from_json!()

        {:ok, user}

      %{status: 404} ->
        {:ok, nil}

      _ ->
        {:error, :get_user_by_login}
    end
  end

  def do_handle_call(:get_installation_repos, {:raw, token}, {}) do
    {:ok,
     get_installation_repos_!(
       token,
       "#{site()}/installation/repositories",
       []
     )}
  end

  @spec get_statuses_!(binary, binary | nil, %{bitstring => GitHub.tstatus()}) ::
          {:ok, %{bitstring => GitHub.tstatus()}}
  defp get_statuses_!(_, nil, statuses) do
    statuses
  end

  defp get_statuses_!(token, url, statuses) do
    params = get_url_params(url)

    {raw, headers} =
      "token #{token}"
      |> tesla_client(@content_type)
      |> Tesla.get!(url, query: params)
      |> case do
        %{body: raw, status: 200, headers: headers} -> {raw, headers}
        _ -> {~s("statuses":[]), %{}}
      end

    statuses =
      Jason.decode!(raw)["statuses"]
      |> Enum.map(
        &{
          &1["context"] |> GitHub.map_changed_status(),
          GitHub.map_state_to_status(&1["state"])
        }
      )
      |> Map.new()
      |> Map.merge(statuses)

    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> {:ok, statuses}
      [next] -> get_statuses_!(token, next.url, statuses)
    end
  end

  @spec get_checks_!(binary, binary | nil, %{bitstring => GitHub.tstatus()}) ::
          {:ok, %{bitstring => GitHub.tstatus()}}
  defp get_checks_!(_, nil, checks) do
    checks
  end

  defp get_checks_!(token, url, checks) do
    params = get_url_params(url)

    {raw, headers} =
      "token #{token}"
      |> tesla_client(@content_type)
      |> Tesla.get!(url, query: params)
      |> case do
        %{body: raw, status: 200, headers: headers} -> {raw, headers}
        _ -> {~s("check_runs":[]), %{}}
      end

    checks =
      Jason.decode!(raw)["check_runs"]
      |> Enum.map(
        &{
          &1["name"] |> GitHub.map_changed_status(),
          GitHub.map_check_to_status(&1["conclusion"])
        }
      )
      |> Map.new()
      |> Map.merge(checks)

    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> {:ok, checks}
      [next] -> get_checks_!(token, next.url, checks)
    end
  end

  defp get_reviews_json_!(_, nil, append) do
    append
  end

  defp get_reviews_json_!(token, url, append) do
    params = get_url_params(url)

    %{body: raw, status: 200, headers: headers} =
      "token #{token}"
      |> tesla_client(@installation_content_type)
      |> Tesla.get!(url, query: params)

    json = Enum.concat(append, Jason.decode!(raw))
    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> json
      [next] -> get_reviews_json_!(token, next.url, json)
    end
  end

  @spec get_installation_repos_!(binary, binary, [trepo]) :: [trepo]
  defp get_installation_repos_!(_, nil, repos) do
    repos
  end

  defp get_installation_repos_!(token, url, append) do
    params = get_url_params(url)

    %{body: raw, status: 200, headers: headers} =
      "token #{token}"
      |> tesla_client(@installation_content_type)
      |> Tesla.get!(url, query: params)

    repositories =
      Jason.decode!(raw)["repositories"]
      |> Enum.map(&GitHub.Repo.from_json!/1)
      |> Enum.concat(append)

    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> repositories
      [next] -> get_installation_repos_!(token, next.url, repositories)
    end
  end

  @spec get_installation_list_!(binary, binary | nil, [integer]) :: [integer]
  defp get_installation_list_!(_, nil, list) do
    list
  end

  defp get_installation_list_!(jwt_token, url, append) do
    params = get_url_params(url)

    %{body: raw, status: 200, headers: headers} =
      "Bearer #{jwt_token}"
      |> tesla_client(@installation_content_type)
      |> Tesla.get!(url, query: params)

    list =
      Jason.decode!(raw)
      |> Enum.map(fn %{"id" => id} -> id end)
      |> Enum.concat(append)

    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> list
      [next] -> get_installation_list_!(jwt_token, next.url, list)
    end
  end

  @spec get_open_prs_!(binary, binary | nil, [tpr]) :: [tpr]
  defp get_open_prs_!(_, nil, prs) do
    prs
  end

  defp get_open_prs_!(token, url, append) do
    params = get_url_params(url)

    {raw, headers} =
      "token #{token}"
      |> tesla_client(@content_type)
      |> Tesla.get!(url, query: params)
      |> case do
        %{body: raw, status: 200, headers: headers} -> {raw, headers}
        _ -> {"[]", %{}}
      end

    prs =
      Jason.decode!(raw)
      |> Enum.flat_map(fn %{"url" => url} ->
        "token #{token}"
        |> tesla_client(@content_type)
        |> Tesla.get!(url)
        |> case do
          %{body: raw, status: 200} -> Jason.decode!(raw)
          _ -> %{}
        end
        |> GitHub.Pr.from_json()
        |> case do
          {:ok, pr} -> [pr]
          _ -> []
        end
      end)
      |> Enum.concat(append)

    next_headers = get_next_headers(headers)

    case next_headers do
      [] -> prs
      [next] -> get_open_prs_!(token, next.url, prs)
    end
  end

  defp get_pr_commits_(_, nil, append) do
    {:ok, append}
  end

  defp get_pr_commits_(token, url, append) do
    params = get_url_params(url)

    "token #{token}"
    |> tesla_client(@team_content_type)
    |> Tesla.get(url, query: params)
    |> case do
      {:ok, %{body: raw, status: 200, headers: headers}} ->
        Logger.info("Raw response from GH #{inspect(raw)}")

        commits =
          raw
          |> Jason.decode!()
          |> Enum.map(&GitHub.Commit.from_json!/1)

        next_headers = get_next_headers(headers)

        case next_headers do
          [] -> {:ok, commits ++ append}
          [next] -> get_pr_commits_(token, next.url, commits)
        end

      {:error, %{status: status}} ->
        {:error, :get_pr_commits, status, url}

      error ->
        IO.inspect(error)
        {:error, :get_pr_commits}
    end
  end

  @spec extract_user_repo_perms(map()) :: tuser_repo_perms
  defp extract_user_repo_perms(data) do
    Map.new(["admin", "push", "pull"], fn perm ->
      {String.to_atom(perm), !!data["permissions"][perm]}
    end)
  end

  @spec get_collaborators_by_repo_(binary, binary, [tcollaborator]) ::
          {:ok, [tcollaborator]} | {:error, :get_collaborators_by_repo}
  def get_collaborators_by_repo_(token, url, append) do
    params = get_url_params(url)

    "token #{token}"
    |> tesla_client(@team_content_type)
    |> Tesla.get(url, query: params)
    |> case do
      {:ok, %{body: raw, status: 200, headers: headers}} ->
        users =
          raw
          |> Jason.decode!()
          |> Enum.map(fn user ->
            %{user: GitHub.User.from_json!(user), perms: extract_user_repo_perms(user)}
          end)
          |> Enum.concat(append)

        next_headers = get_next_headers(headers)

        case next_headers do
          [] ->
            {:ok, users}

          [next] ->
            get_collaborators_by_repo_(token, next.url, users)
        end

      error ->
        IO.inspect(error)
        {:error, :get_collaborators_by_repo}
    end
  end

  @spec post!(tconn, binary, binary, binary) :: map
  defp post!(
         {{:raw, token}, repo_xref},
         path,
         body,
         content_type \\ @content_type
       ) do
    "token #{token}"
    |> tesla_client(content_type)
    |> Tesla.post!(URI.encode("/repositories/#{repo_xref}/#{path}"), body)
  end

  @spec put!(tconn, binary, binary, binary) :: map
  defp put!(
         {{:raw, token}, repo_xref},
         path,
         body,
         content_type \\ @content_type
       ) do
    "token #{token}"
    |> tesla_client(content_type)
    |> Tesla.put!(URI.encode("/repositories/#{repo_xref}/#{path}"), body)
  end

  @spec patch!(tconn, binary, binary, binary) :: map
  defp patch!(
         {{:raw, token}, repo_xref},
         path,
         body,
         content_type \\ @content_type
       ) do
    "token #{token}"
    |> tesla_client(content_type)
    |> Tesla.patch!(URI.encode("/repositories/#{repo_xref}/#{path}"), body)
  end

  @spec get!(tconn, binary, binary, list) :: map
  defp get!(
         {{:raw, token}, repo_xref},
         path,
         content_type \\ @content_type,
         params \\ []
       ) do
    "token #{token}"
    |> tesla_client(content_type)
    |> Tesla.get!(URI.encode("/repositories/#{repo_xref}/#{path}"), params)
  end

  @spec delete!(tconn, binary, binary, list) :: map
  defp delete!(
         {{:raw, token}, repo_xref},
         path,
         content_type \\ @content_type,
         params \\ []
       ) do
    "token #{token}"
    |> tesla_client(content_type)
    |> Tesla.delete!(URI.encode("/repositories/#{repo_xref}/#{path}"), params)
  end

  defp get_next_headers(headers) do
    Enum.flat_map(headers, fn {name, value} ->
      name
      |> String.downcase(:ascii)
      |> case do
        "link" ->
          value = ExLinkHeader.parse!(value)
          if is_nil(value.next), do: [], else: [value.next]

        _ ->
          []
      end
    end)
  end

  defp get_url_params(url) do
    case URI.parse(url).query do
      nil -> []
      qry -> URI.query_decoder(qry) |> Enum.to_list()
    end
  end

  @token_exp 60

  @spec get_installation_token!(number) :: binary
  def get_installation_token!(installation_xref) do
    jwt_token = get_jwt_token()

    %{body: raw, status: 201} =
      "Bearer #{jwt_token}"
      |> tesla_client(@installation_content_type)
      |> Tesla.post!("app/installations/#{installation_xref}/access_tokens", "")

    Jason.decode!(raw)["token"]
  end

  def get_jwt_token do
    import Joken.Config
    cfg = config()

    Joken.generate_and_sign!(
      default_claims(),
      %{
        "iat" => Joken.current_time(),
        "exp" => Joken.current_time() + @token_exp,
        "iss" => cfg[:iss]
      },
      Joken.Signer.create("RS256", %{"pem" => cfg[:pem]})
    )
  end

  @doc """
  Uses a token from the cache, or, if the request fails,
  retry without using the cached token.
  """
  @spec use_token!(ttoken, ttokenreg, (ttoken -> term)) ::
          {:reply, term, ttokenreg}
  def use_token!({:installation, installation_xref} = token, state, fun) do
    {token, state} = raw_token!(token, state)
    result = fun.(token)

    case result do
      {:ok, _} ->
        {:reply, result, state}

      :ok ->
        {:reply, result, state}

      _ ->
        state = Map.delete(state, installation_xref)
        {token, state} = raw_token!(token, state)
        result = fun.(token)
        {:reply, result, state}
    end
  end

  def use_token!(token, state, fun) do
    {token, state} = raw_token!(token, state)
    result = fun.(token)
    {:reply, result, state}
  end

  @doc """
  Given an {:installation, installation_xref},
  look it up in the token cache.
  If it's there, and it's still usable, use it.
  Otherwise, fetch a new one.
  """
  @spec raw_token!(ttoken, ttokenreg) :: {{:raw, binary}, ttokenreg}
  def raw_token!({:installation, installation_xref}, state) do
    now = Joken.current_time()

    case state[installation_xref] do
      {token, issued} when issued + @token_exp > now ->
        {{:raw, token}, state}

      _ ->
        token = get_installation_token!(installation_xref)
        state = Map.put(state, installation_xref, {token, now})
        {{:raw, token}, state}
    end
  end

  def raw_token!({:raw, _} = raw, state) do
    {raw, state}
  end

  defp tesla_client(authorization, content_type \\ @content_type) do
    middleware = [
      {Tesla.Middleware.BaseUrl, site()},
      {Tesla.Middleware.Headers,
       [
         {"authorization", authorization},
         {"accept", content_type},
         {"user-agent", "bors-ng https://bors.tech"}
       ]},
      {Tesla.Middleware.Retry, delay: 100, max_retries: 5}
    ]

    middleware =
      if Confex.get_env(:bors, :log_outgoing, false) do
        middleware ++ [{Tesla.Middleware.Logger, filter_headers: ["authorization"], debug: true}]
      else
        middleware
      end

    params =
      [
        connect_timeout: Confex.get_env(:bors, :api_github_timeout, 8_000) - 1,
        recv_timeout: Confex.get_env(:bors, :api_github_timeout, 8_000) - 1
      ] ++
        case System.get_env("HTTPS_PROXY") do
          nil ->
            []

          proxy ->
            [proxy: proxy]
        end

    Tesla.client(
      middleware,
      {Tesla.Adapter.Hackney, params}
    )
  end
end
