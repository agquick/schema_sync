require "schema_sync/version"
require "schema_sync/model"

# TODO:
# 1. Add 'cleanup' rake method to remove columns and tables
#
module SchemaSync
  # Your code goes here...
  
  class Railtie < Rails::Railtie
    railtie_name :schema_sync
    rake_tasks do
      load File.expand_path("../../tasks/db.rake", __FILE__)
    end
  end

  def self.models
    @models ||= []
  end

  def self.base_models
    @base_models ||= {}
  end
  
  def self.models_with_database(database)
    conf = ActiveRecord::Base.configurations[database]
    raise "Configuration for database #{database} not found" if conf.nil?
    conf = conf.symbolize_keys
    return self.models.select {|m|
      mc = m.connection_config
      mc[:host] == conf[:host] && mc[:port] == conf[:port] && mc[:database] == conf[:database]
    }
  end

  def self.has_multiple_databases?
    c = ActiveRecord::Base.configurations
    if c.respond_to?(:configs_for)
      return c.configs_for(env_name: Rails.env).length > 1
    else
      return false
    end
  end

  def self.register_model(m)
    if !self.models.include?(m)
      self.models << m
    end
  end

  def self.register_base_model(model, database)
    self.base_models[database] = model
  end

  def self.load_models
    Dir[Rails.root + 'app/models/**/*.rb'].each do |path|
      require path
    end
  end

  def self.logger
    if @logger.nil? && defined?(Rails)
      @logger = Rails.logger
    end
    @logger
  end

  def self.logger=(val)
    @logger = val
  end

  ##
  # Computes changes based on schema and models. For now, this should only
  # determine additions. Removals of tables, columns, or indexes need to
  # be done through a manual migration.
  #
  def self.compute_changes(opts={})
    do_cleanup = opts[:clean]==true || false

    # check database option
    db = opts[:database]
    if has_multiple_databases? && db.nil?
      raise "This app has multiple databases. Please add the database=<name> option."
    end

    # load models
    puts "Loading all models..."
    self.load_models

    puts "Computing changes... (cleanup: #{do_cleanup})"
    changes = []
    models = db.nil? ? self.models : self.models_with_database(db)
    existing_table_names = self.existing_table_names(db)
    model_table_names = models.collect {|m| m.table_name}
    active_columns = self.active_columns(models)
    schema_columns = self.schema_columns(models)
    active_indexes = self.active_indexes(models)
    schema_indexes = self.schema_indexes(models)

    # determine tables needed to add (in models but not in database)
    add_table_names = model_table_names - existing_table_names
    add_table_names.each do |t|
      changes << {action: :create_table, table_name: t}
    end

    # determine columns needed to add
    schema_columns.each do |key, c|
      if !(sc = active_columns[key]).nil?
        # TODO: column exists, check if needs changes
        # check if type or default changed
      else
        changes << {action: :add_column, table_name: c[:table_name], field: c}
      end
    end

    # determine indexes needed to add
    schema_indexes.each do |key, idx|
      if !(sc = active_indexes[key]).nil?
        # TODO: index exists, check if needs changes
        # check if type or default changed
      else
        changes << {action: :add_index, table_name: idx[:table_name], index: idx}
      end
    end

    # determine enhancements needed
    models.each do |m|
      m.schema_enhancements.each do |e|
        # TODO: handle enhancements here
      end
    end

    if do_cleanup
      # determine tables that can be removed
      remove_table_names = existing_table_names - model_table_names
      remove_table_names.each do |t|
        changes << {action: :drop_table, table_name: t}
      end

      # determine active fields that can be removed
      active_columns.each do |key, c|
        next if c[:name] == 'id'
        next if remove_table_names.include?(c[:table_name])
        if schema_columns[key].nil? && !schema_columns.values.any?{|mc| mc[:table_name] == c[:table_name] && mc[:rename_from] && mc[:rename_from].to_s == c[:name].to_s}
          changes << {action: :remove_column, table_name: c[:table_name], column: c[:column]}
        end
      end

      # determine active indexes that can be removed
      active_indexes.each do |key, idx|
        next if remove_table_names.include?(idx[:table_name])
        if schema_indexes[key].nil?
          changes << {action: :remove_index, table_name: idx[:table_name], columns: idx[:columns], index: idx}
        end
      end

    end

    return changes
  end

  def self.existing_table_names(database=nil)
    ret = []
    if database
      ret = self.base_models[database].connection.tables
    else
      ret = ActiveRecord::Base.connection
    end
    return ret - ["schema_migrations"]
  end

  def self.active_columns(models)
    ret = {}
    models.each do |m|
      next if !m.table_exists?
      tn = m.table_name
      m.columns.each do |c|
        ret["#{tn}/#{c.name}"] = {table_name: tn, name: c.name, column: c}
      end
    end
    return ret
  end

  def self.schema_columns(models)
    ret = {}
    models.each do |m|
      tn = m.table_name
      m.schema_fields.values.each do |f|
        k = "#{tn}/#{f[:name]}"
        ret[k] = f
      end
    end
    return ret
  end

  def self.active_indexes(models)
    ret = {}
    models.each do |m|
      next if !m.table_exists?
      tn = m.table_name
      m.connection.indexes(tn).each do |idx|
        ret["#{tn}/#{idx.columns.join("|")}"] = {table_name: tn, columns: idx.columns, name: idx.name}
      end
    end
    return ret
  end

  def self.schema_indexes(models)
    ret = {}
    models.each do |m|
      tn = m.table_name
      m.schema_indexes.values.each do |idx|
        ret["#{tn}/#{idx[:columns].join("|")}"] = idx
      end
    end
    return ret
  end

  def self.build_migrations(changes, opts={})
    prompt = opts.key?(:prompt) ? opts[:prompt] : false
    write = opts.key?(:write) ? opts[:write] : false
    rs = opts[:hash] || self.random_string
    db = opts[:database]
    rails_ver = Rails.version
    mgr_cls = "ActiveRecord::Migration"
    if rails_ver[0].to_i > 4
      mgr_cls = "ActiveRecord::Migration[#{rails_ver[0..2]}]"
    end

    s = "### Generated by SchemaSync"
    s << "\nclass SchemaSync#{rs.capitalize} < #{mgr_cls}"
    s << "\n\tdef change"
    changes.each do |c|
      s << "\n\t\t"
      case c[:action]
      when :create_table
        s << "create_table :#{c[:table_name]}"
      when :drop_table
        s << "drop_table :#{c[:table_name]}"
      when :add_column
        f = c[:field]
        copts = f.except(:name, :type, :table_name, :schema_type, :to_api, :scope, :index)
        if f[:rename_from]
          s << "rename_column :#{f[:table_name]}, :#{f[:rename_from]}, :#{f[:name]}"
        else
          s << "add_column :#{f[:table_name]}, :#{f[:name]}, :#{f[:schema_type]}"
          if !copts.empty?
            s << ", #{copts}"
          end
        end
      when :remove_column
        cl = c[:column]
        s << "remove_column :#{c[:table_name]}, :#{cl.name}"
      when :add_index
        idx = c[:index]
        iopts = idx.except(:table_name, :fields, :columns)
        ifs = idx[:fields].length == 1 ? idx[:fields].first.inspect : idx[:fields].to_s
        s << "add_index :#{idx[:table_name]}, #{ifs.to_s}"
        if !iopts.empty?
          s << ", #{iopts}"
        end
      when :remove_index
        idx = c[:index]
        s << "remove_index :#{c[:table_name]}, name: \"#{idx[:name].to_s}\""
      when :add_timestamps
        s << "add_timestamps :#{c[:table_name]}"
        copts = c[:opts]
        if !copts.empty?
          s << ", #{copts}"
        end
      end
    end
    s << "\n\tend"
    s << "\nend"
    if write == true
      subdir = "db/migrate"
      if has_multiple_databases?
        subdir = ActiveRecord::Base.configurations[db]["migrations_paths"] || subdir
      end
      dir = Rails.root.join(subdir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      fn = File.join dir, "#{timestamp}_schema_sync_#{rs}.rb"
      FileUtils.mkdir_p dir
      File.open fn, "w" do |f|
        f.write(s)
      end
      return {text: s, filename: fn}
    else 
      return {text: s}
    end
  end

  def self.schema_type_for(type)
    case type.to_s
    when "Time"
      :datetime
    when "Hash"
      :jsonb
    when "Float"
      :decimal
    when "reference", "ref"
      :bigint
    else
      type.to_s.downcase.to_sym
    end
  end

  def self.random_string(len=5)
    ('a'..'z').to_a.shuffle[0,len].join
  end

end
