namespace :projects do
  task recreate_index: :environment do
    # If the index doesn't exists can't be deleted, returns 404, carry on
    Project.__elasticsearch__.client.indices.delete index: 'projects' rescue nil
    Project.__elasticsearch__.create_index! force: true
  end

  desc 'Reindex the search'
  task reindex: [:environment, :recreate_index] do
    Project.import query: -> { indexable }
  end

  desc 'Update the sitemap every other day'
  task update_sitemap: :environment do
    if Date.today.wday.zero?
      Rake::Task["sitemap:refresh"].invoke
    end
  end

  task sync: :environment do
    ids = Project.where(last_synced_at: nil).order('projects.updated_at DESC').limit(100_000).pluck(:id)
    Project.where(id: ids).find_each(&:async_sync)
  end

  task update_source_ranks: :environment do
    Project.where('projects.updated_at < ?', 1.week.ago).find_each(&:update_source_rank_async) if Date.today.sunday?
  end

  task link_dependencies: :environment do
    Dependency.without_project_id.with_project_name.find_each(&:update_project_id)
    RepositoryDependency.without_project_id.with_project_name.find_each(&:update_project_id)
  end

  task check_status: :environment do
    ['npm', 'rubygems', 'packagist', 'nuget', 'wordpress', 'cpan', 'clojars', 'cocoapods',
    'hackage', 'cran', 'atom', 'sublime', 'pub', 'elm', 'dub'].each do |platform|
      Project.platform(platform).not_removed.where('projects.updated_at < ?', 1.week.ago).select('id, name').find_each do |project|
        CheckStatusWorker.perform_async(project.id, platform, project.name)
      end
    end
  end

  task update_repos: :environment do
    repo_names = Project.maintained.where('projects.updated_at < ?', 1.week.ago).with_repo.pluck('github_repositories.full_name').uniq.compact

    repo_names.each do |repo_name|
      GithubUpdateWorker.perform_async(repo_name)
    end
  end

  task chech_repo_status: :environment do
    ['bower', 'go', 'elm', 'alcatraz', 'julia', 'nimble'].each do |platform|
      repo_names = Project.platform(platform).maintained.where('projects.updated_at < ?', 1.week.ago).with_repo.pluck('github_repositories.full_name').uniq.compact
      repo_names.each do |repo_name|
        CheckRepoStatusWorker.perform_async(repo_name)
      end
    end
  end

  task check_removed_status: :environment do
    ['npm', 'rubygems', 'packagist', 'wordpress', 'cpan', 'clojars', 'cocoapods',
    'hackage', 'cran', 'atom', 'sublime', 'pub', 'elm', 'dub'].each do |platform|
      Project.platform(platform).removed.select('id, name').find_each do |project|
        CheckStatusWorker.perform_async(project.id, platform, project.name, true)
      end
    end

    ['bower', 'go', 'elm', 'alcatraz', 'julia', 'nimble'].each do |platform|
      repo_names = Project.platform(platform).removed.with_repo.pluck('github_repositories.full_name').uniq.compact
      repo_names.each do |repo_name|
        CheckRepoStatusWorker.perform_async(repo_name, true)
      end
    end
  end

  task check_nuget_yanks: :environment do
    if Date.today.wday.zero?
      Project.platform('nuget').not_removed.includes(:versions).find_each do |project|
        if project.versions.all? { |version| version.published_at < 100.years.ago  }
          project.update_attribute(:status, 'Removed')
        end
      end
    end
  end
end
