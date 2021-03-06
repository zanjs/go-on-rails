class GorGenerator < Rails::Generators::Base
  source_root File.expand_path('../templates', __FILE__)
  argument :env_name, type: :string, default: "development"
  class_option :models, type: :array, default: [], aliases: '-m'
  class_option :only_models, type: :boolean, default: false, aliases: '-o', description: "only generate models"

  def generate_gor
    env_names = ActiveRecord::Base.configurations.keys
    rails_env = case env_name
                when "dev"
                  "development"
                when "pro"
                  "production"
                else
                  env_name
                end

    unless env_names.include? rails_env
      printf("Invalid env argument \"%s\": Not in the available list %p\n\n", rails_env, env_names)
      exit
    end

    @models = options[:models]
    if @models.empty?
      @models = get_all_models "app/models"
    else
      @models.map!(&:camelize)
    end
    puts "Rails env: [#{rails_env}]"
    puts "The models: #{@models} will be converted to a Golang App!"

    # read the database configuration
    @db_config = {}
    read_database_config(rails_env)

    # iterate the models to generate Go codes
    @models.each do |m|
      begin
        klass = m.split('::').inject(Object) { |kls, part| kls.const_get(part) }
        if klass < ActiveRecord::Base && !klass.abstract_class?
          @model_name = klass.to_s
          convertor = GoOnRails::Convertor.new(klass, @models)
          @struct_info = convertor.convert
          template "gor_model.go.erb", "go_app/models/gor_#{@model_name.underscore}.go"
        end
      rescue Exception => e
        puts "Failed to convert the model [#{m}]: #{e.message}"
      end
    end

    # generate program for database connection
    template "db.go.erb", "go_app/models/db.go"

    unless options[:only_models]
      # generate the main.go
      copy_file "main.go", "go_app/main.go"
      # generate the controllers and views dir
      template "home_controller.go.erb", "go_app/controllers/home_controller.go"
      copy_file "index.tmpl", "go_app/views/index.tmpl"
      copy_file "favicon.ico", "go_app/public/favicon.ico"
    end

    # use gofmt to prettify the generated Golang files
    gofmt_go_files

    # generate go docs for models
    generate_go_docs
  end

  private

  def get_all_models model_dir
    Dir.chdir(model_dir) do
      Dir["**/*.rb"]
    end.map { |m| m.sub(/\.rb$/,'').camelize } - ["ApplicationRecord"]
  end

  def read_database_config rails_env
    db_conf = Rails.configuration.database_configuration[rails_env]
    db_conf["host"] = "localhost" unless db_conf["host"]
    case db_conf["adapter"]
    when "sqlite3"
      @db_config[:driver_name] = "sqlite3"
      @db_config[:dsn] = "../" + db_conf["database"]
      @db_config[:driver_package] = "_ \"github.com/mattn/go-sqlite3\""
    when "mysql2"
      @db_config[:driver_name] = "mysql"
      db_conf["port"] = 3306 unless db_conf["port"]
      # MySQL DSN format: username:password@protocol(address)/dbname?param=value
      # See more: https://github.com/go-sql-driver/mysql
      format = "%s:%s@tcp(%s:%s)/%s?charset=%s&parseTime=True&loc=Local"
      @db_config[:dsn] = sprintf(format, *db_conf.values_at("username", "password", "host", "port", "database", "encoding"))
      @db_config[:driver_package] = "_ \"github.com/go-sql-driver/mysql\""
    when "postgresql"
      @db_config[:driver_name] = "postgres"
      format = "host=%s user=%s dbname=%s sslmode=disable password=%s"
      @db_config[:dsn] = sprintf(format, *db_conf.values_at("host", "username", "database", "password"))
      @db_config[:driver_package] = "_ \"github.com/lib/pq\""
    end
  end

  def gofmt_go_files
    go_files = Rails.root.join('go_app', 'models/*.go').to_s
    system "gofmt -w #{go_files} > /dev/null 2>&1"
  end

  def generate_go_docs
    models_dir = Rails.root.join('go_app', 'models').to_s
    return unless Dir.exist?(File.expand_path(models_dir))
    doc_dir = File.join(models_dir, "doc")
    Dir.mkdir(doc_dir) unless Dir.exist?(doc_dir)
    system "godoc -html #{models_dir} | awk '{ gsub(\"/src/target\", \"\"); print }' > #{doc_dir}/models.html"
  end
end

require_relative 'go-on-rails/converter'
