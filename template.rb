require "fileutils"
require "shellwords"

# Copied from: https://github.com/mattbrictson/rails-template
# Add this template directory to source_paths so that Thor actions like
# copy_file and template resolve against our source files. If this file was
# invoked remotely via HTTP, that means the files are not present locally.
# In that case, use `git clone` to download them to a local temporary dir.
def add_template_repository_to_source_path
  if __FILE__ =~ %r{\Ahttps?://}
    require "tmpdir"
    source_paths.unshift(tempdir = Dir.mktmpdir("jumpstarter-"))
    at_exit { FileUtils.remove_entry(tempdir) }
    git clone: [
      "--quiet",
      "https://github.com/whatapalaver/jumpstarter.git",
      tempdir
    ].map(&:shellescape).join(" ")

    if (branch = __FILE__[%r{jumpstarter/(.+)/template.rb}, 1])
      Dir.chdir(tempdir) { git checkout: branch }
    end
  else
    source_paths.unshift(File.dirname(__FILE__))
  end
end

def rails_version
  @rails_version ||= Gem::Version.new(Rails::VERSION::STRING)
end

def rails_5?
  Gem::Requirement.new(">= 5.2.0", "< 6.0.0.beta1").satisfied_by? rails_version
end

def rails_6?
  Gem::Requirement.new(">= 6.0.0.beta1", "< 7").satisfied_by? rails_version
end

def add_gems
  gem 'devise', '~> 4.7', '>= 4.7.3'
  gem 'devise-bootstrapped', github: 'excid3/devise-bootstrapped', branch: 'bootstrap4'
  gem 'devise_masquerade', '~> 1.2'
  gem 'font-awesome-sass', '~> 5.15.1'
  gem 'friendly_id', '~> 5.3'
  gem 'image_processing'
  gem 'madmin'
  gem 'mini_magick', '~> 4.10', '>= 4.10.1'
  gem 'name_of_person', '~> 1.1'
  gem 'noticed', '~> 1.2'
  gem 'omniauth-facebook', '~> 6.0'
  gem 'omniauth-github', '~> 1.4'
  gem 'omniauth-twitter', '~> 1.4'
  gem 'pundit', '~> 2.1'
  gem 'redis', '~> 4.2', '>= 4.2.2'
  gem 'sidekiq', '~> 6.1'
  gem 'sitemap_generator', '~> 6.1', '>= 6.1.2'
  gem 'whenever', require: false
end

def add_test_gems
  gem_group :test do
    gem 'capybara-screenshot'
    gem 'cucumber-rails', require: false
    gem 'database_cleaner'
    gem 'rails-controller-testing'
  end

  gem_group :development, :test do
    gem 'rspec-rails'
    gem 'factory_bot_rails'
    gem 'shoulda-matchers'
    gem 'faker'
  end
end

def pg_db
  # config the app to use postgres
  remove_file 'config/database.yml'
  template 'database.erb', 'config/database.yml'
end

def yarn(lib)
  run("yarn add #{lib}")
end

def set_application_name
  # Add Application Name to Config
  environment "config.application_name = Rails.application.class.module_parent_name"

  # Announce the user where they can change the application name in the future.
  puts "You can change application name inside: ./config/application.rb"
end

def add_users
  # Install Devise
  generate "devise:install"

  # Configure Devise
  environment "config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }",
              env: 'development'
  route "root to: 'home#index'"

  # Devise notices are installed via Bootstrap
  generate "devise:views:bootstrapped"

  # Create Devise User
  generate :devise, "User",
           "first_name",
           "last_name",
           "announcements_last_read_at:datetime",
           "admin:boolean"

  # Set admin default to false
  in_root do
    migration = Dir.glob("db/migrate/*").max_by{ |f| File.mtime(f) }
    gsub_file migration, /:admin/, ":admin, default: false"
  end

  if Gem::Requirement.new("> 5.2").satisfied_by? rails_version
    gsub_file "config/initializers/devise.rb",
      /  # config.secret_key = .+/,
      "  config.secret_key = Rails.application.credentials.secret_key_base"
  end

  # Add Devise masqueradable to users
  inject_into_file("app/models/user.rb", "omniauthable, :masqueradable, :", after: "devise :")
end

def add_authorization
  generate 'pundit:install'
end

def add_javascript
  yarn("bootstrap@next")
  yarn("@popperjs/core")
  yarn ("@fortawesome/fontawesome-free")
end

def copy_templates
  copy_file "Procfile"
  copy_file "Procfile.dev"
  copy_file ".foreman"

  directory "app", force: true
  directory "config", force: true
  directory "lib", force: true

  route "get '/terms', to: 'home#terms'"
  route "get '/privacy', to: 'home#privacy'"
end

def copy_features
  directory "features", force: true
end

def add_sidekiq
  environment "config.active_job.queue_adapter = :sidekiq"

  insert_into_file "config/routes.rb",
    "require 'sidekiq/web'\n\n",
    before: "Rails.application.routes.draw do"

  content = <<~RUBY
                authenticate :user, lambda { |u| u.admin? } do
                  mount Sidekiq::Web => '/sidekiq'

                  namespace :madmin do
                  end
                end
            RUBY
  insert_into_file "config/routes.rb", "#{content}\n", after: "Rails.application.routes.draw do\n"
end

def add_announcements
  generate "model Announcement published_at:datetime announcement_type name description:text"
  route "resources :announcements, only: [:index]"
end

def add_notifications
  generate "noticed:model"
  route "resources :notifications, only: [:index]"
end

def add_multiple_authentication
    insert_into_file "config/routes.rb",
    ', controllers: { omniauth_callbacks: "users/omniauth_callbacks" }',
    after: "  devise_for :users"

    generate "model Service user:references provider uid access_token access_token_secret refresh_token expires_at:datetime auth:text"

    template = """
    env_creds = Rails.application.credentials[Rails.env.to_sym] || {}
    %i{ facebook twitter github }.each do |provider|
      if options = env_creds[provider]
        config.omniauth provider, options[:app_id], options[:app_secret], options.fetch(:options, {})
      end
    end
    """.strip

    insert_into_file "config/initializers/devise.rb", "  " + template + "\n\n",
          before: "  # ==> Warden configuration"
end

def add_whenever
  run "wheneverize ."
end

def add_friendly_id
  generate "friendly_id"

  insert_into_file(
    Dir["db/migrate/**/*friendly_id_slugs.rb"].first,
    "[5.2]",
    after: "ActiveRecord::Migration"
  )
end

def stop_spring
  run "spring stop"
end

def add_sitemap
  rails_command "sitemap:install"
end

def update_readme
  template = """
    ## To get started with your new app

    - cd {app_name}
    - Update config/database.yml with your database credentials
    - rails db:create db:migrate
    - rails g madmin:install # Generate admin dashboards
    - gem install foreman
    - foreman start # Run Rails, sidekiq, and webpack-dev-server

    ### Running your app

    To run your app, use `foreman start`. Foreman will run `Procfile.dev` via `foreman start -f Procfile.dev` as configured by the `.foreman` file and will launch the development processes `rails server`, `sidekiq`, and `webpack-dev-server` processes. 
    You can also run them in separate terminals manually if you prefer.
    A separate `Procfile` is generated for deploying to production on Heroku.

    ### Authenticate with social networks

    We use the encrypted Rails Credentials for app_id and app_secrets when it comes to omniauth authentication. Edit them as so:

    ```
    EDITOR=vim rails credentials:edit
    ```

    Make sure your file follow this structure:

    ```yml
    secret_key_base: [your-key]
    development:
      github:
        app_id: something
        app_secret: something
        options:
          scope: 'user:email'
          whatever: true
    production:
      github:
        app_id: something
        app_secret: something
        options:
          scope: 'user:email'
          whatever: true
    ```

    With the environment, the service and the app_id/app_secret. If this is done correctly, you should see login links
    for the services you have added to the encrypted credentials using `EDITOR=vim rails credentials:edit`

    ### Testing

    The app is set up for BDD using cucumber. Just run `cucumber` to be woalked through the process.

    ### Cleaning up

    ```bash
    rails db:drop
    spring stop
    cd ..
    rm -rf myapp
    ```
    """.strip
    insert_into_file 'README.md', "\n" + template, after: "# README"  
end

# Main setup
add_template_repository_to_source_path

add_gems
add_test_gems

after_bundle do
  set_application_name
  stop_spring
  add_users
  add_authorization
  add_javascript
  add_announcements
  add_notifications
  add_multiple_authentication
  add_sidekiq
  add_friendly_id

  copy_templates
  pg_db
  add_whenever
  add_sitemap
  update_readme

  rails_command "active_storage:install"
  rails_command "generate rspec:install"
  rails_command "generate cucumber:install"

  copy_features

  # Commit everything to git
  unless ENV["SKIP_GIT"]
    git :init
    git add: "."
    # git commit will fail if user.email is not configured
    begin
      git commit: %( -m 'Initial commit' )
    rescue StandardError => e
      puts e.message
    end
  end

  say
  say "Jumpstarter app successfully created!", :blue
  say
  say "To get started with your new app:", :green
  say "  cd #{app_name}"
  say
  say "  # Update config/database.yml with your database credentials"
  say
  say "  rails db:create db:migrate"
  say "  rails g madmin:install # Generate admin dashboards"
  say "  gem install foreman"
  say "  foreman start # Run Rails, sidekiq, and webpack-dev-server"
end
