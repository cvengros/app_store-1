# utf-8
require 'open-uri'
require 'csv'
require 'gooddata'

module GoodData::Bricks

  class UsersBrick < GoodData::Bricks::Brick
    MODES = %w(add_only_to_domain sync_domain_and_project sync_multiple_projects_based_on_pid sync_one_project_based_on_pid sync_one_project_based_on_custom_id)

    def version
      "0.0.1"
    end

    def call(params)
      client = params['GDC_GD_CLIENT'] || fail('client needs to be passed into a brick as "GDC_GD_CLIENT"')
      domain_name = params['domain']
      project = client.projects(params['gdc_project']) || client.projects(params['GDC_PROJECT_ID'])
      csv_path = params['csv_path']
      mode = params['sync_mode']
      unless mode.nil? || MODES.include?(mode)
        fail "The parameter \"sync_mode\" has to have one of the values #{MODES.map(&:to_s).join(', ')} or has to be empty."
      end

      whitelists = params['whitelists'] || [client.user.login]
      multiple_projects_column = params['multiple_projects_column']

      # Check mandatory columns and parameters
      mandatory_params = [domain_name, csv_path]

      mandatory_params.each do |param|
        fail param+' is required in the block parameters.' unless param
      end

      domain = client.domain(domain_name)

      first_name_column   = params['first_name_column'] || 'first_name'
      last_name_column    = params['last_name_column'] || 'last_name'
      login_column        = params['login_column'] || 'login'
      password_column     = params['password_column'] || 'password'
      email_column        = params['email_column'] || 'email'
      role_column         = params['role_column'] || 'role'
      sso_provider_column = params['sso_provider_column'] || 'sso_provider'


      sso_provider = params['sso_provider']
      ignore_failures = params['ignore_failures'] == "true" || params['ignore_failures'] == true ? true : false

      new_users = []
      
      CSV.foreach(File.open(csv_path, 'r:UTF-8'), :headers => true, :return_headers => false, encoding:'utf-8') do |row|
        new_users << {
          :first_name => row[first_name_column],
          :last_name => row[last_name_column],
          :login => row[login_column],
          :password => row[password_column],
          :email => row[email_column] || row[login_column],
          :role => row[role_column],
          :domain => domain_name,
          :sso_provider => sso_provider || row[sso_provider_column],
          :pid => multiple_projects_column.nil? ? nil : row[multiple_projects_column]
        }
      end

      # There are several scenarios we want to provide with this brick
      # 1) Sync only domain
      # 2) Sync both domain and project
      # 3) Sync multiple projects. Sync them by using one file. The file has to
      #     contain additional column that contains the PID of the project so the
      #     process can partition the users correctly. The column is configurable
      # 4) Sync one project the users are filtered based on a column in the data
      #     that should contain pid of the project
      # 5) Sync one project. The users are filtered form a given file based on the
      #     value in the file. The value is compared against the value
      #     GOODOT_CUSTOM_PROJECT_ID that is saved in project metadata. This is
      #     aiming at solving the problem that the customer cannot give us the
      #     value of a project id in the data since he does not know it upfront
      #     and we cannot influence its value.
      case mode
      when 'add_only_to_domain'
        domain.create_users(new_users, :ignore_failures => ignore_failures)
      when 'sync_multiple_projects_based_on_pid'
        new_users.group_by {|u| u[:pid]}.map do |project_id, users|
          project = client.projects(project_id)
          project.import_users(users, domain: domain, whitelists: whitelists, ignore_failures: ignore_failures)
        end
      when 'sync_one_project_based_on_pid'
        filtered_users = new_users.select { |u| u[:pid] == project.pid }
        project.import_users(filtered_users, domain: domain, whitelists: whitelists, ignore_failures: ignore_failures)
      when 'sync_one_project_based_on_custom_id'
        md = project.metadata
        if md['GOODOT_CUSTOM_PROJECT_ID']
          filter_value = md['GOODOT_CUSTOM_PROJECT_ID']
          filtered_users = new_users.select { |u| u[:pid] == filter_value }
          project.import_users(filtered_users, domain: domain, whitelists: whitelists, ignore_failures: ignore_failures)
        else
          fail "Project \"#{project.pid}\" metadata does not contain key GOODOT_CUSTOM_PROJECT_ID. We are unable to get the value to filter users."
        end
      else
        domain.create_users(new_users, :ignore_failures => ignore_failures)
        project.import_users(new_users , domain: domain, whitelists: whitelists, ignore_failures: ignore_failures)
      end
    end
  end
end